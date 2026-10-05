import Testing
import Foundation
@testable import Port42Lib

// Bringing terminals up after a launch in order, a few at a time (#223, docs/plan-boot-order.md).

@Suite("#223: the terminal start queue", .serialized)
@MainActor
struct TerminalStartsTests {
    final class Log { var started: [String] = [] }

    func queue(_ ids: [(String, String)], everywhere: Set<String> = [], log: Log) -> TerminalStarts {
        let q = TerminalStarts()
        for (id, space) in ids {
            q.enqueue(.init(id: id, spaces: [space], everywhere: everywhere.contains(id), start: { log.started.append(id) }))
        }
        return q
    }

    @Test("no more than five start at once; the next starts when one settles")
    func cap() {
        let log = Log()
        let q = queue((1...8).map { ("t\($0)", "S") }, log: log)
        q.pump()
        #expect(log.started == ["t1", "t2", "t3", "t4", "t5"], "the cap of five did not hold: \(log.started)")
        q.hasStarted = { ["t1", "t2"].contains($0) }
        q.settle()
        #expect(log.started.count == 7, "two settled starts did not let two more in: \(log.started)")
    }

    @Test("a start that never reports is let go after twenty seconds")
    func settleAfter() {
        let log = Log()
        let q = queue((1...6).map { ("t\($0)", "S") }, log: log)
        q.pump()
        q.settle(now: Date().addingTimeInterval(5))
        #expect(log.started.count == 5)
        q.settle(now: Date().addingTimeInterval(TerminalStarts.settleAfter + 1))
        #expect(log.started.count == 6, "a start that never reported held its place for good")
    }

    @Test("the current space comes first, and anything pinned everywhere; then other spaces, most recently visited first")
    func order() {
        let log = Log()
        let q = queue([("old", "C"), ("recent", "B"), ("here1", "A"), ("pinned", "D"), ("here2", "A")],
                      everywhere: ["pinned"], log: log)
        q.order(current: "A", visited: ["B": Date(), "C": Date().addingTimeInterval(-3600)])
        #expect(q.waitingIds == ["here1", "pinned", "here2", "recent", "old"], "\(q.waitingIds)")
    }

    @Test("a terminal something needs starts now, ahead of the queue and past the cap")
    func startNow() {
        let log = Log()
        let q = queue((1...8).map { ("t\($0)", "S") }, log: log)
        q.pump()
        q.startNow("t8")
        #expect(log.started.last == "t8" && log.started.count == 6, "\(log.started)")
        #expect(!q.isWaiting("t8"))
    }

    @Test("going to a space moves its waiting terminals to the front")
    func prefer() {
        let log = Log()
        let q = queue((1...5).map { ("busy\($0)", "S") } + [("a1", "A"), ("b1", "B"), ("b2", "B")], log: log)
        q.pump()
        q.prefer(space: "B")
        #expect(q.waitingIds == ["b1", "b2", "a1"], "\(q.waitingIds)")
    }

    @Test("a relaunch starts five terminals and leaves the rest waiting; a message to a waiting companion starts it")
    func relaunch() throws {
        let w = try makeParityWorld()
        let state = w.state, db = w.state.db, space = w.space
        var names: [String] = []
        for i in 1...7 {
            var c = AgentConfig.createCommand(ownerId: state.currentUser!.id, displayName: "c\(i)", command: "claude",
                                              systemPrompt: nil, trigger: .mentionOnly)
            c.openInTerminal = true
            try db.saveAgent(c); state.companions.append(c); names.append(c.displayName)
            _ = try #require(state.spawnNativeTerminalPort(command: "true", cwd: NSTemporaryDirectory(), spaceId: space.id,
                                                           title: c.displayName, companionName: c.displayName,
                                                           companionId: c.id, systemPrompt: nil, postCard: false))
        }

        let state2 = AppState(db: db)                      // the relaunch, over the same database
        state2.spaces = [space]; state2.currentSpace = space
        state2.companions = state.companions
        state2.portWindows.restoreFromDB(appState: state2)
        #expect(state2.terminalControllers.count == 5, "the relaunch started \(state2.terminalControllers.count) terminals at once")
        #expect(state2.terminalStarts.waitingIds.count == 2)

        let waitingId = try #require(state2.terminalStarts.waitingIds.last)
        let panel = try #require(state2.portWindows.panels.first { $0.id == waitingId })
        let companion = try #require(state2.companions.first { $0.displayName == panel.terminalConfig?.companionName })
        state2.deliverToTerminalCompanion(companion, line: "hello", replyChat: nil, spaceId: space.id)
        #expect(state2.terminalControllers[waitingId] != nil, "a message to a waiting companion did not start its terminal")
        #expect(state2.pendingTerminalInjections[companion.displayName.lowercased()] == ["hello"], "the message was not held for it")
        _ = names
    }

    @Test("a call to a waiting terminal starts it now, instead of being refused for having nothing running")
    func callStartsIt() async throws {
        let w = try makeParityWorld()
        for i in 1...7 {
            var c = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: "k\(i)", command: "claude",
                                              systemPrompt: nil, trigger: .mentionOnly)
            c.openInTerminal = true
            try w.state.db.saveAgent(c); w.state.companions.append(c)
            _ = try #require(w.state.spawnNativeTerminalPort(command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id,
                                                             title: c.displayName, companionName: c.displayName,
                                                             companionId: c.id, systemPrompt: nil, postCard: false))
        }
        let state2 = AppState(db: w.state.db)
        state2.spaces = [w.space]; state2.currentSpace = w.space
        state2.companions = w.state.companions
        state2.portWindows.restoreFromDB(appState: state2)
        let waitingId = try #require(state2.terminalStarts.waitingIds.first)
        let was = AppState.waitForWaitingTerminal
        AppState.waitForWaitingTerminal = 0.2          // no real surface comes up under test
        defer { AppState.waitForWaitingTerminal = was }
        _ = try? await state2.runBridgeMethod("port.push", principal: w.principal,
                                              args: BridgeArgs(["id": waitingId, "data": "ls"]), pregrant: [.terminal])
        #expect(!state2.terminalStarts.isWaiting(waitingId), "a call that needs the waiting terminal left it waiting")
        #expect(state2.terminalControllers[waitingId] != nil, "the terminal was not started for the call")
    }
}

@Suite("A plain terminal that becomes a companion comes back as one", .serialized)
@MainActor
struct AutoRegisteredStartupTests {
    /// A Terminal-button terminal: a codename, a shell, no startup command. Its controller, and its saved startup.
    func plainTerminal(_ w: ParityWorld) throws -> (String, GhosttyTerminalController) {
        let made = w.state.createPort(type: "terminal", title: nil, html: nil, command: "/bin/zsh", cwd: NSTemporaryDirectory(),
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let raw = try #require(made["id"] as? String)
        let panel = try #require(w.state.portWindows.panels.first { $0.id == raw || $0.udid == raw })
        w.state.portWindows.rewriteTerminalStartup(id: panel.id) { _ in "" }
        let controller = try #require(w.state.terminalControllers[panel.id])
        return (panel.id, controller)
    }
    func startup(_ w: ParityWorld, _ id: String) -> String? {
        w.state.portWindows.panels.first { $0.id == id }?.terminalConfig?.startupCommand
    }

    @Test("claude starting in a plain terminal saves claude --continue as its startup, through the terminal's own session start")
    func savesResume() throws {
        let w = try makeParityWorld()
        let (id, controller) = try plainTerminal(w)
        #expect(startup(w, id) == "")
        controller.handleEvent(.sessionStarted(cli: "claude"))
        #expect(startup(w, id) == "claude --continue", "the terminal will reopen as a bare shell: \(startup(w, id) ?? "nil")")
        #expect(AppState.resumeStartup(cli: "codex") == "codex resume --last")
    }

    @Test("a terminal whose saved startup is set (claude --resume abc) keeps it when its CLI starts")
    func keepsAStartup() throws {
        let w = try makeParityWorld()
        let (id, controller) = try plainTerminal(w)
        w.state.portWindows.rewriteTerminalStartup(id: id) { _ in "claude --resume abc" }
        controller.handleEvent(.sessionStarted(cli: "claude"))
        #expect(startup(w, id) == "claude --resume abc", "a saved startup was overwritten: \(startup(w, id) ?? "nil")")
    }
}
