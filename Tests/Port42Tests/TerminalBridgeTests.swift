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

    @Test("terminal.send requires no permission (session already permitted at spawn)")
    func sendPermission() {
        #expect(PortPermission.permissionForMethod("terminal.send") == nil)
    }

    @Test("terminal.resize requires no permission (session already permitted at spawn)")
    func resizePermission() {
        #expect(PortPermission.permissionForMethod("terminal.resize") == nil)
    }

    @Test("terminal.kill requires no permission (session already permitted at spawn)")
    func killPermission() {
        #expect(PortPermission.permissionForMethod("terminal.kill") == nil)
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

    // MARK: - sendToFirst

    @Test("sendToFirst returns true when session exists")
    @MainActor
    func sendToFirstWithActiveSession() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)
        defer { tb.killAll() }

        _ = tb.spawn()
        let ok = tb.sendToFirst(data: "echo hello\n")
        #expect(ok)
    }

    @Test("sendToFirst returns false when no sessions")
    @MainActor
    func sendToFirstNoSessions() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)

        let ok = tb.sendToFirst(data: "echo hello\n")
        #expect(!ok)
    }

    @Test("sendToFirst returns false after killAll")
    @MainActor
    func sendToFirstAfterKill() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)

        _ = tb.spawn()
        tb.killAll()
        try await Task.sleep(for: .milliseconds(100))
        let ok = tb.sendToFirst(data: "echo hello\n")
        #expect(!ok)
    }

    // MARK: - CWD tracking via OSC 7

    @Test("extractCwdFromChunk parses BEL-terminated OSC 7")
    func extractCwdBel() {
        let chunk = "\u{1b}]7;file://localhost/private/tmp\u{07}"
        #expect(TerminalBridge.extractCwdFromChunk(chunk) == "/private/tmp")
    }

    @Test("extractCwdFromChunk parses ST-terminated OSC 7")
    func extractCwdSt() {
        let chunk = "\u{1b}]7;file://localhost/Users/gordon/Code\u{1b}\\"
        #expect(TerminalBridge.extractCwdFromChunk(chunk) == "/Users/gordon/Code")
    }

    @Test("extractCwdFromChunk returns nil when no OSC 7")
    func extractCwdNoOsc7() {
        #expect(TerminalBridge.extractCwdFromChunk("normal output\r\n") == nil)
    }

    @Test("extractCwdFromChunk handles OSC 7 embedded in other output")
    func extractCwdEmbedded() {
        let chunk = "some output\r\n\u{1b}]7;file://localhost/tmp\u{07}\r\n$ "
        #expect(TerminalBridge.extractCwdFromChunk(chunk) == "/tmp")
    }

    @Test("cwd returns nil for unknown session")
    @MainActor
    func cwdUnknownSession() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)
        #expect(tb.cwd(sessionId: "no-such-id") == nil)
    }

    @Test("cwd returns nil before any OSC 7 is received")
    @MainActor
    func cwdNilBeforeOsc7() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)
        defer { tb.killAll() }

        let sid = try #require(tb.spawn())
        try await Task.sleep(for: .milliseconds(300))
        #expect(tb.cwd(sessionId: sid) == nil)
    }

    @Test("updateCwd sets cwd on the session")
    @MainActor
    func updateCwdSetsProperty() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)
        defer { tb.killAll() }

        let sid = try #require(tb.spawn())
        let session = try #require(tb.session(for: sid))
        session.updateCwd(from: "/private/tmp")

        #expect(tb.cwd(sessionId: sid) == "/private/tmp")
    }

    @Test("firstActiveSessionCwd reflects updateCwd")
    @MainActor
    func firstActiveSessionCwdReflectsUpdate() async throws {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        let tb = TerminalBridge(bridge: bridge)
        defer { tb.killAll() }

        let sid = try #require(tb.spawn())
        let session = try #require(tb.session(for: sid))
        session.updateCwd(from: "/Users/gordon/Code")

        #expect(tb.firstActiveSessionCwd == "/Users/gordon/Code")
    }
}
