import Foundation
import Combine

// MARK: - Permission Coordinator
//
// ONE place a permission is asked, queued, and answered — for every caller.
//
// Before this, three callers each rolled their own: `PortBridge` (a port's JS), `ToolExecutor` (an
// in-app companion's tool use), and `RemoteToolExecutor` (the gateway — Claude Code, curl, any
// external caller). Each owned a `permissionContinuation` + `pendingPermission` pair, and each had
// (or lacked) its own render site. Two holes and a leak followed:
//
//   1. The port card rendered inside ChatView — a chat TILE. Focused on a port, it was off-screen
//      and the call hung forever.
//   2. The tool-use card rendered in ContentView, deleted by 60fc1d7 ("retire classic mode").
//      Since that commit `activeToolExecutor` had NO reader: every gated gateway call hung
//      indefinitely with no prompt on any rung (verified 2026-07-16 in dev — notify.send,
//      clipboard.read, terminal.exec all timed out at 6s).
//   3. A second ask clobbered the first's continuation, so the first waiter never resumed.
//      Reproduced by accident with three curl probes ten seconds apart.
//
// The fix is structural, not cosmetic: requesters own no continuation state, there is one queue,
// and ShellView renders it once — so a render site can never again go missing without the compiler
// noticing.

// Who is asking is a `Principal` (Principal.swift) — the same identity the dispatcher keys grants
// on. Identity drives coalescing (same asker + same permission = one card) and the grant's scope,
// so the card can state what "Allow" actually does. `PermissionRequester`, the coordinator's own
// first draft of that identity, collapsed into Principal in Phase 3.

/// One pending ask. Many awaiters can ride a single request (coalescing), so a port that fires
/// three `ai.complete` calls at once shows one card and resumes all three.
public final class PermissionRequest: Identifiable, ObservableObject {
    public let id = UUID()
    public let permission: PortPermission
    public let principal: Principal
    fileprivate var continuations: [CheckedContinuation<Bool, Never>] = []

    /// How many awaiters ride this request. Continuations stay private; the count is observable so
    /// a caller (or a test settling on registration) can see coalescing without touching them.
    public var awaiterCount: Int { continuations.count }

    fileprivate init(permission: PortPermission, principal: Principal) {
        self.permission = permission
        self.principal = principal
    }

    /// Resume every awaiter exactly once. The list is cleared first so a double-answer (Esc racing
    /// a click) is a no-op rather than a crash on a resumed continuation.
    fileprivate func resolve(_ granted: Bool) {
        let waiting = continuations
        continuations.removeAll()
        for c in waiting { c.resume(returning: granted) }
    }

    /// The macOS consent dialogs that follow OUR card, named before they appear. Found live
    /// 2026-07-16: a mic port fires three dialogs back-to-back — our card, then macOS Microphone,
    /// then macOS Speech Recognition (`SFSpeechRecognizer` needs its own TCC grant; nobody expects
    /// that one). GM: "our permission box should say: we're asking you for two permissions, Apple
    /// will show you the screens, click Yes and Yes."
    public var systemFollowUp: String? {
        switch permission {
        case .microphone:
            return "macOS will ask twice next — Microphone, then Speech Recognition. Say yes to both."
        case .camera:
            return "macOS will ask for Camera access next."
        case .screen:
            return "macOS will ask for Screen Recording next. It may need Port42 restarted once."
        case .automation:
            return "macOS will ask to allow controlling other apps, per app, as they're touched."
        default:
            return nil
        }
    }
}

/// Owns the queue and is the single source of truth for what card (if any) is on screen.
/// Rendered once, at the shell level (`ShellView`), above every other overlay — a blocking ask is
/// not a browsable one.
@MainActor
public final class PermissionCoordinator: ObservableObject {

    /// The request currently on screen. nil = no card.
    @Published public private(set) var current: PermissionRequest?

    /// Asks behind the current one, in arrival order. Shown as "1 of N" so a queue is never a
    /// surprise.
    @Published public private(set) var queued: [PermissionRequest] = []

    public var pendingCount: Int { (current == nil ? 0 : 1) + queued.count }

    public init() {}

    /// Ask for a permission. Suspends until the human answers. Never returns without resolving —
    /// that's the whole point of routing every caller through one queue.
    ///
    /// Coalesces on (principal.id, permission): a repeat ask for something already pending joins
    /// the existing request instead of clobbering its continuation.
    public func request(_ permission: PortPermission, from principal: Principal) async -> Bool {
        await withCheckedContinuation { continuation in
            if let existing = find(permission, principal) {
                existing.continuations.append(continuation)
                return
            }
            let req = PermissionRequest(permission: permission, principal: principal)
            req.continuations.append(continuation)
            if current == nil {
                current = req
            } else {
                queued.append(req)
            }
        }
    }

    private func find(_ permission: PortPermission, _ principal: Principal) -> PermissionRequest? {
        if let c = current, c.permission == permission, c.principal.id == principal.id { return c }
        return queued.first { $0.permission == permission && $0.principal.id == principal.id }
    }

    /// Answer the current card and advance the queue.
    public func resolveCurrent(granted: Bool) {
        guard let req = current else { return }
        current = nil
        req.resolve(granted)
        advance()
    }

    /// Deny everything pending — the "get me out of here" path (Esc denies only the current card;
    /// this is for teardown, e.g. the shell going away with asks outstanding).
    public func denyAll() {
        let all = (current.map { [$0] } ?? []) + queued
        current = nil
        queued.removeAll()
        for req in all { req.resolve(false) }
    }

    /// Drop any pending asks from a principal that no longer exists — a port closed while its card
    /// was queued. Denies rather than leaks, so the caller's `await` always returns.
    public func cancelRequests(from principalId: String) {
        queued.removeAll { req in
            guard req.principal.id == principalId else { return false }
            req.resolve(false)
            return true
        }
        if let c = current, c.principal.id == principalId {
            current = nil
            c.resolve(false)
            advance()
        }
    }

    private func advance() {
        guard current == nil, !queued.isEmpty else { return }
        current = queued.removeFirst()
    }
}
