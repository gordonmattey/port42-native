import Testing
import Foundation
@testable import Port42Lib

// A CLI stuck at a startup prompt (a Codex restarted after a rebuild) never reported SessionStart, and
// every message to it was typed into the prompt and lost (GM, twice, 2026-09-26). It is detected,
// the person is told what the prompt says, messages stay held, and they go in once it is answered.
@Suite("A CLI stuck at a startup prompt")
@MainActor
struct StartupPromptTests {

    func controller(stuck: @escaping (String) -> Void) -> (GhosttyTerminalController, () -> [TerminalWrite]) {
        let cfg = TerminalPortConfig(command: "/bin/zsh", args: [], startupCommand: "codex", cwd: "/tmp",
                                     spaceId: "space-1", spaceName: "Demo", companionName: "coder", createdBy: "u1",
                                     companionPrompt: "")
        let c = GhosttyTerminalController(panelId: "p1", config: cfg, post: { _ in }, onStartupStuck: stuck)
        c.startupWait = 0.3
        c.clearedQuiet = 0.2
        c.heldFallback = 0.6
        var writes: [TerminalWrite] = []
        c.bindSurface { w, done in writes.append(w); done() }
        return (c, { writes })
    }

    func waitUntil(_ cond: () -> Bool, _ seconds: Double = 20) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !cond() && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test("stuck: the person is told what it says, messages are not typed into it, and go in once it is answered")
    func stuckThenAnswered() async throws {
        var told: [String] = []
        let (c, writes) = controller { told.append($0) }
        c.receiveTee("\u{1b}[1mDo you trust this folder?\u{1b}[0m [y/n] ")
        c.inject("[@gordon in #demo]: hi")
        try await waitUntil({ !told.isEmpty })
        #expect(told == ["Do you trust this folder? [y/n]"])
        #expect(c.startupStuck)
        try await Task.sleep(nanoseconds: 900_000_000)                    // past the old fallback
        #expect(writes().isEmpty, "a held message was typed into the startup prompt")
        c.receiveTee("\u{1b}[2J codex ready  > ")                          // answered: it draws, then settles
        try await waitUntil({ !writes().isEmpty })
        #expect(writes().map(\.text) == ["[@gordon in #demo]: hi"])
        #expect(!c.startupStuck)
        c.teardown()
    }

    @Test("a CLI that reports starting in time is never called stuck")
    func startsInTime() async throws {
        var told: [String] = []
        let (c, _) = controller { told.append($0) }
        c.handleEvent(.sessionStarted(cli: "codex"))
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(told.isEmpty && !c.startupStuck)
        c.teardown()
    }
}
