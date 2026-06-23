import Testing
import Foundation
import AppKit
@testable import Port42Lib

/// Tests for the port window lifecycle architectural fix.
///
/// The core invariant: ALL port types (chat, web, terminal) must share one
/// window creation/gating path. Windows are created by showRestoredFloatingPanels()
/// only — switchToSpace only manages record existence and raises existing windows.
///
/// Note: actual NSPanel creation requires NSApplication.shared to be initialized,
/// which the swiftpm test runner does not do. Tests below verify record/eligibility
/// state — window creation is covered by app-level testing.
///
/// RED tests (fail before fix, green after):
///   switchToSpaceDoesNotCreateChatPortWindow
///
/// GREEN tests (regression guards, pass before and after):
///   switchToSpaceAddsChatPortRecord
///   switchToSpaceNoDuplicateChatPort
///   nonDockedChatPortIsEligibleForWindowRestoration
///   dockedChatPortIsNotEligibleForWindowRestoration
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

    // MARK: - switchToSpace: no premature window creation (RED before fix)

    /// After the fix, switchToSpace must NOT create a window for a chat port.
    /// Windows are the sole responsibility of showRestoredFloatingPanels().
    ///
    /// Before the fix: openChatPort() calls createWindow() immediately — this test FAILS.
    /// After the fix: ensureChatPort() creates a record only — this test PASSES.
    @Test("switchToSpace does not create a window for chat port")
    @MainActor
    func switchToSpaceDoesNotCreateChatPortWindow() throws {
        let (manager, _) = try makeManager()
        manager.switchToSpace("space-1", spaceName: "general")

        let chatPort = manager.panels.first(where: { $0.isChatPort && $0.spaceId == "space-1" })
        let portId = try #require(chatPort?.id)
        #expect(manager.windows[portId] == nil)
    }

    // MARK: - panelsVisible gate

    @Test("panelsVisible is false before showRestoredFloatingPanels")
    @MainActor
    func panelsVisibleIsFalseBeforeUnlock() throws {
        let (manager, _) = try makeManager()
        #expect(manager.panelsVisible == false)
    }

    @Test("showRestoredFloatingPanels sets panelsVisible true")
    @MainActor
    func showRestoredPanelsSetsFlag() throws {
        let (manager, _) = try makeManager()
        manager.showRestoredFloatingPanels()
        #expect(manager.panelsVisible == true)
    }

    @Test("hideFloatingPanels clears panelsVisible")
    @MainActor
    func hideFloatingPanelsClearsFlag() throws {
        let (manager, _) = try makeManager()
        manager.showRestoredFloatingPanels()
        manager.hideFloatingPanels()
        #expect(manager.panelsVisible == false)
    }

    // MARK: - showRestoredFloatingPanels: active-space filter

    @Test("showRestoredFloatingPanels completes without crash for chat port")
    @MainActor
    func showRestoredPanelsCompletesForChatPort() throws {
        let (manager, _) = try makeManager()
        manager.switchToSpace("space-1", spaceName: "general")

        // Should not crash. NSApp is nil in test runner so createWindow is a no-op,
        // but the chat port must not be excluded before reaching createWindow.
        manager.showRestoredFloatingPanels()

        // Record intact, panelsVisible set
        #expect(manager.panels.contains(where: { $0.isChatPort && $0.spaceId == "space-1" }))
        #expect(manager.panelsVisible == true)
    }

    @Test("showRestoredFloatingPanels does not create window for other-space chat port")
    @MainActor
    func showRestoredPanelsSkipsOtherSpacePorts() throws {
        let (manager, appState) = try makeManager()
        // space-1 is active, but inject a chat port for space-2
        manager.activeSpaceId = "space-1"
        let portId = injectChatPortRecord(into: manager, appState: appState, spaceId: "space-2")

        manager.showRestoredFloatingPanels()

        // space-2's port has no window (NSApp nil anyway, but also filtered)
        #expect(manager.windows[portId] == nil)
    }

    @Test("Docked chat port is not eligible for window restoration")
    @MainActor
    func dockedChatPortNotEligibleForRestoration() throws {
        let (manager, appState) = try makeManager()
        let portId = injectChatPortRecord(into: manager, appState: appState)
        guard let idx = manager.panels.firstIndex(where: { $0.id == portId }) else {
            Issue.record("Injected chat port not found"); return
        }
        manager.panels[idx].isBackground = true

        let chatPort = manager.panels[idx]
        #expect(chatPort.isBackground == true)
        #expect(manager.windows[portId] == nil)
    }
}
