import Foundation

// MARK: - The input seam (I2 · C1)
//
// ONE DOOR for "something entered a port", whatever the surface technology.
//
// The frame is already public: a human and an agent reach the same surface through one bridge, with
// the same methods and the same permissions. Five caller types are named there and ALL of them are
// programmatic. A person typing, dictating, pasting or dropping touches no bridge at all. This is
// the missing half of a promise already made, not a new layer.
//
// WHY IT IS A SEAM AND NOT A SWEEP. There were six ad-hoc hooks for "input reached a port", split by
// surface technology (Ghostty, WKWebView, SwiftUI chrome), because each grew its own plumbing. Three
// separate sweeps for "every way into a terminal" each found a path the last had missed, and C0 then
// found a fourth. A guarantee that depends on someone having enumerated the callers is a to-do list
// that rots silently.
//
// WHAT IT IS FOR: the TOKEN. A token claims "has this port changed since I looked", and that claim
// is FALSE for any mutation that does not count. Measured in Spike C: dictation, the emoji picker,
// right-click paste and a cross-app drag all changed a port while its token stood still. Until every
// way in counts, R5 ("terminals require a token") would enforce a guarantee we cannot make.
//
// C1 defines the door and nothing calls it. C2 moves the translators, C4 makes the tables private so
// the compiler names anything missed.

/// Something entered a port. One shape for every surface, so the surfaces only translate.
public struct PortInput: Equatable {

    /// What arrived. Deliberately about the SOURCE, not about what any consumer wants to do with it.
    public enum Kind: Equatable {
        /// Characters reached the port: typed, pasted, dictated, dropped, or composed by an IME.
        /// The payload is what arrived, not how it was produced, which is why dictation and the
        /// emoji picker are translators here rather than special cases.
        case text(String)
        /// A pointer gesture. GM: a gesture bumps the token, because a canvas click can change
        /// everything and produces no `beforeinput` at all.
        case gesture
        /// A browser port went somewhere new, which replaces the entire document.
        case navigation(URL)
        /// A write with no human behind it: a bridge verb, a startup command, a prefill.
        case programmatic
    }

    /// How we know this happened. R7 lives here: moving the human's claim off page-reported
    /// `isTrusted` becomes a change of this value at one translator, not a new mechanism.
    public enum Trust: Equatable {
        /// Observed by us. A page cannot forge it.
        case native
        /// A page told us, via an injected listener's `isTrusted`. A page can shadow that property,
        /// so this is a claim and not evidence.
        case reportedByPage
        /// An authenticated caller arrived through the dispatcher.
        case principal
    }

    /// The port, as `PortRef.key`. One address, resolved once by the caller.
    public let port: String
    public let kind: Kind

    /// WHO, or nil when there is nobody to attribute it to.
    ///
    /// **The plan sketched this non-optional; I1.1 measured that it cannot be.** Native input can
    /// arrive before setup completes, when `humanPrincipal` is nil, and the app writes to a pty at
    /// spawn time (startup command, first-run prefill) on behalf of no one. Forcing a value would
    /// mean inventing an identity for those, which is precisely what I1.3 forbade after finding
    /// every gateway-created port pooled into one shared id.
    ///
    /// So nil is a real answer: *the port changed, and we do not know who.* The token still moves,
    /// because it must, and presence records nothing, because naming a driver would be a lie.
    public let actor: ActorRef?
    public let trust: Trust

    /// Display name for presence. Carried beside `actor` rather than inside it because `ActorRef` is
    /// the wire identity and a label must never become part of one (Phase 3: grants key on the id,
    /// display never is). nil falls back to the principal id, so a chip is never blank.
    public let actorName: String?

    public init(port: String, kind: Kind, actor: ActorRef?, actorName: String? = nil, trust: Trust) {
        self.port = port
        self.kind = kind
        self.actor = actor
        self.actorName = actorName
        self.trust = trust
    }
}

// MARK: - The seam

/// Owns everything a port's input can mutate, so that "did this path remember to count" stops being
/// a question anyone has to ask.
///
/// Pure and value-typed: it decides, and returns what its caller must then do in the world
/// (broadcast a driver change). Nothing here reaches a bus, a view or a clock, which is what makes
/// the policy testable without an app.
public struct PortInputSeam {

    /// What the caller must do as a result. A driver change is the only observable side effect, and
    /// it is returned rather than performed so this stays pure.
    public struct Outcome: Equatable {
        /// The port's token AFTER this input. Every input produces one, because every input counts.
        public let token: String
        /// Non-nil when presence MOVED and the change is worth broadcasting. A refresh is silent by
        /// design: publishing per keystroke would drown the port's topic in non-news.
        public let driverChanged: Driver?
    }

    private var activity: PortActivity
    private var drivers: DriverRegistry
    private var throttle: PresenceThrottle

    public init(activity: PortActivity = PortActivity(),
                drivers: DriverRegistry = DriverRegistry(),
                throttle: PresenceThrottle = PresenceThrottle()) {
        self.activity = activity
        self.drivers = drivers
        self.throttle = throttle
    }

    // MARK: Reads

    public func token(for port: String) -> String { activity.token(for: port) }
    public func seq(for port: String) -> Int { activity.seq(for: port) }
    public func driver(of port: String, now: Date) -> Driver? { drivers.driver(of: port, now: now) }

    /// A CONSISTENT snapshot of every port's counter, for a caller listing many ports at once.
    ///
    /// `ports.list` reads a token per row, and rows read at different moments would hand out tokens
    /// that were never all true together: a caller could compose against a set of tokens that never
    /// coexisted. Taking the value once gives every row the same instant. A copy, so a reader cannot
    /// mutate through it.
    public var activitySnapshot: PortActivity { activity }

    // MARK: Transitional passthroughs (C2.0 only — C2.1..n and C4 delete these)
    //
    // C2.0 moves OWNERSHIP of the tables and nothing else. Ownership has to move first and in one
    // step: while `AppState` held its own copies and the seam held others, moving a single
    // translator would have bumped one counter while every reader read the other, splitting a port's
    // token in two for the length of the migration. That is the exact lie the seam exists to
    // prevent, and it would have been introduced by the work meant to prevent it.
    //
    // So the existing call sites keep their logic verbatim and simply operate on the seam's tables.
    // Each translator that moves to `received(_:)` deletes its passthrough with it; C4 removes
    // whatever is left and the compiler names anything still reaching for one.
    //
    // These are NOT the seam's interface. `received(_:)` is.

    @discardableResult
    mutating func bumpDirectly(_ port: String) -> String { activity.bump(port) }

    mutating func recordDirectly(port: String, actor: ActorRef, name: String, now: Date) -> DriverChange {
        drivers.record(port: port, actor: actor, name: name, now: now)
    }

    mutating func throttleAllows(port: String, now: Date) -> Bool {
        throttle.allow(port: port, now: now)
    }


    // MARK: The door

    /// Something entered a port. THE one place the token moves and presence is recorded.
    ///
    /// Two rules, and the second follows from the first:
    ///
    /// 1. **The token ALWAYS moves.** Unconditionally, before anything else, for every kind. This is
    ///    the entire point of the seam: a token is a claim about whether the port changed, so a path
    ///    that changes the port without counting makes the claim false. It is deliberately not
    ///    throttled either, which would be a correctness hole rather than a tuning choice: a
    ///    companion's write composed four seconds ago would pass CAS against a line you are halfway
    ///    through typing, which is the splice R5 exists to stop.
    ///
    /// 2. **Presence is recorded only when there is an actor.** Not a separate flag, which would be
    ///    the fifth field the design warns about. The absence of an actor already says everything:
    ///    an app writing a startup command into a pty has nobody to name, and naming the app as the
    ///    driver of a port the user just opened would be a lie.
    ///
    /// The throttle applies to a REFRESH and never to a TAKEOVER. Its original argument was
    /// "re-claiming a lease you already hold is noise", which died with the lock: under
    /// last-driver-wins you do not still hold it, so your next keystroke is a genuine change and
    /// dropping it leaves the chrome naming someone who stopped.
    @discardableResult
    public mutating func received(_ input: PortInput, now: Date = Date()) -> Outcome {
        let token = activity.bump(input.port)

        guard let actor = input.actor else {
            return Outcome(token: token, driverChanged: nil)
        }

        if drivers.driver(of: input.port, now: now)?.ref == actor {
            guard throttle.allow(port: input.port, now: now) else {
                return Outcome(token: token, driverChanged: nil)
            }
        }

        switch drivers.record(port: input.port, actor: actor,
                              name: input.actorName ?? actor.principal, now: now) {
        case .changed(let d): return Outcome(token: token, driverChanged: d)
        case .refreshed:      return Outcome(token: token, driverChanged: nil)
        }
    }

    /// A port is gone. Presence forgets it; **the token deliberately does not.**
    ///
    /// The two have opposite lifecycles, and Spike A's fourth correction was exactly this: a reset
    /// counter lets a token minted against a dead port pass CAS against a live one that reused the
    /// id. Presence is a statement about now and must lapse; a token is a statement about history
    /// and must not rewind. The epoch covers a restart; this covers a reused id within one run.
    public mutating func portClosed(_ port: String) {
        drivers.forget(port: port)
        throttle.forget(port: port)
    }
}
