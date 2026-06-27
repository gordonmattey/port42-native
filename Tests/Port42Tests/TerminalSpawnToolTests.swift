import Testing
import Foundation
@testable import Port42Lib

/// Step 2 of the first-class-terminal-ports plan: the `terminal_spawn` tool must exist so
/// companions get a native `terminal` port instead of hand-rolling xterm. The spawn itself
/// needs a real window/Ghostty surface (manual verify), but the tool's *registration* —
/// presence in the schema list and permission gating — is pure and testable here.
@Suite("TerminalSpawnTool")
struct TerminalSpawnToolTests {

    @Test("terminal_spawn is registered in ToolDefinitions.all")
    func registered() {
        let names = Set(ToolDefinitions.all.compactMap { $0["name"] as? String })
        #expect(names.contains("terminal_spawn"))
    }

    @Test("terminal_spawn is gated behind the terminal permission")
    func permissionGated() {
        #expect(ToolDefinitions.permission(for: "terminal_spawn") == .terminal)
    }

    @Test("terminal_spawn schema has no required fields (all inputs optional)")
    func allInputsOptional() {
        let tool = ToolDefinitions.all.first { $0["name"] as? String == "terminal_spawn" }
        #expect(tool != nil)
        let schema = tool?["input_schema"] as? [String: Any]
        // No `required` array → every field (command/cwd/title/space_id) is optional.
        #expect(schema?["required"] == nil)
        let props = schema?["properties"] as? [String: Any]
        #expect(props?["command"] != nil)
        #expect(props?["space_id"] != nil)
    }
}
