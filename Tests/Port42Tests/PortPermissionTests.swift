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

    @Test("space.current requires no permission")
    func spaceCurrentNoPermission() {
        #expect(PortPermission.permissionForMethod("space.current") == nil)
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

    @Test("terminal.exec is the only gated terminal method; spawn is ungated")
    func terminalExecPermission() {
        #expect(PortPermission.permissionForMethod("terminal.exec") == .terminal)
        // spawn/send/list were removed from the bridge during the uniform-port.create sweep.
        #expect(PortPermission.permissionForMethod("terminal.spawn") == nil)
    }

    @Test("terminal.send requires no permission (session already permitted via spawn)")
    func terminalSendNoPermission() {
        #expect(PortPermission.permissionForMethod("terminal.send") == nil)
    }

    @Test("terminal.resize requires no permission (session already permitted via spawn)")
    func terminalResizeNoPermission() {
        #expect(PortPermission.permissionForMethod("terminal.resize") == nil)
    }

    @Test("terminal.kill requires no permission (session already permitted via spawn)")
    func terminalKillNoPermission() {
        #expect(PortPermission.permissionForMethod("terminal.kill") == nil)
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
        let bridge = PortBridge(appState: NSObject(), spaceId: nil)
        bridge.grantedPermissions.insert(.ai)
        #expect(!bridge.grantedPermissions.contains(.terminal))
    }

    @Test("terminal permission does not grant microphone")
    func terminalDoesNotGrantMicrophone() {
        let bridge = PortBridge(appState: NSObject(), spaceId: nil)
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
        let bridge = PortBridge(appState: NSObject(), spaceId: nil)
        #expect(bridge.grantedPermissions.isEmpty)
    }

    @Test("granted permission persists within session")
    func grantedPermissionPersists() {
        let bridge = PortBridge(appState: NSObject(), spaceId: nil)
        bridge.grantedPermissions.insert(.ai)
        #expect(bridge.grantedPermissions.contains(.ai))
    }

    @Test("new bridge has no active streams")
    func newBridgeNoStreams() {
        let bridge = PortBridge(appState: NSObject(), spaceId: nil)
        #expect(bridge.streamTasks.isEmpty)
    }

    // ("pending permission starts nil" retired: a bridge no longer owns pending-permission state.
    //  Asks live on the one PermissionCoordinator — see PermissionCoordinatorTests.)

    // MARK: - Companion-Level Persistence (P-260)

    @Test("companionPermissions returns empty set for unknown companion+space")
    @MainActor
    func companionPermissionsUnknown() throws {
        let db = try DatabaseService(inMemory: true)
        let appState = AppState(db: db)
        let perms = appState.companionPermissions(createdBy: "unknown-companion", spaceId: "unknown-space")
        #expect(perms.isEmpty)
    }

    @Test("saveCompanionPermissions and companionPermissions round-trip")
    @MainActor
    func companionPermissionsRoundTrip() throws {
        let db = try DatabaseService(inMemory: true)
        let appState = AppState(db: db)
        let key = "test-companion-\(UUID().uuidString)"
        let spaceId = "test-space-\(UUID().uuidString)"
        appState.saveCompanionPermissions([.terminal, .ai], createdBy: key, spaceId: spaceId)
        let restored = appState.companionPermissions(createdBy: key, spaceId: spaceId)
        #expect(restored.contains(.terminal))
        #expect(restored.contains(.ai))
        #expect(!restored.contains(.camera))
        // Cleanup
        appState.saveCompanionPermissions([], createdBy: key, spaceId: spaceId)
    }

    @Test("companion permissions are scoped to spaceId — different space gets empty set")
    @MainActor
    func companionPermissionsScopedToSpace() throws {
        let db = try DatabaseService(inMemory: true)
        let appState = AppState(db: db)
        let companion = "test-companion-\(UUID().uuidString)"
        let spaceA = "space-a-\(UUID().uuidString)"
        let spaceB = "space-b-\(UUID().uuidString)"
        appState.saveCompanionPermissions([.terminal], createdBy: companion, spaceId: spaceA)
        let permsB = appState.companionPermissions(createdBy: companion, spaceId: spaceB)
        #expect(permsB.isEmpty)
        // Cleanup
        appState.saveCompanionPermissions([], createdBy: companion, spaceId: spaceA)
    }

    @Test("companion permissions are scoped to createdBy — different companion gets empty set")
    @MainActor
    func companionPermissionsScopedToCompanion() throws {
        let db = try DatabaseService(inMemory: true)
        let appState = AppState(db: db)
        let spaceId = "test-space-\(UUID().uuidString)"
        let companionA = "companion-a-\(UUID().uuidString)"
        let companionB = "companion-b-\(UUID().uuidString)"
        appState.saveCompanionPermissions([.terminal], createdBy: companionA, spaceId: spaceId)
        let permsB = appState.companionPermissions(createdBy: companionB, spaceId: spaceId)
        #expect(permsB.isEmpty)
        // Cleanup
        appState.saveCompanionPermissions([], createdBy: companionA, spaceId: spaceId)
    }

    @Test("saving empty permissions removes the entry")
    @MainActor
    func saveEmptyPermissionsRemoves() throws {
        let db = try DatabaseService(inMemory: true)
        let appState = AppState(db: db)
        let companion = "test-companion-\(UUID().uuidString)"
        let spaceId = "test-space-\(UUID().uuidString)"
        appState.saveCompanionPermissions([.terminal], createdBy: companion, spaceId: spaceId)
        appState.saveCompanionPermissions([], createdBy: companion, spaceId: spaceId)
        let perms = appState.companionPermissions(createdBy: companion, spaceId: spaceId)
        #expect(perms.isEmpty)
    }
}
