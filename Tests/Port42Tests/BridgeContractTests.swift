import Testing
import Foundation
@testable import Port42Lib

// Phase 0 of the API/tool-use unification: the contract types have no wiring yet, so these are pure
// unit tests. The load-bearing one is `ToolNaming coverage` — it proves the snake↔dotted map covers
// every tool the model can emit, with no collisions, which is what deletes the "Unknown tool" class.

@Suite("BridgeValue encoders")
struct BridgeValueTests {

    @Test("scalars encode to JSON as themselves")
    func scalarsJSON() {
        #expect(BridgeValue.bool(true).toJSONObject() as? Bool == true)
        #expect(BridgeValue.int(42).toJSONObject() as? Int == 42)
        #expect(BridgeValue.double(1.5).toJSONObject() as? Double == 1.5)
        #expect(BridgeValue.string("hi").toJSONObject() as? String == "hi")
        #expect(BridgeValue.null.toJSONObject() is NSNull)
    }

    @Test("array + object encode recursively (ports.list is an array everywhere)")
    func containersJSON() {
        let v = BridgeValue.array([.object(["id": .string("a"), "n": .int(1)])])
        let arr = v.toJSONObject() as? [Any]
        #expect(arr?.count == 1)
        let first = arr?.first as? [String: Any]
        #expect(first?["id"] as? String == "a")
        #expect(first?["n"] as? Int == 1)
    }

    @Test("data encodes to its base64 string for JSON/JS")
    func dataJSON() {
        #expect(BridgeValue.data(base64: "QUJD", mime: "image/png").toJSONObject() as? String == "QUJD")
    }

    @Test("a string renders as a plain text block for tool-use")
    func stringToolBlock() {
        let blocks = BridgeValue.string("pong").toToolBlocks()
        #expect(blocks.count == 1)
        #expect(blocks.first?["type"] as? String == "text")
        #expect(blocks.first?["text"] as? String == "pong")
    }

    @Test("structured data renders as one JSON text block for tool-use")
    func structuredToolBlock() {
        let v = BridgeValue.object(["ok": .bool(true), "id": .string("z")])
        let blocks = v.toToolBlocks()
        #expect(blocks.count == 1)
        #expect(blocks.first?["type"] as? String == "text")
        // sortedKeys makes this deterministic.
        #expect(blocks.first?["text"] as? String == "{\"id\":\"z\",\"ok\":true}")
    }

    @Test("binary renders as an Anthropic image block for tool-use")
    func imageToolBlock() {
        let blocks = BridgeValue.data(base64: "QUJD", mime: "image/png").toToolBlocks()
        #expect(blocks.first?["type"] as? String == "image")
        let source = blocks.first?["source"] as? [String: Any]
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/png")
        #expect(source?["data"] as? String == "QUJD")
    }

    @Test("a bare scalar still serializes for tool-use (fragmentsAllowed)")
    func scalarToolBlock() {
        #expect(BridgeValue.int(7).toToolBlocks().first?["text"] as? String == "7")
        #expect(BridgeValue.bool(false).toToolBlocks().first?["text"] as? String == "false")
    }
}

@Suite("BridgeError rendering")
struct BridgeErrorTests {

    @Test("renders {error,code} for JSON and an Error: block for tool-use")
    func renders() {
        let e = BridgeError.missingArg("id")
        let json = e.toJSONObject() as? [String: Any]
        #expect(json?["error"] as? String == "missing required argument 'id'")
        #expect(json?["code"] as? String == "missing_arg")
        #expect(e.toToolBlocks().first?["text"] as? String == "Error: missing required argument 'id'")
    }
}

@Suite("ToolNaming map")
struct ToolNamingTests {

    @Test("snakeify handles dots and camelCase")
    func snakeify() {
        #expect(ToolNaming.snakeify("ports.list") == "ports_list")
        #expect(ToolNaming.snakeify("port.getHtml") == "port_get_html")
        #expect(ToolNaming.snakeify("crease.read") == "crease_read")
    }

    @Test("the camelCase methods that used to 404 now round-trip")
    @MainActor
    func camelCaseRoundTrip() throws {
        // These are the exact names the `.`→`_` munge broke.
        let w = try makeParityWorld()
        #expect(ToolNaming.tool(fromCanonical: "port.getHtml") == "port_get_html")
        #expect(w.state.canonicalFromTool("port_get_html") == "port.getHtml")
    }

    @Test("the genuine renames map through the override table")
    @MainActor
    func overrides() throws {
        let w = try makeParityWorld()
        #expect(ToolNaming.tool(fromCanonical: "automation.runAppleScript") == "run_applescript")
        #expect(w.state.canonicalFromTool("run_applescript") == "automation.runAppleScript")
        #expect(w.state.canonicalFromTool("screen_info") == "screen.displays")
        #expect(w.state.canonicalFromTool("file_read") == "fs.read")
        #expect(w.state.canonicalFromTool("file_write") == "fs.write")
    }

    @Test("files.* aliases resolve to their fs.* canonical")
    func aliases() {
        #expect(ToolNaming.resolveAlias("files.read") == "fs.read")
        #expect(ToolNaming.resolveAlias("port.getHtml") == "port.getHtml")   // non-alias passes through
    }

    // The bijection gate moved to BridgeNamingTests.roundTripAndUnique: the inventory it iterates
    // is the registry itself now, not a hand list (close-out step 4a).

    @Test("COVERAGE: every generated tool name maps to a canonical method")
    @MainActor
    func coversAllToolDefinitions() throws {
        // Was ToolDefinitions.all until the hybrid list emptied (tail items 4+5) — the hand-written
        // list is [] by design now, so the coverage subject is the GENERATED tool list, same repoint
        // as the step-1 suites.
        let toolNames = try generatedToolList().compactMap { $0["name"] as? String }
        #expect(!toolNames.isEmpty)
        var unmapped: [String] = []
        let w = try makeParityWorld()
        for name in toolNames where w.state.canonicalFromTool(name) == nil {
            unmapped.append(name)
        }
        #expect(unmapped.isEmpty, "tool names with no canonical mapping: \(unmapped)")
    }
}

@Suite("Principal")
struct PrincipalTests {

    @Test("a principal is the permission identity: stable id, display label, space scope")
    func identity() {
        let p = Principal(id: "peer-abc", displayName: "Claude Code", spaceId: nil, kind: .peer)
        #expect(p.id == "peer-abc")          // grant keys on identity, not a label
        #expect(p.displayName == "Claude Code")
        #expect(p.spaceId == nil)
    }

    @Test("a spaceless principal scopes its grant globally, not unpersistably")
    func spacelessScope() {
        let p = Principal(id: "peer-abc", displayName: "Claude Code", spaceId: nil, kind: .peer)
        // nil spaceId = the coordinator's "everywhere" wording, not "ask every time".
        #expect(p.scopeDescription.contains("globally"))
    }

    @Test("a port principal in a space scopes its grant to that space")
    func portScope() {
        let p = Principal(id: "port-1", displayName: "shader", spaceId: "space-9", kind: .port)
        #expect(p.scopeDescription.contains("in this space"))
    }
}

@Suite("BridgeArgs")
struct BridgeArgsTests {

    @Test("named form reads typed values with lenient coercion")
    func named() throws {
        let a = BridgeArgs(["id": "abc", "version": 3, "ratio": 1, "count": "5"])
        #expect(a.string("id") == "abc")
        #expect(a.int("version") == 3)
        #expect(a.double("ratio") == 1.0)   // Int coerced to Double
        #expect(a.int("count") == 5)        // String coerced to Int
        #expect(try a.requireString("id") == "abc")
    }

    @Test("positional form zips against parameter names (the port-JS mapping)")
    func positional() {
        // port42.port.getHtml(id, version)  →  ["abc", 2]
        let a = BridgeArgs(positional: ["abc", 2], names: ["id", "version"])
        #expect(a.string("id") == "abc")
        #expect(a.int("version") == 2)
    }

    @Test("a missing required arg throws a uniform BridgeError")
    func missingRequired() {
        let a = BridgeArgs([:])
        #expect(throws: BridgeError.self) { try a.requireString("id") }
    }
}
