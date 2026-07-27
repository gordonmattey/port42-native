//  PortInputProbe.swift
//
//  I2 · C6 — does EVERY way into a port reach the seam?
//  (docs/plan-port42-protocol-local-bus.md §C.)
//
//  THE QUESTION, AND WHY NO COMPILER CAN ANSWER IT.
//
//  C2 and C4 proved that nothing BYPASSES the door: the tables are private, the seam has three
//  entry points, and deleting a direct route made the compiler name every caller. That closes the
//  "wrong caller" class completely.
//
//  It says nothing about the "missing caller" class: a path that changes a port and touches the seam
//  NOT AT ALL. Dictation, the emoji picker, right-click paste, a cross-app drag, an SPA route change.
//  Nothing fails to compile, because there is nothing there to fail. Spike C measured the web
//  listener at 8 of 11 real content changes, and found the three misses only by looking.
//
//  R5 ("terminals require a token") depends on THIS class. Declaring the token honest on C4's
//  evidence would prove only that nothing bypasses the door, never that everything arrives at it.
//
//  LABELLED, BECAUSE THE LAST PROBE WAS NOT.
//
//  Spike C logged events but not which ACTION produced them, so the labels were inferred afterwards
//  and one was wrong: `fn fn` turned out to be the emoji picker on GM's machine, not dictation. The
//  mechanism finding survived; the feature labels were a guess. So here the operator NAMES the
//  action first and then performs it, and every event lands under that name.
//
//  A label with ZERO events is the finding. That is the whole instrument: an action that changes a
//  port and produces no line is a way in that does not count.
//
//      echo "dictation into terminal" > /tmp/port42-input-label
//      …perform exactly that action…
//      cat /tmp/port42-input-probe.log
//
//  A FILE, not a bridge method. A DEBUG-only verb in the registry would appear in the generated
//  `llms.txt`, documenting an API that does not exist in a release build — the same
//  declaration-disagrees-with-behaviour defect the register already carries in §5. The probe has no
//  API surface at all.

#if DEBUG
import Foundation

public enum PortInputProbe {

    /// Off until the label file exists, so normal use does not fill the log with noise.
    public static let logPath = "/tmp/port42-input-probe.log"
    public static let labelPath = "/tmp/port42-input-label"

    private static let lock = NSLock()
    private static var label = ""
    private static var lastLabelRead = Date.distantPast
    private static var order: [String] = []                 // labels, in the order they were set
    private static var events: [String: [String: Int]] = [:] // label -> "kind|trust|actor" -> count

    /// The label the operator most recently wrote, re-read at most twice a second.
    ///
    /// Cheap enough for a per-keystroke path (one `stat` twice a second), and the staleness is
    /// irrelevant by construction: the label is written BEFORE the action is performed, so it is
    /// always in place by the time events arrive.
    private static func currentLabel() -> String {
        let now = Date()
        if now.timeIntervalSince(lastLabelRead) > 0.5 {
            lastLabelRead = now
            label = ((try? String(contentsOfFile: labelPath, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return label
    }

    /// Called from the seam's door. Records WHAT arrived under the CURRENT label.
    public static func record(kind: String, trust: String, attributed: Bool) {
        lock.lock()
        let l = currentLabel()
        guard !l.isEmpty else { lock.unlock(); return }
        if !order.contains(l) { order.append(l); events[l] = [:] }
        let key = "\(kind) | trust=\(trust) | actor=\(attributed ? "yes" : "none")"
        events[l, default: [:]][key, default: 0] += 1
        lock.unlock()
        flush()
    }

    /// Record a label that produced NOTHING. Called by the operator's tooling when it moves on, so a
    /// silent action appears in the tally instead of being absent from it — the difference between
    /// "this way in does not count" and "we forgot to test it".
    public static func noteLabel(_ l: String) {
        let l = l.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return }
        lock.lock()
        if !order.contains(l) { order.append(l); events[l] = [:] }
        lock.unlock()
        flush()
    }

    /// Live tally, rewritten in place: `cat` at any moment is the whole measurement, and a
    /// per-keystroke action cannot bury the one label that produced nothing.
    private static func flush() {
        lock.lock()
        let snapshotOrder = order
        let snapshot = events
        lock.unlock()

        var out = "PORT42 INPUT PROBE (I2 · C6) — does every way in reach the seam?\n"
        out += "A label with ZERO events is the finding: that action changed a port and did not count.\n\n"
        for l in snapshotOrder {
            let rows = snapshot[l] ?? [:]
            if rows.isEmpty {
                out += "✗ \(l)\n      NO EVENTS — this way in does not reach the seam\n"
            } else {
                out += "✓ \(l)\n"
                for k in rows.keys.sorted() { out += "      \(rows[k]!)×  \(k)\n" }
            }
        }
        try? out.write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    public static func reset() {
        lock.lock()
        label = ""; lastLabelRead = .distantPast; order.removeAll(); events.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(atPath: logPath)
        try? FileManager.default.removeItem(atPath: labelPath)
    }
}
#endif
