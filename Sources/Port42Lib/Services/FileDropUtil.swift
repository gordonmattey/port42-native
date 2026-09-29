import AppKit

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

/// What ⌘V puts into a terminal, from what the clipboard holds (GM, 2026-09-29: pasting an image did
/// nothing, because only text was read):
/// - files copied in Finder: their paths, quoted as a drop is (the text on the clipboard is only the
///   names);
/// - text: the text;
/// - an image with no text (a screenshot, Copy Image): saved as a PNG in `imageDir`, and its path, which
///   Claude Code and Codex attach as an image.
/// nil when there is nothing to paste.
public func terminalPasteText(from pb: NSPasteboard, imageDir: URL = terminalPasteImageDir) -> String? {
    if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
       !urls.isEmpty {
        return escapeDroppedPaths(urls.map(\.path))
    }
    if let str = pb.string(forType: .string), !str.isEmpty { return str }
    guard let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                            formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
        .replacingOccurrences(of: ":", with: "")
    let file = imageDir.appendingPathComponent("pasted-\(stamp)-\(UUID().uuidString.prefix(4)).png")
    do {
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        try png.write(to: file)
    } catch {
        return nil
    }
    return escapeDroppedPaths([file.path])
}

/// Where pasted images are kept: the per-user temporary folder, so macOS clears them in time.
public let terminalPasteImageDir = FileManager.default.temporaryDirectory.appendingPathComponent("port42-pasted", isDirectory: true)
