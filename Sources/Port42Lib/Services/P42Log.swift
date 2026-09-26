import Foundation

/// The app's log, written OFF the main thread (2026-09-26).
///
/// `NSLog` writes to stderr synchronously on the thread that calls it, and most of the app's logging
/// happens on the main thread: every terminal hook event, every routed mention, every port write.
/// With the disk busy, one such write held the main thread for over a second, and gateway calls
/// queued behind it timed out (sampled on Dev4: the main thread in `writev` under
/// `GhosttyTerminalController.log`). Here a line is formatted where it is logged, so it says what was
/// true then, and written by one serial queue, so lines stay in order.
public enum P42Log {
    private static let queue = DispatchQueue(label: "com.port42.log", qos: .utility)
    nonisolated(unsafe) private static var _sink: @Sendable (String) -> Void = { NSLog("%@", $0) }
    private static let lock = NSLock()

    /// Where lines go. Replaceable in tests.
    static var sink: @Sendable (String) -> Void {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }

    public static func write(_ line: String) {
        let s = sink
        queue.async { s(line) }
    }

    /// Wait until every line logged so far has been written. For tests.
    static func drain() { queue.sync {} }
}

/// `NSLog`'s signature, written off the main thread through `P42Log`.
public func p42log(_ format: String, _ args: CVarArg...) {
    P42Log.write(args.isEmpty ? format : String(format: format, arguments: args))
}
