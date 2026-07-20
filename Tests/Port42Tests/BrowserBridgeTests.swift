import Testing
import Foundation
@testable import Port42Lib

@Suite("Browser Bridge")
struct BrowserBridgeTests {

    // MARK: - Permission Mapping

    @Test("browser.open requires .browser permission")
    @MainActor func openPermission() throws {
        #expect(try registryPermission("browser.open") == .browser)
    }

    @Test("browser.navigate requires .browser permission")
    @MainActor func navigatePermission() throws {
        #expect(try registryPermission("browser.navigate") == .browser)
    }

    @Test("browser.capture requires .browser permission")
    @MainActor func capturePermission() throws {
        #expect(try registryPermission("browser.capture") == .browser)
    }

    @Test("browser.text requires .browser permission")
    @MainActor func textPermission() throws {
        #expect(try registryPermission("browser.text") == .browser)
    }

    @Test("browser.html requires .browser permission")
    @MainActor func htmlPermission() throws {
        #expect(try registryPermission("browser.html") == .browser)
    }

    @Test("browser.execute requires .browser permission")
    @MainActor func executePermission() throws {
        #expect(try registryPermission("browser.execute") == .browser)
    }

    @Test("browser.close requires .browser permission")
    @MainActor func closePermission() throws {
        #expect(try registryPermission("browser.close") == .browser)
    }

    // MARK: - Permission descriptions

    @Test(".browser permission has descriptive text")
    func browserPermissionDescription() {
        let desc = PortPermission.browser.permissionDescription
        #expect(!desc.title.isEmpty)
        #expect(!desc.message.isEmpty)
    }
}
