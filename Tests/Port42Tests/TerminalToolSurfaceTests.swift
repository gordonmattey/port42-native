import Testing
import Foundation
@testable import Port42Lib

/// Step 5a guard: after the `TerminalBridge` deletion sweep, the NATIVE terminal tool surface must
/// stay intact and the removed legacy bridge tools must stay gone. This is the tripwire that
/// catches the sweep (or a future edit) accidentally deleting the wrong symbol.
@Suite("TerminalToolSurface")
struct TerminalToolSurfaceTests {

    private var toolNames: Set<String> {
        Set(ToolDefinitions.all.compactMap { $0["name"] as? String })
    }

    @Test("native terminal tools survive the sweep")
    func nativeToolsPresent() {
        let names = toolNames
        #expect(names.contains("terminal_spawn"))
        #expect(names.contains("terminal_send"))
        #expect(names.contains("terminal_list"))
        #expect(names.contains("terminal_exec"))
    }

    @Test("native terminal tools are gated behind the terminal permission")
    func nativeToolsGated() {
        #expect(ToolDefinitions.permission(for: "terminal_spawn") == .terminal)
        #expect(ToolDefinitions.permission(for: "terminal_send") == .terminal)
        #expect(ToolDefinitions.permission(for: "terminal_list") == .terminal)
        #expect(ToolDefinitions.permission(for: "terminal_exec") == .terminal)
    }

    @Test("legacy bridge tools are gone (D4)")
    func bridgeToolsRemoved() {
        let names = toolNames
        #expect(!names.contains("terminal_bridge"))
        #expect(!names.contains("terminal_unbridge"))
    }
}
