import Testing
import Foundation
@testable import Port42Lib

@Suite("Terminal Bridge")
struct TerminalBridgeTests {

    // MARK: - Permission Mapping

    @Test("terminal.spawn requires .terminal permission")
    func spawnPermission() {
        #expect(PortPermission.permissionForMethod("terminal.spawn") == .terminal)
    }

    @Test("terminal.send requires .terminal permission")
    func sendPermission() {
        #expect(PortPermission.permissionForMethod("terminal.send") == .terminal)
    }

    @Test("terminal.resize requires .terminal permission")
    func resizePermission() {
        #expect(PortPermission.permissionForMethod("terminal.resize") == .terminal)
    }

    @Test("terminal.kill requires .terminal permission")
    func killPermission() {
        #expect(PortPermission.permissionForMethod("terminal.kill") == .terminal)
    }

    // MARK: - TerminalBridge.Session

    @Test("spawn returns a session ID")
    @MainActor
    func spawnReturnsSessionId() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)
        defer { tb.killAll() }

        let sessionId = tb.spawn()
        #expect(sessionId != nil)
        #expect(!sessionId!.isEmpty)
    }

    @Test("spawned session is running")
    @MainActor
    func spawnedSessionIsRunning() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)
        defer { tb.killAll() }

        let sessionId = tb.spawn()!
        #expect(tb.isRunning(sessionId: sessionId))
    }

    @Test("send returns true for running session")
    @MainActor
    func sendToRunningSession() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)
        defer { tb.killAll() }

        let sessionId = tb.spawn()!
        let ok = tb.send(sessionId: sessionId, data: "echo hello\n")
        #expect(ok)
    }

    @Test("send returns false for unknown session")
    @MainActor
    func sendToUnknownSession() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)

        let ok = tb.send(sessionId: "nonexistent", data: "echo hello\n")
        #expect(!ok)
    }

    @Test("resize returns true for running session")
    @MainActor
    func resizeRunningSession() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)
        defer { tb.killAll() }

        let sessionId = tb.spawn()!
        let ok = tb.resize(sessionId: sessionId, cols: 120, rows: 40)
        #expect(ok)
    }

    @Test("kill returns true and session stops")
    @MainActor
    func killSession() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)

        let sessionId = tb.spawn()!
        let ok = tb.kill(sessionId: sessionId)
        #expect(ok)

        // After kill, send should fail
        try await Task.sleep(for: .milliseconds(100))
        let sendOk = tb.send(sessionId: sessionId, data: "echo\n")
        #expect(!sendOk)
    }

    @Test("kill returns false for unknown session")
    @MainActor
    func killUnknownSession() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)

        let ok = tb.kill(sessionId: "nonexistent")
        #expect(!ok)
    }

    @Test("killAll cleans up all sessions")
    @MainActor
    func killAllSessions() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)

        let id1 = tb.spawn()!
        let id2 = tb.spawn()!
        tb.killAll()

        try await Task.sleep(for: .milliseconds(100))
        #expect(!tb.isRunning(sessionId: id1))
        #expect(!tb.isRunning(sessionId: id2))
    }

    @Test("spawn with custom shell")
    @MainActor
    func spawnCustomShell() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)
        defer { tb.killAll() }

        let sessionId = tb.spawn(shell: "/bin/bash")
        #expect(sessionId != nil)
    }

    @Test("spawn with custom dimensions")
    @MainActor
    func spawnCustomDimensions() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)
        defer { tb.killAll() }

        let sessionId = tb.spawn(cols: 120, rows: 40)
        #expect(sessionId != nil)
    }
}
