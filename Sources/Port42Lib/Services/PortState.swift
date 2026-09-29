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

/// The state of every port Port42 can describe, by port id (docs/plan-port-state-v1.md). Owned by
/// AppState; cards, the hidden list and ⌘K read it.
@MainActor
public final class PortStateStore: ObservableObject {
    @Published public private(set) var terminals: [String: TerminalFacts] = [:]

    public init() {}

    public func apply(_ e: TerminalEvent, port: String, at: Date = Date()) {
        var f = terminals[port] ?? TerminalFacts()
        f.apply(e, at: at)
        if f != terminals[port] { terminals[port] = f }
    }

    public func forget(port: String) { terminals[port] = nil }
}
