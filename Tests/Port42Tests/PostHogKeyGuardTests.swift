import Testing
import Foundation

/// A build refuses any PostHog key but the public project key (SEC-03). Two personal keys (phx_,
/// account-wide read/write) were committed in the shipped Info.plist and went out in the DMGs.
@Suite("PostHog key guard")
struct PostHogKeyGuardTests {
    /// Runs build.sh's SEC-03 block alone with the given key and returns its exit status.
    private func guardStatus(key: String?) throws -> Int32 {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        let begin = try #require(script.range(of: "# SEC-03 BEGIN"))
        let end = try #require(script.range(of: "# SEC-03 END"))
        let block = String(script[begin.lowerBound..<end.upperBound])

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "set -euo pipefail\n" + block]
        var env = ["PATH": "/usr/bin:/bin"]
        if let key { env["POSTHOG_API_KEY"] = key }
        p.environment = env
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    @Test("a project key or no key builds")
    func projectKeyPasses() throws {
        #expect(try guardStatus(key: "phc_projectkey123") == 0)
        #expect(try guardStatus(key: nil) == 0)
        #expect(try guardStatus(key: "") == 0)
    }

    @Test("a personal key or anything else stops the build")
    func personalKeyFails() throws {
        #expect(try guardStatus(key: "phx_personalkey123") != 0)
        #expect(try guardStatus(key: "sk-something") != 0)
    }
}
