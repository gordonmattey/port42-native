import Foundation

/// Shell-escape dropped file paths into a single space-separated string suitable for pasting into
/// a terminal or a chat draft. Each path is wrapped in single quotes (with embedded single quotes
/// escaped as '\''), so spaces and shell metacharacters are safe.
///
/// Pure + unit-testable; shared by the native-terminal drop and the chat drop (Step 5c).
public func escapeDroppedPaths(_ paths: [String]) -> String {
    paths
        .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        .joined(separator: " ")
}
