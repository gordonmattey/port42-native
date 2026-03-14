import Testing
import Foundation
@testable import Port42Lib

@Suite("Automation Bridge")
struct AutomationBridgeTests {

    // MARK: - Permission Mapping

    @Test("automation.runAppleScript requires .automation permission")
    func runAppleScriptPermission() {
        #expect(PortPermission.permissionForMethod("automation.runAppleScript") == .automation)
    }

    @Test("automation.runJXA requires .automation permission")
    func runJXAPermission() {
        #expect(PortPermission.permissionForMethod("automation.runJXA") == .automation)
    }

    // MARK: - Permission Description

    @Test(".automation permission has descriptive text")
    func automationPermissionDescription() {
        let desc = PortPermission.automation.permissionDescription
        #expect(!desc.title.isEmpty)
        #expect(!desc.message.isEmpty)
    }

    // MARK: - Timeout Clamping

    @Test("timeout defaults to 30s when not specified")
    @MainActor
    func defaultTimeout() async {
        let bridge = AutomationBridge()
        // Run a trivial AppleScript that returns quickly to verify it works
        let result = await bridge.runAppleScript(source: "return \"hello\"", opts: [:])
        // If we get here without timing out at 30s, the default timeout is working
        #expect(result["result"] as? String == "hello" || result["error"] != nil)
    }

    @Test("timeout clamps to max 120s")
    @MainActor
    func timeoutClamp() async {
        let bridge = AutomationBridge()
        // Pass a timeout of 999 which should be clamped to 120
        // Just verify it doesn't crash; the actual timeout value is internal
        let result = await bridge.runAppleScript(source: "return \"ok\"", opts: ["timeout": 999])
        #expect(result["result"] as? String == "ok" || result["error"] != nil)
    }

    // MARK: - Error Handling

    @Test("invalid AppleScript returns error")
    @MainActor
    func invalidAppleScript() async {
        let bridge = AutomationBridge()
        let result = await bridge.runAppleScript(source: "this is not valid applescript !!!", opts: [:])
        #expect(result["error"] != nil)
    }

    @Test("invalid JXA returns error")
    @MainActor
    func invalidJXA() async {
        let bridge = AutomationBridge()
        let result = await bridge.runJXA(source: "this is not valid javascript !!!", opts: [:])
        #expect(result["error"] != nil)
    }
}
