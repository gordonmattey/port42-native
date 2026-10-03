import Testing
import Foundation
@testable import Port42Lib

// Two instances, an agent on each side, on one shared port: Phase 6, addressing and machine names
// (docs/plan-two-agents-one-port.md). In the realistic run bram wrote alba's name with his own machine
// (`@alba%20%28gordon11%29`) and woke nobody, silently.

@Suite("two agents: names and mentions in a shared chat")
struct SharedChatNameTests {
    @Test("a shared chat's name splits into the name and its machine")
    func split() {
        #expect(ChatRouting.splitLabel("alba (Gordon's MacBook Pro)") == ("alba", "Gordon's MacBook Pro"))
        #expect(ChatRouting.splitLabel("alba") == ("alba", nil))
        #expect(ChatRouting.splitLabel("(odd)") == ("(odd)", nil))
        #expect(ChatRouting.plainName("bram (gordon11)") == "bram")
    }

    @Test("a mention of a companion here with any machine after it is that companion, unless the other machine has one called exactly that")
    func localized() {
        let bug = "@alba220752%20%28gordon11%29 your turn"
        #expect(ChatRouting.localizedMentions(bug, local: ["alba220752"], remote: ["bram (gordon11)"]) == "@alba220752 your turn")
        #expect(ChatRouting.localizedMentions("@alba%20%28Sam%27s%20laptop%29 hi", local: ["alba"], remote: ["alba (Sam's laptop)"])
                == "@alba%20%28Sam%27s%20laptop%29 hi", "the other machine's alba was taken for this one's")
        #expect(ChatRouting.localizedMentions("@cora%20%28x%29 hi", local: ["alba"], remote: []) == "@cora%20%28x%29 hi")
        #expect(ChatRouting.localizedMentions("@alba and @bram", local: ["alba"], remote: []) == "@alba and @bram")
    }

    @Test("an entry in a shared chat carries this machine's name beside a local author, never beside another machine's or Port42's")
    func labeled() {
        let local = PortChatEntry(seq: 1, at: Date(), text: "t", fromId: "c1", fromName: "alba", fromKind: "companion")
        let remote = PortChatEntry(seq: 2, at: Date(), text: "t", fromId: "peer/B1", fromName: "bram (gordon11)", fromKind: "companion")
        let notice = PortChatEntry(seq: 3, at: Date(), text: "t", fromId: "port42", fromName: "Port42", fromKind: "system")
        #expect(ChatRouting.labeled(local, local: "Mac A").fromName == "alba (Mac A)")
        #expect(ChatRouting.labeled(remote, local: "Mac A").fromName == "bram (gordon11)")
        #expect(ChatRouting.labeled(notice, local: "Mac A").fromName == "Port42")
        #expect(ChatRouting.labeled(local, local: nil).fromName == "alba")
    }

    @Test("completing a mention writes the plain name, and a mention with a machine is someone here")
    func composer() {
        #expect(ChatRouting.complete("hi @br", with: "bram (Sam's laptop)") == "hi @bram ")
        #expect(ChatRouting.unmatchedMentions("@bram%20%28wrong%29 and @zed", known: ["bram (Sam's laptop)"]) == ["zed"])
        #expect(ChatRouting.mentions("@Gordon%20%28Mac%29 look", name: "Gordon"))
    }

    @Test("this machine's name is the Mac's, with the profile on a dev instance")
    func machineName() {
        #expect(AppState.defaultMachineName(computer: "Gordon's MacBook Pro", bundleId: "com.port42.app") == "Gordon's MacBook Pro")
        #expect(AppState.defaultMachineName(computer: "Gordon's MacBook Pro", bundleId: "com.port42.dev6") == "Gordon's MacBook Pro dev6")
        #expect(AppState.defaultMachineName(computer: nil, bundleId: nil) == "a Mac")
    }
}

@Suite("two agents: addressing across machines", .serialized)
@MainActor
struct TwoAgentsAddressingTests {
    static let me = "25njqamcweflpvkl73j4szahhihoc4xt3ktcgjnpaingr5yhkena"
    static let host = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"
    static let peer = "peer-gordon11"

    func board(_ w: ParityWorld) throws -> String {
        let made = w.state.createPort(type: "web", title: "board", html: "<title>board</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        return try #require(made["id"] as? String)
    }
    func companion(_ w: ParityWorld, _ name: String, terminal: Bool = true) throws -> AgentConfig {
        var a = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: name, command: "claude",
                                          systemPrompt: nil, trigger: .mentionOnly)
        a.openInTerminal = true
        try w.state.db.saveAgent(a)
        w.state.companions.append(a)
        w.state.joinCompanionToSpace(a, spaceId: w.space.id)
        if terminal {
            _ = try #require(w.state.spawnNativeTerminalPort(command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id,
                                                             title: name, companionName: name, companionId: a.id,
                                                             systemPrompt: nil, postCard: false))
        }
        return a
    }
    func bram(_ name: String = "bram") -> Principal {
        Principal.remote(peer: Self.peer, displayName: "gordon11").acting(as: RemoteActor(id: "B-" + name, name: name, kind: .companion))
    }
    func names(_ v: BridgeValue) -> [String] {
        guard case .object(let o) = v, case .array(let es)? = o["entries"] ?? o["presence"] else { return [] }
        return es.compactMap { e -> String? in
            guard case .object(let x) = e else { return nil }
            if case .object(let from)? = x["from"], case .string(let n)? = from["name"] { return n }
            if case .string(let n)? = x["name"] { return n }
            return nil
        }
    }

    @Test("a shared chat shows this machine's people and agents with its name, to its own agents and to the other machine")
    func hostLabels() async throws {
        let w = try makeParityWorld()
        let id = try board(w)
        let alba = Principal.companion(id: "A1", displayName: "alba", spaceId: w.space.id)
        _ = try w.state.postToChat(key: id, text: "before sharing", from: alba)
        let plain = try await w.state.runBridgeMethod("chat.read", principal: w.principal, args: BridgeArgs(["port": id]))
        #expect(names(plain) == ["alba"], "an unshared chat labels its authors")

        w.state.grantRemoteRights([.see, .use, .wakeAgents], to: Self.peer, onPort: id)
        var heard: [String] = []
        _ = w.state.notifyBus.subscribe(topic: PortNotify.topic(forPortKey: id)) { json in
            if let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], o["kind"] as? String == "chat",
               let from = (o["payload"] as? [String: Any])?["from"] as? [String: Any], let n = from["name"] as? String { heard.append(n) }
        }
        _ = try w.state.postToChat(key: id, text: "now shared", from: alba)
        _ = try w.state.postToChat(key: id, text: "hello", from: bram())
        let label = w.state.selfLabel
        let read = try await w.state.runBridgeMethod("chat.read", principal: w.principal, args: BridgeArgs(["port": id]))
        #expect(names(read) == ["alba (\(label))", "alba (\(label))", "bram (gordon11)"])
        #expect(heard == ["alba (\(label))", "bram (gordon11)"], "the chat event carried another name than chat.read")
        #expect((try w.state.db.chatEntries(chat: id, after: 0, limit: 10)).map(\.fromName) == ["alba", "alba", "bram (gordon11)"],
                "the label was stored rather than shown")
    }

    @Test("this machine's label never matches a machine it shares with (NAU-04)")
    func labelNeverCollides() throws {
        let w = try makeParityWorld()
        try w.state.db.upsertPeerClient(id: "peer-x", name: w.state.machineName, peerKey: "xpeer")
        #expect(w.state.selfLabel != w.state.machineName)
        #expect(w.state.selfLabel.hasPrefix(w.state.machineName))
    }

    @Test("an agent on the other machine reaches alba with alba's name and any machine after it, as bram wrote it")
    func hostForgivesTheLabel() async throws {
        let w = try makeParityWorld()
        let alba = try companion(w, "alba")
        let id = try board(w)
        w.state.grantRemoteRights([.see, .use, .wakeAgents], to: Self.peer, onPort: id)
        try w.state.db.saveGrants([.crossWake], grantee: Self.peer + "/B-bram", object: AppState.crossWakeObject(companion: alba.id, port: id), zone: "")
        w.state.chatReplyTargets = [:]
        _ = try w.state.postToChat(key: id, text: "@alba%20%28gordon11%29 your turn", from: bram())
        #expect(w.state.chatReplyTargets["alba"] == id, "the mention with the wrong machine woke nobody")

        // The other machine's own alba, by her full name, is hers: alba here does not wake.
        _ = try w.state.postToChat(key: id, text: "hi", from: bram("alba"))
        w.state.chatReplyTargets = [:]
        _ = try w.state.postToChat(key: id, text: "@alba%20%28gordon11%29 not you", from: bram())
        #expect(w.state.chatReplyTargets["alba"] == nil, "the other machine's alba woke this one")
    }

    @Test("an agent's mention of nobody in a shared chat gets a Port42 line naming who is there; a right one does not")
    func wrongMentionSaid() throws {
        let w = try makeParityWorld()
        _ = try companion(w, "alba", terminal: false)
        let id = try board(w)
        w.state.grantRemoteRights([.see, .use], to: Self.peer, onPort: id)
        func lines() throws -> [String] { try w.state.db.chatEntries(chat: id, after: 0, limit: 50).filter { $0.fromId == "port42" }.map(\.text) }
        let before = try lines().count
        _ = try w.state.postToChat(key: id, text: "@alba hello", from: bram())
        #expect(try lines().count == before, "a right mention was flagged")
        _ = try w.state.postToChat(key: id, text: "@zed please look", from: bram())
        let said = try lines()
        #expect(said.count == before + 1)
        #expect(said.last?.contains("Nobody in this chat is called @zed") == true && said.last?.contains("bram (gordon11)") == true,
                "the line does not say who is there: \(said.last ?? "")")
        let person = Principal.human(id: w.state.currentUser!.id, displayName: "Gordon", spaceId: w.space.id)
        _ = try w.state.postToChat(key: id, text: "@zed are you there", from: person)
        #expect(try lines().count == before + 1, "a person's post was flagged; the composer tells them first")
    }

    func tileWorld() throws -> (ParityWorld, String, String) {
        let w = try makeParityWorld()
        w.state.door.receive(#"{"type":"welcome","sender_id":"host","self_peer":"\#(Self.me)"}"#)
        w.state.door.sendOverride = { _ in }
        let tile = try board(w)
        let row = DatabaseService.RemotePortRow(peerKey: Self.host, portKey: "P", title: "Shared board",
                                                rights: [.see, .use, .edit, .wakeAgents], relays: ["wss://relay.test/v1"],
                                                hostName: "Gordon's Mac")
        try w.state.db.upsertRemotePort(row)
        try w.state.db.setRemotePortWakes(peerKey: Self.host, portKey: "P", wakes: true)
        try w.state.db.setRemotePortKnownAs(peerKey: Self.host, portKey: "P", knownAs: "gordon11")
        try w.state.db.setRemotePortTile(peerKey: Self.host, portKey: "P", localPort: tile)
        return (w, tile, try #require(w.state.mirrorChatKey(tile)))
    }

    @Test("on a tile, the host's people reach a companion brought onto it by its plain name; one not brought on stays asleep")
    func guestPlainName() throws {
        let (w, tile, key) = try tileWorld()
        let bram = try companion(w, "bram")
        _ = try companion(w, "cora")
        w.state.addPortMember(bram.id, port: key)
        w.state.chatReplyTargets = [:]
        let fromHost = PortChatEntry(seq: 1, at: Date(), text: "@bram and @cora have a look", fromId: "u-gordon",
                                     fromName: "Gordon (Gordon's Mac)", fromKind: "human")
        w.state.wakeMentioned(tile: tile, key: key, entry: fromHost)
        #expect(w.state.chatReplyTargets["bram"] == key, "the plain name did not reach the companion brought onto the tile")
        #expect(w.state.chatReplyTargets["cora"] == nil, "a companion not brought onto the tile woke for its plain name")

        // The host's agent guessing this machine's label wrong still reaches bram.
        w.state.chatReplyTargets = [:]
        w.state.chats.received(key, PortChatEntry(seq: 2, at: Date(), text: "hi", fromId: "a1", fromName: "alba (Gordon's Mac)", fromKind: "human"))
        w.state.wakeMentioned(tile: tile, key: key, entry: PortChatEntry(seq: 3, at: Date(), text: "@bram%20%28Gordon%27s%20Mac%29 go",
                                                                        fromId: "u-gordon", fromName: "Gordon (Gordon's Mac)", fromKind: "human"))
        #expect(w.state.chatReplyTargets["bram"] == key, "the wrong machine after bram's name woke nobody")
    }

    @Test("a post this machine made, coming back from the host, wakes nobody a second time")
    func guestSkipsItsEcho() throws {
        let (w, tile, key) = try tileWorld()
        let bram = try companion(w, "bram")
        w.state.addPortMember(bram.id, port: key)
        w.state.chatReplyTargets = [:]
        let echo = PortChatEntry(seq: 1, at: Date(), text: "@bram go", fromId: Self.me + "/u", fromName: "Gordon (gordon11)", fromKind: "human")
        w.state.wakeMentioned(tile: tile, key: key, entry: echo)
        #expect(w.state.chatReplyTargets["bram"] == nil, "this machine's own post woke bram again when it came back")
    }
}
