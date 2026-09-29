import Testing
import Foundation

/// No tracked text carries a real channel key (SEC-04). A design doc published a working invite for the
/// first-swimmers channel, its AES key included, in a public repo. A channel key is 32 random bytes, so
/// a real one is 43 base64 characters plus its padding; placeholders and short examples are not.
@Suite("Published invites")
struct PublishedInviteTests {
    @Test("no tracked text file holds a 32-byte channel key in an invite or config")
    func noChannelKeys() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "ls-files", "-z", "*.md", "*.txt", "*.json", "*.html", "*.swift", "*.go", "*.js", "*.mjs"]
        let pipe = Pipe()
        git.standardOutput = pipe
        try git.run()
        let listing = pipe.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        let files = listing.split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) }
        #expect(files.count > 50)

        // key=<43 base64 chars>= (or %3D) in a link, or "encryptionKey": "<43 chars>=" in a config.
        let pattern = try Regex(#"(key=|"encryptionKey"\s*:\s*")[A-Za-z0-9+/]{43}(=|%3D)"#)
        var offenders: [String] = []
        for f in files where !f.hasPrefix("Tests/") {
            guard let text = try? String(contentsOf: root.appendingPathComponent(f), encoding: .utf8) else { continue }
            if text.contains(pattern) { offenders.append(f) }
        }
        #expect(offenders.isEmpty, "a channel key is published in: \(offenders.joined(separator: ", "))")
    }
}
