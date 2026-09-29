import Foundation
import GhosttyKit

/// What a terminal reported about itself, through Ghostty (docs/plan-port-state-v1.md, Phase A). Ghostty
/// sends these as actions; Port42 ignored them all until 2026-09-29.
public enum TerminalEvent: Equatable {
    /// The title the running program set (OSC 0/2): Claude Code sets its task name.
    case title(String)
    /// The shell's working directory (OSC 7).
    case pwd(String)
    /// A command finished (shell integration): its exit code, when reported, and how long it ran.
    case commandFinished(exit: Int?, seconds: Double)
    /// A progress bar the program reports (OSC 9;4): nil percent when it is indeterminate.
    case progress(TerminalFacts.Progress?)
    case bell
    case notification(title: String, body: String)

    /// The event an action carries, or nil for one Port42 does not use. Strings are copied here, since
    /// Ghostty owns them only for the call.
    nonisolated static func decode(_ a: ghostty_action_s) -> TerminalEvent? {
        func str(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
        switch a.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            return .title(str(a.action.set_title.title))
        case GHOSTTY_ACTION_PWD:
            return .pwd(str(a.action.pwd.pwd))
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let c = a.action.command_finished
            return .commandFinished(exit: c.exit_code < 0 ? nil : Int(c.exit_code),
                                    seconds: Double(c.duration) / 1_000_000_000)
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let r = a.action.progress_report
            let percent: Int? = r.progress < 0 ? nil : Int(r.progress)
            switch r.state {
            case GHOSTTY_PROGRESS_STATE_REMOVE: return .progress(nil)
            case GHOSTTY_PROGRESS_STATE_ERROR: return .progress(.init(percent: percent, failed: true, paused: false))
            case GHOSTTY_PROGRESS_STATE_PAUSE: return .progress(.init(percent: percent, failed: false, paused: true))
            case GHOSTTY_PROGRESS_STATE_INDETERMINATE: return .progress(.init(percent: nil, failed: false, paused: false))
            default: return .progress(.init(percent: percent, failed: false, paused: false))
            }
        case GHOSTTY_ACTION_RING_BELL:
            return .bell
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = a.action.desktop_notification
            return .notification(title: str(n.title), body: str(n.body))
        default:
            return nil
        }
    }
}

/// Everything a terminal has told Port42 about itself, newest wins. A card shows it; nothing here is
/// read from the screen.
public struct TerminalFacts: Equatable {
    public struct Progress: Equatable {
        public var percent: Int?
        public var failed: Bool
        public var paused: Bool
    }
    public struct Finished: Equatable {
        public var exit: Int?
        public var seconds: Double
        public var at: Date
    }
    public struct Notice: Equatable {
        public var title: String
        public var body: String
        public var at: Date
    }

    public var title: String?
    public var cwd: String?
    public var lastCommand: Finished?
    public var progress: Progress?
    public var bellAt: Date?
    public var notification: Notice?

    public init() {}

    public mutating func apply(_ e: TerminalEvent, at: Date) {
        switch e {
        case .title(let t): title = t.isEmpty ? nil : t
        case .pwd(let p): cwd = Self.path(p)
        case .commandFinished(let exit, let seconds): lastCommand = Finished(exit: exit, seconds: seconds, at: at)
        case .progress(let p): progress = p
        case .bell: bellAt = at
        case .notification(let title, let body): notification = Notice(title: title, body: body, at: at)
        }
    }

    /// OSC 7 sends a `file://host/path` URL; a shell may send a bare path.
    static func path(_ raw: String) -> String? {
        guard raw.hasPrefix("file://") else { return raw.isEmpty ? nil : raw }
        let rest = raw.dropFirst("file://".count)                 // host/path
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let p = String(rest[slash...])
        return p.removingPercentEncoding ?? p
    }
}

/// What a browser port is showing, from its web view (title, address, loading).
public struct BrowserFacts: Equatable {
    public var title: String?
    public var url: URL?
    /// 0...1 while loading; nil once loaded.
    public var progress: Double?
    public init(title: String? = nil, url: URL? = nil, progress: Double? = nil) {
        self.title = title; self.url = url; self.progress = progress
    }
}

/// One line a port declares about itself (`state.set`).
public struct StateLine: Equatable {
    public let label: String
    public let value: String
    public init(label: String, value: String) { self.label = label; self.value = value }

    /// A declared list is kept to this many lines and this long a value (docs/plan-port-state-v1.md).
    public static let maxLines = 5
    public static let maxValue = 80
}

/// The state of every port Port42 can describe, by panel id (docs/plan-port-state-v1.md). Owned by
/// AppState; cards, `state.get`, the hidden list and ⌘K read it.
@MainActor
public final class PortStateStore: ObservableObject {
    @Published public private(set) var terminals: [String: TerminalFacts] = [:]
    @Published public private(set) var browsers: [String: BrowserFacts] = [:]
    @Published public private(set) var declared: [String: [StateLine]] = [:]

    public init() {}

    public func apply(_ e: TerminalEvent, port: String, at: Date = Date()) {
        var f = terminals[port] ?? TerminalFacts()
        f.apply(e, at: at)
        if f != terminals[port] { terminals[port] = f }
    }

    public func setBrowser(_ f: BrowserFacts, port: String) {
        if browsers[port] != f { browsers[port] = f }
    }

    /// What the port says about itself, trimmed to the caps. An empty list clears it.
    public func declare(_ lines: [StateLine], port: String) {
        let kept = lines.prefix(StateLine.maxLines).map {
            StateLine(label: String($0.label.prefix(24)), value: String($0.value.prefix(StateLine.maxValue)))
        }
        declared[port] = kept.isEmpty ? nil : Array(kept)
    }

    public func forget(port: String) {
        terminals[port] = nil
        browsers[port] = nil
        declared[port] = nil
    }
}

/// What a card shows for one port: its title and up to five lines, declared first, then what Port42
/// knows (docs/plan-port-state-v1.md). Built in one place, so the card, `state.get`, the hidden list and
/// ⌘K all say the same thing.
public struct PortCard: Equatable {
    public enum Tone: Equatable { case normal, alert, quiet }
    public struct Line: Equatable {
        public let label: String
        public let value: String
        public var tone: Tone = .normal
        /// True for a line Port42 wrote, false for one the port declared.
        public var known: Bool = true
    }

    public var title: String
    public var lines: [Line]
    /// A bar, 0...1, when the port reports progress or is loading.
    public var progress: Double?
    public var progressFailed = false

    public static let maxLines = 5

    /// What Port42 knows about a companion working in a terminal.
    public struct Companion: Equatable {
        public var presence: ChatPresence?
        public var waitingMessages: Bool
        public init(presence: ChatPresence?, waitingMessages: Bool) {
            self.presence = presence; self.waitingMessages = waitingMessages
        }
    }

    public static func build(title: String, declared: [StateLine] = [], terminal: TerminalFacts? = nil,
                             companion: Companion? = nil, browser: BrowserFacts? = nil, errors: Int = 0,
                             home: String = NSHomeDirectory(), now: Date = Date()) -> PortCard {
        var lines = declared.map { Line(label: $0.label, value: $0.value, known: false) }
        var progress: Double?
        var failed = false

        if let c = companion, let p = c.presence {
            switch p.state {
            case .received: lines.append(Line(label: "received", value: ago(p.since, now)))
            case .working: lines.append(Line(label: "working", value: ago(p.since, now)))
            case .waiting(let why):
                lines.append(Line(label: "waiting", value: why.isEmpty ? ago(p.since, now) : why, tone: .alert))
            }
            if let doing = p.doing { lines.append(Line(label: "doing", value: doing.detail)) }
        }
        if companion?.waitingMessages == true {
            lines.append(Line(label: "queued", value: "a message is waiting for it"))
        }
        if let t = terminal {
            if let title = t.title, !title.isEmpty, title != t.cwd, title != shortPath(t.cwd, home: home) {
                lines.append(Line(label: "running", value: title))
            }
            if let c = t.lastCommand {
                let took = duration(c.seconds)
                if let exit = c.exit, exit != 0 {
                    lines.append(Line(label: "failed", value: "exit \(exit) · \(took) · \(ago(c.at, now)) ago", tone: .alert))
                } else {
                    lines.append(Line(label: "last", value: "done · \(took) · \(ago(c.at, now)) ago", tone: .quiet))
                }
            }
            if let cwd = shortPath(t.cwd, home: home) { lines.append(Line(label: "in", value: cwd, tone: .quiet)) }
            if let n = t.notification, n.at > (t.bellAt ?? .distantPast) {
                lines.append(Line(label: "notice", value: n.body.isEmpty ? n.title : n.body, tone: .alert))
            } else if let bell = t.bellAt, now.timeIntervalSince(bell) < 600 {
                lines.append(Line(label: "bell", value: "\(ago(bell, now)) ago", tone: .alert))
            }
            if let p = t.progress {
                progress = p.percent.map { Double($0) / 100 } ?? 0
                failed = p.failed
            }
        }
        if let b = browser {
            if let t = b.title, !t.isEmpty { lines.append(Line(label: "page", value: t)) }
            if let host = b.url?.host { lines.append(Line(label: "site", value: host, tone: .quiet)) }
            progress = progress ?? b.progress
        }
        if errors > 0 {
            lines.append(Line(label: "errors", value: "\(errors)", tone: .alert))
        }
        return PortCard(title: title, lines: Array(lines.prefix(maxLines)), progress: progress, progressFailed: failed)
    }

    /// The first line, for a one-line listing (the hidden list, ⌘K): "label value", or nil.
    public var summary: String? {
        lines.first.map { "\($0.label) \($0.value)" }
    }

    static func ago(_ d: Date, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    static func shortPath(_ path: String?, home: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
