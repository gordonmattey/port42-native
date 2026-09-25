import Foundation

/// Phase 0 instrumentation for "the desktop rearranges itself" (docs/summer2026-todo.md). Every
/// layout trigger names itself and lands in a file, so a reproduction can be read back afterwards
/// instead of reasoned about. The point is to find out WHICH trigger fires on leave-and-return,
/// app-switch and resize — four candidates were read but never measured.
///
/// Off unless asked for:
///   defaults write com.port42.dev2 PORT42_ARRANGE_LOG -bool true    (then relaunch)
/// Lines land in `/tmp/port42-arrange-<bundle id>.log` and are also printed with an `[arrange]` tag.
public enum ArrangeLog {

    /// Read once — a live `UserDefaults` read per tile per arrange would itself be a cost.
    public static let enabled: Bool = UserDefaults.standard.bool(forKey: "PORT42_ARRANGE_LOG")

    public static let path: String = {
        let id = Bundle.main.bundleIdentifier ?? "com.port42.app"
        return "/tmp/port42-arrange-\(id).log"
    }()

    private static let queue = DispatchQueue(label: "com.port42.arrange-log")

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// One event: a short name, then key=value detail. Cheap and a no-op when disabled.
    public static func note(_ event: String, _ detail: String = "") {
        guard enabled else { return }
        let line = "\(stamp.string(from: Date())) \(event)" + (detail.isEmpty ? "\n" : " \(detail)\n")
        print("[arrange] \(line)", terminator: "")
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let fh = FileHandle(forWritingAtPath: path) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
