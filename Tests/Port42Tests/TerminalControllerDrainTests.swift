import Testing
import Foundation
@testable import Port42Lib

/// Phase 1 of the auto-reopen feature: messages that arrive while a native terminal companion
/// is still (re)spawning are queued, then injected once the CLI signals readiness (SessionStart),
/// arming the gate so the reply is broadcast back to the space. These tests exercise that drain →
/// flush → arm → post chain at the controller level (no surface, no AppState).
@MainActor
@Suite("Terminal Controller — pending injection drain")
struct TerminalControllerDrainTests {

    private func makeConfig(name: String = "claude9", startup: String = "claude") -> TerminalPortConfig {
        TerminalPortConfig(
            command: "/bin/zsh", args: [], startupCommand: startup, cwd: "/tmp",
            spaceId: "space-1", spaceName: "Demo", companionName: name, createdBy: "u1",
            companionPrompt: "")
    }

    @Test("queued messages are injected once the CLI signals readiness (sessionStarted)")
    func flushOnSessionStarted() {
        var queue = ["[gordon]: @claude9 hi\r"]
        var injected: [String] = []
        let ctl = GhosttyTerminalController(
            panelId: "p1", config: makeConfig(), post: { _ in },
            drainPending: { let q = queue; queue = []; return q })
        ctl.bindSurface { injected.append($0) }

        ctl.handleEvent(.sessionStarted)

        #expect(injected == ["[gordon]: @claude9 hi\r"])
        ctl.teardown()
    }

    @Test("flushing a queued message arms the gate so the next turnComplete posts the reply")
    func flushArmsGateForReply() {
        var queue = ["[gordon]: hello\r"]
        var posted: [String] = []
        let ctl = GhosttyTerminalController(
            panelId: "p2", config: makeConfig(), post: { posted.append($0) },
            drainPending: { let q = queue; queue = []; return q })
        ctl.bindSurface { _ in }

        ctl.handleEvent(.sessionStarted)                       // drains + injects + arms
        ctl.handleEvent(.turnComplete(text: "Hey gordon", exitCode: 0))

        #expect(posted == ["Hey gordon"])                      // armed by the flushed inject
        ctl.teardown()
    }

    @Test("flush runs at most once even if readiness fires repeatedly")
    func flushIsIdempotent() {
        var drains = 0
        var injected: [String] = []
        let ctl = GhosttyTerminalController(
            panelId: "p3", config: makeConfig(), post: { _ in },
            drainPending: { drains += 1; return drains == 1 ? ["[gordon]: x\r"] : ["LATE\r"] })
        ctl.bindSurface { injected.append($0) }

        ctl.handleEvent(.sessionStarted)
        ctl.handleEvent(.sessionStarted)                       // second readiness signal

        #expect(injected == ["[gordon]: x\r"])                 // only the first drain delivered
        #expect(drains == 1)                                   // queue not re-read
        ctl.teardown()
    }

    @Test("an empty queue is a harmless no-op (normal startup, nothing waiting)")
    func emptyQueueNoOp() {
        var injected: [String] = []
        let ctl = GhosttyTerminalController(
            panelId: "p4", config: makeConfig(), post: { _ in },
            drainPending: { [] })
        ctl.bindSurface { injected.append($0) }

        ctl.handleEvent(.sessionStarted)

        #expect(injected.isEmpty)
        ctl.teardown()
    }

    @Test("readiness before a surface is bound defers the flush (message not lost)")
    func flushDeferredUntilSurfaceBound() {
        var queue = ["[gordon]: hi\r"]
        var injected: [String] = []
        let ctl = GhosttyTerminalController(
            panelId: "p5", config: makeConfig(), post: { _ in },
            drainPending: { let q = queue; queue = []; return q })

        ctl.handleEvent(.sessionStarted)                       // no surface yet → deferred, must not crash
        #expect(injected.isEmpty)
        #expect(queue == ["[gordon]: hi\r"])                   // still queued, not drained

        ctl.bindSurface { injected.append($0) }
        ctl.handleEvent(.sessionStarted)                       // now bound → delivers
        #expect(injected == ["[gordon]: hi\r"])
        ctl.teardown()
    }
}
