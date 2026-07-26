import Foundation

// MARK: - Presence (keystone #2, docs/plan-port42-protocol-local-bus.md §"Phase L2 REVISED")
//
// WHO IS DRIVING a port right now. It shows; it does not refuse. R1 demoted this from a write
// lock, because the built version conflated two problems: stale writes are a CORRECTNESS problem
// and who is driving is a COORDINATION one, and a single time-based lock served both badly — which
// is why the TTL never had a principled value. Correctness moves to state tokens (R2–R5, one
// monotonic activity `seq` per port); this layer keeps only the part a lock was never needed for.
//
// LAST DRIVER WINS. Recording is unconditional: whoever wrote most recently is the one driving,
// which is the only reading that stays true when a human starts typing into a port a companion has
// been writing to. Refusing to move the ref would leave the chrome naming someone who stopped.
//
// Pure and time-injected: no AppState, no clock of its own. Expiry is the behaviour most likely to
// be wrong and the most miserable to test against a real clock, so `now` is always a parameter.
// The remaining TTL is DISPLAY freshness (when the chip should fade), not correctness — R6 replaces
// it with turn-scoped events for companions, which have a real end signal.

/// WHO is driving, peer-qualified. `decision-identity-model.md`: identity is three axes, and
/// presence names an ACTOR (a human, a companion, a port) at an INSTANCE. Local is the degenerate form
/// — `peer == nil` — so the same value works unchanged when slice-02 makes the peer explicit, and
/// the local lease is not a different object from the remote one.
public struct ActorRef: Equatable, Hashable, CustomStringConvertible {
    /// The instance. nil = this one (written as a bare principal id).
    public let peer: String?
    /// The acting principal: `Principal.id` — a human, a companion, or a port's creator.
    public let principal: String

    public init(peer: String? = nil, principal: String) {
        self.peer = peer
        self.principal = principal
    }

    /// `<peerID>/<principalId>`, or just `<principalId>` locally. The wire form.
    public var description: String {
        guard let peer, !peer.isEmpty else { return principal }
        return "\(peer)/\(principal)"
    }

    /// Parse the wire form back. A bare id is local, which is what makes today's strings
    /// forward-compatible instead of needing a migration when peers arrive.
    public static func parse(_ s: String) -> ActorRef {
        guard let slash = s.firstIndex(of: "/") else { return ActorRef(principal: s) }
        let peer = String(s[s.startIndex..<slash])
        let principal = String(s[s.index(after: slash)...])
        return peer.isEmpty || principal.isEmpty ? ActorRef(principal: s)
                                                 : ActorRef(peer: peer, principal: principal)
    }
}

public struct Driver: Equatable {
    public let ref: ActorRef
    /// What a human reads on the tile ("gordon", "echo"). Never the identity — that is `ref`.
    public let name: String
    public let expires: Date

    public func isLive(at now: Date) -> Bool { now < expires }
}

public enum DriverChange: Equatable {
    /// The driver CHANGED — a free port, a lapsed one, or a different actor taking over.
    case changed(Driver)
    /// The same actor again; only the freshness window moved. Deliberately distinct from `.changed`
    /// so the broadcast can fire on CHANGE only and not spam the topic on every keystroke (§L2.5).
    case refreshed(Driver)
}

/// The per-port driver table. A value type: one lives on `AppState`, and tests build their own.
public struct DriverRegistry: Equatable {
    /// How long presence survives without use — DISPLAY freshness, not a lock. Short enough that a
    /// crashed writer stops being shown as driving, long enough that a human thinking between
    /// keystrokes does not flicker off the chrome.
    public static let defaultTTL: TimeInterval = 30

    private var drivers: [String: Driver] = [:]
    public let ttl: TimeInterval

    public init(ttl: TimeInterval = DriverRegistry.defaultTTL) { self.ttl = ttl }

    /// The live driver of a port, or nil when nobody is or the record went stale. Read-only: never
    /// extends anything.
    public func driver(of port: String, now: Date) -> Driver? {
        guard let l = drivers[port], l.isLive(at: now) else { return nil }
        return l
    }

    /// Record that this actor just drove the port. ALWAYS succeeds — presence observes, it does not
    /// arbitrate (R1). The return says only whether the driver CHANGED, which is what the Notify
    /// broadcast keys off: a refresh fires per keystroke and publishing it would be all noise.
    @discardableResult
    public mutating func record(port: String, actor: ActorRef, name: String, now: Date) -> DriverChange {
        let fresh = Driver(ref: actor, name: name, expires: now.addingTimeInterval(ttl))
        let sameDriver = drivers[port].map { $0.isLive(at: now) && $0.ref == actor } ?? false
        drivers[port] = fresh
        return sameDriver ? .refreshed(fresh) : .changed(fresh)
    }

    /// Stop being shown as the driver. Only the current one can: a stray release from anyone else is
    /// a no-op, so nobody can clear someone else's presence out from under them.
    @discardableResult
    public mutating func release(port: String, actor: ActorRef, now: Date) -> Bool {
        guard let current = drivers[port], current.isLive(at: now), current.ref == actor else { return false }
        drivers.removeValue(forKey: port)
        return true
    }

    /// Explicit handoff — the answer to a knock. Only the current driver may hand off; handing off a
    /// port nobody is driving is not a way to assign it to someone else behind their back.
    @discardableResult
    public mutating func handoff(port: String, from: ActorRef, to: ActorRef,
                                 toName: String, now: Date) -> Bool {
        guard let current = drivers[port], current.isLive(at: now), current.ref == from else { return false }
        drivers[port] = Driver(ref: to, name: toName, expires: now.addingTimeInterval(ttl))
        return true
    }

    /// Drop a port's presence entirely (the port closed). Not a release: no driver check, because
    /// the thing being driven no longer exists.
    public mutating func forget(port: String) {
        drivers.removeValue(forKey: port)
    }
}

/// Rate-limits "the human is interacting with this port" so a claim happens at most once per
/// interval per port. Typing fires this per KEYSTROKE; the freshness window is 30s, so re-recording
/// on every character is pure noise, and the claim path resolves the port each time (the one part of
/// it that is not free). Pure and time-injected, like the registry.
public struct PresenceThrottle: Equatable {
    /// Comfortably inside the TTL, so a continuously-used port never goes stale, while an idle one
    /// still ages out on schedule.
    public static let defaultInterval: TimeInterval = 5

    private var last: [String: Date] = [:]
    public let interval: TimeInterval

    public init(interval: TimeInterval = PresenceThrottle.defaultInterval) { self.interval = interval }

    /// True when this port should claim now. The FIRST interaction always passes — the moment you
    /// touch a port is exactly when the claim matters most.
    public mutating func allow(port: String, now: Date) -> Bool {
        if let prev = last[port], now.timeIntervalSince(prev) < interval { return false }
        last[port] = now
        return true
    }

    /// Forget a port's throttle state (it closed), so a reused id starts fresh.
    public mutating func forget(port: String) { last.removeValue(forKey: port) }
}
