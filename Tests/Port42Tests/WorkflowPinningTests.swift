import Testing
import Foundation

/// Every GitHub workflow runs actions pinned by commit SHA under a read-only default token (BLD-09).
/// relay.yml ran with contents and packages write for every job, and the Windows spike ran a
/// third-party action from its moving `main` branch.
@Suite("Workflow pinning")
struct WorkflowPinningTests {
    private let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".github/workflows")

    private func workflows() throws -> [(String, String)] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".yml") }
            .map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    @Test("every uses: names a 40-character commit SHA")
    func actionsPinned() throws {
        let files = try workflows()
        #expect(!files.isEmpty)
        let uses = try Regex(#"uses:\s*([^\s#]+)"#)
        let pinned = try Regex(#"^[^@]+@[0-9a-f]{40}$"#)
        for (name, text) in files {
            for m in text.matches(of: uses) {
                let ref = String(text[m.range]).replacingOccurrences(of: "uses:", with: "").trimmingCharacters(in: .whitespaces)
                let target = ref.split(separator: "#").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ref
                #expect(target.wholeMatch(of: pinned) != nil, "\(name): \(target) is not pinned by SHA")
            }
        }
    }

    @Test("every workflow sets a top-level permissions block that grants no write")
    func readOnlyByDefault() throws {
        for (name, text) in try workflows() {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let i = lines.firstIndex(of: "permissions:") else {
                Issue.record("\(name) has no top-level permissions block")
                continue
            }
            let block = lines[(i + 1)...].prefix { $0.hasPrefix("  ") }
            #expect(!block.contains { $0.contains("write") }, "\(name) grants write by default")
        }
    }
}
