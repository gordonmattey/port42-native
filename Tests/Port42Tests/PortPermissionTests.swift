import Testing
import Foundation
@testable import Port42Lib

@Suite("Port Permission")
struct PortPermissionTests {

    // MARK: - the registry permission map (the old parallel table is gone)

    @Test("ai.complete requires .ai permission")
    @MainActor func aiCompletePermission() throws {
        #expect(try registryPermission("ai.complete") == .ai)
    }

    @Test("ai.cancel is bridge machinery, not a registry method — no separate permission")
    @MainActor func aiCancelPermission() throws {
        // Cancelling a stream you were allowed to start needs no second grant; ai.cancel lives as
        // an explicit PortBridge machinery branch (the documented transport shim), not in the
        // registry. The old table gated it .ai, which double-charged a permission for stopping.
        #expect(try registryPermission("ai.cancel") == nil)
    }

    @Test("companions.invoke requires .ai permission")
    @MainActor func companionsInvokePermission() throws {
        #expect(try registryPermission("companions.invoke") == .ai)
    }

    @Test("user.get requires no permission")
    @MainActor func userGetNoPermission() throws {
        #expect(try registryPermission("user.get") == nil)
    }

    @Test("companions.list requires no permission")
    @MainActor func companionsListNoPermission() throws {
        #expect(try registryPermission("companions.list") == nil)
    }

    @Test("companions.get requires no permission")
    @MainActor func companionsGetNoPermission() throws {
        #expect(try registryPermission("companions.get") == nil)
    }

    @Test("messages.recent requires no permission")
    @MainActor func messagesRecentNoPermission() throws {
        #expect(try registryPermission("messages.recent") == nil)
    }

    @Test("messages.send requires no permission")
    @MainActor func messagesSendNoPermission() throws {
        #expect(try registryPermission("messages.send") == nil)
    }

    @Test("space.current requires no permission")
    @MainActor func spaceCurrentNoPermission() throws {
        #expect(try registryPermission("space.current") == nil)
    }

    @Test("storage.set requires no permission")
    @MainActor func storageSetNoPermission() throws {
        #expect(try registryPermission("storage.set") == nil)
    }

    @Test("unknown method requires no permission")
    @MainActor func unknownMethodNoPermission() throws {
        #expect(try registryPermission("some.unknown.method") == nil)
    }

    // MARK: - Device Permission Mapping

    @Test("terminal.exec is the only gated terminal method; spawn is ungated")
    @MainActor func terminalExecPermission() throws {
        #expect(try registryPermission("terminal.exec") == .terminal)
        // spawn/send/list were removed from the bridge during the uniform-port.create sweep.
        #expect(try registryPermission("terminal.spawn") == nil)
    }

    @Test("terminal.send requires no permission (session already permitted via spawn)")
    @MainActor func terminalSendNoPermission() throws {
        #expect(try registryPermission("terminal.send") == nil)
    }

    @Test("terminal.resize requires no permission (session already permitted via spawn)")
    @MainActor func terminalResizeNoPermission() throws {
        #expect(try registryPermission("terminal.resize") == nil)
    }

    @Test("terminal.kill requires no permission (session already permitted via spawn)")
    @MainActor func terminalKillNoPermission() throws {
        #expect(try registryPermission("terminal.kill") == nil)
    }

    @Test("audio.capture requires .microphone permission")
    @MainActor func audioCapturePermission() throws {
        #expect(try registryPermission("audio.capture") == .microphone)
    }

    @Test("audio.speak requires no permission (output only)")
    @MainActor func audioSpeakNoPermission() throws {
        #expect(try registryPermission("audio.speak") == nil)
    }

    @Test("camera.capture requires .camera permission")
    @MainActor func cameraCapturePermission() throws {
        #expect(try registryPermission("camera.capture") == .camera)
    }

    @Test("camera.stream requires .camera permission")
    @MainActor func cameraStreamPermission() throws {
        #expect(try registryPermission("camera.stream") == .camera)
    }

    @Test("screen.capture requires .screen permission")
    @MainActor func screenCapturePermission() throws {
        #expect(try registryPermission("screen.capture") == .screen)
    }

    @Test("clipboard.read requires .clipboard permission")
    @MainActor func clipboardReadPermission() throws {
        #expect(try registryPermission("clipboard.read") == .clipboard)
    }

    @Test("clipboard.write requires .clipboard permission")
    @MainActor func clipboardWritePermission() throws {
        #expect(try registryPermission("clipboard.write") == .clipboard)
    }

    @Test("fs.pick requires .filesystem permission")
    @MainActor func fsPickPermission() throws {
        #expect(try registryPermission("fs.pick") == .filesystem)
    }

    @Test("fs.read requires .filesystem permission")
    @MainActor func fsReadPermission() throws {
        #expect(try registryPermission("fs.read") == .filesystem)
    }

    @Test("fs.write requires .filesystem permission")
    @MainActor func fsWritePermission() throws {
        #expect(try registryPermission("fs.write") == .filesystem)
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
