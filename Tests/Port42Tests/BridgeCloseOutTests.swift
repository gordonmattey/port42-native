import Testing
import Foundation
@testable import Port42Lib

// The close-out gate: the unification arc ends when the two old switches are GONE and nothing
// falls through to them. Source-scan (same technique as Spike B): the old `case "<method>"` labels
// must not exist in PortBridge.handleMethod or ToolExecutor. ai.cancel survives as an explicit
// machinery branch (the documented transport shim), not a switch case. `help` moves into the
// registry so the port surface keeps serving the API reference.

@Suite("Bridge — close-out (the switches are gone)")
struct BridgeCloseOutTests {

    static func source(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/Port42Tests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/Port42Lib/Services/\(file)")
        return try String(contentsOf: dir, encoding: .utf8)
    }

    /// Every `case "<name>"` label whose name looks like a bridge method (dotted or snake), i.e.
    /// an old-switch case. Nested action switches on plain words (e.g. "focus") do not match.
    static func methodCaseLabels(in source: String) -> [String] {
        let pattern = #"case "([a-z][a-zA-Z0-9]*[._][a-zA-Z0-9._]+)""#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    @Test("PortBridge carries no old-switch method cases")
    func portBridgeSwitchGone() throws {
        let labels = Self.methodCaseLabels(in: try Self.source("PortBridge.swift"))
        #expect(labels.isEmpty, "old-switch cases remain in PortBridge: \(labels)")
    }

    @Test("ToolExecutor carries no old-switch method cases")
    func toolExecutorSwitchGone() throws {
        let labels = Self.methodCaseLabels(in: try Self.source("ToolExecutor.swift"))
        #expect(labels.isEmpty, "old-switch cases remain in ToolExecutor: \(labels)")
    }

    @Test("help is served by the registry")
    @MainActor
    func helpInRegistry() async throws {
        let w = try makeParityWorld()
        let help = try #require(w.registry["help"], "help must join the registry")
        // Flipped tool-exposed with topics (GM decision 2026-07-19, knowledge item B): help is the
        // one lazy-load mechanism for platform knowledge, for companions too.
        #expect(help.toolExposed, "help is an LLM tool since the knowledge-distribution arc")
        let value = try await help.run(w.principal, BridgeArgs([:]))
        guard case let .string(text) = value else {
            Issue.record("help should return the API reference text")
            return
        }
        #expect(!text.isEmpty)
    }

    @Test("an unknown method fails cleanly on the registry path, nothing falls through")
    @MainActor
    func unknownMethodFails() async throws {
        let w = try makeParityWorld()
        #expect(w.registry["definitely.not.a.method"] == nil)
        await #expect(throws: BridgeError.self) {
            _ = try await w.state.runBridgeMethod(
                "definitely.not.a.method",
                principal: w.principal,
                args: BridgeArgs([:]))
        }
    }
}
