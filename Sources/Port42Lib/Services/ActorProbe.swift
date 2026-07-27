//  ActorProbe.swift
//
//  I1.1 — the ACTOR noun, measured before it is designed
//  (docs/plan-port42-protocol-local-bus.md §B).
//
//  THE QUESTION THIS ANSWERS, AND NOTHING ELSE: which callers actually reach a bridge
//  dispatch WITHOUT an identity of their own, by which surface, and calling what.
//
//  Six `Principal` construction sites exist. Two of them fall back to a shared
//  `"anonymous-tool-caller"` string, one falls back through a three-rung chain, and one uses
//  the deliberately-shared `local-http` id. Permissions key on `principal.id`, so every caller
//  that lands on the same fallback string shares one grant bucket: grant `filesystem` to one
//  and all of them have it, persistently.
//
//  I1.3 decides what an unattributed caller IS — refused, or given a per-surface synthetic
//  identity that never pools. That decision is worth nothing if the set of callers is imagined.
//  It has been imagined twice in this thread: finding 7's three sweeps each missed a path, and
//  Spike C's probe mislabelled dictation because the actions were guessed rather than named.
//  So: measure, then decide.
//
//  HOW IT WORKS. A fallback identity is registered as SYNTHETIC at the site that mints it. A
//  dispatch then records itself only when its principal's id is one of those. That is an exact
//  test rather than a string match, so it cannot drift if a fallback string is edited.
//
//  HOW TO READ IT. The log file holds a CURRENT TALLY, rewritten in place (throttled), not an
//  append-only stream — so `cat /tmp/port42-actor.log` at any moment is the whole measurement,
//  and a per-keystroke path cannot bury the one call that matters under ten thousand lines.
//
//      cat /tmp/port42-actor.log
//
//  DEBUG only, and inert until `enabled` is set (`PORT42_ACTOR_PROBE`, on by default in dev).

#if DEBUG
import Foundation

public enum ActorProbe {

    /// Off makes every hook a no-op. Set from the `PORT42_ACTOR_PROBE` default at launch.
    public static var enabled: Bool = true

    public static let logPath = "/tmp/port42-actor.log"

    // MARK: - State

    private static let lock = NSLock()
    /// Ids minted from a fallback rather than carried by a real caller. Membership is the test
    /// for "unattributed", so it stays exact as the fallback strings change.
    private static var synthetic: Set<String> = []
    /// event key -> (count, first seen). The key is the whole record minus its count, so the
    /// file is one line per DISTINCT thing that happened.
    private static var tally: [String: (count: Int, first: Date)] = [:]
    private static var lastFlush = Date.distantPast
    private static var started = Date()

    // MARK: - Hooks

    /// A principal was built from a FALLBACK — the caller carried no identity of its own.
    ///
    /// `rung` names which fallback fired, because a chain of them (`PortBridge`) hides how bad
    /// the miss is: falling back to the port's own message id still names one port, falling back
    /// to an `ObjectIdentifier` names an address that changes every launch.
    public static func minted(id: String, surface: String, rung: String) {
        guard enabled else { return }
        lock.lock()
        synthetic.insert(id)
        lock.unlock()
        record("MINT", ["surface": surface, "rung": rung, "id": redact(id)])
    }

    /// A bridge dispatch ran. Recorded only when the principal is one of the minted ones —
    /// this is the list I1.3 needs: the real callers, by surface, by method.
    ///
    /// `pooledWith` is the live count of OTHER minted ids sharing this exact grant bucket. It
    /// is the hole itself, in a number: anything above 1 means two callers can see each other's
    /// grants right now.
    public static func dispatch(method: String, principal: Principal,
                                grants: Set<PortPermission>, streaming: Bool = false) {
        guard enabled else { return }
        lock.lock()
        let isSynthetic = synthetic.contains(principal.id)
        lock.unlock()
        guard isSynthetic else { return }
        record(streaming ? "DISPATCH-STREAM" : "DISPATCH", [
            "surface": principal.kind.rawValue,
            "method": method,
            "id": redact(principal.id),
            "space": principal.spaceId == nil ? "nil" : "set",
            "grants": grants.isEmpty ? "-" : grants.map(\.rawValue).sorted().joined(separator: "+"),
        ])
    }

    /// EVERY dispatch, attributed or not, counted per surface. The denominator: on its own the
    /// MINT/DISPATCH lines say how often the hole is hit but not how often it is not, and one in
    /// ten thousand is a different decision from one in three.
    public static func anyDispatch(surface: String) {
        guard enabled else { return }
        record("ALL", ["surface": surface])
    }

    /// Native input reached a port with NOBODY to attribute it to (`humanPrincipal` is nil
    /// before setup completes). The token bumps and presence records nothing — an anonymous
    /// mutation that no `Principal` site would ever show, because it builds no principal at all.
    public static func inputWithoutIdentity(port: String) {
        guard enabled else { return }
        record("INPUT-ANON", ["port": redact(port)])
    }

    // MARK: - Recording

    private static func record(_ event: String, _ fields: [String: String]) {
        let key = event + "\t" + fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }
            .joined(separator: " ")
        lock.lock()
        let isNew = tally[key] == nil
        let now = Date()
        tally[key] = (count: (tally[key]?.count ?? 0) + 1, first: tally[key]?.first ?? now)
        let due = isNew || now.timeIntervalSince(lastFlush) > 2.0
        if due { lastFlush = now }
        let snapshot = due ? tally : [:]
        let since = started
        lock.unlock()
        // A NEW key flushes immediately: the first time a path appears is the event worth
        // catching, and a 2s throttle on it would lose the tail of a short run.
        if due { flush(snapshot, since: since) }
    }

    /// Rewrite the file with the whole current tally. Bounded by the number of DISTINCT events,
    /// which is small by construction, so a rewrite is cheaper than reasoning about an
    /// append-only file that has to be aggregated after the fact.
    private static func flush(_ snapshot: [String: (count: Int, first: Date)], since: Date) {
        var out = "PORT42 ACTOR PROBE (I1.1) — tally, rewritten live\n"
        out += "started \(stamp(since)), \(snapshot.count) distinct events\n"
        out += "count\tevent\tfields\n"
        for key in snapshot.keys.sorted() {
            out += "\(snapshot[key]!.count)\t\(key)\n"
        }
        try? out.write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    /// Ids can be long UUIDs; the tally is read by eye. Keep enough to tell two apart.
    private static func redact(_ s: String) -> String {
        s.count <= 20 ? s : String(s.prefix(10)) + "…" + String(s.suffix(4))
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    /// Wipe the tally for a clean run.
    public static func reset() {
        lock.lock()
        synthetic.removeAll(); tally.removeAll(); started = Date(); lastFlush = .distantPast
        lock.unlock()
        try? FileManager.default.removeItem(atPath: logPath)
    }
}
#endif
