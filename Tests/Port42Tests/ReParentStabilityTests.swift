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
/// `inline ↔ floating` exists today and is asserted for real. `tiled` / `parked` arrive in S3; those
/// tests are stubbed `.disabled` until `promoteToTiled` / `park` land — fill in the body and drop the
/// trait when they do.
@Suite("Re-parent stability (no reload)")
struct ReParentStabilityTests {

    @MainActor
    private func makeManager() throws -> (PortWindowManager, AppState) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return (state.portWindows, state)
    }

    @Test("inline → floating keeps the SAME webview instance (no recreate)")
    @MainActor
    func inlineToFloatingPreservesInstance() throws {
        let (manager, _) = try makeManager()
        manager.registerInlinePort(id: "p1", html: "<title>t</title><div/>", spaceId: "s1",
                                    createdBy: nil, title: nil, anchorMessageId: "m1")
        let before = try #require(manager.webViews["p1"])

        manager.promoteInlineToFloating(id: "p1", in: CGSize(width: 800, height: 600))

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

    // MARK: - S3 stubs (enable when tiled/parked presentations land)

    @Test("floating → tiled keeps the same webview instance",
          .disabled("S3 — `tiled` presentation / promoteToTiled not implemented yet"))
    @MainActor
    func floatingToTiledPreservesInstance() throws {
        // TODO(S3): register a floating port, capture webViews[id], move it to a desktop tile
        // (presentation == "tiled"), then assert webViews[id] === the captured instance.
    }

    @Test("tiled → parked → tiled round-trip keeps the same webview instance",
          .disabled("S3 — `parked` presentation / park+restore not implemented yet"))
    @MainActor
    func parkRoundTripPreservesInstance() throws {
        // TODO(S3): tile a port, capture webViews[id], park it (presentation == "parked"), restore it
        // (presentation == "tiled"), and assert the instance is identical at every step — the
        // counter/terminal-keeps-state demo from §8 S3, at the registry level.
    }
}
