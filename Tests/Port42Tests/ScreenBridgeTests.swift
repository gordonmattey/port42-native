import Testing
import Foundation
@testable import Port42Lib

@Suite("Screen Bridge")
struct ScreenBridgeTests {

    // MARK: - Permission Mapping

    @Test("screen.capture requires .screen permission")
    func capturePermission() {
        #expect(PortPermission.permissionForMethod("screen.capture") == .screen)
    }

    @Test("screen.windows requires .screen permission")
    func windowsPermission() {
        #expect(PortPermission.permissionForMethod("screen.windows") == .screen)
    }

    // MARK: - Permission descriptions

    @Test(".screen permission has descriptive text")
    func screenPermissionDescription() {
        let desc = PortPermission.screen.permissionDescription
        #expect(!desc.title.isEmpty)
        #expect(!desc.message.isEmpty)
    }

    // MARK: - ScreenBridge construction

    @Test("ScreenBridge can be instantiated")
    @MainActor
    func instantiation() {
        let bridge = ScreenBridge()
        #expect(bridge != nil)
    }
}
