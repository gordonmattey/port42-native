import Testing
import Foundation

/// Relay downloads are verifiable, and the docs never tell anyone to wave a warning through
/// (BLD-10). The binaries and SHA256SUMS shipped unsigned, and the README said to right-click Open on
/// macOS and "Run anyway" past SmartScreen.
@Suite("Relay release")
struct RelayReleaseTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func read(_ p: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(p), encoding: .utf8)
    }

    @Test("the release workflow attests every archive and SHA256SUMS")
    func provenance() throws {
        let wf = try read(".github/workflows/relay.yml")
        #expect(wf.contains("actions/attest-build-provenance@"))
        #expect(wf.contains("dist/relay/SHA256SUMS") && wf.contains("dist/relay/*.tar.gz") && wf.contains("dist/relay/*.zip"))
        #expect(wf.contains("id-token: write") && wf.contains("attestations: write"))
    }

    @Test("relay-dist.sh notarizes the macOS binaries it signs")
    func notarized() throws {
        #expect(try read("scripts/relay-dist.sh").contains("notarytool submit"))
    }

    @Test("the relay docs say how to verify a download and never to bypass a warning")
    func docs() throws {
        for p in ["gateway/relay-README.txt", "docs/run-a-relay.md"] {
            let text = try read(p)
            #expect(text.contains("gh attestation verify"), "\(p) does not say how to verify")
            #expect(!text.contains("Run anyway") && !text.lowercased().contains("right-click, open"),
                    "\(p) tells people to bypass a warning")
        }
    }
}
