import Testing
import Foundation
@testable import Port42Lib

// Two instances, an agent on each side, on one shared port: Phase 4, UX (docs/plan-two-agents-one-port.md).

@Suite("two agents: bring a companion, the shared chat", .serialized)
@MainActor
struct TwoAgentsUXTests {
    static let me = "25njqamcweflpvkl73j4szahhihoc4xt3ktcgjnpaingr5yhkena"
    static let host = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"

    func tileWorld() throws -> (ParityWorld, String) {
        let w = try makeParityWorld()
        w.state.door.receive(#"{"type":"welcome","sender_id":"host","self_peer":"\#(Self.me)"}"#)
        w.state.door.sendOverride = { _ in }
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let tile = try #require(made["id"] as? String)
        var row = DatabaseService.RemotePortRow(peerKey: Self.host, portKey: "P", title: "Shared board", rights: [.see, .use, .edit],
                                                relays: ["wss://relay.test/v1"], hostName: "Gordon")
        row.knownAs = "gordon11"
        try w.state.db.upsertRemotePort(row)
        try w.state.db.setRemotePortTile(peerKey: Self.host, portKey: "P", localPort: tile)
        return (w, tile)
    }

    @Test("bringing a companion onto a tile makes it a member and tells it where it is and to answer in the port's chat")
    func bringOnto() throws {
        let (w, tile) = try tileWorld()
        var bram = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: "bram", command: "claude",
                                             systemPrompt: nil, trigger: .mentionOnly)
        bram.openInTerminal = true
        try w.state.db.saveAgent(bram)
        w.state.companions.append(bram)
        _ = try #require(w.state.spawnNativeTerminalPort(command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id,
                                                         title: "bram", companionName: "bram", companionId: bram.id,
                                                         systemPrompt: nil, postCard: false))
        let key = try #require(w.state.mirrorChatKey(tile))
        #expect(w.state.sharedChatLabel(key)?.contains("Gordon") == true, "the tile's chat does not say it is shared")
        w.state.pendingTerminalInjections = [:]
        w.state.chatReplyTargets = [:]
        w.state.bringOnto(tile: tile, companions: [bram])
        #expect(w.state.isPortMember(bram.id, port: key), "the companion was not brought onto the tile")
        #expect(w.state.chatReplyTargets["bram"] == key, "the companion was not told, or its reply would not reach the port's chat")
        let told = (w.state.pendingTerminalInjections.values.flatMap { $0 }).joined()
        #expect(told.contains("Shared board") && told.contains("reply in that chat") && told.contains("shared from Gordon") && told.contains("work with the agents on Gordon on this port"),
                "the companion was not told where it is: \(told)")
        #expect(w.state.sharedChatLabel(key)?.contains("bram") == true, "the shared chat does not list the companion")
    }

    @Test("a port this machine shares says so in its chat")
    func hostSideLabel() throws {
        let w = try makeParityWorld()
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let key = try #require(made["id"] as? String)
        #expect(w.state.sharedChatLabel(key) == nil, "an unshared port's chat says it is shared")
        w.state.grantRemoteRights([.see, .use], to: "guestpeer", onPort: key)
        #expect(w.state.sharedChatLabel(key)?.hasPrefix("shared chat with") == true)
    }

    @Test("the host tells the guest, on the port's topic, when its rights change or sharing stops")
    func hostAnnouncesAccess() throws {
        let w = try makeParityWorld()
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let key = try #require(made["id"] as? String)
        var heard: [[String: Any]] = []
        _ = w.state.notifyBus.subscribe(topic: PortNotify.topic(forPortKey: key)) { json in
            if let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], o["kind"] as? String == "access" { heard.append(o) }
        }
        w.state.grantRemoteRights([.see, .use], to: "guestpeer", onPort: key)
        w.state.stopSharing(peer: "guestpeer", port: key)
        let last = try #require(heard.last?["payload"] as? [String: Any], "the guest was not told sharing stopped")
        #expect(last["peer"] as? String == "guestpeer")
        #expect((last["rights"] as? [Any])?.isEmpty == true, "the last notice does not say no longer shared")
    }

    @Test("a guest told sharing stopped shows it on the tile and in its chat")
    func guestShowsEnded() throws {
        let (w, tile) = try tileWorld()
        let row = try #require(w.state.mirroredRemote(tile))
        w.state.mirrorStatus[tile] = MirrorStatus(hostName: "Gordon", online: true)
        let key = try #require(w.state.mirrorChatKey(tile))
        w.state.mirrorEvent(tile: tile, row: row, ["kind": "access", "payload": ["peer": "someone-else", "rights": []]])
        #expect(w.state.sharePill(tile: tile, key: key) == .theirs(host: "Gordon", online: true), "another machine's notice changed this tile")
        w.state.mirrorEvent(tile: tile, row: row, ["kind": "access", "payload": ["peer": Self.me, "rights": ["see"]]])
        #expect(w.state.mirroredRemote(tile)?.rights == [.see], "the tile did not take its new rights")
        w.state.mirrorEvent(tile: tile, row: row, ["kind": "access", "payload": ["peer": Self.me, "rights": []]])
        #expect(w.state.sharePill(tile: tile, key: key) == .ended(host: "Gordon"), "the tile does not show sharing stopped")
        #expect(try w.state.db.chatEntries(chat: key, after: 0, limit: 50).contains { $0.text.contains("stopped sharing") },
                "nothing in the tile's chat says so")
    }

    @Test("a companion woken from two chats in one turn answers in both (the round 4 stall)")
    func replyGoesToEveryChatThatAsked() throws {
        let w = try makeParityWorld()
        var alba = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: "alba", command: "claude",
                                             systemPrompt: nil, trigger: .mentionOnly)
        alba.openInTerminal = true
        try w.state.db.saveAgent(alba)
        w.state.companions.append(alba)
        w.state.deliverToTerminalCompanion(alba, line: "from the board", replyChat: "BOARD", spaceId: w.space.id)
        w.state.deliverToTerminalCompanion(alba, line: "from its own chat", replyChat: "OWN", spaceId: w.space.id)
        let targets = w.state.takeReplyTargets(companion: "alba", ownTerminalChat: "TERMINAL")
        #expect(targets == ["OWN", "BOARD"], "the answer did not go to both chats that asked: \(targets)")
        #expect(w.state.takeReplyTargets(companion: "alba", ownTerminalChat: "TERMINAL") == ["TERMINAL"],
                "the next turn still answers the last turn's chats")
        w.state.deliverToTerminalCompanion(alba, line: "again", replyChat: "BOARD", spaceId: w.space.id)
        w.state.deliverToTerminalCompanion(alba, line: "and again", replyChat: "BOARD", spaceId: w.space.id)
        #expect(w.state.takeReplyTargets(companion: "alba", ownTerminalChat: "TERMINAL") == ["BOARD"], "one chat was answered twice")
    }

    @Test("any post on this machine in a tile's chat wakes this machine's companions it names, never the sender")
    func localPostsWakeLocalCompanions() async throws {
        let (w, tile) = try tileWorld()
        let door = w.state.door
        door.sendOverride = { [weak door] text in       // the host takes the post
            guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  o["type"] as? String == "remote_call", let cid = o["call_id"] as? String else { return }
            let reply = #"{"type":"response","call_id":"\#(cid)","payload":{"senderName":"host","senderType":"host","content":"{\"ok\":true}"}}"#
            Task { @MainActor in door?.receive(reply) }
        }
        func companion(_ name: String) throws -> AgentConfig {
            var c = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: name, command: "claude",
                                              systemPrompt: nil, trigger: .mentionOnly)
            c.openInTerminal = true
            try w.state.db.saveAgent(c); w.state.companions.append(c)
            return c
        }
        let bram = try companion("bram"), cora = try companion("cora")
        let key = try #require(w.state.mirrorChatKey(tile))
        w.state.addPortMember(bram.id, port: key)                           // bram is on the tile
        w.state.chatReplyTargets = [:]
        // bram hands off to cora in the shared chat: a companion's post, not the person's.
        let asBram = Principal.companion(id: bram.id, displayName: "bram", spaceId: w.space.id)
        _ = try await w.state.runBridgeMethod("chat.post", principal: asBram, args: BridgeArgs(["port": tile, "text": "@cora please review, and @bram notes"]))
        #expect(w.state.chatReplyTargets["cora"] == key, "a companion's mention of another companion here woke nobody")
        #expect(w.state.isPortMember(cora.id, port: key), "the mention did not bring cora onto the tile")
        #expect(w.state.chatReplyTargets["bram"] == nil, "the sender woke itself")
        // A script on this machine does the same.
        w.state.chatReplyTargets = [:]
        _ = try await w.state.runBridgeMethod("chat.post", principal: .peer(id: "cli", displayName: "cli"),
                                              args: BridgeArgs(["port": tile, "text": "@bram over to you"]))
        #expect(w.state.chatReplyTargets["bram"] == key, "a script's mention here woke nobody")
    }
}
