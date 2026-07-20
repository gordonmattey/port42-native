import Testing
import Foundation
@testable import Port42Lib

// Close-out step 4a: the tool-name map DERIVES from the registry instead of the hand-typed
// ToolNaming.canonicalMethods list. ToolNaming keeps only spelling rules (snakeify + the override
// table); the inventory is the registry itself, so a method that exists is nameable and a method
// that does not exist is not. The two honest failure directions of the hand list today: `help` is
// registry-served but absent from the list; `port.resize` and `ai.cancel` are listed but are NOT
// registry methods (pure JS carve-out / per-bridge machinery).

@Suite("Bridge — naming (derived from the registry)")
struct BridgeNamingTests {

    @Test("the map knows every registry method and nothing else")
    @MainActor
    func derivedFromRegistry() throws {
        let w = try makeParityWorld()
        // In the registry, missing from the old hand list:
        #expect(w.state.canonicalFromTool("help") == "help")
        // In the old hand list, not registry methods (carve-out / machinery):
        #expect(w.state.canonicalFromTool("port_resize") == nil)
        #expect(w.state.canonicalFromTool("ai_cancel") == nil)
        // Override spellings survive the flip:
        #expect(w.state.canonicalFromTool("file_read") == "fs.read")
        #expect(w.state.canonicalFromTool("screen_info") == "screen.displays")
        #expect(w.state.canonicalFromTool("run_applescript") == "automation.runAppleScript")
    }

    @Test("every registry method round-trips canonical -> tool -> canonical, uniquely")
    @MainActor
    func roundTripAndUnique() throws {
        let w = try makeParityWorld()
        let canonicals = Set(w.registry.keys).union(w.state.bridgeStreamRegistry.keys)
        var seenTools: [String: String] = [:]
        for c in canonicals {
            let t = ToolNaming.tool(fromCanonical: c)
            #expect(seenTools[t] == nil, "tool name collision: '\(t)' from \(c) and \(seenTools[t] ?? "")")
            seenTools[t] = c
            #expect(w.state.canonicalFromTool(t) == c, "round-trip failed for \(c) via \(t)")
        }
    }
}
