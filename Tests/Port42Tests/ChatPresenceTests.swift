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
}
