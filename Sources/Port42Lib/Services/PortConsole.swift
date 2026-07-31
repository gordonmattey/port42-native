import Foundation

/// WHAT A PORT SAID, kept so someone can ask.
///
/// A port's output has always been write-only. A web port's `console.log` went to NSLog and nowhere
/// else; a terminal's output was published to the Notify bus and then dropped. Both are fine for a
/// human reading a log file next to the app, and useless to anything reaching the API — which is the
/// caller that most needs it, because **generative ports are built BY agents**. An agent asks an LLM
/// for a port, the port throws a TypeError in `render()` every frame, and the agent has no way to
/// find out. It debugs blind, or does not debug at all.
///
/// The same hole costs more than that. Diagnosing a terminal companion this session meant reading the
/// app's log file over the shoulder of the port, because there is no way to ask a port what it
/// printed — and twice the answer was that the CLI had exited immediately, which the port could not
/// say either.
///
/// A ring buffer per port, capped. Not a log: the recent past, so a caller can ask "what just
/// happened" without anyone deciding in advance to record.
@MainActor
public final class PortConsole {
    public static let shared = PortConsole()

    /// One line of output.
    public struct Line: Sendable, Equatable {
        /// `log` / `warn` / `error` for a web port; `out` for a terminal; `system` for Port42 itself.
        public let level: String
        public let text: String
        public let at: Date
        public init(level: String, text: String, at: Date) {
            self.level = level
            self.text = text
            self.at = at
        }
    }

    /// Per port. Capped so a chatty port cannot grow without bound — a port rendering at 60fps and
    /// logging each frame would otherwise be a memory leak with a friendly name.
    public static let maxLines = 500
    /// A single line is capped too: a terminal can emit a megabyte on one line (a `cat` of a binary),
    /// and the buffer's job is legibility, not fidelity.
    public static let maxLineLength = 4_000

    private var lines: [String: [Line]] = [:]

    /// The key a port's console is filed under. **`PortRef.key`'s rule, deliberately duplicated
    /// nowhere else**: writers hold a panel, readers hold a resolved ref, and if the two disagree the
    /// buffer fills up under one name and reads empty under another — which is exactly what happened
    /// first time, and it looks identical to "nothing was captured".
    public static func key(udid: String?, id: String, messageId: String? = nil) -> String {
        udid ?? (id.isEmpty ? (messageId ?? "") : id)
    }

    /// Record one line against a port.
    public func append(portId: String, level: String, text: String, at: Date = Date()) {
        guard !portId.isEmpty else { return }
        let trimmed = text.count > Self.maxLineLength
            ? String(text.prefix(Self.maxLineLength)) + "…"
            : text
        guard !trimmed.isEmpty else { return }
        var existing = lines[portId] ?? []
        existing.append(Line(level: level, text: trimmed, at: at))
        if existing.count > Self.maxLines {
            existing.removeFirst(existing.count - Self.maxLines)
        }
        lines[portId] = existing
    }

    /// The most recent `tail` lines, oldest first — reading order, so a caller can paste it straight
    /// into a question.
    public func recent(portId: String, tail: Int = 100) -> [Line] {
        let all = lines[portId] ?? []
        guard tail > 0, all.count > tail else { return all }
        return Array(all.suffix(tail))
    }

    /// Forget a port's output. Called when the port goes away, so a closed port's console does not
    /// outlive it.
    public func clear(portId: String) {
        lines.removeValue(forKey: portId)
    }

    /// Total lines held, for tests and introspection.
    public func count(portId: String) -> Int { lines[portId]?.count ?? 0 }
}
