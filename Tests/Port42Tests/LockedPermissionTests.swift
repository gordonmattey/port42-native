import Testing
import Foundation
@testable import Port42Lib

/// **While locked, nothing is asked** (APP-16).
///
/// The permission card renders only in the shell, and the lock screen (and setup) replaces the shell.
/// An ask raised then queued a card nobody could see, and the caller hung until someone unlocked.
/// Now it is refused at once with its own code, `locked`, and locking withdraws a card already up.
@Suite("Locked permission asks (APP-16)", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LockedPermissionTests {

    func port() -> Principal {
        Principal.port(id: "port-\(UUID().uuidString)", displayName: "a port", spaceId: "space-1")
    }

    @Test("no card can be seen: the coordinator queues nothing and answers .locked")
    func coordinatorRefuses() async {
        let c = PermissionCoordinator()
        c.canPrompt = { false }
        final class Box { var outcome: PermissionOutcome? }
        let box = Box()
        let p = port()
        let task = Task { @MainActor in box.outcome = await c.decide(.clipboard, from: p) }
        if !(await within(5) { box.outcome != nil }) {
            Issue.record("the ask was queued for a card nobody can see")
            c.resolveCurrent(granted: false)
        }
        await task.value
        #expect(box.outcome == .locked)
        #expect(c.pendingCount == 0)
    }

    /// Wait up to `seconds` for `condition`; true if it held. Bounded, so a broken gate fails
    /// instead of hanging the suite.
    func within(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    @Test("a gated call while locked is refused as `locked`, not left hanging")
    func gatedCallRefusedAsLocked() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.showDreamscape = true
        #expect(appState.permissions.canPrompt() == false, "locked: the shell is not mounted")
        final class Box { var code: String?; var done = false }
        let box = Box()
        let p = port()
        let task = Task { @MainActor in
            do { _ = try await appState.runBridgeMethod("clipboard.read", principal: p, args: BridgeArgs([:])) }
            catch let e as BridgeError { box.code = e.code }
            catch {}
            box.done = true
        }
        _ = await within(5) { box.done || appState.permissions.current != nil }
        if appState.permissions.current != nil {
            Issue.record("a card was queued while locked, where nobody can see it")
            appState.permissions.resolveCurrent(granted: false)
        }
        await task.value
        #expect(box.code == BridgeErrorCode.locked.wire)
        #expect(appState.permissions.pendingCount == 0, "no invisible card left behind")
    }

    @Test("locking withdraws a card already up, as .locked, and grants nothing")
    func lockingWithdraws() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { true }
        appState.showDreamscape = false
        let p = port()
        final class Box { var outcome: PermissionOutcome? }
        let box = Box()
        let task = Task { @MainActor in box.outcome = await appState.permissions.decide(.camera, from: p) }
        #expect(await within(5) { appState.permissions.current != nil })
        appState.showDreamscape = true
        if !(await within(5) { box.outcome != nil }) {
            Issue.record("locking left the card pending")
            appState.permissions.resolveCurrent(granted: false)
        }
        await task.value
        #expect(box.outcome == .locked)
        #expect(appState.permissions.pendingCount == 0)
        #expect(appState.grants(grantee: p.id, on: .machine, zone: p.zone).isEmpty)
    }

    @Test("`locked` is its own wire code, filed under asking the person")
    func distinctCode() {
        #expect(BridgeErrorCode.locked.wire == "locked")
        #expect(BridgeErrorCode.locked.wire != BridgeErrorCode.permissionDenied.wire)
        #expect(BridgeErrorCode.locked.repair == .askTheUser)
    }
}
