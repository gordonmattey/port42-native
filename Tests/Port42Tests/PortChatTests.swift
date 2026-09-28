import Testing
import Foundation
@testable import Port42Lib

/// Every port has a chat (nautilus Phase 1 step 5, step 1 of its build order): the transcript, the
/// two methods, attribution from the caller, and the `chat` event. Headless.
@Suite("Port chat")
@MainActor
struct PortChatTests {

    func call(_ w: ParityWorld, _ method: String, _ args: [String: Any],
              as p: Principal? = nil) async throws -> [String: Any] {
        let v = try await w.state.runBridgeMethod(method, principal: p ?? w.principal, args: BridgeArgs(args))
        return v.toJSONObject() as? [String: Any] ?? [:]
    }

    func entries(_ r: [String: Any]) -> [[String: Any]] { r["entries"] as? [[String: Any]] ?? [] }

    static let person = Principal.human(id: "alice", displayName: "Alice", spaceId: nil)

    @Test("a post lands in the port's chat, in order, attributed to whoever called")
    func postAndRead() async throws {
        let w = try makeParityWorld()
        _ = try await call(w, "chat.post", ["port": w.space.id, "text": "hello"])
        _ = try await call(w, "chat.post", ["port": w.space.id, "text": "second"],
                           as: .peer(id: "cli-7", displayName: "harness"))

        let r = try await call(w, "chat.read", ["port": w.space.id])
        let e = entries(r)
        #expect(e.map { $0["text"] as? String } == ["hello", "second"])
        #expect(e.map { $0["seq"] as? Int } == [1, 2])
        let from0 = e.first?["from"] as? [String: Any], from1 = e.last?["from"] as? [String: Any]
        #expect(from0?["name"] as? String == w.companion.displayName)
        #expect(from0?["kind"] as? String == "companion")
        #expect(from1?["id"] as? String == "cli-7")
        #expect(from1?["kind"] as? String == "peer")
        #expect(r["last"] as? Int == 2)
    }

    /// F16: a post through the API used to speak as the person. There is no name to pass.
    @Test("a caller cannot post under another name")
    func noSenderOverride() async throws {
        let w = try makeParityWorld()
        do {
            _ = try await call(w, "chat.post", ["port": w.space.id, "text": "hi", "senderName": "Alice"])
            Issue.record("chat.post accepted a sender name")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.badArg.wire)
        }
    }

    @Test("port 0 is the desktop's chat; a port that does not exist has none")
    func scopes() async throws {
        let w = try makeParityWorld()
        // The desktop's chat belongs to no space, so it is the person's: a companion in a space may
        // neither post there (APP-08) nor read it (APP-09).
        _ = try await call(w, "chat.post", ["port": "0", "text": "desk"], as: Self.person)
        #expect(entries(try await call(w, "chat.read", ["port": "0"], as: Self.person)).count == 1)
        #expect(entries(try await call(w, "chat.read", ["port": w.space.id])).isEmpty,
                "chats are per port, not shared")
        do {
            _ = try await call(w, "chat.post", ["port": "no-such-port", "text": "x"])
            Issue.record("posted to a port that does not exist")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.notFound.wire)
        }
    }

    @Test("empty text is refused")
    func emptyRefused() async throws {
        let w = try makeParityWorld()
        await #expect(throws: BridgeError.self) {
            _ = try await call(w, "chat.post", ["port": w.space.id, "text": "  \n"])
        }
    }

    @Test("after and limit page the transcript, oldest first")
    func paging() async throws {
        let w = try makeParityWorld()
        // The caller's own space chat: paging is not about scope (APP-09).
        for i in 1...5 { _ = try await call(w, "chat.post", ["port": w.space.id, "text": "m\(i)"]) }
        let after = entries(try await call(w, "chat.read", ["port": w.space.id, "after": 3]))
        #expect(after.map { $0["text"] as? String } == ["m4", "m5"])
        let newest = entries(try await call(w, "chat.read", ["port": w.space.id, "limit": 2]))
        #expect(newest.map { $0["text"] as? String } == ["m4", "m5"], "limit keeps the newest")
    }

    @Test("a post is published on the port's topic as a chat event carrying the entry")
    func publishesEvent() async throws {
        let w = try makeParityWorld()
        var got: [[String: Any]] = []
        let topic = PortNotify.topic(forPortKey: w.space.id)
        let id = w.state.notifyBus.subscribe(topic: topic) { json in
            if let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] { got.append(o) }
        }
        defer { w.state.notifyBus.unsubscribe(id: id, topic: topic) }
        _ = try await call(w, "chat.post", ["port": w.space.id, "text": "ping"])
        #expect(got.count == 1)
        #expect(got.first?["kind"] as? String == "chat")
        #expect((got.first?["payload"] as? [String: Any])?["text"] as? String == "ping")
    }

    /// The transcript sits in a storage scope `storage.*` cannot name, so an entry cannot be forged
    /// or edited around `chat.post`.
    @Test("storage cannot see or write a chat")
    func storageIsolated() async throws {
        let w = try makeParityWorld()
        _ = try await call(w, "chat.post", ["port": w.space.id, "text": "private"])
        let keys = try await call(w, "storage.list", [:])["keys"] as? [String]
        #expect(keys?.isEmpty == true)
        let shared = try await call(w, "storage.list", ["shared": true])["keys"] as? [String]
        #expect(shared?.isEmpty == true)
    }

    @Test("a chat whose port is gone is reaped; the desktop's and a live space's stay")
    func reap() throws {
        let w = try makeParityWorld()
        let db = w.state.db
        for chat in ["0", w.space.id, "gone-port"] {
            _ = try db.appendChatEntry(chat: chat, text: "x", at: Date(), fromId: "a", fromName: "a", fromKind: "human")
        }
        #expect(try db.reapOrphanChats() == 1)
        #expect(try db.lastChatSeq(chat: "gone-port") == 0)
        #expect(try db.lastChatSeq(chat: "0") == 1)
        #expect(try db.lastChatSeq(chat: w.space.id) == 1)
    }

    // MARK: - What the shell shows (build step 2)

    func entry(_ seq: Int, from: String) -> PortChatEntry {
        PortChatEntry(seq: seq, at: Date(), text: "t\(seq)", fromId: from, fromName: from.uppercased(), fromKind: "peer")
    }

    @Test("unread counts what others posted since you last read; your own posts never count")
    func unreadAndMarkRead() throws {
        let db = try DatabaseService(inMemory: true)
        let store = PortChatStore(defaults: nil)
        store.load("P", from: db)
        store.received("P", entry(1, from: "echo"))
        store.received("P", entry(2, from: "me"))
        store.received("P", entry(3, from: "echo"))
        #expect(store.unread("P", me: "me") == 2)
        store.markRead("P")
        #expect(store.unread("P", me: "me") == 0)
        store.received("P", entry(4, from: "echo"))
        #expect(store.unread("P", me: "me") == 1)
    }

    @Test("participants are everyone who posted, newest first, once each")
    func participants() throws {
        let store = PortChatStore(defaults: nil)
        store.load("P", from: try DatabaseService(inMemory: true))
        for (i, who) in ["a", "b", "a", "c"].enumerated() { store.received("P", entry(i + 1, from: who)) }
        #expect(store.participants("P").map(\.id) == ["c", "a", "b"])
    }

    @Test("a post reaches an open chat at once, whoever made it, and a repeat is not doubled")
    func postFeedsStore() async throws {
        let w = try makeParityWorld()
        w.state.chats.load(w.space.id, from: w.state.db)
        _ = try await call(w, "chat.post", ["port": w.space.id, "text": "live"],
                           as: .peer(id: "cli-1", displayName: "harness"))
        let list = w.state.chats.entries[w.space.id] ?? []
        #expect(list.map(\.text) == ["live"])
        w.state.chats.received(w.space.id, list[0])
        #expect(w.state.chats.entries[w.space.id]?.count == 1)
    }

    @Test("the person posts through the registry, attributed to them")
    func personPosts() async throws {
        let w = try makeParityWorld()
        try await w.state.postToChatAsPerson(key: w.space.id, text: "from the panel")
        let e = entries(try await call(w, "chat.read", ["port": w.space.id])).first
        #expect((e?["from"] as? [String: Any])?["kind"] as? String == "human")
        #expect((e?["from"] as? [String: Any])?["name"] as? String == "Alice")
    }

    // MARK: - Who a post wakes, and where the reply goes (build step 3)

    @Test("a post wakes its mentions, then the port's own companion, once each, never the sender")
    func routingTargets() {
        #expect(ChatRouting.targets(text: "@Critic look", senderName: "Alice", portCompanion: nil) == ["critic"])
        #expect(ChatRouting.targets(text: "hi", senderName: "Alice", portCompanion: "Echo") == ["echo"],
                "a terminal port's chat is its companion's session: no mention needed")
        #expect(ChatRouting.targets(text: "@echo @Critic @echo", senderName: "Alice", portCompanion: "Echo")
                == ["echo", "critic"], "once each")
        #expect(ChatRouting.targets(text: "done, @Critic review", senderName: "Echo", portCompanion: "Echo")
                == ["critic"], "a companion's reply in its own chat must not wake itself")
        #expect(ChatRouting.targets(text: "plain", senderName: "Alice", portCompanion: nil).isEmpty)
    }

    @Test("a reply goes to the chat that asked last; an ask from the old space chat clears it")
    func replyTargets() {
        var t: [String: String] = [:]
        ChatRouting.recordReply(&t, companion: "echo", chat: "port-A")
        ChatRouting.recordReply(&t, companion: "echo", chat: "port-B")
        #expect(t["echo"] == "port-B", "the latest ask wins")
        ChatRouting.recordReply(&t, companion: "echo", chat: nil)
        #expect(t["echo"] == nil, "asked from the old chat, the reply goes there, not to a stale port chat")
    }

    @Test("headless companions: mentioned ones wake; with no mention, every member only when a person posts")
    func headlessRouting() {
        func agent(_ name: String, terminal: Bool = false) -> AgentConfig {
            var a = AgentConfig.createCommand(ownerId: "u", displayName: name, command: "bot",
                                              systemPrompt: nil, trigger: .mentionOnly)
            a.openInTerminal = terminal
            return a
        }
        let bot = agent("Bot"), critic = agent("Critic"), echo = agent("Echo", terminal: true)
        let members = [bot, critic, echo]
        func names(_ xs: [AgentConfig]) -> [String] { xs.map(\.displayName) }
        #expect(names(ChatRouting.headlessTargets(mentioned: [critic], members: members, text: "@Critic hi",
                                                  senderName: "Alice", senderIsPerson: true)) == ["Critic"])
        #expect(names(ChatRouting.headlessTargets(mentioned: [], members: members, text: "hello all",
                                                  senderName: "Alice", senderIsPerson: true)) == ["Bot", "Critic"],
                "a person's plain post reaches every headless member; terminals are routed elsewhere")
        #expect(ChatRouting.headlessTargets(mentioned: [], members: members, text: "done",
                                            senderName: "Bot", senderIsPerson: false).isEmpty,
                "a companion's plain post wakes nobody, so two companions cannot loop")
        #expect(ChatRouting.headlessTargets(mentioned: [bot], members: members, text: "@Bot me again",
                                            senderName: "Bot", senderIsPerson: false).isEmpty,
                "never the sender")
    }

    @Test("a companion's terminal is told which chat a message came from")
    func terminalLineCarriesSource() {
        #expect(ChatRouting.terminalLine(sender: "gordon", source: "#genesis", text: "hi")
                == "[@gordon in #genesis]: hi\r")
        #expect(ChatRouting.terminalLine(sender: "gordon", source: nil, text: "hi") == "[@gordon]: hi\r")
        #expect(ChatRouting.terminalLine(sender: "app dev", source: nil, text: "hi") == "[@app%20dev]: hi\r",
                "the sender is written as a mention an agent can copy to reply")
        #expect(ChatRouting.sourceLabel(space: "genesis") == "#genesis")
        #expect(ChatRouting.sourceLabel(port: "shader", ownTerminal: true) == "your terminal's chat")
        #expect(ChatRouting.sourceLabel(port: "shader") == "the chat of port 'shader'")
        #expect(ChatRouting.sourceLabel(desktop: true) == "the desktop chat")
    }

    @Test("@name autocomplete: the name being typed, and completing it")
    func mentionCompletion() {
        #expect(ChatRouting.mentionQuery(in: "hey @ec") == "ec")
        #expect(ChatRouting.mentionQuery(in: "@") == "")
        #expect(ChatRouting.mentionQuery(in: "mail me@x") == nil, "an email is not a mention")
        #expect(ChatRouting.mentionQuery(in: "@echo done") == nil, "a finished mention is not being typed")
        #expect(ChatRouting.complete("hey @ec", with: "Echo") == "hey @Echo ")
        #expect(ChatRouting.complete("no mention", with: "Echo") == "no mention")
    }

    // MARK: - GM's multi-agent test, 2026-09-25: replies are never dropped, and companions cannot loop

    @Test("a reply goes to the chat that asked, else the terminal's own chat, never nowhere")
    func replyDestination() {
        #expect(ChatRouting.replyDestination(asked: "port-shader", ownTerminalChat: "term-1") == "port-shader")
        #expect(ChatRouting.replyDestination(asked: nil, ownTerminalChat: "term-1") == "term-1")
    }

    @Test("another companion's post in a terminal's chat does not wake its companion without a mention")
    func companionsMustMention() {
        #expect(ChatRouting.wakesOwnCompanion(senderIsCompanion: false), "a person or client wakes it")
        #expect(!ChatRouting.wakesOwnCompanion(senderIsCompanion: true), "a companion must @mention")
    }

    @Test("a companion's post in a terminal chat wakes only whom it mentions (routeChat, end to end)")
    func noCompanionLoop() throws {
        let w = try makeParityWorld()
        // Two terminal companions, A with a terminal port whose chat B posts into.
        var a = AgentConfig.createCommand(ownerId: "u", displayName: "alpha", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        a.openInTerminal = true
        var b = AgentConfig.createCommand(ownerId: "u", displayName: "beta", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        b.openInTerminal = true
        w.state.companions = [a, b]
        let panelId = w.state.spawnNativeTerminalPort(command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id,
                                                      title: "alpha", companionName: "alpha", companionId: a.id,
                                                      systemPrompt: nil, postCard: false)
        let key = try #require(w.state.portWindows.panels.first { $0.id == panelId }?.udid)
        // beta posts into alpha's terminal chat with no mention: alpha must not be woken.
        w.state.pendingTerminalInjections = [:]
        _ = try w.state.postToChat(key: key, text: "here is my update", from: .companion(id: b.id, displayName: "beta", spaceId: w.space.id))
        #expect(w.state.chatReplyTargets["alpha"] == nil, "a companion's plain post woke the terminal's companion")
        // The person posting there does wake alpha.
        _ = try w.state.postToChat(key: key, text: "alpha, go", from: .human(id: "u", displayName: "gordon", spaceId: w.space.id))
        #expect(w.state.chatReplyTargets["alpha"] == key)
        withExtendedLifetime(w.state) {}
    }

    @Test("a companion posting through its terminal is recorded as the companion, so its posts and replies are one sender")
    func postAsCompanion() async throws {
        let w = try makeParityWorld()
        var b = AgentConfig.createCommand(ownerId: try #require(w.state.currentUser?.id), displayName: "beta",
                                          command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        b.openInTerminal = true
        try w.state.db.saveAgent(b)
        w.state.companions = [w.companion, b]
        let panelId = try #require(w.state.spawnNativeTerminalPort(
            command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id, title: "beta",
            companionName: "beta", companionId: b.id, systemPrompt: nil, postCard: false))
        let clientId = try #require(w.state.terminalClientPanels.first { $0.value == panelId }?.key)
        // The caller the gateway builds for this terminal: bound to its companion and its spawn space
        // (APP-15), which is also what lets it post in that space's chat (APP-08).
        let terminal = Principal.forGatewayClient(clientId: clientId, displayName: "beta",
                                                  spawn: w.state.spawnBindings[clientId])
        _ = try await w.state.runBridgeMethod("chat.post", principal: terminal,
                                              args: BridgeArgs(["port": w.space.id, "text": "one"]))
        let last = try #require(w.state.db.chatEntries(chat: w.space.id, after: 0, limit: 10).last)
        #expect(last.fromId == b.id, "recorded under the terminal's client id")
        #expect(last.fromKind == Principal.Kind.companion.rawValue)
        // A client that is no companion's terminal stays itself.
        _ = try await w.state.runBridgeMethod("chat.post", principal: .peer(id: "some-tool", displayName: "tool"),
                                              args: BridgeArgs(["port": w.space.id, "text": "two"]))
        #expect(try w.state.db.chatEntries(chat: w.space.id, after: 0, limit: 10).last?.fromId == "some-tool")
        withExtendedLifetime(w.state) {}
    }

    // MARK: - Knowing who and where you are (GM's multi-agent test, 2026-09-25)

    @Test("a port's chat is named with its id, so a companion can post there without searching")
    func labelCarriesPortId() {
        #expect(ChatRouting.sourceLabel(port: "mic shader", portId: "BB8C")
                == "the chat of port 'mic shader' (id BB8C)")
    }

    @Test("whoami tells a terminal companion its name, space, terminal port and who else is here")
    func whoami() async throws {
        let w = try makeParityWorld()
        var b = AgentConfig.createCommand(ownerId: try #require(w.state.currentUser?.id), displayName: "beta",
                                          command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        b.openInTerminal = true
        try w.state.db.saveAgent(b)
        try w.state.db.assignAgentToSpace(agentId: b.id, spaceId: w.space.id)
        try w.state.db.assignAgentToSpace(agentId: w.companion.id, spaceId: w.space.id)
        w.state.companions = [w.companion, b]
        w.state.spaceAgentIds = [w.space.id: [w.companion.id, b.id]]
        let panelId = try #require(w.state.spawnNativeTerminalPort(
            command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id, title: "beta",
            companionName: "beta", companionId: b.id, systemPrompt: nil, postCard: false))
        let clientId = try #require(w.state.terminalClientPanels.first { $0.value == panelId }?.key)
        let v = try await w.state.runBridgeMethod("whoami", principal: .peer(id: clientId, displayName: "beta"),
                                                  args: BridgeArgs([:]))
        let o = try #require(v.toJSONObject() as? [String: Any])
        let udid = try #require(w.state.portWindows.panels.first { $0.id == panelId }?.udid)
        #expect(o["name"] as? String == "beta")
        #expect(o["terminal_port"] as? String == udid)
        #expect(o["chat"] as? String == udid)
        #expect(o["space_id"] as? String == w.space.id)
        #expect((o["companions"] as? [String]) == [w.companion.displayName], "who else is here, not itself")
        withExtendedLifetime(w.state) {}
    }

    @Test("a terminal that started codex is registered as codex, not claude")
    func autoRegisterNamesTheCLI() {
        #expect(AppState.autoRegisterCommand(cli: "codex").hasSuffix("codex"))
        #expect(AppState.autoRegisterCommand(cli: nil).hasSuffix("claude"))
        #expect(AppState.autoRegisterCommand(cli: "claude").hasSuffix("claude"))
        // A hook that names nothing: the terminal's own startup command decides.
        #expect(AppState.resolvedCLI(hook: nil, startupCommand: "codex \"$(cat '/tmp/b.txt')\"") == "codex")
        #expect(AppState.resolvedCLI(hook: nil, startupCommand: "claude") == nil)
        #expect(AppState.resolvedCLI(hook: "codex", startupCommand: "") == "codex")
    }

    /// GM, 2026-09-25: the default names (swift-fox, nimble-wren) are more fun than named roles, and
    /// two claude terminals must be two companions, not two "claude"s.
    @Test("a terminal made with no title gets a codename, not the command's name")
    func terminalCodename() throws {
        let w = try makeParityWorld()
        let a = w.state.createPort(type: "terminal", title: nil, html: nil, command: "true", cwd: NSTemporaryDirectory(),
                                   systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let b = w.state.createPort(type: "terminal", title: nil, html: nil, command: "true", cwd: NSTemporaryDirectory(),
                                   systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let ta = try #require(a["title"] as? String), tb = try #require(b["title"] as? String)
        #expect(ta != "true" && tb != "true", "named after the command")
        #expect(ta != tb, "two terminals, two names")
        #expect(ta.contains("-"), "a codename like swift-fox")
        withExtendedLifetime(w.state) {}
    }

    // MARK: - Who is in a chat (GM, 2026-09-25)

    func e(_ seq: Int, _ from: String, _ text: String, kind: String = "human") -> PortChatEntry {
        PortChatEntry(seq: seq, at: Date(), text: text, fromId: from, fromName: from, fromKind: kind)
    }

    @Test("a chat's members are the companions mentioned in it or posting in it, once each")
    func chatMembers() {
        let entries = [e(1, "gordon", "@swift-fox lead this with @nimble-wren and @keen-owl"),
                       e(2, "swift-fox", "on it", kind: "companion"), e(3, "gordon", "@ghost hi")]
        #expect(ChatRouting.members(of: entries, companions: ["swift-fox", "nimble-wren", "keen-owl"])
                == ["swift-fox", "nimble-wren", "keen-owl"], "a name that is not a companion is ignored")
    }

    @Test("a plain post reaches the chat's members; a post with a mention reaches only the mentioned")
    func plainPostReachesMembers() {
        #expect(ChatRouting.targets(text: "how's it going?", senderName: "gordon", portCompanion: nil,
                                    members: ["swift-fox", "keen-owl"]) == ["swift-fox", "keen-owl"])
        #expect(ChatRouting.targets(text: "@keen-owl just you", senderName: "gordon", portCompanion: nil,
                                    members: ["swift-fox", "keen-owl"]) == ["keen-owl"])
    }

    @Test("after a person mentions a companion in a chat, their plain posts reach it (routeChat)")
    func mentionedCompanionHearsPlainPosts() throws {
        let w = try makeParityWorld()
        var a = AgentConfig.createCommand(ownerId: try #require(w.state.currentUser?.id), displayName: "swift-fox",
                                          command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        a.openInTerminal = true
        try w.state.db.saveAgent(a)
        w.state.companions = [a]
        let person = Principal.human(id: "u", displayName: "gordon", spaceId: w.space.id)
        _ = try w.state.postToChat(key: w.space.id, text: "@swift-fox build it", from: person)
        w.state.chatReplyTargets = [:]
        _ = try w.state.postToChat(key: w.space.id, text: "also make it blue", from: person)
        #expect(w.state.chatReplyTargets["swift-fox"] == w.space.id, "the member did not hear the plain post")
        // A companion's plain post does not wake members, so companions cannot loop.
        w.state.chatReplyTargets = [:]
        _ = try w.state.postToChat(key: w.space.id, text: "done", from: .companion(id: "x", displayName: "keen-owl", spaceId: w.space.id))
        #expect(w.state.chatReplyTargets["swift-fox"] == nil)
        // Port42's own notice wakes no member; one that @mentions a companion still reaches it.
        let port42 = Principal.peer(id: ChatRouting.port42SenderId, displayName: "port42", spaceId: w.space.id)
        _ = try w.state.postToChat(key: w.space.id, text: "swift-fox is waiting at a startup prompt", from: port42)
        #expect(w.state.chatReplyTargets["swift-fox"] == nil, "a Port42 notice woke a member")
        _ = try w.state.postToChat(key: w.space.id, text: "@swift-fox the budget is spent", from: port42)
        #expect(w.state.chatReplyTargets["swift-fox"] == w.space.id, "a Port42 notice lost its mention")
        withExtendedLifetime(w.state) {}
    }

    @Test("the transcript is one text, so a drag copies several messages")
    func transcriptIsOneText() {
        let t = ChatTranscript.build([e(1, "gordon", "first"), e(2, "swift-fox", "second")], me: nil, accent: .green)
        #expect(t.text.string == "gordon\nfirst\nswift-fox\nsecond")
    }

    // MARK: - Mentioning anyone in a chat (GM, 2026-09-28)

    @Test("everyone in a chat can be mentioned: own companions, then whoever posted there, never Port42 or me")
    func mentionableNames() {
        let t = Date()
        func e(_ id: String, _ name: String) -> PortChatEntry { PortChatEntry(seq: 1, at: t, text: "x", fromId: id, fromName: name, fromKind: "human") }
        let names = ChatRouting.mentionable(companions: ["sunny-lynx"],
            entries: [e("u-me", "gordon"), e("peer-j", "Justin"), e("port42", "port42"), e("peer-j2", "Ovi (Justin)"), e("peer-j", "Justin")],
            me: "u-me")
        #expect(names == ["sunny-lynx", "Justin", "Ovi (Justin)"])   // newest first: Justin posted last
        #expect(ChatRouting.mentionSuggestions(query: "ov", names: names) == ["Ovi (Justin)"])
        #expect(ChatRouting.mentionSuggestions(query: "ju", names: names) == ["Justin"])
    }

    @Test("a mention is recognised however it is spelled, and one that matches no one is named")
    func mentionMatching() {
        #expect(ChatRouting.mentions("hey @Justin look", name: "justin"))
        #expect(ChatRouting.mentions("try \(CompanionName.mention("Ovi (Justin)")) now", name: "Ovi (Justin)"))
        #expect(!ChatRouting.mentions("email justin@example.com", name: "justin"))
        #expect(ChatRouting.unmatchedMentions("@Ovi and @sunny-lynx and @all", known: ["sunny-lynx"]) == ["Ovi"])
        #expect(ChatRouting.unmatchedMentions("no mentions here", known: []).isEmpty)
    }


    @Test("you cannot @ yourself: your own name is never offered, from the posts or the people list")
    func notMyself() {
        let t = Date()
        let mine = PortChatEntry(seq: 1, at: t, text: "x", fromId: "u-me", fromName: "gordon", fromKind: "human")
        let names = ChatRouting.mentionable(companions: ["echo"], people: ["Gordon", "Justin"], entries: [mine],
                                            me: "u-me", myName: "gordon")
        #expect(names == ["echo", "Justin"], "offered the person their own name: \(names)")
    }


    @Test("a guest person is offered once, by the name the host knows them as, though their posts carry a longer label")
    func guestOnce() {
        let t = Date()
        // The real shapes (Dev5, 2026-09-28): a remote post's author id is "<peer key>/<actor id>"; the
        // sharing list has the peer key alone. A test with equal ids passed while Dev5 listed them twice.
        let post = PortChatEntry(seq: 1, at: t, text: "hi", fromId: "peer-3xpo/BFF7AC3D", fromName: "gordon (gordon 3xpo)", fromKind: "human")
        let theirCompanion = PortChatEntry(seq: 2, at: t, text: "4", fromId: "peer-3xpo/tern-id", fromName: "quiet-tern (gordon 3xpo)", fromKind: "companion")
        let names = ChatRouting.mentionable(companions: ["echo"], people: ["gordon 3xpo"], entries: [post, theirCompanion],
                                            me: "u-me", myName: "gordon", peopleIds: ["peer-3xpo"])
        #expect(names == ["echo", "gordon 3xpo", "quiet-tern (gordon 3xpo)"], "listed: \(names)")
    }

}
