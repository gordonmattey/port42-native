import Testing
import Foundation
@testable import Port42Lib

/// Step 5 guard: the parallel terminal tool family (`terminal_spawn`/`terminal_send`/`terminal_list`)
/// is deleted — a terminal is just a port type, driven through `port.create` / `port_push` /
/// `ports_list`. `terminal_exec` (headless run-and-capture) is the only remaining — and the only
/// gated — terminal tool. This is the tripwire against accidentally resurrecting the old family or
/// dropping the wrong symbol.
@Suite("TerminalToolSurface")
@MainActor
struct TerminalToolSurfaceTests {

    private func toolNames() throws -> Set<String> {
        Set(try generatedToolList().compactMap { $0["name"] as? String })
    }

    @Test("the parallel terminal tool family is deleted")
    func legacyTerminalToolsRemoved() throws {
        let names = try toolNames()
        #expect(!names.contains("terminal_spawn"))
        #expect(!names.contains("terminal_send"))
        #expect(!names.contains("terminal_list"))
        // and the older bridge tools stay gone
        #expect(!names.contains("terminal_bridge"))
        #expect(!names.contains("terminal_unbridge"))
    }

    @Test("terminal_exec survives and stays the only gated terminal tool")
    func terminalExecRemainsGated() throws {
        #expect(try toolNames().contains("terminal_exec"))
        #expect(ToolDefinitions.permission(for: "terminal_exec") == .terminal)
        // the deleted tools resolve to no permission (not found in the switch)
        #expect(ToolDefinitions.permission(for: "terminal_spawn") == nil)
        #expect(ToolDefinitions.permission(for: "terminal_send") == nil)
        #expect(ToolDefinitions.permission(for: "terminal_list") == nil)
    }

    @Test("the port verbs that replace them are present and ungated")
    func replacementVerbsUngated() throws {
        let names = try toolNames()
        #expect(names.contains("port_create"))
        #expect(names.contains("port_push"))
        #expect(names.contains("ports_list"))
        #expect(ToolDefinitions.permission(for: "port_create") == nil)
        #expect(ToolDefinitions.permission(for: "port_push") == nil)
    }
}
