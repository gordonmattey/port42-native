import Foundation

// MARK: - Activity tokens (R2, docs/plan-port42-protocol-local-bus.md §"Phase L2 REVISED")
//
// CORRECTNESS, the half that presence gave up. Every port carries a monotonic counter bumped by
// anything that changes it: a bridge write, a programmatic terminal write, trusted human input, an
// external change we observe. A writer composes against a token and hands it back with the write;
// if the port has moved since, the write is stale and is refused with the current token attached,
// so a naive caller self-corrects in one retry (R3).
//
// Correct whether the writer thought for 3ms or 3 hours, and identical locally and across
// instances — which a lock can never be, because clocks do not agree between peers. That is what
// this replaced: the lease was doing this job with a TTL, and a TTL has no principled value.
//
// WHY AN INPUT COUNT AND NOT AN OUTPUT ONE: a redrawing TUI (claude's own UI, htop) emits
// constantly, so an output token would move every frame and every write would fail. Input sequence
// means exactly "has anyone written to this since I looked", and redraw does not perturb it.
//
// THE COUNTER-RULE: a port's OWN internal mutation must NOT bump. Only external writes and human
// input count. An animating port that bumped per frame would invalidate every token every frame,
// which is the same failure that ruled out an output token.
//
// STEP 3 (2026-07-27): PRESENCE IS DERIVED FROM THIS RECORD, not stored beside it.
//
// `DriverRegistry` was a second table answering "who acted on this port", next to a counter that
// already moved when someone did. Two homes for one fact is what the register exists to catch, and
// it was the last instance inside the seam. So an entry carries WHO moved the counter and WHEN, and
// the driver is read off it. GM's framing: presence is proven through the token, and humans hold one
// too, because their keystroke is what moves it.
//
// What that deleted: the registry, the presence throttle (recording is no longer a second write with
// a cost to rate-limit), `release`/`handoff` (lease-era verbs with no production callers), and the
// seam's second mutating door. R6 went with them: with a derived driver there is no expiry to tune,
// only a display fade over the last write's timestamp.

/// Per-port activity, epoch-qualified: how many times a port changed, plus who changed it last.
/// Pure: no AppState, no clock, no IO.
public struct PortActivity: Equatable {

    /// The optional argument a writer passes to say "I composed this against THIS state" (R3).
    /// Named once here so the dispatcher, the schema injection and the tests cannot drift.
    /// The request field a write carries its composed-against token in.
    ///
    /// Named `token`, the same word every RESPONSE uses (`ports.list`, `port.create`, and every
    /// write return one). It was `expect` while CAS was optional; making it mandatory (R5) exposed
    /// the asymmetry, since a caller held a thing called `token` and had to type `expect`.
    ///
    /// The objection to `token` was that a request field of that name reads as a credential. It does
    /// not here: `token` already means the port's state token throughout this API, and gateway auth
    /// (plan-gateway-auth-tls P1) is a HEADER, so the two never share a namespace. Renamed while
    /// adoption was still zero, hours after the rule shipped, because the cost of this rename rises
    /// every hour that generated ports bake the old name in.
    public static let expectParam = "token"

    /// The key every write's response carries its new token under, and every port-returning read.
    /// One spelling, so a caller threads the same field everywhere.
    public static let tokenKey = "token"

    /// The error code a stale write is refused with. The response also carries `current`, so the
    /// caller's retry needs no extra round trip to discover it.
    public static let staleCode = "stale_write"

    /// R5: a write arrived with NO token while someone ELSE was driving the port.
    ///
    /// Distinct from `stale_write`, which means "your token is out of date". This means "you did not
    /// say what you composed against, and it matters right now". Both carry `current`, so either way
    /// one retry converges.
    public static let tokenRequiredCode = "token_required"

    /// This launch. Two runs of the app never share one, which is what makes a token from before a
    /// restart mismatch BY CONSTRUCTION rather than by luck.
    ///
    /// Spike A finding A4, and the reason it is not just a bare `Int`: `panel.id` and `udid` are
    /// both restored from the DB, so a port's KEY survives a restart while an in-memory counter
    /// would not — while the port's live state definitely changed (a web port comes back from its
    /// persisted SOURCE with all `exec`/`push` runtime gone; a terminal's pty is new). A peer
    /// holding a pre-restart token of 0, checked against a post-restart counter of 0, would pass
    /// and write into a port that had been wiped. The epoch closes that without a wire-format
    /// migration later — the same call `ActorRef` made when it was built peer-qualified from day
    /// one so that local was the degenerate form of remote.
    public let epoch: String

    /// How long the last writer keeps being SHOWN as the driver. Display freshness, never
    /// correctness: the counter itself never expires, and what refuses a write is CAS.
    ///
    /// Short enough that a crashed writer stops being shown as driving, long enough that a human
    /// thinking between keystrokes does not flicker off the chrome.
    public static let driverTTL: TimeInterval = 30

    /// What a port's history amounts to: how many times it changed, and who changed it last.
    ///
    /// **The attribution is separate from the count on purpose.** Not every write has someone to
    /// name — the app writes a startup command into a pty on behalf of nobody, and a browser
    /// navigation can be a human clicking or the page's own script, which are indistinguishable at
    /// that seam. Those move `seq` and leave the attribution alone. See `bump`.
    struct Entry: Equatable {
        var seq: Int = 0
        var actor: ActorRef?
        var actorName: String?
        /// When `actor` last acted. Not "when the port last changed": an unattributed write must not
        /// keep a stale name lit, so this moves only when the attribution does.
        var at: Date?
    }

    /// port key (`PortRef.key`, the same key the Notify topic uses) → its entry.
    ///
    /// DELIBERATELY NO `forget` for the COUNT (see `portClosed`, which drops only the attribution).
    /// A counter that resets lets a token composed against a DEAD id pass CAS against a reused one.
    /// Monotonic per id and never reset is strictly safer: a stale token then mismatches by
    /// construction. The cost of keeping them is one small entry per port id for the session.
    private var entries: [String: Entry] = [:]

    public init(epoch: String = PortActivity.newEpoch()) { self.epoch = epoch }

    /// A short, unique-per-launch tag. Only ever compared for equality, never ordered, so length
    /// buys collision resistance and nothing else.
    public static func newEpoch() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// How many times this port has changed. A port nobody has touched is 0 — reading an unknown
    /// port is not an error, because "nothing has happened here" is a true and useful answer.
    public func seq(for port: String) -> Int { entries[port]?.seq ?? 0 }

    /// The token a writer composes against and hands back: `<epoch>:<seq>`.
    public func token(for port: String) -> String { "\(epoch):\(seq(for: port))" }

    /// WHO is driving: whoever last moved this port's token, while that is still fresh enough to
    /// show. Derived, never stored twice — that is step 3 in one method.
    ///
    /// Read-only, and it never extends anything: reading who is driving is not driving.
    public func driver(of port: String, now: Date) -> Driver? {
        guard let e = entries[port], let actor = e.actor, let at = e.at else { return nil }
        let expires = at.addingTimeInterval(PortActivity.driverTTL)
        guard now < expires else { return nil }
        return Driver(ref: actor, name: e.actorName ?? actor.principal, expires: expires)
    }

    /// The result of a bump: the new token, and the driver when presence MOVED.
    ///
    /// `driverChanged` is non-nil only on a real change (a different actor, or the same one after
    /// the display window lapsed), because the broadcast keys off it. A refresh must stay silent:
    /// publishing per keystroke would drown the port's topic in non-news.
    public struct Bumped: Equatable {
        public let token: String
        public let driverChanged: Driver?
    }

    /// Something changed this port.
    ///
    /// **A nil actor moves the counter and leaves the attribution ALONE.** It does not clear the
    /// driver, and that is load-bearing rather than a nicety: a companion's `port.push` counts twice
    /// on a terminal, once attributed at the dispatch seam and once unattributed at the pty funnel
    /// (R2b), so clearing on nil would blank the chip of every companion the instant it wrote. The
    /// honest reading of an unattributed write is "the port changed and we do not know who", which
    /// says nothing about who was driving a moment ago.
    @discardableResult
    public mutating func bump(_ port: String, by actor: ActorRef? = nil,
                              named name: String? = nil, at now: Date = Date()) -> Bumped {
        var e = entries[port] ?? Entry()
        e.seq += 1

        guard let actor else {
            entries[port] = e
            return Bumped(token: "\(epoch):\(e.seq)", driverChanged: nil)
        }

        let wasLive = e.at.map { now < $0.addingTimeInterval(PortActivity.driverTTL) } ?? false
        let changed = !(wasLive && e.actor == actor)
        e.actor = actor
        e.actorName = name ?? actor.principal
        e.at = now
        entries[port] = e

        let driver = Driver(ref: actor, name: e.actorName ?? actor.principal,
                            expires: now.addingTimeInterval(PortActivity.driverTTL))
        return Bumped(token: "\(epoch):\(e.seq)", driverChanged: changed ? driver : nil)
    }

    /// The port is gone. **Attribution drops; the count does not.**
    ///
    /// The two have opposite lifecycles, which was Spike A's fourth correction and survives step 3
    /// unchanged. A dead port has no driver, so a reused id must not inherit the last one's name for
    /// the rest of the display window. But a counter that reset would let a token composed against
    /// the dead port pass CAS against the live one that took its id.
    public mutating func portClosed(_ port: String) {
        guard var e = entries[port] else { return }
        e.actor = nil
        e.actorName = nil
        e.at = nil
        entries[port] = e
    }
}
