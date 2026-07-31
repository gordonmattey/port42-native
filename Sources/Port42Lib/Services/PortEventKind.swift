import Foundation

// MARK: - What a port event is CALLED (the output seam's namespace)
//
// Every envelope on a port's Notify topic carries a `kind`, and until now that string could be
// anything, from anywhere. Measured 2026-07-28: six `notifyBus.publish` sites, eleven `pushEvent`
// callers, and THREE entry points taking a caller-supplied name — `port.publish`'s `kind` argument,
// `PortBridge.pushEvent(event:)`, and `pushEventToBridges(event:)`. So `browser.load`,
// `camera.frame`, `driver` and whatever a port invented all sat in one flat namespace, and nothing
// distinguished what Port42 said from what a port said.
//
// That is the output-side version of the problem the input seam solved: a guarantee that depends on
// every emitter having chosen a sensible name is a to-do list, not a namespace.
//
// TWO RULES, and the second is what makes the first worth anything:
//
// 1. **Every SYSTEM kind is a case here.** `pushEvent` takes this type, not a String, so inventing a
//    system event is a compile error rather than a new string in the wild. The set is also now
//    enumerable, which is what lets a document list it without going stale.
//
// 2. **A PORT's own kind is namespaced under `port.`** — see `PortEventKind.fromPort`. A port
//    publishing `state` emits `port.state` and CANNOT emit `driver`, `browser.load`, or any other
//    system name. Not a blocklist of reserved words, which would rot the moment a system kind was
//    added; a prefix cannot be escaped, so the guarantee is structural.
//
// WHY THE PORT SIDE TOOK THE BREAK AND THE SYSTEM SIDE DID NOT. Prefixing the system kinds instead
// (`port42.browser.load`) would have been the same structural fix pointing the other way, and it
// would have broken every generated port listening for `presentation`, `browser.load` or
// `companion.activity` — names `ports-context.txt` teaches and ports already use. Prefixing the
// port's own kind breaks one documented example pair (`publish('state')` / `kind === 'state'`), and
// `port.publish` adoption is near zero. Same call as the `expect` → `token` rename and the
// `port.exec` scalar reshape: take the break while it is cheap, because its cost only rises.

/// A system event kind. One definition, so the wire names cannot drift from the code that emits them.
public enum PortEventKind: String, CaseIterable, Equatable {
    // Port lifecycle and content
    case console
    case push
    case presentation
    case driver
    case filedrop

    // Terminal
    case terminalOutput = "terminal.output"

    // Browser ports
    case browserLoad = "browser.load"
    case browserRedirect = "browser.redirect"
    case browserError = "browser.error"

    // Device streams
    case screenFrame = "screen.frame"
    case cameraFrame = "camera.frame"
    case audioData = "audio.data"
    case audioTranscription = "audio.transcription"

    // Space traffic a port can observe
    case message
    case companionActivity = "companion.activity"

    /// The name on the wire.
    public var wire: String { rawValue }

    // MARK: - Published from the enum, never restated in prose
    //
    // `ports-context.txt` listed the system kinds by hand ("'driver', 'browser.load',
    // 'terminal.output', 'console'"), which was already incomplete and would go further out of date
    // with every case added here. Rendered, a new case reaches both documents by existing.

    public static let docsMarker = "{{EVENT_KINDS}}"

    /// Every system kind, wrapped to a readable width. The port prefix is stated once at the end,
    /// because it is the rule that makes the list closed rather than another entry in it.
    public static func publishedKinds(indent: String = "  ", width: Int = 92) -> String {
        var lines: [String] = []
        var line = indent
        for wire in allCases.map(\.wire).sorted() {
            let piece = line == indent ? wire : " · \(wire)"
            if line.count + piece.count > width { lines.append(line); line = indent + wire }
            else { line += piece }
        }
        if line != indent { lines.append(line) }
        lines.append("\(indent)a PORT's own kind is namespaced `\(portPrefix)<yours>`, so it can never "
                   + "collide with the above")
        return lines.joined(separator: "\n")
    }

    public static func publish(into text: String, indent: String = "  ") -> String {
        text.replacingOccurrences(of: docsMarker, with: publishedKinds(indent: indent))
    }

    /// The prefix every port-authored kind carries.
    ///
    /// A dot, not a colon or a slash, because the existing system names already read as dotted paths
    /// (`browser.load`, `audio.data`), so a consumer's matching code does not change shape.
    public static let portPrefix = "port."

    /// A kind a PORT chose, namespaced so it cannot impersonate a system event.
    ///
    /// Idempotent: a port that already sends `port.state` is not turned into `port.port.state`, so a
    /// caller reading its own emitted names back does not accumulate prefixes.
    ///
    /// Empty or whitespace-only input becomes `port.event`, because an unnamed event still has to be
    /// addressable by a subscriber, and a bare `port.` is a name nobody can match on deliberately.
    public static func fromPort(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return portPrefix + "event" }
        return t.hasPrefix(portPrefix) ? t : portPrefix + t
    }

    /// True when this name belongs to Port42 rather than to a port. The question a subscriber used to
    /// have no way to ask.
    public static func isSystem(_ name: String) -> Bool {
        allCases.contains { $0.rawValue == name }
    }
}
