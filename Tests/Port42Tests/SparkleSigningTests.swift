import Testing
import Foundation

/// Sparkle's helpers are signed with no entitlements of ours, as Sparkle documents (BLD-03). They
/// used to get JIT, unsigned executable memory, disable-library-validation and Apple Events.
@Suite("Sparkle signing")
struct SparkleSigningTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("no Sparkle signing line passes --entitlements")
    func noSparkleEntitlements() throws {
        let script = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        let sparkleSigning = script.split(separator: "\n").filter {
            $0.contains("codesign") && ($0.contains("SPARKLE") || $0.contains("Sparkle"))
        }
        #expect(!sparkleSigning.isEmpty)
        for line in sparkleSigning {
            #expect(!line.contains("--entitlements"), "\(line)")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sparkle.entitlements").path))
    }
}
