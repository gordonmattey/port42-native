import Testing
import Foundation
@testable import Port42Lib

// MARK: - BridgeSchemaParityTests (Spike A)
//
// Proves the self-describing registry can GENERATE the Anthropic tool schemas that `ToolDefinitions`
// currently hand-maintains. For every tool in `ToolDefinitions` that has a registry method, the schema
// generated from the method's inline `description` + `inputSchema` (via `anthropicToolSchema`) must
// equal the hand-written one, byte-for-byte after sorted-keys canonicalization.
//
// Green ⇒ generation is faithful for all 52 parity-set methods, so `ToolDefinitions` can be flipped to
// generated and deleted (the big-bang shrinks to flip-source + delete + Proxy). Red ⇒ the failing tool
// names are the exact list to fix before touching production — which is the whole point of the spike.
//
// This also proves, for free, that `ToolNaming`'s canonical⇄tool override table (the `file_*`,
// `port_get_html`, `screen_info`, `run_applescript`/`run_jxa` renames) is complete: a missing or wrong
// override makes the generated `name` differ from the tool name, which fails parity.

@Suite("Bridge schema parity — generated == ToolDefinitions")
@MainActor
struct BridgeSchemaParityTests {

    // Tools that are still live-only on the old path — no registry method exists yet, so the generator
    // cannot produce them and they stay hand-written in `ToolDefinitions` (hybrid mode). Excluded from
    // parity here; the guard test below asserts this list stays accurate (no method silently landed).
    static let hybridOnlyTools: Set<String> = []

    /// Sorted-keys JSON of a schema dict, for order-insensitive deep comparison (same canonicalization
    /// the parity harness uses on tool blocks).
    static func canon(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "UNSERIALIZABLE" }
        return s
    }

    static func goldenURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/tool-definitions-golden.json")
    }

    /// The golden tool schemas indexed by tool name — originally the hand-written `ToolDefinitions`
    /// snapshotted before deletion, and since then the last REVIEWED generated set. It is what the
    /// generator is checked against now that the hand-written schemas are gone from production.
    ///
    /// Regenerate deliberately after a registry change, then READ THE DIFF before committing:
    ///   PORT42_REGEN_GOLDEN=1 swift test --filter BridgeSchemaParityTests
    /// Without the flag the suite only verifies. (Same contract as `llms.txt`
    /// in `BridgeDocsExportTests` — a generated artifact needs a regen path, or it rots: this
    /// fixture silently missed the four `screen.record*` methods for exactly that reason.)
    static func toolDefsByName() -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: goldenURL()),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        var m: [String: [String: Any]] = [:]
        for t in arr { if let n = t["name"] as? String { m[n] = t } }
        return m
    }

    /// Writes the current generated set to the fixture. Runs FIRST (it is the only test that
    /// mutates the fixture) and only under the env flag; a normal run is read-only.
    @Test("A. regenerate the golden (opt-in: PORT42_REGEN_GOLDEN=1)")
    func regenerateGolden() throws {
        guard ProcessInfo.processInfo.environment["PORT42_REGEN_GOLDEN"] == "1" else { return }
        let world = try makeParityWorld()
        // Sorted by name: the registry hands them back in dictionary order, which would rewrite
        // the whole file on every regen and bury the real change in a 1000-line diff.
        let generated = world.state.generatedToolDefinitions()
            .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        let data = try JSONSerialization.data(withJSONObject: generated,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.goldenURL())
    }

    /// The tool schema generated from whichever registry (one-shot or streaming) holds `canonical`, or
    /// nil if neither does.
    static func generatedSchema(canonical: String,
                                registry: BridgeRegistry,
                                stream: BridgeStreamRegistry) -> [String: Any]? {
        if let m = registry[canonical] { return anthropicToolSchema(canonical: canonical, method: m) }
        if let sm = stream[canonical] { return anthropicToolSchema(canonical: canonical, method: sm) }
        return nil
    }

    @Test("Generated schema equals the hand-written ToolDefinitions schema for all 52 parity methods")
    func generatedMatchesHandWritten() throws {
        let world = try makeParityWorld()
        let registry = buildBridgeRegistry(world.state)
        let stream = buildBridgeStreamRegistry(world.state)
        let defs = Self.toolDefsByName()

        var checked = 0
        var mismatches: [String] = []

        for (toolName, expected) in defs {
            if Self.hybridOnlyTools.contains(toolName) { continue }
            guard let canonical = world.state.canonicalFromTool(toolName) else {
                Issue.record("no canonical mapping for tool '\(toolName)' — registry inventory gap")
                mismatches.append(toolName)
                continue
            }
            guard let generated = Self.generatedSchema(canonical: canonical, registry: registry, stream: stream) else {
                Issue.record("tool '\(toolName)' (canonical '\(canonical)') has no registry entry and is not in hybridOnlyTools — extract it or add it to the exclusion list")
                mismatches.append(toolName)
                continue
            }
            let g = Self.canon(generated)
            let e = Self.canon(expected)
            if g != e {
                mismatches.append(toolName)
                Issue.record("SCHEMA MISMATCH for \(toolName)\n  generated: \(g)\n  expected:  \(e)")
            }
            checked += 1
        }

        #expect(mismatches.isEmpty, "schema mismatches (fix these before flipping ToolDefinitions to generated): \(mismatches.sorted())")
        // Coverage: every ToolDefinitions tool is either checked or explicitly hybrid-only. No silent skip.
        #expect(checked == defs.count - Self.hybridOnlyTools.count,
                "checked \(checked) but expected \(defs.count - Self.hybridOnlyTools.count) (defs \(defs.count) minus hybrid \(Self.hybridOnlyTools.count))")
        // 63 = the full golden: 52 original + rest_call (item 4) + the 4 browser tools (item 5)
        // + help (knowledge item B: tool-exposed with topics, GM decision 2026-07-19)
        // + port_publish + screen_record{,_start,_stop,_status} (added to the registry after the
        // snapshot; the fixture had no regen path, so it silently missed them until 2026-07-24).
        // + port_get_dom (R3, 2026-07-26): a read-only live-DOM read, so a caller can look at a port
        // without `port.exec` bumping its activity token and invalidating the caller's own read.
        // The hybrid list is empty; every golden schema is parity-checked against the generator.
        #expect(checked == 64, "expected 64 parity-set methods, checked \(checked)")
    }

    @Test("generatedToolDefinitions reproduces the full ToolDefinitions.all set (the flip is safe)")
    func fullListParity() throws {
        let world = try makeParityWorld()
        let generated = world.state.generatedToolDefinitions()

        var genByName: [String: [String: Any]] = [:]
        for t in generated { if let n = t["name"] as? String { genByName[n] = t } }
        let expected = Self.toolDefsByName()

        // Same set of tool names (57: 52 generated + 5 hybrid).
        #expect(Set(genByName.keys) == Set(expected.keys),
                "tool name set differs (symmetric diff): \(Set(genByName.keys).symmetricDifference(Set(expected.keys)).sorted())")

        // Each schema matches the hand-written oracle byte-for-byte (sorted-keys).
        var mismatches: [String] = []
        for (name, exp) in expected {
            guard let gen = genByName[name] else { mismatches.append("missing:\(name)"); continue }
            if Self.canon(gen) != Self.canon(exp) { mismatches.append(name) }
        }
        #expect(mismatches.isEmpty, "generated schema differs from ToolDefinitions.all for: \(mismatches.sorted())")
    }

    @Test("Hybrid-only tools genuinely have no registry method (exclusion list has not rotted)")
    func hybridOnlyToolsAreNotYetInRegistry() throws {
        let world = try makeParityWorld()
        let registry = buildBridgeRegistry(world.state)
        let stream = buildBridgeStreamRegistry(world.state)
        let defsByName = Self.toolDefsByName()

        for tool in Self.hybridOnlyTools {
            #expect(defsByName[tool] != nil, "hybridOnlyTools names '\(tool)' but ToolDefinitions has no such tool")
            guard let canonical = world.state.canonicalFromTool(tool) else { continue }
            let inRegistry = registry[canonical] != nil || stream[canonical] != nil
            #expect(!inRegistry, "'\(tool)' (canonical '\(canonical)') is now in the registry — remove it from hybridOnlyTools so it gets parity-checked")
        }
    }
}
