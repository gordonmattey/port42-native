import Testing
import Foundation
@testable import Port42Lib

// Knowledge-distribution item A: the published API reference is a COMMITTED artifact that cannot
// drift from the registry. `llms.txt` at the repo root is generated (preamble + inventory) by the
// same renderer `help` serves live; this suite is both the exporter (regen mode) and the CI gate.
//
// Regenerate deliberately after a registry change:
//   PORT42_REGEN_DOCS=1 swift test --filter BridgeDocsExportTests
// then commit the updated llms.txt. Without the env flag the suite only verifies.
@Suite("Bridge docs export (llms.txt)")
struct BridgeDocsExportTests {

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/Port42Tests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    @Test("the generated reference is deterministic and non-empty")
    @MainActor
    func deterministic() throws {
        // Two separately built worlds must render byte-equal: the renderer sorts namespaces,
        // entries, and aliases, so dictionary seeding can never flap the freshness gate.
        let a = generateAPIReference(try makeParityWorld().state)
        let b = generateAPIReference(try makeParityWorld().state)
        #expect(a == b)
        #expect(a.contains("## Available Methods"))
        #expect(a.contains("user.get"))
        // The published artifact must be WHAT THE APP SERVES: preamble + inventory. Bundle.port42
        // used to fall back to Bundle.main under test, silently dropping the preamble — an
        // exported llms.txt would then differ from the live `help` output.
        #expect(a.hasPrefix("PORTS: A port is a live interactive surface"),
                "the conceptual preamble (llms-preamble.txt) must lead the reference")
    }

    @Test("committed llms.txt equals the generated reference (the freshness gate)")
    @MainActor
    func freshness() throws {
        let generated = generateAPIReference(try makeParityWorld().state)
        let url = Self.repoRoot().appendingPathComponent("llms.txt")
        if ProcessInfo.processInfo.environment["PORT42_REGEN_DOCS"] == "1" {
            try generated.write(to: url, atomically: true, encoding: .utf8)
        }
        let committed = try String(contentsOf: url, encoding: .utf8)
        #expect(committed == generated,
                "llms.txt drifted from the registry — regenerate: PORT42_REGEN_DOCS=1 swift test --filter BridgeDocsExportTests, then commit")
    }
}
