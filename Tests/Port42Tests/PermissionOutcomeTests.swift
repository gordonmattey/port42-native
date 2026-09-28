import Testing
import Foundation
import ScreenCaptureKit
@testable import Port42Lib

/// **A denial, a withdrawn card and a macOS refusal are three answers, not one** (APP-17).
///
/// A card torn down unanswered (the port closed, the queue went away) reached the caller as
/// `permission_denied`, the same code as the person clicking Deny. macOS privacy refusals said
/// `permission_denied` too, and Screen Recording's was found by matching "permission" or "denied"
/// in a localized message.
@Suite("Permission outcomes keep their reason (APP-17)", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct PermissionOutcomeTests {

    func port(_ id: String = "port-\(UUID().uuidString)") -> Principal {
        Principal.port(id: id, displayName: id, spaceId: "space-1")
    }

    /// Bounded wait, so a broken coordinator fails instead of hanging.
    func within(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    @Test("Deny is .denied; a closed asker and a torn-down queue are .cancelled")
    func coordinatorKeepsTheReason() async {
        let c = PermissionCoordinator()
        final class Box { var denied, dropped, torn: PermissionOutcome? }
        let box = Box()
        let asked = port("asked"), closes = port("closes"), torn = port("torn")
        let t1 = Task { @MainActor in box.denied = await c.decide(.clipboard, from: asked) }
        #expect(await within(5) { c.current != nil })
        let t2 = Task { @MainActor in box.dropped = await c.decide(.camera, from: closes) }
        #expect(await within(5) { c.queued.count == 1 })

        c.cancelRequests(from: closes.id)
        c.resolveCurrent(granted: false)
        await t1.value; await t2.value
        #expect(box.denied == .denied)
        #expect(box.dropped == .cancelled)

        let t3 = Task { @MainActor in box.torn = await c.decide(.ai, from: torn) }
        #expect(await within(5) { c.current != nil })
        c.denyAll()
        await t3.value
        #expect(box.torn == .cancelled)
    }

    @Test("the gate answers permission_cancelled for a withdrawn card, and keeps no grant")
    func gateMapsCancelled() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { true }   // a mounted shell (APP-16)
        let p = port()
        final class Box { var code: String? }
        let box = Box()
        let task = Task { @MainActor in
            do { _ = try await appState.runBridgeMethod("clipboard.read", principal: p, args: BridgeArgs([:])) }
            catch let e as BridgeError { box.code = e.code }
            catch {}
        }
        #expect(await within(5) { appState.permissions.current != nil })
        appState.permissions.cancelRequests(from: p.id)
        await task.value
        #expect(box.code == BridgeErrorCode.permissionCancelled.wire)
        #expect(appState.grants(grantee: p.id, on: .machine, zone: p.zone).isEmpty)
    }

    @Test("Screen Recording: macOS's own refusal is os_denied; other failures are not, whatever they say")
    func screenRefusalByCodeNotText() {
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        #expect(ScreenBridge.isScreenRecordingRefusal(declined, preflight: true))
        #expect(ScreenBridge.isScreenRecordingRefusal(NSError(domain: "x", code: 1), preflight: false),
                "no access right now is a refusal")

        // The old rule called both of these refusals: any SCStreamError, and any "permission" text.
        let otherStreamError = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStart.rawValue)
        let wordy = NSError(domain: "x", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "file permission denied by the disk"])
        #expect(!ScreenBridge.isScreenRecordingRefusal(otherStreamError, preflight: true))
        #expect(!ScreenBridge.isScreenRecordingRefusal(wordy, preflight: true))
    }

    @Test("Automation: -1743 and -1744 are macOS's refusal; a script's own error is not")
    func automationRefusal() {
        #expect(AutomationBridge.isAutomationRefusal(-1743))
        #expect(AutomationBridge.isAutomationRefusal(-1744))
        #expect(!AutomationBridge.isAutomationRefusal(-2753))
        #expect(!AutomationBridge.isAutomationRefusal(nil))
    }

    @Test("each outcome has its own wire code")
    func codesAreDistinct() {
        let wires: Set = [BridgeErrorCode.permissionDenied.wire, BridgeErrorCode.permissionCancelled.wire,
                          BridgeErrorCode.osDenied.wire, BridgeErrorCode.locked.wire]
        #expect(wires.count == 4)
    }
}
