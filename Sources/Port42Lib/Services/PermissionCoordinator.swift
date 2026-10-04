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

/// How an ask ended (APP-16). A Bool could not say that NOTHING was asked: while Port42 is locked
/// the shell, the only place a card renders, is not mounted, so an ask hung with no card anywhere.
public enum PermissionOutcome: Equatable {
    /// The person clicked Allow.
    case granted
    /// The person clicked Deny, or pressed Esc on the card.
    case denied
    /// Nobody answered (APP-17): the asker went away (a port closed) or the queue was torn down.
    /// Not a denial, so the caller is told to ask again rather than that the person said no.
    case cancelled
    /// Nothing was asked: no card could be seen (locked, or not set up), so the caller retries later.
    case locked
}

/// A port asking to reach a port in another space (#238, docs/plan-cross-space-ports.md): both sides
/// by name and space, and the right the call that raised it needs. The first user of the shared card
/// (docs/plan-permission-card.md): who wants to do what to what, with the rights to pick from.
public struct CrossSpaceAsk: Equatable {
    public let readerKey: String
    public let readerTitle: String
    public let readerSpace: String
    public let targetKey: String
    public let targetTitle: String
    public let targetSpaceId: String
    public let targetSpace: String
    /// The right the call that raised the card needs. Shown, never ticked for the person.
    public let needs: RemoteRight

    public init(readerKey: String, readerTitle: String, readerSpace: String, targetKey: String,
                targetTitle: String, targetSpaceId: String, targetSpace: String, needs: RemoteRight) {
        self.readerKey = readerKey; self.readerTitle = readerTitle; self.readerSpace = readerSpace
        self.targetKey = targetKey; self.targetTitle = targetTitle
        self.targetSpaceId = targetSpaceId; self.targetSpace = targetSpace; self.needs = needs
    }

    /// The rights the card offers, weakest first. `move` is a hand-over, never a grant.
    public static let offered: [RemoteRight] = [.see, .use, .edit, .wakeAgents, .fork]
    /// The space box covers these and no more: edit is per port, always (Gordon, 2026-09-30).
    public static let spaceWide: Set<RemoteRight> = [.see, .use]
    /// What is ticked when the card opens: see, and nothing stronger.
    public static let preset: Set<RemoteRight> = [.see]

    /// The card's sentence: "Launch desk, small (port42-app) wants to use Launch desk in port42-growth".
    public var sentence: String {
        "\(readerTitle) (\(readerSpace)) wants to \(Self.verb(needs)) \(targetTitle) in \(targetSpace)"
    }

    /// The space box's words.
    public var spaceBoxLabel: String {
        "Also let it see and use every port in \(targetSpace)"
    }

    static func verb(_ r: RemoteRight) -> String {
        switch r {
        case .see: return "see"
        case .use: return "use"
        case .edit: return "edit"
        case .wakeAgents: return "wake the companions of"
        case .fork, .move: return "copy"
        }
    }

    /// What each right gives, in a line, for the card and for Settings, Access.
    public static func meaning(_ r: RemoteRight) -> String {
        switch r {
        case .see: return "read its page, source, console and state"
        case .use: return "send it input, and read and post in its chat"
        case .edit: return "change its code and name"
        case .wakeAgents: return "its chat posts wake that space's companions"
        case .fork: return "take a copy of it"
        case .move: return "take it over"
        }
    }

    /// A right that changes something or reaches people looks stronger on the card (#243).
    public static func isStrong(_ r: RemoteRight) -> Bool { r != .see }

    /// A right's name on the card and in Settings, Access.
    public static func name(_ r: RemoteRight) -> String {
        switch r {
        case .see: return "See"
        case .use: return "Use"
        case .edit: return "Edit"
        case .wakeAgents: return "Wake companions"
        case .fork: return "Copy"
        case .move: return "Take over"
        }
    }

    /// What VoiceOver reads for a right's box: its name, what it gives, its weight, and whether the
    /// call waiting on the card needs it.
    public static func accessibilityLabel(_ r: RemoteRight, needs: RemoteRight) -> String {
        var parts = [name(r), meaning(r)]
        if r == needs { parts.append("this call needs it") }
        return parts.joined(separator: ", ")
    }

    /// What VoiceOver reads for Allow: what a press gives, so it is never a bare "Allow".
    public static func allowLabel(_ picked: Set<RemoteRight>, wholeSpace: Bool) -> String {
        let names = offered.filter(picked.contains).map { name($0).lowercased() }
        guard !names.isEmpty else { return "Allow, nothing ticked" }
        var label = "Allow " + names.joined(separator: ", ")
        if wholeSpace, !picked.intersection(spaceWide).isEmpty { label += ", and see and use on every port in the space" }
        return label
    }
}

/// What the person picked on a cross-space card.
public struct CrossSpaceChoice: Equatable {
    public var rights: Set<RemoteRight>
    /// The space box: see and use on every port in the target's space, never more.
    public var wholeSpace: Bool

    public init(rights: Set<RemoteRight>, wholeSpace: Bool) {
        self.rights = rights
        self.wholeSpace = wholeSpace
    }
}

/// How an ask ended, with what the person picked on a card that offers a choice.
public struct PermissionAnswer: Equatable {
    public let outcome: PermissionOutcome
    public let choice: CrossSpaceChoice?
}

/// One pending ask. Many awaiters can ride a single request (coalescing), so a port that fires
/// three `ai.complete` calls at once shows one card and resumes all three.
public final class PermissionRequest: Identifiable, ObservableObject {
    public let id = UUID()
    public let permission: PortPermission
    public let principal: Principal
    /// What exactly is asked for, when the permission alone does not say: the named secret a caller
    /// wants to use (`rest.call`). Part of the coalescing key, so two different secrets are two cards.
    public let detail: String?
    /// A cross-space ask (#238): the card offers rights rather than a yes to one capability.
    public let crossSpace: CrossSpaceAsk?
    /// Each awaiter has an id, so one that gives up can leave without answering the others (#247).
    fileprivate var continuations: [(id: UUID, resume: CheckedContinuation<PermissionAnswer, Never>)] = []

    /// How many awaiters ride this request. Continuations stay private; the count is observable so
    /// a caller (or a test settling on registration) can see coalescing without touching them.
    public var awaiterCount: Int { continuations.count }

    fileprivate init(permission: PortPermission, principal: Principal, detail: String?,
                     crossSpace: CrossSpaceAsk? = nil) {
        self.permission = permission
        self.principal = principal
        self.detail = detail
        self.crossSpace = crossSpace
    }

    /// Resume every awaiter exactly once. The list is cleared first so a double-answer (Esc racing
    /// a click) is a no-op rather than a crash on a resumed continuation.
    fileprivate func resolve(_ outcome: PermissionOutcome, choice: CrossSpaceChoice? = nil) {
        let waiting = continuations
        continuations.removeAll()
        let answer = PermissionAnswer(outcome: outcome, choice: outcome == .granted ? choice : nil)
        for c in waiting { c.resume.resume(returning: answer) }
    }

    /// Who the card names as asking. A cross-space grant belongs to the reading port, not to whoever
    /// made it (P-260 authorizes a companion's port as the companion), so the card names the port.
    public var asker: String { crossSpace?.readerTitle ?? principal.displayName }

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

    /// Whether a card can be SEEN right now (APP-16). Supplied by the owner, which knows what the
    /// root is showing: `AppState` answers false while locked or before setup, when the shell and
    /// with it `ShellPermissionOverlay` are not mounted. Such an ask is refused as `.locked` rather
    /// than queued for a card nobody can see.
    public var canPrompt: () -> Bool = { true }

    /// Ask for a permission. Suspends until the human answers. Never returns without resolving —
    /// that's the whole point of routing every caller through one queue.
    ///
    /// Coalesces on (principal.id, permission): a repeat ask for something already pending joins
    /// the existing request instead of clobbering its continuation.
    public func request(_ permission: PortPermission, from principal: Principal,
                        detail: String? = nil) async -> Bool {
        await decide(permission, from: principal, detail: detail) == .granted
    }

    /// Called, from the task that is about to wait, when an ask will wait on a person. The gateway
    /// door sets it per call, to tell the gateway to keep the call open while the card is up (#247).
    @TaskLocal public static var awaitingPerson: (@Sendable @MainActor () -> Void)?

    /// `request`, keeping how it ended, so a lock can reach the caller as its own error (APP-16).
    ///
    /// **A caller that gives up takes its ask with it** (#247). Cancelling the waiting task resumes
    /// it as `.cancelled` and withdraws its place on the card; a card nobody else waits on goes. A
    /// late click then answers nobody, so it cannot act for a caller that is gone (a gateway call that
    /// timed out used to have its companions.delete applied when the person clicked Allow later).
    public func decide(_ permission: PortPermission, from principal: Principal,
                       detail: String? = nil) async -> PermissionOutcome {
        await answer(permission, from: principal, detail: detail, crossSpace: nil).outcome
    }

    /// Ask the cross-space card (#238). Coalesces on the two ports, so a port that calls twice while
    /// the card is up gets one card, whatever right each call needs.
    public func decideCrossSpace(_ ask: CrossSpaceAsk, from principal: Principal) async -> PermissionAnswer {
        await answer(.crossSpace, from: principal, detail: ask.sentence, crossSpace: ask)
    }

    private func answer(_ permission: PortPermission, from principal: Principal, detail: String?,
                        crossSpace: CrossSpaceAsk?) async -> PermissionAnswer {
        guard canPrompt() else { return PermissionAnswer(outcome: .locked, choice: nil) }
        if Task.isCancelled { return PermissionAnswer(outcome: .cancelled, choice: nil) }
        Self.awaitingPerson?()
        let awaiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let existing = find(permission, principal, detail, crossSpace) {
                    existing.continuations.append((awaiter, continuation))
                    return
                }
                let req = PermissionRequest(permission: permission, principal: principal, detail: detail,
                                            crossSpace: crossSpace)
                req.continuations.append((awaiter, continuation))
                if current == nil {
                    current = req
                } else {
                    queued.append(req)
                }
            }
        } onCancel: {
            // Hops to the main actor, where the continuation above was registered synchronously, so
            // the withdrawal always finds it.
            Task { @MainActor [weak self] in self?.withdraw(awaiter) }
        }
    }

    /// One awaiter gives up: it is answered `.cancelled`, and its card goes if nobody else waits on it.
    private func withdraw(_ awaiter: UUID) {
        let all = (current.map { [$0] } ?? []) + queued
        guard let req = all.first(where: { $0.continuations.contains { $0.id == awaiter } }),
              let i = req.continuations.firstIndex(where: { $0.id == awaiter }) else { return }
        let gone = req.continuations.remove(at: i)
        gone.resume.resume(returning: PermissionAnswer(outcome: .cancelled, choice: nil))
        guard req.continuations.isEmpty else { return }
        if current === req {
            current = nil
            advance()
        } else {
            queued.removeAll { $0 === req }
        }
    }

    private func find(_ permission: PortPermission, _ principal: Principal,
                      _ detail: String?, _ crossSpace: CrossSpaceAsk?) -> PermissionRequest? {
        func same(_ r: PermissionRequest) -> Bool {
            if let ask = crossSpace {
                return r.crossSpace.map { $0.readerKey == ask.readerKey && $0.targetKey == ask.targetKey } ?? false
            }
            return r.permission == permission && r.principal.id == principal.id && r.detail == detail
        }
        if let c = current, same(c) { return c }
        return queued.first(where: same)
    }

    /// Answer the current card and advance the queue.
    public func resolveCurrent(granted: Bool, choice: CrossSpaceChoice? = nil) {
        guard let req = current else { return }
        current = nil
        req.resolve(granted ? .granted : .denied, choice: choice)
        advance()
    }

    /// Resolve everything pending as CANCELLED (APP-17): nobody answered these cards. The "get me out of here" path (Esc denies only the current card;
    /// this is for teardown, e.g. the shell going away with asks outstanding).
    public func denyAll() {
        withdrawAll(.cancelled)
    }

    /// Resolve everything pending with one outcome. Locking uses `.locked` (APP-16): the cards on
    /// screen are about to be covered, and a card nobody can see is not a consent surface.
    public func withdrawAll(_ outcome: PermissionOutcome) {
        let all = (current.map { [$0] } ?? []) + queued
        current = nil
        queued.removeAll()
        for req in all { req.resolve(outcome) }
    }

    /// Drop any pending asks from a principal that no longer exists — a port closed while its card
    /// was queued. Denies rather than leaks, so the caller's `await` always returns.
    public func cancelRequests(from principalId: String) {
        queued.removeAll { req in
            guard req.principal.id == principalId else { return false }
            req.resolve(.cancelled)
            return true
        }
        if let c = current, c.principal.id == principalId {
            current = nil
            c.resolve(.cancelled)
            advance()
        }
    }

    private func advance() {
        guard current == nil, !queued.isEmpty else { return }
        current = queued.removeFirst()
    }
}
