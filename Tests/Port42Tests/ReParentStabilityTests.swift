import Testing
import Foundation
import AppKit
@testable import Port42Lib

/// SHELL — S3 test gate: re-parent with NO reload.
///
/// The load-bearing invariant of the shell (and of `plan-uniform-port-create.md` Step 8): one
/// registry-owned `WKWebView` is *moved* between hosts (inline row ↔ floating panel ↔ desktop tile ↔
/// parked chip) and its DOM/JS state survives. Confirming live needs a real surface; `NSApp` is nil in
/// the test runner, so here we assert the **registry-level proxy**: `webViews[id]` is the *same object
/// instance* before and after a presentation flip. Same instance = not recreated = the webview (and its
/// JS state) was re-parented, not reloaded.
///
/// Classic mode is retired: the transitions are inline → tiled (undock) and tiled ↔ parked.
/// "floating" no longer exists.
@Suite("Re-parent stability (no reload)")
struct ReParentStabilityTests {

    @MainActor
    private func makeManager() throws -> (PortWindowManager, AppState) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return (state.portWindows, state)
    }

    @Test("tiled → parked → tiled round-trip keeps the SAME webview instance")
    @MainActor
    func parkRoundTripPreservesInstance() throws {
        let (manager, state) = try makeManager()
        defer { withExtendedLifetime(state) {} }   // the manager holds AppState weakly
        manager.registerTiledPort(id: "p1", html: "<title>t</title><div/>", spaceId: "s1",
                                  createdBy: nil, title: nil, position: CGPoint(x: 40, y: 40))
        let before = try #require(manager.webViews["p1"])

        manager.park(id: "p1")
        #expect(manager.webViews["p1"] === before)
        #expect(manager.panels.first { $0.id == "p1" }?.presentation == "parked")

        manager.unpark(id: "p1")
        #expect(manager.webViews["p1"] === before)   // the counter/terminal-keeps-state demo, at the registry level
        #expect(manager.panels.first { $0.id == "p1" }?.presentation == "tiled")
    }
}
