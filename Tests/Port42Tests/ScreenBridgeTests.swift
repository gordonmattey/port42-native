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

    // MARK: - Ownership guard (backlog 0.5, Step 1) — keyed on the stable port id

    @Test("releaseIfOwned ignores a non-owner port id")
    @MainActor
    func releaseIgnoresNonOwner() {
        let sb = ScreenBridge()
        sb.isStreaming = true
        sb.ownerPortId = "A"
        sb.releaseIfOwned(byPortId: "other")
        #expect(sb.isStreaming, "another port's id must not stop this stream")
    }

    @Test("releaseIfOwned stops the stream for the owning port id")
    @MainActor
    func releaseStopsForOwner() {
        let sb = ScreenBridge()
        sb.isStreaming = true
        sb.ownerPortId = "A"
        sb.releaseIfOwned(byPortId: "A")
        #expect(!sb.isStreaming, "the owning port id must stop the stream")
    }

    @Test("releaseIfOwned is idempotent")
    @MainActor
    func releaseIdempotent() {
        let sb = ScreenBridge()
        sb.isStreaming = true
        sb.ownerPortId = "A"
        sb.releaseIfOwned(byPortId: "A")
        sb.releaseIfOwned(byPortId: "A")  // second call is a safe no-op
        #expect(!sb.isStreaming)
    }
}
