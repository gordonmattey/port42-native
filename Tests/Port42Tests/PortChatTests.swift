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
        _ = try await call(w, "chat.post", ["port": "0", "text": "desk"])
        #expect(entries(try await call(w, "chat.read", ["port": "0"])).count == 1)
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
        for i in 1...5 { _ = try await call(w, "chat.post", ["port": "0", "text": "m\(i)"]) }
        let after = entries(try await call(w, "chat.read", ["port": "0", "after": 3]))
        #expect(after.map { $0["text"] as? String } == ["m4", "m5"])
        let newest = entries(try await call(w, "chat.read", ["port": "0", "limit": 2]))
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
}
