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
/// Phase 2 (port units): the shell has NO floating presentation — its transitions are
/// inline → tiled (undock), tiled ↔ parked. `inline → floating` survives only on the classic
/// path (until classic mode is retired), asserted with an explicit `shellMode: false`.
@Suite("Re-parent stability (no reload)")
struct ReParentStabilityTests {

    @MainActor
    private func makeManager() throws -> (PortWindowManager, AppState) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return (state.portWindows, state)
    }

    @Test("classic undock (inline → floating) keeps the SAME webview instance (no recreate)")
    @MainActor
    func inlineToFloatingPreservesInstance() throws {
        let (manager, _) = try makeManager()
        manager.registerInlinePort(id: "p1", html: "<title>t</title><div/>", spaceId: "s1",
                                    createdBy: nil, title: nil, anchorMessageId: "m1")
        let before = try #require(manager.webViews["p1"])

        manager.undockInline(id: "p1", in: CGSize(width: 800, height: 600), shellMode: false)

        let after = try #require(manager.webViews["p1"])
        #expect(after === before)  // re-parented, not reloaded
        let panel = try #require(manager.panels.first(where: { $0.id == "p1" }))
        #expect(panel.presentation == "floating")
    }

    @Test("re-registering an existing id never swaps the webview instance")
    @MainActor
    func reRegisterPreservesInstance() throws {
        let (manager, _) = try makeManager()
        manager.registerInlinePort(id: "p1", html: "<div>a</div>", spaceId: "s1",
                                    createdBy: nil, title: nil, anchorMessageId: "m1")
        let before = try #require(manager.webViews["p1"])
        manager.registerInlinePort(id: "p1", html: "<div>DIFFERENT</div>", spaceId: "s1",
                                    createdBy: nil, title: nil, anchorMessageId: "m1")
        #expect(manager.webViews["p1"] === before)
    }

    // MARK: - S3/Phase 2 (tiled / parked — the shell's only presentations)

    @Test("shell undock (inline → tiled) keeps the SAME webview instance (no recreate)")
    @MainActor
    func shellUndockPreservesInstance() throws {
        let (manager, _) = try makeManager()
        manager.registerInlinePort(id: "p1", html: "<title>t</title><div/>", spaceId: "s1",
                                    createdBy: nil, title: nil, anchorMessageId: "m1")
        let before = try #require(manager.webViews["p1"])

        manager.undockInline(id: "p1", in: CGSize(width: 800, height: 600), shellMode: true)
        #expect(manager.webViews["p1"] === before)   // the tile adopts the same live view
        #expect(manager.panels.first { $0.id == "p1" }?.presentation == "tiled")
    }

    @Test("tiled → parked → tiled round-trip keeps the SAME webview instance")
    @MainActor
    func parkRoundTripPreservesInstance() throws {
        let (manager, _) = try makeManager()
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
