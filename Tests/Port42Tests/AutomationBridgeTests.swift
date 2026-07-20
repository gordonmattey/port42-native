import Testing
import Foundation
@testable import Port42Lib

@Suite("Automation Bridge")
struct AutomationBridgeTests {

    // MARK: - Permission Mapping

    @Test("automation.runAppleScript requires .automation permission")
    @MainActor func runAppleScriptPermission() throws {
        #expect(try registryPermission("automation.runAppleScript") == .automation)
    }

    @Test("automation.runJXA requires .automation permission")
    @MainActor func runJXAPermission() throws {
        #expect(try registryPermission("automation.runJXA") == .automation)
    }

    // MARK: - Permission Description

    @Test(".automation permission has descriptive text")
    func automationPermissionDescription() {
        let desc = PortPermission.automation.permissionDescription
        #expect(!desc.title.isEmpty)
        #expect(!desc.message.isEmpty)
    }

    // MARK: - Timeout Clamping

    // The timeout LOGIC is tested directly (resolveTimeout), not through a live NSAppleScript run:
    // a headless test process has no Automation TCC grant, so the live path returns neither a value
    // nor an error and can't gate this. The real osascript/NSAppleScript path stays live-only.
    @Test("timeout defaults to 30s when not specified")
    @MainActor
    func defaultTimeout() {
        #expect(AutomationBridge().resolveTimeout([:]) == AutomationBridge.defaultTimeout)
    }

    @Test("timeout clamps to [1, 120]")
    @MainActor
    func timeoutClamp() {
        let bridge = AutomationBridge()
        #expect(bridge.resolveTimeout(["timeout": 999]) == AutomationBridge.maxTimeout)  // clamp high
        #expect(bridge.resolveTimeout(["timeout": 0]) == 1)                               // clamp low
        #expect(bridge.resolveTimeout(["timeout": 45]) == 45)                             // in range
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
