import Testing
import Foundation
@testable import Port42Lib

@Suite("Port Permission")
struct PortPermissionTests {

    // MARK: - permissionForMethod

    @Test("ai.complete requires .ai permission")
    func aiCompletePermission() {
        #expect(PortPermission.permissionForMethod("ai.complete") == .ai)
    }

    @Test("ai.cancel requires .ai permission")
    func aiCancelPermission() {
        #expect(PortPermission.permissionForMethod("ai.cancel") == .ai)
    }

    @Test("companions.invoke requires .ai permission")
    func companionsInvokePermission() {
        #expect(PortPermission.permissionForMethod("companions.invoke") == .ai)
    }

    @Test("user.get requires no permission")
    func userGetNoPermission() {
        #expect(PortPermission.permissionForMethod("user.get") == nil)
    }

    @Test("companions.list requires no permission")
    func companionsListNoPermission() {
        #expect(PortPermission.permissionForMethod("companions.list") == nil)
    }

    @Test("companions.get requires no permission")
    func companionsGetNoPermission() {
        #expect(PortPermission.permissionForMethod("companions.get") == nil)
    }

    @Test("messages.recent requires no permission")
    func messagesRecentNoPermission() {
        #expect(PortPermission.permissionForMethod("messages.recent") == nil)
    }

    @Test("messages.send requires no permission")
    func messagesSendNoPermission() {
        #expect(PortPermission.permissionForMethod("messages.send") == nil)
    }

    @Test("channel.current requires no permission")
    func channelCurrentNoPermission() {
        #expect(PortPermission.permissionForMethod("channel.current") == nil)
    }

    @Test("storage.set requires no permission")
    func storageSetNoPermission() {
        #expect(PortPermission.permissionForMethod("storage.set") == nil)
    }

    @Test("unknown method requires no permission")
    func unknownMethodNoPermission() {
        #expect(PortPermission.permissionForMethod("some.unknown.method") == nil)
    }

    // MARK: - Permission Description

    @Test(".ai permission has non-empty description")
    func aiPermissionDescription() {
        let desc = PortPermission.ai.permissionDescription
        #expect(!desc.title.isEmpty)
        #expect(!desc.message.isEmpty)
    }

    // MARK: - PortBridge Permission State

    @Test("new bridge has empty grantedPermissions")
    func newBridgeEmptyPermissions() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        #expect(bridge.grantedPermissions.isEmpty)
    }

    @Test("granted permission persists within session")
    func grantedPermissionPersists() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        bridge.grantedPermissions.insert(.ai)
        #expect(bridge.grantedPermissions.contains(.ai))
    }

    @Test("new bridge has no active streams")
    func newBridgeNoStreams() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        #expect(bridge.activeStreams.isEmpty)
    }

    @Test("pending permission starts nil")
    func pendingPermissionNil() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        #expect(bridge.pendingPermission == nil)
    }
}
