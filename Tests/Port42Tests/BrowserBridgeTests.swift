import Testing
import Foundation
@testable import Port42Lib

@Suite("Browser Bridge")
struct BrowserBridgeTests {

    // MARK: - Permission Mapping

    @Test("browser.open requires .browser permission")
    func openPermission() {
        #expect(PortPermission.permissionForMethod("browser.open") == .browser)
    }

    @Test("browser.navigate requires .browser permission")
    func navigatePermission() {
        #expect(PortPermission.permissionForMethod("browser.navigate") == .browser)
    }

    @Test("browser.capture requires .browser permission")
    func capturePermission() {
        #expect(PortPermission.permissionForMethod("browser.capture") == .browser)
    }

    @Test("browser.text requires .browser permission")
    func textPermission() {
        #expect(PortPermission.permissionForMethod("browser.text") == .browser)
    }

    @Test("browser.html requires .browser permission")
    func htmlPermission() {
        #expect(PortPermission.permissionForMethod("browser.html") == .browser)
    }

    @Test("browser.execute requires .browser permission")
    func executePermission() {
        #expect(PortPermission.permissionForMethod("browser.execute") == .browser)
    }

    @Test("browser.close requires .browser permission")
    func closePermission() {
        #expect(PortPermission.permissionForMethod("browser.close") == .browser)
    }

    // MARK: - Permission descriptions

    @Test(".browser permission has descriptive text")
    func browserPermissionDescription() {
        let desc = PortPermission.browser.permissionDescription
        #expect(!desc.title.isEmpty)
        #expect(!desc.message.isEmpty)
    }
}
