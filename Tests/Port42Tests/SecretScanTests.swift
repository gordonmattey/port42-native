import Testing
import Foundation

/// Secrets are caught before they ship (SEC-01): a PostHog personal key reached two releases in March.
/// This runs on every build (build.sh's test gate); CI runs gitleaks on every push
/// (.github/workflows/secrets.yml) and scripts/pre-commit-secrets.sh checks each commit.
@Suite("Secret scan")
struct SecretScanTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("no tracked file outside the test fixtures holds a key-shaped secret")
    func noSecretsTracked() throws {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "ls-files", "-z"]
        let pipe = Pipe()
        git.standardOutput = pipe
        try git.run()
        let listing = pipe.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        let files = listing.split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) }
            .filter { !$0.hasPrefix("Tests/") && !$0.hasPrefix("guest/test/") && !$0.hasSuffix("_test.go") }
        #expect(files.count > 100)
        let pattern = try Regex(#"phx_[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{36}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----"#)
        var offenders: [String] = []
        for f in files {
            guard let text = try? String(contentsOf: root.appendingPathComponent(f), encoding: .utf8) else { continue }
            if text.contains(pattern) { offenders.append(f) }
        }
        #expect(offenders.isEmpty, "key-shaped secrets in: \(offenders.joined(separator: ", "))")
    }

    @Test("gitleaks is configured with a phx_ rule, run in CI, and offered as a pre-commit hook")
    func scannerWired() throws {
        let config = try String(contentsOf: root.appendingPathComponent(".gitleaks.toml"), encoding: .utf8)
        #expect(config.contains("phx_") && config.contains("useDefault = true"))
        let wf = try String(contentsOf: root.appendingPathComponent(".github/workflows/secrets.yml"), encoding: .utf8)
        #expect(wf.contains("gitleaks") && wf.contains(".gitleaks.toml"))
        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("scripts/git-hooks/pre-commit").path))
    }
}
