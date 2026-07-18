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
    static let hybridOnlyTools: Set<String> = [
        "browser_open", "browser_text", "browser_capture", "browser_close",
        "rest_call",
    ]

    /// Sorted-keys JSON of a schema dict, for order-insensitive deep comparison (same canonicalization
    /// the parity harness uses on tool blocks).
    static func canon(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "UNSERIALIZABLE" }
        return s
    }

    /// `ToolDefinitions.all` indexed by tool name.
    static func toolDefsByName() -> [String: [String: Any]] {
        var m: [String: [String: Any]] = [:]
        for t in ToolDefinitions.all where t["name"] is String {
            m[t["name"] as! String] = t
        }
        return m
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
            guard let canonical = ToolNaming.canonical(fromTool: toolName) else {
                Issue.record("no canonical mapping for tool '\(toolName)' — ToolNaming inventory gap")
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
        #expect(checked == 52, "expected 52 parity-set methods, checked \(checked)")
    }

    @Test("Hybrid-only tools genuinely have no registry method (exclusion list has not rotted)")
    func hybridOnlyToolsAreNotYetInRegistry() throws {
        let world = try makeParityWorld()
        let registry = buildBridgeRegistry(world.state)
        let stream = buildBridgeStreamRegistry(world.state)
        let defsByName = Self.toolDefsByName()

        for tool in Self.hybridOnlyTools {
            #expect(defsByName[tool] != nil, "hybridOnlyTools names '\(tool)' but ToolDefinitions has no such tool")
            guard let canonical = ToolNaming.canonical(fromTool: tool) else { continue }
            let inRegistry = registry[canonical] != nil || stream[canonical] != nil
            #expect(!inRegistry, "'\(tool)' (canonical '\(canonical)') is now in the registry — remove it from hybridOnlyTools so it gets parity-checked")
        }
    }
}
