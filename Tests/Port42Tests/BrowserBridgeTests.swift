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

    // MARK: - Session ownership (backlog 0.5, Step 2) — keyed on the stable port id

    @MainActor
    private func session(_ id: String, owner: String?) -> BrowserSession {
        BrowserSession(id: id, width: 320, height: 240, userAgent: nil, bridge: nil, ownerPortId: owner)
    }

    @Test("releaseIfOwned closes only the sessions the given port opened")
    @MainActor
    func releaseClosesOwnedSessions() {
        let browser = BrowserBridge()
        browser.sessions["a1"] = session("a1", owner: "portA")
        browser.sessions["b1"] = session("b1", owner: "portB")
        browser.releaseIfOwned(byPortId: "portA")
        #expect(browser.sessions["a1"] == nil, "port A's session must be closed")
        #expect(browser.sessions["b1"] != nil, "port B's session must survive")
    }

    @Test("releaseIfOwned for an unrelated port id closes nothing")
    @MainActor
    func releaseIgnoresNonOwner() {
        let browser = BrowserBridge()
        browser.sessions["a1"] = session("a1", owner: "portA")
        browser.releaseIfOwned(byPortId: "other")
        #expect(browser.sessions["a1"] != nil, "an unrelated id must not close the session")
    }
}
