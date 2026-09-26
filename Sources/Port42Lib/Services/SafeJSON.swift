import Foundation

/// JSON writing that cannot raise. THE one way this package writes JSON from `Any`.
///
/// `JSONSerialization` raises an Objective-C exception, which `try?` does not catch, on a NaN or an
/// infinity and on any value that is not JSON. On the main queue AppKit swallows it, and the main
/// queue and the main actor never run again while the run loop keeps pumping: the app looks alive,
/// takes keystrokes, and every task, timer hop and gateway call is dead. Dev4 froze this way on
/// 2026-09-26 at 12:16:10 (a hang reporter thread named "SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_
/// EXCEPTION" was stamped with that second, and the door's receive loop, a main-actor task, never
/// re-armed). A NaN reaches here easily, for example a `port.exec` whose script returns NaN.
///
/// So values are cleaned first: a non-finite number becomes null, a value JSON cannot hold becomes
/// its description, and a dictionary key becomes a string. `SafeJSONTests` holds the gate that no
/// other file calls `JSONSerialization.data(withJSONObject:)`.
public enum SafeJSON {

    public static func data(_ value: Any, options: JSONSerialization.WritingOptions = []) -> Data? {
        let clean = sanitize(value)
        guard JSONSerialization.isValidJSONObject([clean]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: clean, options: options.union(.fragmentsAllowed))
    }

    public static func string(_ value: Any, options: JSONSerialization.WritingOptions = []) -> String? {
        data(value, options: options).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func sanitize(_ value: Any) -> Any {
        switch value {
        case is NSNull:
            return value
        case let s as String:
            return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n }
            return n.doubleValue.isFinite ? n : NSNull()
        case let d as [String: Any]:
            return d.mapValues(sanitize)
        case let d as [AnyHashable: Any]:
            return Dictionary(d.map { ("\($0.key)", sanitize($0.value)) }, uniquingKeysWith: { a, _ in a })
        case let a as [Any]:
            return a.map(sanitize)
        default:
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                return mirror.children.first.map { sanitize($0.value) } ?? NSNull()
            }
            return String(describing: value)
        }
    }
}
