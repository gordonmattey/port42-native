import Foundation

// MARK: - Right-of-way (keystone #2, docs/plan-port42-protocol-local-bus.md §L2)
//
// One holder per port at a time: who may WRITE to it right now. A write by a non-holder is
// REJECTED, never queued and never merged — a queued write is a stale write, composed against a
// port that has since moved, applied with the author gone (§L2.6). Pessimistic and explicit,
// matching slice-02's deliberate choice for the same mechanism across the wire.
//
// Pure and time-injected: no AppState, no clock of its own. Expiry is the behaviour most likely to
// be wrong and the most miserable to test against a real clock, so `now` is always a parameter.

/// WHO holds the pen, peer-qualified. `decision-identity-model.md`: identity is three axes, and a
/// lease holds an ACTOR (a human, a companion, a port) at an INSTANCE. Local is the degenerate form
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

public struct Lease: Equatable {
    public let holder: ActorRef
    /// What a human reads on the tile ("gordon", "echo"). Never the identity — that is `holder`.
    public let holderName: String
    public let expires: Date

    public func isLive(at now: Date) -> Bool { now < expires }
}

public enum LeaseDecision: Equatable {
    /// The port was free (or the previous lease had expired) — this actor now holds it.
    case granted(Lease)
    /// Already the holder; the TTL moved forward. Deliberately distinct from `.granted` so the
    /// broadcast can fire on CHANGE only and not spam the topic on every keystroke (§L2.5).
    case refreshed(Lease)
    /// Someone else holds it. Carries who, so the error can name them.
    case denied(Lease)
}

/// The per-port holder table. A value type: one lives on `AppState`, and tests build their own.
public struct LeaseRegistry: Equatable {
    /// How long a lease survives without use. Short enough that a crashed holder frees the port on
    /// its own, long enough that a human thinking between keystrokes never loses the pen.
    public static let defaultTTL: TimeInterval = 30

    private var leases: [String: Lease] = [:]
    public let ttl: TimeInterval

    public init(ttl: TimeInterval = LeaseRegistry.defaultTTL) { self.ttl = ttl }

    /// The live holder of a port, or nil when free or expired. Read-only: never extends anything.
    public func holder(of port: String, now: Date) -> Lease? {
        guard let l = leases[port], l.isLive(at: now) else { return nil }
        return l
    }

    /// THE write gate. Acquires implicitly when free — so every single-driver flow that works today
    /// keeps working and the lease only becomes visible when there is actually contention (§L2.3).
    @discardableResult
    public mutating func check(port: String, actor: ActorRef, name: String, now: Date) -> LeaseDecision {
        let fresh = Lease(holder: actor, holderName: name, expires: now.addingTimeInterval(ttl))
        guard let current = leases[port], current.isLive(at: now) else {
            leases[port] = fresh
            return .granted(fresh)
        }
        guard current.holder == actor else { return .denied(current) }
        leases[port] = fresh
        return .refreshed(fresh)
    }

    /// Give up the pen. Only the holder can: a stray release from anyone else is a no-op, not a
    /// way to knock the current driver off.
    @discardableResult
    public mutating func release(port: String, actor: ActorRef, now: Date) -> Bool {
        guard let current = leases[port], current.isLive(at: now), current.holder == actor else { return false }
        leases.removeValue(forKey: port)
        return true
    }

    /// Explicit handoff — the answer to a knock. Only the holder may hand off; handing off a free
    /// port is not a way to assign the pen to someone else behind their back.
    @discardableResult
    public mutating func handoff(port: String, from: ActorRef, to: ActorRef,
                                 toName: String, now: Date) -> Bool {
        guard let current = leases[port], current.isLive(at: now), current.holder == from else { return false }
        leases[port] = Lease(holder: to, holderName: toName, expires: now.addingTimeInterval(ttl))
        return true
    }

    /// Drop a port's lease entirely (the port closed). Not a release: no holder check, because the
    /// thing being held no longer exists.
    public mutating func forget(port: String) {
        leases.removeValue(forKey: port)
    }
}

/// Rate-limits "the human is interacting with this port" so a claim happens at most once per
/// interval per port. Typing fires this per KEYSTROKE; the lease TTL is 30s, so re-claiming on
/// every character is pure noise, and the claim path resolves the port each time (the one part of
/// it that is not free). Pure and time-injected, like the registry.
public struct ClaimThrottle: Equatable {
    /// Comfortably inside the TTL, so a continuously-used port never lapses, while an idle one
    /// still frees itself on schedule.
    public static let defaultInterval: TimeInterval = 5

    private var last: [String: Date] = [:]
    public let interval: TimeInterval

    public init(interval: TimeInterval = ClaimThrottle.defaultInterval) { self.interval = interval }

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
