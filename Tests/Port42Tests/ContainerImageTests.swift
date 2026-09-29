import Testing
import Foundation

/// The relay and invite-page images build from digest-pinned bases, run as a non-root user, and send
/// the builder only what they copy (BLD-08). They ran as root on tag-pinned bases with the whole
/// directory, stale binaries included, as build context.
@Suite("Container images")
struct ContainerImageTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("every FROM is pinned by digest, and the runtime stage is distroless nonroot", arguments: ["gateway/relay.Dockerfile", "tele.Dockerfile"])
    func pinnedAndNonroot(_ path: String) throws {
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        let froms = text.split(separator: "\n").filter { $0.hasPrefix("FROM ") }
        #expect(froms.count == 2, "\(path): \(froms)")
        for f in froms { #expect(f.contains("@sha256:"), "\(path): \(f) is not pinned by digest") }
        #expect(froms.last?.contains("distroless/static-debian12:nonroot@sha256:") == true, "\(path) does not run as nonroot")
    }

    @Test("each build context ignores everything it does not copy", arguments: ["gateway/.dockerignore", "tele.Dockerfile.dockerignore"])
    func contextIsMinimal(_ path: String) throws {
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        let rules = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        #expect(rules.first == "**", "\(path) must start by excluding everything")
    }
}
