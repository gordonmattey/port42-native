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

    @Test("a near miss names the agent it meant; nobody's name is no one's near miss")
    func nearest() {
        #expect(ChatRouting.nearestAgent("alda", agents: ["alba (Mac)", "otto"]) == "alba")
        #expect(ChatRouting.nearestAgent("sam", agents: ["alba", "otto"]) == nil)
        #expect(ChatRouting.nearestAgent("sam", agents: ["bram"]) == nil, "a short name two letters off was taken for a typo")
        #expect(ChatRouting.nearestAgent("otto (wrong)", agents: ["otto (Mac)"]) == "otto")
    }

    @Test("completing a mention writes the plain name, and a mention with a machine is someone here")
    func composer() {
        #expect(ChatRouting.complete("hi @br", with: "bram (Sam's laptop)") == "hi @bram ")
        #expect(ChatRouting.unmatchedMentions("@bram%20%28wrong%29 and @zed", known: ["bram (Sam's laptop)"]) == ["zed"])
        #expect(ChatRouting.mentions("@Gordon%20%28Mac%29 look", name: "Gordon"))
        // A tile's own computer's agent, posting back from the host, is offered once, by its plain name.
        let back = PortChatEntry(seq: 1, at: Date(), text: "hi", fromId: "PEER/juno-id", fromName: "juno (Sam's Port42)", fromKind: "companion")
        let theirs = PortChatEntry(seq: 2, at: Date(), text: "hi", fromId: "wren-id", fromName: "wren (Gordon's Port42)", fromKind: "companion")
        #expect(ChatRouting.mentionable(companions: ["juno"], entries: [back, theirs], me: nil, ownPeer: "PEER") == ["juno", "wren (Gordon's Port42)"])
    }

    @Test("a machine is called \"<its person>'s Port42\" until its person names it")
    func machineName() {
        #expect(AppState.defaultMachineName(person: "Gordon") == "Gordon's Port42")
        #expect(AppState.defaultMachineName(person: " ") == "Port42")
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
        w.state.chatReplyTargets = [:]
        _ = try w.state.postToChat(key: id, text: "@alba%20%28gordon11%29 your turn", from: bram())
        #expect(w.state.chatReplyTargets["alba"] == id, "the mention with the wrong machine woke nobody")

        // The other machine's own alba, by her full name, is hers: alba here does not wake.
        _ = try w.state.postToChat(key: id, text: "hi", from: bram("alba"))
        w.state.chatReplyTargets = [:]
        _ = try w.state.postToChat(key: id, text: "@alba%20%28gordon11%29 not you", from: bram())
        #expect(w.state.chatReplyTargets["alba"] == nil, "the other machine's alba woke this one")
    }

    @Test("an agent's near miss of an agent's name in a shared chat gets a Port42 line naming who it meant; a stranger's name does not")
    func wrongMentionSaid() throws {
        let w = try makeParityWorld()
        _ = try companion(w, "alba", terminal: false)
        let id = try board(w)
        w.state.grantRemoteRights([.see, .use], to: Self.peer, onPort: id)
        func lines() throws -> [String] { try w.state.db.chatEntries(chat: id, after: 0, limit: 50).filter { $0.fromId == "port42" }.map(\.text) }
        let before = try lines().count
        _ = try w.state.postToChat(key: id, text: "@alba hello", from: bram())
        #expect(try lines().count == before, "a right mention was flagged")
        _ = try w.state.postToChat(key: id, text: "@sam, what launch date do you want?", from: bram())
        #expect(try lines().count == before, "a person in the story was flagged as a wrong agent")
        _ = try w.state.postToChat(key: id, text: "@alda please look", from: bram())
        let said = try lines()
        #expect(said.count == before + 1)
        #expect(said.last == "Nobody in this chat is called @alda. Did you mean @alba?", "\(said.last ?? "")")
        let person = Principal.human(id: w.state.currentUser!.id, displayName: "Gordon", spaceId: w.space.id)
        _ = try w.state.postToChat(key: id, text: "@alda are you there", from: person)
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

    @Test("a machine that renames itself reads by the new name from then on; what it said before keeps the old one")
    func hostFollowsARename() async throws {
        let w = try makeParityWorld()
        let id = try board(w)
        try w.state.db.upsertPeerClient(id: "peer-g11", name: "gordon11", peerKey: Self.peer)
        w.state.grantRemoteRights([.see, .use], to: Self.peer, onPort: id)
        let before = try w.state.remotePrincipal(peer: Self.peer).acting(as: RemoteActor(id: "B1", name: "otto", kind: .companion))
        _ = try w.state.postToChat(key: id, text: "hi", from: before)
        let out = w.state.renamePeer(peer: Self.peer, args: ["name": "Sam's Port42"])
        #expect(out["knownAs"] as? String == "Sam's Port42")
        #expect(out["host"] as? String == w.state.machineName, "the host did not say its own name")
        let after = try w.state.remotePrincipal(peer: Self.peer).acting(as: RemoteActor(id: "B1", name: "otto", kind: .companion))
        _ = try w.state.postToChat(key: id, text: "again", from: after)
        #expect(try w.state.db.chatEntries(chat: id, after: 0, limit: 10).map(\.fromName) == ["otto (gordon11)", "otto (Sam's Port42)"])
        // A name this machine already goes by is not taken.
        let taken = w.state.renamePeer(peer: Self.peer, args: ["name": w.state.machineName])
        #expect(taken["knownAs"] as? String != w.state.machineName)
    }

    @Test("a tile tells its host this machine's name once, and keeps the names the host answers with")
    func guestTellsItsName() async throws {
        let (w, tile, _) = try tileWorld()
        let door = w.state.door
        var told: [String] = []
        door.sendOverride = { [weak door] text in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  o["method"] as? String == AppState.renameMethod, let cid = o["call_id"] as? String else { return }
            told.append(((o["args"] as? [String: Any])?["name"] as? String) ?? "")
            let reply = #"{"type":"response","call_id":"\#(cid)","payload":{"senderName":"host","senderType":"host","content":"{\"knownAs\":\"Sam's Port42\",\"host\":\"Gordon's Port42\"}"}}"#
            Task { @MainActor in door?.receive(reply) }
        }
        let row = try #require(w.state.mirroredRemote(tile))
        await w.state.tellMachineName(row: row)
        await w.state.tellMachineName(row: row)
        #expect(told == [w.state.machineName], "told the host \(told.count) times")
        let now = try #require(w.state.mirroredRemote(tile))
        #expect(now.knownAs == "Sam's Port42" && now.hostName == "Gordon's Port42")
    }

    @Test("reading a shared port's chat names the host's agents on it; an unshared one does not")
    func hostListsItsAgents() async throws {
        let w = try makeParityWorld()
        _ = try companion(w, "iris", terminal: false)
        let id = try board(w)
        func agents() async throws -> [String]? {
            let v = try await w.state.runBridgeMethod("chat.read", principal: w.principal, args: BridgeArgs(["port": id]))
            return ((v.toJSONObject() as? [String: Any])?["agents"] as? [String])
        }
        #expect(try await agents() == nil)
        w.state.grantRemoteRights([.see, .use], to: Self.peer, onPort: id)
        #expect(try await agents()?.contains("iris (\(w.state.selfLabel))") == true)
    }

    @Test("a tile's @ picker offers the host's agents before they have posted")
    func guestPickerKnowsHostAgents() async throws {
        let (w, tile, key) = try tileWorld()
        let door = w.state.door
        door.sendOverride = { [weak door] text in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let cid = o["call_id"] as? String else { return }
            let content = o["method"] as? String == "chat.read" ? #"{\"entries\":[],\"last\":0,\"agents\":[\"iris (Gordon's Port42)\"]}"# : #"{}"#
            let reply = #"{"type":"response","call_id":"\#(cid)","payload":{"senderName":"host","senderType":"host","content":"\#(content)"}}"#
            Task { @MainActor in door?.receive(reply) }
        }
        let row = try #require(w.state.mirroredRemote(tile))
        await w.state.loadMirrorChat(tile: tile, row: row)
        #expect(w.state.chatPeople(key: key).contains("iris (Gordon's Port42)"))
        #expect(ChatRouting.complete("@ir", with: "iris (Gordon's Port42)") == "@iris ")
    }

    @Test("a copy's page says what it is doing about the copy, here, as the original does there; it never speaks for another port")
    func copySpeaksForItself() async throws {
        let (w, tile, key) = try tileWorld()
        let page = try #require(w.state.portWindows.panels.first { $0.id == tile }).bridge.portPrincipal
        // Run here, not sent to the host, which refuses both to another computer.
        #expect(w.state.mirroredCall("state.set", fromTile: tile, args: [[["label": "done", "value": "3/5"]]]) == nil)
        #expect(w.state.mirroredCall("port.publish", fromTile: tile, args: ["state", ["a": 1]]) == nil)
        #expect(w.state.mirroredCall("storage.get", fromTile: tile, args: ["k"]) != nil, "the page's storage stopped going to the host")

        _ = try await w.state.runBridgeMethod("state.set", principal: page,
                                               args: BridgeArgs(["lines": [["label": "done", "value": "3/5"]]]))
        let card = w.state.portCard(try #require(w.state.portWindows.panels.first { $0.id == tile }))
        #expect(card.lines.contains { $0.label == "done" && $0.value == "3/5" }, "the copy's card does not show what its page said")

        var heard = false
        _ = w.state.notifyBus.subscribe(topic: PortNotify.topic(forPortKey: key)) { json in if json.contains("\"a\":1") { heard = true } }
        _ = try await w.state.runBridgeMethod("port.publish", principal: page, args: BridgeArgs(["kind": "state", "payload": ["a": 1]]))
        #expect(heard, "a watcher of the copy did not hear its page")

        let other = try board(w)
        let refused = try #require(w.state.mirroredCall("state.set", fromTile: tile, args: [[["label": "x", "value": "1"]], other]))
        #expect((await refused.value as? [String: Any])?["code"] as? String == BridgeErrorCode.notGranted.wire,
                "a copy's page named another port here")
    }

    /// The host answers `chat.read` with these entries, and anything else with nothing.
    func hostAnswersChat(_ w: ParityWorld, _ entries: [[String: Any]]) {
        let door = w.state.door
        door.sendOverride = { [weak door] text in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let cid = o["call_id"] as? String else { return }
            let body: [String: Any] = o["method"] as? String == "chat.read" ? ["entries": entries, "last": entries.count] : [:]
            let content = String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
            let payload: [String: Any] = ["senderName": "host", "senderType": "host", "content": content]
            let frame: [String: Any] = ["type": "response", "call_id": cid, "payload": payload]
            let reply = String(data: try! JSONSerialization.data(withJSONObject: frame), encoding: .utf8)!
            Task { @MainActor in door?.receive(reply) }
        }
    }

    @Test("a tile that reconnects wakes the agents named in what was posted while its link was down; a first load wakes nobody")
    func reconnectCatchesUp() async throws {
        let (w, tile, key) = try tileWorld()
        let bram = try companion(w, "bram")
        w.state.addPortMember(bram.id, port: key)
        let row = try #require(w.state.mirroredRemote(tile))
        func post(_ seq: Int, _ text: String) -> [String: Any] {
            ["seq": seq, "at": Date().timeIntervalSince1970, "text": text, "from": ["id": "u-gordon", "name": "Gordon (Gordon's Mac)", "kind": "human"]]
        }
        hostAnswersChat(w, [post(1, "@bram an old ask, long done")])
        w.state.chatReplyTargets = [:]
        await w.state.loadMirrorChat(tile: tile, row: row)
        #expect(w.state.chatReplyTargets["bram"] == nil, "a first load replayed an old mention")

        hostAnswersChat(w, [post(1, "@bram an old ask, long done"), post(2, "@bram missed while the link was down")])
        await w.state.loadMirrorChat(tile: tile, row: row)
        #expect(w.state.chatReplyTargets["bram"] == key, "a mention posted while the link was down never woke bram")

        w.state.chatReplyTargets = [:]
        await w.state.loadMirrorChat(tile: tile, row: row)
        #expect(w.state.chatReplyTargets["bram"] == nil, "a caught-up mention woke bram again")

        // An ask from before the window is history: a tile back after a long time away does not act on it.
        w.state.chatReplyTargets = [:]
        let old = Date().addingTimeInterval(-2 * 3600).timeIntervalSince1970
        hostAnswersChat(w, [post(1, "@bram an old ask, long done"), post(2, "@bram missed while the link was down"),
                            ["seq": 3, "at": old, "text": "@bram from two hours ago",
                             "from": ["id": "u-gordon", "name": "Gordon (Gordon's Mac)", "kind": "human"]]])
        await w.state.loadMirrorChat(tile: tile, row: row)
        #expect(w.state.chatReplyTargets["bram"] == nil, "a two-hour-old ask woke bram")
        #expect(w.state.mirrorSeenSeq[tile] == 3, "the last post seen is not kept for the next launch")
    }

    @Test("a tile restored at launch is not shown online until its host has answered")
    func onlineOnlyOnceAnswered() throws {
        let (w, tile, _) = try tileWorld()
        w.state.door.sendOverride = { _ in }          // the host never answers
        w.state.startMirror(tile: tile)
        #expect(w.state.mirrorStatus[tile]?.online == false, "the tile said online before the host answered")
        w.state.stopMirror(tile: tile)
    }

    @Test("when the host says the tile's stream is live, the tile catches up on what was posted before it was")
    func liveStreamCatchesUp() async throws {
        let (w, tile, key) = try tileWorld()
        let bram = try companion(w, "bram")
        w.state.addPortMember(bram.id, port: key)
        let row = try #require(w.state.mirroredRemote(tile))
        w.state.mirrorSeenSeq[tile] = 1
        hostAnswersChat(w, [["seq": 2, "at": Date().timeIntervalSince1970, "text": "@bram posted before the stream was live",
                             "from": ["id": "u-gordon", "name": "Gordon (Gordon's Mac)", "kind": "human"]]])
        w.state.chatReplyTargets = [:]
        w.state.mirrorEvent(tile: tile, row: row, ["kind": "subscribed", "topic": "port:P", "payload": [String: Any]()])
        for _ in 0..<200 where w.state.chatReplyTargets["bram"] == nil { await Task.yield() }
        #expect(w.state.chatReplyTargets["bram"] == key, "a post made before the stream was live never woke bram")
    }
}
