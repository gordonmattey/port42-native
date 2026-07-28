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
//
// STEP 3 (2026-07-27) LEFT ONLY THE VOCABULARY HERE. `DriverRegistry` and `PresenceThrottle` are
// gone: presence is DERIVED from the activity record, because whoever moved the token last is the
// one driving, and a second table storing that fact could only ever disagree with the first. See
// `PortActivity`. What remains is the two value types the derivation and the broadcast both speak
// in — an ACTOR and the DRIVER a surface displays.
//
// FOCUS NO LONGER CONFERS PRESENCE (GM, 2026-07-27). It used to record a driver without moving the
// token, which under a derived driver would assert presence while proving nothing. The alternative
// considered was writing the actor into the same record without touching `seq`, which keeps the old
// behaviour and still deletes the table; it was rejected because presence has to cross the wire at
// slice-02, and a peer cannot verify a focus against anything, since a focus is invisible to them.
// Derived from the token, the claim is checkable from the token itself. Zooming into a port and not
// touching it now leaves the chip naming the companion that is actually writing, which is true.
// Pointerdown INSIDE a surface still counts as acting, on terminals and web ports both.

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

/// What a surface SHOWS: who is driving a port, and until when. A derived value since step 3 —
/// `PortActivity.driver(of:now:)` builds one from the last actor to move the port's token. Nothing
/// stores it, which is why nothing can disagree about it.
public struct Driver: Equatable {
    public let ref: ActorRef
    /// What a human reads on the tile ("gordon", "echo"). Never the identity — that is `ref`.
    public let name: String
    /// When the chip should fade. DISPLAY freshness, not a lock and not a lease: nothing consults
    /// this to decide whether a write lands. What refuses a write is CAS against the token.
    public let expires: Date

    public func isLive(at now: Date) -> Bool { now < expires }
}
