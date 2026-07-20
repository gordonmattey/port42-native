import Testing
import Foundation
@testable import Port42Lib

/// Step 1 (uniform port.create): `terminal.exec` is restored to the JS bridge as the only
/// permission-gated terminal method, backed by the shared `ShellExec` runner.
@Suite("TerminalExecBridge")
struct TerminalExecBridgeTests {

    @Test("terminal.exec bridge method is gated behind .terminal")
    @MainActor func bridgeMethodGated() throws {
        #expect(try registryPermission("terminal.exec") == .terminal)
    }

    @Test("spawn/send/resize/kill stay removed from the bridge permission map")
    @MainActor func legacyTerminalMethodsUngated() throws {
        // These bridge methods were deleted in the xterm sweep and must not reappear.
        #expect(try registryPermission("terminal.spawn") == nil)
        #expect(try registryPermission("terminal.send") == nil)
        #expect(try registryPermission("terminal.resize") == nil)
        #expect(try registryPermission("terminal.kill") == nil)
    }

    @Test("ShellExec.run captures stdout")
    func runCapturesStdout() async {
        let out = await ShellExec.run("echo hi")
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
    }

    @Test("ShellExec.run annotates a non-zero exit code")
    func runAnnotatesExitCode() async {
        let out = await ShellExec.run("exit 3")
        #expect(out.contains("[exit code: 3]"))
    }

    @Test("ShellExec.run honours cwd")
    func runHonoursCwd() async {
        let out = await ShellExec.run("pwd", cwd: "/tmp")
        // /tmp is a symlink to /private/tmp on macOS — accept either resolution.
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed == "/tmp" || trimmed == "/private/tmp")
    }
}
