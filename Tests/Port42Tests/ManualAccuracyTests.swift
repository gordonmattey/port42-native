import Testing
import Foundation
@testable import Port42Lib

/// The manuals agents read teach only methods that exist (found 2026-09-25: after the engine and
/// the old chat went, `ports-context.txt` still taught `ai.complete`, Keeper's creases and folds,
/// `companions.invoke` and `messages_recent`, so an agent following it called methods that answer
/// `unknown_method`).
@Suite("Manual accuracy")
@MainActor
struct ManualAccuracyTests {

    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Port42Lib/Resources")

    static func manual(_ name: String) throws -> String {
        try String(contentsOf: resources.appendingPathComponent(name), encoding: .utf8)
    }

    static func matches(_ pattern: String, in text: String) -> Set<String> {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return Set(re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) })
    }

    /// The port's own JS surface, not registry methods: event listeners and the helpers
    /// `PortBridge` defines in the page. Pinned, so a new name here is a deliberate edit.
    static let jsOnly: Set<String> = [
        "audio.on", "browser.on", "camera.on", "screen.on", "viewport.on",
        "connection.onStatusChange", "connection.status", "fs.onFileDrop", "port.resize",
    ]

    @Test("every port42.x.y(...) the manuals teach is a registry method or a pinned JS helper")
    func jsCallsExist() throws {
        let w = try makeParityWorld()
        let known = Set(w.registry.keys).union(w.state.bridgeStreamRegistry.keys)
        var unknown: Set<String> = []
        for file in ["ports-context.txt", "ports-core.txt", "llms-preamble.txt"] {
            let taught = Self.matches(#"port42\.([a-zA-Z]+\.[a-zA-Z]+)\("#, in: try Self.manual(file))
            unknown.formUnion(taught.filter { !known.contains($0) && !Self.jsOnly.contains($0) }
                .map { "\(file): \($0)" })
        }
        #expect(unknown.isEmpty, "taught but not in the registry: \(unknown.sorted())")
    }

    @Test("every tool name the manuals teach is a generated tool")
    func toolCallsExist() throws {
        let w = try makeParityWorld()
        let tools = Set(w.state.generatedToolDefinitions().compactMap { $0["name"] as? String })
        var unknown: Set<String> = []
        for file in ["ports-context.txt", "ports-core.txt"] {
            let taught = Self.matches(#"\b([a-z]+_[a-z_]+)\("#, in: try Self.manual(file))
            unknown.formUnion(taught.filter { !tools.contains($0) }.map { "\(file): \($0)" })
        }
        #expect(unknown.isEmpty, "taught but not a tool: \(unknown.sorted())")
    }
}
