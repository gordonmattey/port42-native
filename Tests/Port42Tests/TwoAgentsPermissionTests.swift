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

    @Test("another instance's agent wakes one of yours only after the person says yes, once (decision 3)")
    func crossWakeCard() async throws {
        let w = try makeParityWorld()
        let alba = try companion(w, "alba", in: w.space)
        let panelId = try #require(w.state.spawnNativeTerminalPort(
            command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id, title: "alba",
            companionName: "alba", companionId: alba.id, systemPrompt: nil, postCard: false))
        _ = panelId
        let id = try board(w, in: w.space)
        let peer = "peer-gordon11"
        w.state.grantRemoteRights([.see, .use, .wakeAgents], to: peer, onPort: id)
        let bram = Principal.remote(peer: peer, displayName: "gordon11").acting(as: RemoteActor(id: "B1", name: "bram", kind: .companion))
        w.state.pendingTerminalInjections = [:]
        w.state.chatReplyTargets = [:]

        _ = try w.state.postToChat(key: id, text: "@alba what do you think", from: bram)
        for _ in 0..<400 where w.state.permissions.current == nil { await Task.yield() }
        #expect(w.state.permissions.current?.permission == .crossWake, "no card before another machine's agent woke yours")
        #expect(w.state.chatReplyTargets["alba"] == nil, "alba woke before the person said yes")
        w.state.permissions.resolveCurrent(granted: true)
        for _ in 0..<400 where w.state.chatReplyTargets["alba"] == nil { await Task.yield() }
        #expect(w.state.chatReplyTargets["alba"] == id, "the yes did not wake alba")

        w.state.chatReplyTargets = [:]
        _ = try w.state.postToChat(key: id, text: "@alba and again", from: bram)
        #expect(w.state.permissions.current == nil, "asked again for the same agent, companion and port")
        #expect(w.state.chatReplyTargets["alba"] == id, "the remembered yes did not wake alba")

        // Another agent there is its own pair: asked again, and a no wakes nobody.
        w.state.chatReplyTargets = [:]
        let cora = Principal.remote(peer: peer, displayName: "gordon11").acting(as: RemoteActor(id: "C1", name: "cora", kind: .companion))
        _ = try w.state.postToChat(key: id, text: "@alba hello", from: cora)
        for _ in 0..<400 where w.state.permissions.current == nil { await Task.yield() }
        #expect(w.state.permissions.current?.permission == .crossWake)
        w.state.permissions.resolveCurrent(granted: false)
        for _ in 0..<50 { await Task.yield() }
        #expect(w.state.chatReplyTargets["alba"] == nil, "a no still woke alba")
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
            sent += 1
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
