import Testing
import Foundation
import AppKit
@testable import Port42Lib

/// Tests for the port panel lifecycle (classic mode retired: there are NO OS windows —
/// switchToSpace manages record existence only, and every port renders as a shell unit).
@Suite("Port Window Lifecycle")
struct PortWindowLifecycleTests {

    @MainActor
    private func makeManager() throws -> (PortWindowManager, AppState) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return (state.portWindows, state)
    }

    /// Inject a chat port record directly into panels (simulates restoreFromDB
    /// loading a saved chat port — no window, just a record).
    @MainActor
    private func injectChatPortRecord(
        into manager: PortWindowManager,
        appState: AppState,
        spaceId: String = "space-1"
    ) -> String {
        let portId = UUID().uuidString
        let bridge = PortBridge(appState: appState, spaceId: spaceId, messageId: nil, createdBy: nil)
        var port = PortPanel(
            id: portId, udid: portId, html: "",
            bridge: bridge, spaceId: spaceId,
            createdBy: nil, messageId: nil,
            userTitle: "chat", size: CGSize(width: 480, height: 680)
        )
        port.isChatPort = true
        port.portType = "chat"
        manager.panels.append(port)
        return portId
    }

    // MARK: - switchToSpace: record creation

    @Test("switchToSpace adds chat port record when none exists")
    @MainActor
    func switchToSpaceAddsChatPortRecord() throws {
        let (manager, _) = try makeManager()
        manager.switchToSpace("space-1", spaceName: "general")
        #expect(manager.panels.contains(where: { $0.isChatPort && $0.spaceId == "space-1" }))
    }

    @Test("switchToSpace does not duplicate chat port on repeated calls")
    @MainActor
    func switchToSpaceNoDuplicateChatPort() throws {
        let (manager, _) = try makeManager()
        manager.switchToSpace("space-1", spaceName: "general")
        manager.switchToSpace("space-2", spaceName: "other")
        manager.switchToSpace("space-1", spaceName: "general")

        let chatPorts = manager.panels.filter { $0.isChatPort && $0.spaceId == "space-1" }
        #expect(chatPorts.count == 1)
    }

    // MARK: - minimize / restore (shell semantics: off the desktop, still running)

    @Test("minimize backgrounds a panel; restore brings it back")
    @MainActor
    func minimizeRestoreRoundTrip() throws {
        let (manager, appState) = try makeManager()
        let portId = injectChatPortRecord(into: manager, appState: appState)

        manager.minimize(portId)
        #expect(manager.panels.first { $0.id == portId }?.isBackground == true)

        #expect(manager.restore(portId))
        #expect(manager.panels.first { $0.id == portId }?.isBackground == false)
        #expect(!manager.restore(portId))                    // not backgrounded → false
    }

    @Test("v39: legacy floating rows migrate to tiled (classic mode retired)")
    @MainActor
    func floatingRowsMigrateToTiled() throws {
        // The migration ran at DB init; anything persisted as "floating" is impossible now,
        // and a fresh panel's default presentation is tiled.
        let (manager, appState) = try makeManager()
        let portId = injectChatPortRecord(into: manager, appState: appState)
        #expect(manager.panels.first { $0.id == portId }?.presentation == "tiled")
    }

    // MARK: - SHELL S2.2: tiled ports (the shell desktop)

    @Test("createPort(presentation: tiled) registers a tiled panel on the given space")
    @MainActor
    func createTiledPortRegistersTiledPanel() throws {
        let (manager, state) = try makeManager()
        let result = state.createPort(type: "web", title: "Clock", html: "<title>Clock</title><div/>",
                                      command: nil, cwd: nil, systemPrompt: nil,
                                      spaceId: "space-1", createdBy: nil, createdByName: nil,
                                      presentation: "tiled", position: CGPoint(x: 120, y: 80))
        let id = try #require(result["id"] as? String)
        #expect(result["error"] == nil)
        let panel = try #require(manager.panels.first(where: { $0.id == id }))
        #expect(panel.presentation == "tiled")
        #expect(panel.spaceId == "space-1")
        #expect(panel.position == CGPoint(x: 120, y: 80))
        #expect(manager.webViews[id] != nil)   // registry-owned webview, not a chat message
    }

    @Test("tiled panels are scoped per space — the desktop renders only the current space's tiles")
    @MainActor
    func tiledPanelsScopedPerSpace() throws {
        let (manager, state) = try makeManager()
        _ = state.createPort(type: "web", title: "A", html: "<div>a</div>", command: nil, cwd: nil,
                             systemPrompt: nil, spaceId: "space-1", createdBy: nil, createdByName: nil,
                             presentation: "tiled", position: CGPoint(x: 10, y: 10))
        _ = state.createPort(type: "web", title: "B", html: "<div>b</div>", command: nil, cwd: nil,
                             systemPrompt: nil, spaceId: "space-2", createdBy: nil, createdByName: nil,
                             presentation: "tiled", position: CGPoint(x: 20, y: 20))
        let s1 = manager.panels.filter { $0.spaceId == "space-1" && $0.presentation == "tiled" }
        let s2 = manager.panels.filter { $0.spaceId == "space-2" && $0.presentation == "tiled" }
        #expect(s1.count == 1)
        #expect(s2.count == 1)
        #expect(s1.first?.title == "A")
    }
}
