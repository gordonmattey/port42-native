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

    // MARK: - Device Permission Mapping

    @Test("terminal.spawn requires .terminal permission")
    func terminalSpawnPermission() {
        #expect(PortPermission.permissionForMethod("terminal.spawn") == .terminal)
    }

    @Test("terminal.send requires .terminal permission")
    func terminalSendPermission() {
        #expect(PortPermission.permissionForMethod("terminal.send") == .terminal)
    }

    @Test("terminal.kill requires .terminal permission")
    func terminalKillPermission() {
        #expect(PortPermission.permissionForMethod("terminal.kill") == .terminal)
    }

    @Test("audio.capture requires .microphone permission")
    func audioCapturePermission() {
        #expect(PortPermission.permissionForMethod("audio.capture") == .microphone)
    }

    @Test("audio.speak requires no permission (output only)")
    func audioSpeakNoPermission() {
        #expect(PortPermission.permissionForMethod("audio.speak") == nil)
    }

    @Test("camera.capture requires .camera permission")
    func cameraCapturePermission() {
        #expect(PortPermission.permissionForMethod("camera.capture") == .camera)
    }

    @Test("camera.stream requires .camera permission")
    func cameraStreamPermission() {
        #expect(PortPermission.permissionForMethod("camera.stream") == .camera)
    }

    @Test("screen.capture requires .screen permission")
    func screenCapturePermission() {
        #expect(PortPermission.permissionForMethod("screen.capture") == .screen)
    }

    @Test("clipboard.read requires .clipboard permission")
    func clipboardReadPermission() {
        #expect(PortPermission.permissionForMethod("clipboard.read") == .clipboard)
    }

    @Test("clipboard.write requires .clipboard permission")
    func clipboardWritePermission() {
        #expect(PortPermission.permissionForMethod("clipboard.write") == .clipboard)
    }

    @Test("fs.pick requires .filesystem permission")
    func fsPickPermission() {
        #expect(PortPermission.permissionForMethod("fs.pick") == .filesystem)
    }

    @Test("fs.read requires .filesystem permission")
    func fsReadPermission() {
        #expect(PortPermission.permissionForMethod("fs.read") == .filesystem)
    }

    @Test("fs.write requires .filesystem permission")
    func fsWritePermission() {
        #expect(PortPermission.permissionForMethod("fs.write") == .filesystem)
    }

    // MARK: - Separate Grants

    @Test("AI permission does not grant terminal")
    func aiDoesNotGrantTerminal() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        bridge.grantedPermissions.insert(.ai)
        #expect(!bridge.grantedPermissions.contains(.terminal))
    }

    @Test("terminal permission does not grant microphone")
    func terminalDoesNotGrantMicrophone() {
        let bridge = PortBridge(appState: NSObject(), channelId: nil)
        bridge.grantedPermissions.insert(.terminal)
        #expect(!bridge.grantedPermissions.contains(.microphone))
    }

    // MARK: - Permission Description

    @Test(".ai permission has non-empty description")
    func aiPermissionDescription() {
        let desc = PortPermission.ai.permissionDescription
        #expect(!desc.title.isEmpty)
        #expect(!desc.message.isEmpty)
    }

    @Test("all permissions have non-empty descriptions")
    func allPermissionDescriptions() {
        let all: [PortPermission] = [.ai, .terminal, .microphone, .camera, .screen, .clipboard, .filesystem]
        for perm in all {
            let desc = perm.permissionDescription
            #expect(!desc.title.isEmpty, "Empty title for \(perm)")
            #expect(!desc.message.isEmpty, "Empty message for \(perm)")
        }
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
