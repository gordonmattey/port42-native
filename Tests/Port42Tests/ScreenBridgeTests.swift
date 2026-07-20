import Testing
import Foundation
@testable import Port42Lib

@Suite("Screen Bridge")
struct ScreenBridgeTests {

    // MARK: - Permission Mapping

    @Test("screen.capture requires .screen permission")
    @MainActor func capturePermission() throws {
        #expect(try registryPermission("screen.capture") == .screen)
    }

    @Test("screen.windows requires .screen permission")
    @MainActor func windowsPermission() throws {
        #expect(try registryPermission("screen.windows") == .screen)
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
