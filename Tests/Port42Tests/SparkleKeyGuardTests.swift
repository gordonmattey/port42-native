import Testing
import Foundation

/// A release build stops unless the built Info.plist carries a real 32-byte EdDSA key (BLD-04).
/// envsubst turned an unset SPARKLE_EDDSA_PUBLIC_KEY into an empty SUPublicEDKey without a word.
@Suite("Sparkle key guard")
struct SparkleKeyGuardTests {
    /// Runs build.sh's BLD-04 block alone against a plist holding `key`, and returns its exit status.
    private func guardStatus(key: String, config: String) throws -> Int32 {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        let begin = try #require(script.range(of: "# BLD-04 BEGIN"))
        let end = try #require(script.range(of: "# BLD-04 END"))
        let block = String(script[begin.lowerBound..<end.upperBound])

        let app = FileManager.default.temporaryDirectory.appendingPathComponent("bld04-\(UUID().uuidString)")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let plist: [String: Any] = ["SUPublicEDKey": key]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "set -euo pipefail\n" + block]
        p.environment = ["PATH": "/usr/bin:/bin", "APP": app.path, "CONFIG": config]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private let validKey = Data(repeating: 7, count: 32).base64EncodedString()

    @Test("a release stops on a missing, empty or short key, and builds with a real one")
    func release() throws {
        #expect(try guardStatus(key: "", config: "release") != 0)
        #expect(try guardStatus(key: "AAAA", config: "release") != 0)
        #expect(try guardStatus(key: validKey, config: "release") == 0)
    }

    @Test("a dev build only warns")
    func debug() throws {
        #expect(try guardStatus(key: "", config: "debug") == 0)
    }
}
