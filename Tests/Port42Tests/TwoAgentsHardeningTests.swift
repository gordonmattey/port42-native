import Testing
import Foundation
@testable import Port42Lib

// Two instances, an agent on each side, on one shared port: Phase 1 (docs/plan-two-agents-one-port.md).

@Suite("two agents: hardening")
@MainActor
struct TwoAgentsHardeningTests {
    @Test("a terminal line carries only text: control characters go, line breaks stay")
    func terminalSafe() {
        let line = ChatRouting.terminalLine(sender: "bram\u{1b}[Z (gordon11)", source: "port \u{1b}]0;x\u{07}",
                                            text: "hi\u{1b}[Z\u{1b}[200~ls\rrm\tx\u{03}\u{9b}31m\nnext line")
        #expect(!line.dropLast().unicodeScalars.contains { $0.value < 0x20 && $0.value != 0x0A }, "a control character reached the line: \(line.debugDescription)")
        #expect(!line.unicodeScalars.contains { (0x80...0x9F).contains($0.value) || $0.value == 0x7F })
        #expect(line.contains("next line") && line.contains("\n"), "a line break was lost")
        #expect(line.hasSuffix("\r"), "the line no longer submits")
        #expect(line.filter { $0 == "\r" }.count == 1, "a carriage return inside the text would submit early")
    }

    @Test("a mention from another instance wakes a companion but never adds it to the space")
    func remoteMentionDoesNotJoin() throws {
        let w = try makeParityWorld()
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let key = try #require(made["id"] as? String)
        let alba = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: "alba", command: "claude",
                                             systemPrompt: nil, trigger: .mentionOnly)
        try w.state.db.saveAgent(alba)
        w.state.companions.append(alba)
        let guest = "guestpeerkey"
        w.state.grantRemoteRights([.see, .use, .wakeAgents], to: guest, onPort: key)
        _ = try w.state.postToChat(key: key, text: "@alba please look", from: .remote(peer: guest, displayName: "bram (gordon11)"))
        let members = try w.state.db.getAgentsForSpace(spaceId: w.space.id).map(\.id)
        #expect(!members.contains(alba.id), "another instance's mention added a companion to the space")

        // A local mention in a port's chat gives the companion that port, not the space (two agents, decision 1).
        _ = try w.state.postToChat(key: key, text: "@alba please look", from: w.principal)
        #expect(!(try w.state.db.getAgentsForSpace(spaceId: w.space.id).map(\.id).contains(alba.id)),
                "a mention in a port's chat added the companion to the whole space")
        #expect(w.state.isPortMember(alba.id, port: key), "a mention in a port's chat did not give the companion the port")
    }

    static let me = "25njqamcweflpvkl73j4szahhihoc4xt3ktcgjnpaingr5yhkena"
    static let host = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"

    @Test("a call naming a shared tile passes the caller's scope before anything is sent")
    func tileScopeBeforeForward() async throws {
        let w = try makeParityWorld()
        w.state.door.receive(#"{"type":"welcome","sender_id":"host","self_peer":"\#(Self.me)"}"#)
        // Anything sent is answered with an error at once, so a call that should never have gone out
        // fails this test instead of hanging it.
        var sent = 0
        let door = w.state.door
        door.sendOverride = { [weak door] text in
            guard text.contains("remote_call"),
                  let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let id = o["call_id"] as? String else { return }
            sent += 1
            Task { @MainActor in door?.receive(#"{"type":"error","code":"transport_failed","error":"sent","call_id":"\#(id)"}"#) }
        }
        let away = Space.create(name: "away")
        try w.state.db.saveSpace(away)
        w.state.spaces.append(away)
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: away.id, createdBy: nil, createdByName: nil)
        let tile = try #require(made["id"] as? String)
        try w.state.db.upsertRemotePort(.init(peerKey: Self.host, portKey: "P", title: "board", rights: [.see, .use, .edit],
                                              relays: ["wss://relay.test/v1"], hostName: "Gordon"))
        try w.state.db.setRemotePortTile(peerKey: Self.host, portKey: "P", localPort: tile)

        let outsider = Principal.companion(id: w.companion.id, displayName: w.companion.displayName, spaceId: w.space.id)
        do {
            _ = try await w.state.runBridgeMethod("port.getHtml", principal: outsider, args: BridgeArgs(["id": tile]))
            Issue.record("a companion in another space reached the tile")
        } catch let e as BridgeError { #expect(e.code == "not_found", "refused as \(e.code)") }
        catch { Issue.record("refused with \(error)") }
        #expect(sent == 0, "the call was sent to the other instance before the scope check")
    }
}
