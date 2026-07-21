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

    @Test("ShellExec.run returns full output — the base no longer truncates any caller")
    func runReturnsFullOutput() async {
        // 300KB, past both the old 50KB base cap and the new 200KB model-path cap. A port/gateway
        // caller must get the whole thing; bounding for the model is ToolExecutor's job now.
        let out = await ShellExec.run("awk 'BEGIN{for(i=0;i<300000;i++)printf \"x\"}'")
        #expect(out.count >= 300_000)
        #expect(!out.contains("truncated"))
    }

    @Test("capForModel bounds an oversized text block in-band; leaves small + non-text blocks")
    func capForModelBounds() {
        let big = String(repeating: "a", count: 250_000)
        let capped = ToolExecutor.capForModel([["type": "text", "text": big]], max: 200_000)
        let text = capped[0]["text"] as? String ?? ""
        #expect(text.utf8.count < big.utf8.count)                       // it was cut
        #expect(text.hasPrefix(String(repeating: "a", count: 100)))     // head preserved
        #expect(text.contains("truncated: showing 200000 of 250000 bytes"))  // in-band, legible

        // A block under the cap is untouched.
        let small = ToolExecutor.capForModel([["type": "text", "text": "hi"]], max: 200_000)
        #expect(small[0]["text"] as? String == "hi")

        // A non-text block (image) is never truncated, even under a tiny cap.
        let img = ToolExecutor.capForModel([["type": "image", "source": ["data": "AAAA"]]], max: 4)
        #expect((img[0]["type"] as? String) == "image")
    }
}
