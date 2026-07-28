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

/// Per-port activity counters, epoch-qualified. Pure: no AppState, no clock, no IO.
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

    /// port key (`PortRef.key`, the same key presence and the Notify topic use) → count.
    ///
    /// DELIBERATELY NO `forget`, and this is the opposite of what presence does on a close
    /// (`DriverRegistry.forget`). A dead port has no driver, so presence must drop it; but a counter
    /// that resets lets a token composed against a DEAD id pass CAS against a reused one. Monotonic
    /// per id and never reset is strictly safer: a stale token then mismatches by construction. The
    /// cost of keeping them is one `Int` per port id for the life of the session.
    private var seqs: [String: Int] = [:]

    public init(epoch: String = PortActivity.newEpoch()) { self.epoch = epoch }

    /// A short, unique-per-launch tag. Only ever compared for equality, never ordered, so length
    /// buys collision resistance and nothing else.
    public static func newEpoch() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// How many times this port has changed. A port nobody has touched is 0 — reading an unknown
    /// port is not an error, because "nothing has happened here" is a true and useful answer.
    public func seq(for port: String) -> Int { seqs[port] ?? 0 }

    /// The token a writer composes against and hands back: `<epoch>:<seq>`.
    public func token(for port: String) -> String { "\(epoch):\(seq(for: port))" }

    /// Something changed this port. Returns the new token.
    @discardableResult
    public mutating func bump(_ port: String) -> String {
        let next = seq(for: port) + 1
        seqs[port] = next
        return "\(epoch):\(next)"
    }
}
