import Foundation

/// Format dropped file paths into a single space-separated string suitable for pasting into a
/// terminal or a chat draft. A path is left **bare** when it contains no shell-significant
/// characters; only paths with spaces/metacharacters get single-quoted (embedded single quotes
/// escaped as '\''). This avoids noisy quotes around ordinary filenames.
///
/// Pure + unit-testable; shared by the native-terminal drop and the chat drop (Step 5c).
public func escapeDroppedPaths(_ paths: [String]) -> String {
    let needsQuoting = Set(" \t\n'\"\\$`(){}[]*?!&;|<>#~")
    return paths
        .map { path in
            if !path.contains(where: { needsQuoting.contains($0) }) { return path }
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        .joined(separator: " ")
}
