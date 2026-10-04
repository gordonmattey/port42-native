import Testing
import Foundation
@testable import Port42Lib

// Two instances, an agent on each side, on one shared port: Phase 3, permissions
// (docs/plan-two-agents-one-port.md, decisions 1 to 3).

@Suite("two agents: permissions", .serialized)
@MainActor
struct TwoAgentsPermissionTests {
    func board(_ w: ParityWorld, in space: Space) throws -> String {
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title><h1>b</h1>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: space.id, createdBy: nil, createdByName: nil)
        return try #require(made["id"] as? String)
    }
    func companion(_ w: ParityWorld, _ name: String, in space: Space?) throws -> AgentConfig {
        var a = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: name, command: "claude",
                                          systemPrompt: nil, trigger: .mentionOnly)
        a.openInTerminal = true
        try w.state.db.saveAgent(a)
        w.state.companions.append(a)
        if let space { w.state.joinCompanionToSpace(a, spaceId: space.id) }
        return a
    }

    @Test("a mention in a port's chat gives the companion that port only (decision 1)")
    func mentionGivesThePort() async throws {
        let w = try makeParityWorld()
        let away = Space.create(name: "away"); try w.state.db.saveSpace(away); w.state.spaces.append(away)
        let alba = try companion(w, "alba", in: away)                       // lives in another space
        let id = try board(w, in: w.space)
        let other = try board(w, in: w.space)
        let asAlba = Principal.companion(id: alba.id, displayName: "alba", spaceId: away.id)
        await #expect(throws: BridgeError.self) { _ = try await w.state.runBridgeMethod("port.getHtml", principal: asAlba, args: BridgeArgs(["id": id])) }
        _ = try w.state.postToChat(key: id, text: "@alba have a look", from: w.principal)
        _ = try await w.state.runBridgeMethod("port.getHtml", principal: asAlba, args: BridgeArgs(["id": id]))
        await #expect(throws: BridgeError.self, "the mention gave the whole space") {
            _ = try await w.state.runBridgeMethod("port.getHtml", principal: asAlba, args: BridgeArgs(["id": other]))
        }
        #expect(!(try w.state.db.getAgentsForSpace(spaceId: w.space.id).map(\.id).contains(alba.id)))
    }

    @Test("another instance's agent wakes a companion on the shared port with no card; one not on the port stays asleep")
    func noSecondCard() async throws {
        let w = try makeParityWorld()
        let alba = try companion(w, "alba", in: w.space)
        _ = try #require(w.state.spawnNativeTerminalPort(
            command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id, title: "alba",
            companionName: "alba", companionId: alba.id, systemPrompt: nil, postCard: false))
        let away = Space.create(name: "away"); try w.state.db.saveSpace(away); w.state.spaces.append(away)
        _ = try companion(w, "cora", in: away)
        let id = try board(w, in: w.space)
        let peer = "peer-gordon11"
        w.state.grantRemoteRights([.see, .use, .wakeAgents], to: peer, onPort: id)
        let bram = Principal.remote(peer: peer, displayName: "gordon11").acting(as: RemoteActor(id: "B1", name: "bram", kind: .companion))
        w.state.chatReplyTargets = [:]
        _ = try w.state.postToChat(key: id, text: "@alba what do you think, and @cora?", from: bram)
        for _ in 0..<50 { await Task.yield() }
        #expect(w.state.permissions.current == nil, "asked again what sharing with wake on already settled")
        #expect(w.state.chatReplyTargets["alba"] == id, "the companion on the port did not wake")
        #expect(w.state.chatReplyTargets["cora"] == nil, "a companion in another space woke from the other computer")
        _ = alba
    }

    static let me = "25njqamcweflpvkl73j4szahhihoc4xt3ktcgjnpaingr5yhkena"
    static let host = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"

    @Test("on a tile, only companions the person brought onto it act on it (decision 2)")
    func tileMembersOnly() async throws {
        let w = try makeParityWorld()
        w.state.door.receive(#"{"type":"welcome","sender_id":"host","self_peer":"\#(Self.me)"}"#)
        let door = w.state.door
        var sent = 0
        door.sendOverride = { [weak door] text in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  o["type"] as? String == "remote_call", let cid = o["call_id"] as? String else { return }
            // Only calls someone made: the tile's own refresh (no actor) can land mid-test on a loaded machine.
            if o["actor"] != nil { sent += 1 }
            let reply = #"{"type":"response","call_id":"\#(cid)","payload":{"senderName":"host","senderType":"host","content":"\"<p>x</p>\""}}"#
            Task { @MainActor in door?.receive(reply) }
        }
        let tile = try board(w, in: w.space)
        try w.state.db.upsertRemotePort(.init(peerKey: Self.host, portKey: "P", title: "board", rights: [.see, .use, .edit],
                                              relays: ["wss://relay.test/v1"], hostName: "Gordon"))
        try w.state.db.setRemotePortTile(peerKey: Self.host, portKey: "P", localPort: tile)
        let bram = try companion(w, "bram", in: w.space)                     // in the tile's own space
        let asBram = Principal.companion(id: bram.id, displayName: "bram", spaceId: w.space.id)
        await #expect(throws: BridgeError.self, "a companion not brought onto the tile used it") {
            _ = try await w.state.runBridgeMethod("port.getHtml", principal: asBram, args: BridgeArgs(["id": tile]))
        }
        #expect(sent == 0)
        let key = try #require(w.state.mirrorChatKey(tile))
        w.state.wakeOwnCompanions(key: key, text: "@bram have a look", fromName: "Gordon", fromId: "u")
        _ = try await w.state.runBridgeMethod("port.getHtml", principal: asBram, args: BridgeArgs(["id": tile]))
        #expect(sent == 1, "the person brought bram in and his call was still refused")
        let person = Principal.human(id: "u", displayName: "Gordon", spaceId: w.space.id)
        _ = try await w.state.runBridgeMethod("port.getHtml", principal: person, args: BridgeArgs(["id": tile]))
        #expect(sent == 2, "the person could not use their own tile")
    }
}
