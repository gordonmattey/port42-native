import Testing
@testable import Port42Lib

/// Tier A gates for the permission queue.
///
/// The property under test is blunt: **every ask resolves exactly once, always.** Each hole this
/// replaced was a caller suspended forever — a port's JS, a companion's turn, or a curl from Claude
/// Code — so a leaked awaiter is the bug, not an edge case.
@Suite("PermissionCoordinator")
@MainActor
struct PermissionCoordinatorTests {

    private func requester(_ id: String, space: String? = "space-1") -> Principal {
        Principal(id: id, displayName: id, spaceId: space, kind: .port)
    }

    /// Spin the main actor until `condition` holds, so a child task's `request(...)` has registered.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test("a grant resolves the waiter")
    func grantResolves() async {
        let c = PermissionCoordinator()
        async let answer = c.request(.ai, from: requester("echo"))
        await settle { c.current != nil }
        c.resolveCurrent(granted: true)
        #expect(await answer == true)
        #expect(c.current == nil)
    }

    @Test("a denial resolves the waiter with false")
    func denyResolves() async {
        let c = PermissionCoordinator()
        async let answer = c.request(.clipboard, from: requester("echo"))
        await settle { c.current != nil }
        c.resolveCurrent(granted: false)
        #expect(await answer == false)
    }

    /// THE regression test. Two asks from one requester used to clobber each other's continuation:
    /// `PortBridge` denied the first on purpose to avoid leaking it; `ToolExecutor` just overwrote
    /// it and leaked the awaiter forever. Reproduced live 2026-07-16 — three curl probes ten
    /// seconds apart leaked all three.
    @Test("concurrent asks from one requester both resolve — neither is clobbered")
    func concurrentAsksBothResolve() async {
        let c = PermissionCoordinator()
        let r = requester("claude-code", space: nil)
        async let first = c.request(.notification, from: r)
        await settle { c.current != nil }
        async let second = c.request(.clipboard, from: r)
        await settle { c.queued.count == 1 }

        #expect(c.pendingCount == 2)
        c.resolveCurrent(granted: true)          // answers .notification, advances to .clipboard
        await settle { c.current?.permission == .clipboard }
        c.resolveCurrent(granted: false)

        #expect(await first == true)
        #expect(await second == false)           // both returned; neither leaked
    }

    @Test("a repeat ask for the same permission coalesces into one card and resumes every waiter")
    func coalescesAndResumesAll() async {
        let c = PermissionCoordinator()
        let r = requester("a-port")
        async let one = c.request(.ai, from: r)
        await settle { c.current != nil }
        async let two = c.request(.ai, from: r)
        async let three = c.request(.ai, from: r)
        // Settle on REGISTRATION, not on `current != nil` (already true from `one`): resolving
        // before two/three have joined would answer only `one` and leave them riding a card nobody
        // ever answers — the exact leak this suite exists to forbid, as a test bug.
        await settle { c.current?.awaiterCount == 3 }

        // Three asks, one card — a port firing three ai.complete calls doesn't stack three prompts.
        #expect(c.pendingCount == 1)
        #expect(c.queued.isEmpty)

        c.resolveCurrent(granted: true)
        #expect(await one == true)
        #expect(await two == true)
        #expect(await three == true)
    }

    @Test("the same permission from a DIFFERENT requester does not coalesce")
    func differentRequestersQueueSeparately() async {
        let c = PermissionCoordinator()
        async let echo = c.request(.ai, from: requester("echo"))
        await settle { c.current != nil }
        async let sage = c.request(.ai, from: requester("sage"))
        await settle { c.queued.count == 1 }

        #expect(c.pendingCount == 2)             // one grant must not silently answer for another
        c.resolveCurrent(granted: true)
        await settle { c.current != nil }
        c.resolveCurrent(granted: false)
        #expect(await echo == true)
        #expect(await sage == false)
    }

    @Test("a closed port's queued ask is denied, not leaked")
    func cancelResolvesRatherThanLeaks() async {
        let c = PermissionCoordinator()
        async let live = c.request(.ai, from: requester("stays"))
        await settle { c.current != nil }
        async let doomed = c.request(.camera, from: requester("closes"))
        await settle { c.queued.count == 1 }

        c.cancelRequests(from: "closes")         // the port died while queued
        #expect(await doomed == false)
        #expect(c.pendingCount == 1)

        c.resolveCurrent(granted: true)
        #expect(await live == true)
    }

    @Test("cancelling the on-screen ask advances the queue")
    func cancelCurrentAdvances() async {
        let c = PermissionCoordinator()
        async let doomed = c.request(.ai, from: requester("closes"))
        await settle { c.current != nil }
        async let next = c.request(.screen, from: requester("stays"))
        await settle { c.queued.count == 1 }

        c.cancelRequests(from: "closes")
        #expect(await doomed == false)
        await settle { c.current?.permission == .screen }
        #expect(c.current?.permission == .screen)   // the queue didn't stall behind a dead asker

        c.resolveCurrent(granted: true)
        #expect(await next == true)
    }

    @Test("denyAll resolves everything pending")
    func denyAllResolvesEverything() async {
        let c = PermissionCoordinator()
        async let a = c.request(.ai, from: requester("one"))
        await settle { c.current != nil }
        async let b = c.request(.terminal, from: requester("two"))
        await settle { c.queued.count == 1 }

        c.denyAll()
        #expect(await a == false)
        #expect(await b == false)
        #expect(c.pendingCount == 0)
    }

    @Test("answering twice is a no-op, not a crash on a resumed continuation")
    func doubleAnswerIsSafe() async {
        let c = PermissionCoordinator()
        async let answer = c.request(.ai, from: requester("echo"))
        await settle { c.current != nil }
        c.resolveCurrent(granted: true)
        c.resolveCurrent(granted: false)         // Esc racing a click
        #expect(await answer == true)
    }

    /// The card has to state what "Allow" does — the old code silently wrote a per-(companion,
    /// space) grant the human was never shown, and for spaceless callers wrote nothing at all.
    @Test("scope description distinguishes a space grant from a global one")
    func scopeDescriptionIsHonest() {
        let inSpace = Principal(id: "echo", displayName: "echo",
                                spaceId: "space-1", kind: .companion)
        let gateway = Principal(id: "local-http", displayName: "Claude Code",
                                spaceId: nil, kind: .peer)

        #expect(inSpace.scopeDescription.contains("in this space"))
        #expect(gateway.scopeDescription.contains("everywhere"))
    }

    /// Found live 2026-07-16: a mic port fires three dialogs — ours, then macOS Microphone, then
    /// macOS Speech Recognition. The card names them before they land.
    @Test("the mic ask narrates both macOS dialogs that follow")
    func micNarratesSystemFollowUp() async {
        let c = PermissionCoordinator()
        async let answer = c.request(.microphone, from: requester("voice-port"))
        await settle { c.current != nil }

        let followUp = c.current?.systemFollowUp
        #expect(followUp?.contains("Microphone") == true)
        #expect(followUp?.contains("Speech Recognition") == true)

        c.resolveCurrent(granted: false)
        _ = await answer
    }

    @Test("an ungated permission-free path never enqueues")
    func nothingPendingByDefault() {
        let c = PermissionCoordinator()
        #expect(c.current == nil)
        #expect(c.pendingCount == 0)
    }
}
