import Testing
import Foundation
@testable import Port42Lib

/// The chat that sent a message shows the agent taking it up (GM, 2026-09-26: "I can't see that the
/// agent received the message and is working"): received when typed in, working when the CLI submits
/// it, waiting when the CLI needs the person, gone when the turn ends. No timeout.
@Suite("Chat presence")
@MainActor
struct ChatPresenceTests {

    func store(at t: Date = Date(timeIntervalSince1970: 1000)) -> ChatPresenceStore {
        let s = ChatPresenceStore()
        s.now = { t }
        return s
    }

    @Test("received, working, waiting, then gone when the turn ends")
    func lifecycle() {
        let s = store()
        s.received("alpha", in: "chat-1")
        #expect(s.entries("chat-1").map(\.state) == [.received])
        s.update("alpha", to: .working)
        #expect(s.entries("chat-1").map(\.state) == [.working])
        s.update("Alpha", to: .waiting("needs permission to use Bash"))
        #expect(s.entries("chat-1").map(\.state) == [.waiting("needs permission to use Bash")])
        s.done("ALPHA")
        #expect(s.entries("chat-1").isEmpty)
        #expect(s.byChat.isEmpty)
    }

    @Test("an agent is shown in the chat that asked last, and only there")
    func movesToTheAskingChat() {
        let s = store()
        s.received("alpha", in: "chat-1")
        s.received("beta", in: "chat-1")
        s.received("alpha", in: "space-1")
        #expect(s.entries("chat-1").map(\.name) == ["beta"])
        #expect(s.entries("space-1").map(\.name) == ["alpha"])
    }

    @Test("a second message from the same chat does not restart a working agent")
    func secondMessageKeepsState() {
        let s = store()
        s.received("alpha", in: "chat-1")
        s.update("alpha", to: .working)
        s.received("alpha", in: "chat-1")
        #expect(s.entries("chat-1").map(\.state) == [.working])
    }

    @Test("an event for an agent not on any message shows nothing (Claude's idle notice after a turn)")
    func strayEventIgnored() {
        let s = store()
        s.update("alpha", to: .waiting("Claude is waiting for your input"))
        #expect(s.byChat.isEmpty)
    }

    @Test("the line says what the agent is doing and for how long")
    func line() {
        let t = Date(timeIntervalSince1970: 1000)
        let p = ChatPresence(name: "alpha", state: .working, since: t)
        #expect(ChatPresenceStore.line(p, now: t) == "is working")
        #expect(ChatPresenceStore.line(p, now: t.addingTimeInterval(42)) == "is working (42s)")
        #expect(ChatPresenceStore.line(p, now: t.addingTimeInterval(185)) == "is working (3m)")
        let r = ChatPresence(name: "alpha", state: .received, since: t)
        #expect(ChatPresenceStore.line(r, now: t) == "has your message")
        let w = ChatPresence(name: "alpha", state: .waiting("needs permission to use Bash"), since: t)
        #expect(ChatPresenceStore.line(w, now: t) == "is waiting for you: needs permission to use Bash")
    }

    @Test("the terminal's own events drive it")
    func controllerEvents() {
        let cfg = TerminalPortConfig(command: "/bin/zsh", args: [], startupCommand: "claude", cwd: "/tmp",
                                     spaceId: "space-1", spaceName: "Demo", companionName: "echo", createdBy: "u1",
                                     companionPrompt: "")
        let c = GhosttyTerminalController(panelId: "p1", config: cfg, post: { _ in })
        var seen: [ChatPresence.State?] = []
        c.onPresence = { seen.append($0) }
        c.handleEvent(.inputSubmitted(prompt: "hi"))
        c.handleEvent(.needsAttention(message: "needs permission"))
        c.handleEvent(.turnComplete(text: "done", exitCode: 0))
        c.handleEvent(.sessionEnded)
        #expect(seen == [.working, .waiting("needs permission"), nil, nil])
        c.teardown()
    }

    @Test("a person's message in a terminal's chat shows its companion there, and its events move it (end to end)")
    func endToEnd() throws {
        let w = try makeParityWorld()
        var a = AgentConfig.createCommand(ownerId: "u", displayName: "alpha", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        a.openInTerminal = true
        w.state.companions = [a]
        let panelId = try #require(w.state.spawnNativeTerminalPort(command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id,
                                                      title: "alpha", companionName: "alpha", companionId: a.id,
                                                      systemPrompt: nil, postCard: false))
        let key = try #require(w.state.portWindows.panels.first { $0.id == panelId }?.udid)
        _ = try w.state.postToChat(key: key, text: "alpha, go", from: .human(id: "u", displayName: "gordon", spaceId: w.space.id))
        #expect(w.state.presence.entries(key).map(\.name) == ["alpha"])
        #expect(w.state.presence.entries(key).first?.state == .received)
        let controller = try #require(w.state.terminalControllers[panelId])
        controller.handleEvent(.inputSubmitted(prompt: "alpha, go"))
        #expect(w.state.presence.entries(key).first?.state == .working)
        controller.handleEvent(.turnComplete(text: "on it", exitCode: 0))
        #expect(w.state.presence.entries(key).isEmpty)
        withExtendedLifetime(w.state) {}
    }

    @Test("a failed turn says why in words, with the CLI's own words when it gave them")
    func failureNotice() {
        #expect(ChatPresence.failureNotice(name: "echo", error: "server_error", details: "")
                == "echo could not reply: the API could not be reached (the connection may have dropped). Send it again.")
        #expect(ChatPresence.failureNotice(name: "echo", error: "rate_limit", details: "429 Too Many Requests")
                .hasSuffix("Wait a moment and send it again. (429 Too Many Requests)"))
        #expect(ChatPresence.failureNotice(name: "echo", error: "something_new", details: "").contains("it hit an error"))
        #expect(!ChatPresence.failureNotice(name: "echo", error: "overloaded", details: "").contains("@"),
                "the notice must not @mention the companion, or it would wake it")
    }

    @Test("a failed turn clears presence and tells the chat that asked, without waking the companion (end to end)")
    func failedTurnEndToEnd() throws {
        let w = try makeParityWorld()
        var a = AgentConfig.createCommand(ownerId: "u", displayName: "alpha", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        a.openInTerminal = true
        w.state.companions = [a]
        let panelId = try #require(w.state.spawnNativeTerminalPort(command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id,
                                                      title: "alpha", companionName: "alpha", companionId: a.id,
                                                      systemPrompt: nil, postCard: false))
        let key = try #require(w.state.portWindows.panels.first { $0.id == panelId }?.udid)
        _ = try w.state.postToChat(key: key, text: "alpha, go", from: .human(id: "u", displayName: "gordon", spaceId: w.space.id))
        let controller = try #require(w.state.terminalControllers[panelId])
        controller.handleEvent(.inputSubmitted(prompt: "alpha, go"))
        controller.handleEvent(.turnFailed(error: "overloaded", details: "529"))
        #expect(w.state.presence.entries(key).isEmpty)
        let last = try #require(w.state.db.chatEntries(chat: key, after: 0, limit: 10).last)
        #expect(last.fromId == ChatRouting.port42SenderId)
        #expect(last.text.hasPrefix("alpha could not reply: the API is overloaded"))
        #expect(w.state.chatReplyTargets["alpha"] == nil, "the notice woke the companion")
        withExtendedLifetime(w.state) {}
    }

    @Test("what the person types into a terminal shows in its chat as them, wakes no one, and shows presence")
    func typedIntoTerminal() throws {
        let w = try makeParityWorld()
        var a = AgentConfig.createCommand(ownerId: "u", displayName: "alpha", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        a.openInTerminal = true
        w.state.companions = [a]
        let panelId = try #require(w.state.spawnNativeTerminalPort(command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id,
                                                      title: "alpha", companionName: "alpha", companionId: a.id,
                                                      systemPrompt: nil, postCard: false))
        let key = try #require(w.state.portWindows.panels.first { $0.id == panelId }?.udid)
        let controller = try #require(w.state.terminalControllers[panelId])
        w.state.pendingTerminalInjections = [:]
        let before = try w.state.db.chatEntries(chat: key, after: 0, limit: 50).count

        // What the CLI submits without the person typing is not theirs (GM, 2026-09-28: Claude Code's
        // task notices and sub-agent reports were posted under his name).
        controller.handleEvent(.inputSubmitted(prompt: "<task-notification>\n<task-id>a3ae</task-id>\n</task-notification>"))
        controller.handleEvent(.inputSubmitted(prompt: "port42-4DEA62FA-928C-45F6-A41D-FB20781ADA41"))
        #expect(try w.state.db.chatEntries(chat: key, after: 0, limit: 50).count == before,
                "a prompt nobody typed was posted as the person")

        w.state.personTyped(inTerminal: panelId)   // the person types (what the terminal view calls on a key)
        controller.handleEvent(.inputSubmitted(prompt: "fix the failing test\n"))
        let entries = try w.state.db.chatEntries(chat: key, after: 0, limit: 10)
        #expect(entries.last?.text == "fix the failing test")
        #expect(entries.last?.fromId == w.state.currentUser?.id)
        #expect(w.state.chatReplyTargets["alpha"] == nil && w.state.pendingTerminalInjections.isEmpty,
                "posting it woke the companion again")
        #expect(w.state.presence.entries(key).first?.state == .working)
        // A line Port42 typed in (from a chat) is not posted a second time.
        w.state.personTyped(inTerminal: panelId)
        controller.handleEvent(.inputSubmitted(prompt: "[@gordon in #demo]: hi\r"))
        #expect(try w.state.db.chatEntries(chat: key, after: 0, limit: 10).count == entries.count)
        // Nor one of the CLI's own, even straight after the person typed something unsent.
        w.state.personTyped(inTerminal: panelId)
        controller.handleEvent(.inputSubmitted(prompt: "<agent-message from=\"a3ae\">\n[Subagent hand-back] …"))
        #expect(try w.state.db.chatEntries(chat: key, after: 0, limit: 10).count == entries.count,
                "a sub-agent's report was posted as the person")
        withExtendedLifetime(w.state) {}
    }

    // MARK: - What it is doing (GM, 2026-09-28: "see what it's doing, files and stuff")

    @Test("a tool call is said by what it touches: a file by its name, never its path; a command cut short")
    func activityFromTools() {
        func a(_ tool: String, _ input: [String: Any]) -> ChatPresence.Activity {
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            return ChatPresence.Activity.from(tool: tool, input: json)
        }
        #expect(a("Read", ["file_path": "/Users/gordon/Clients/Acme/secret/ShellView.swift"])
                == .init(summary: "reading a file", detail: "reading ShellView.swift"))
        #expect(a("Edit", ["file_path": "/x/y/AppState.swift", "old_string": "a", "new_string": "b"]).detail == "editing AppState.swift")
        #expect(a("Write", ["file_path": "/x/notes.md", "content": "…"]).detail == "writing notes.md")
        #expect(a("Bash", ["command": "swift test --filter PresenceAPITests"]).detail == "running swift test --filter PresenceAPITests")
        let long = a("Bash", ["command": String(repeating: "echo hi && ", count: 20) + "\nsecond line"]).detail
        #expect(long.count <= "running ".count + 48 && long.hasSuffix("…") && !long.contains("second line"))
        #expect(a("Grep", ["pattern": "func presence"]).detail == "searching for func presence")
        #expect(a("WebFetch", ["url": "https://docs.example.com/a/b?c=d"]).detail == "reading docs.example.com")
        #expect(a("mcp__github__create_issue", [:]).summary == "using a tool")
        #expect(a("SomethingNew", [:]) == .init(summary: "using a tool", detail: "using SomethingNew"))
        #expect(ChatPresence.Activity.from(tool: "Read", input: "not json").detail == "reading a file")
    }

    @Test("the line says what it is doing, and it clears when the tool finishes")
    func activityInTheLine() {
        let store = ChatPresenceStore()
        let t = Date(timeIntervalSince1970: 1000)
        store.now = { t }
        store.received("echo", in: "c")
        store.update("echo", to: .working)
        store.doing("echo", .init(summary: "editing a file", detail: "editing ShellView.swift"))
        let p = try! #require(store.entries("c").first)
        #expect(ChatPresenceStore.line(p, now: t) == "is working: editing ShellView.swift")
        store.doing("echo", nil)
        #expect(ChatPresenceStore.line(store.entries("c")[0], now: t) == "is working")
    }

    @Test("the terminal's tool events set what it is doing, and finishing clears it")
    func controllerToolEvents() {
        let cfg = TerminalPortConfig(command: "/bin/zsh", args: [], startupCommand: "claude", cwd: "/tmp",
                                     spaceId: "space-1", spaceName: "Demo", companionName: "echo", createdBy: "u1",
                                     companionPrompt: "")
        let c = GhosttyTerminalController(panelId: "p1", config: cfg, post: { _ in })
        var seen: [String?] = []
        c.onActivity = { seen.append($0?.detail) }
        c.handleEvent(.toolStarting(tool: "Read", input: #"{"file_path":"/a/b/README.md"}"#))
        c.handleEvent(.toolFinished(tool: "Read", output: ""))
        #expect(seen == ["reading README.md", nil])
        c.teardown()
    }

    @Test("here the file or command is said; another machine, and the event, get only the kind")
    func activityStaysOnThisMac() async throws {
        let t = InviteTests()
        let w = try t.world()
        _ = try await t.remote(w, as: InviteTests.ada, "invite.redeem", ["nonce": try t.coupon(try await t.create(w)).nonce, "name": "Ada"])
        var events: [String] = []
        let topic = PortNotify.topic(forPortKey: w.p)
        let sub = w.state.notifyBus.subscribe(topic: topic) { events.append($0) }
        defer { w.state.notifyBus.unsubscribe(id: sub, topic: topic) }
        w.state.presence.received("echo", in: w.p)
        w.state.presence.update("echo", to: .working)
        w.state.presence.doing("echo", .init(summary: "editing a file", detail: "editing Acme-contract.md"))

        let here = try await w.state.runBridgeMethod("presence.list", principal: t.person, args: BridgeArgs(["port": w.p]))
        let mine = (here.toJSONObject() as? [String: Any])?["presence"] as? [[String: Any]]
        #expect(mine?.first?["doing"] as? String == "editing Acme-contract.md")

        let theirs = try #require(try await t.remote(w, as: InviteTests.ada, "presence.list", ["port": w.p]) as? [String: Any])
        #expect((theirs["presence"] as? [[String: Any]])?.first?["doing"] as? String == "editing a file")
        #expect(!events.joined().contains("Acme-contract"), "the event carried the file's name off this Mac")
        #expect(events.joined().contains("editing a file"))
    }

}
