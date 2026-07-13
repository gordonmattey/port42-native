import Testing
import Foundation
import AppKit
@testable import Port42Lib

/// Step 8.2: registry-owned inline ports. A web port is ONE registered entity whether shown
/// inline or floating; pop-out flips `presentation` and re-parents the same WKWebView.
///
/// These tests cover the registry bookkeeping (registration idempotency, presentation flip,
/// no-persist invariant). The actual WKWebView re-parent / no-reload behavior needs a live
/// surface and is verified in-app (NSApp is nil in the test runner, so createWindow is a no-op —
/// but the panel-state transitions below still run).
@Suite("Registered Inline Port")
struct RegisteredInlinePortTests {

    @MainActor
    private func makeManager() throws -> (PortWindowManager, AppState) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return (state.portWindows, state)
    }

    @Test("registerInlinePort creates one inline panel + webview")
    @MainActor
    func registersOne() throws {
        let (manager, _) = try makeManager()
        let bridge = manager.registerInlinePort(id: "p1", html: "<title>Hi</title><div/>",
                                                 spaceId: "s1", createdBy: "echo",
                                                 title: "Hi", anchorMessageId: "m1")
        #expect(bridge != nil)
        let panel = try #require(manager.panels.first(where: { $0.id == "p1" }))
        #expect(panel.presentation == "inline")
        #expect(panel.anchorMessageId == "m1")
        #expect(panel.portType == "web")
        #expect(manager.webViews["p1"] != nil)
    }

    @Test("registerInlinePort is idempotent by id — no second webview")
    @MainActor
    func idempotent() throws {
        let (manager, _) = try makeManager()
        let b1 = manager.registerInlinePort(id: "p1", html: "<div>a</div>", spaceId: "s1",
                                            createdBy: nil, title: nil, anchorMessageId: "m1")
        let firstWebView = manager.webViews["p1"]
        let b2 = manager.registerInlinePort(id: "p1", html: "<div>DIFFERENT</div>", spaceId: "s1",
                                            createdBy: nil, title: nil, anchorMessageId: "m1")
        // Same bridge, same webview instance — the existing port is reused untouched.
        #expect(b1 === b2)
        #expect(manager.webViews["p1"] === firstWebView)
        #expect(manager.panels.filter { $0.id == "p1" }.count == 1)
    }

    @Test("inline ports are never persisted")
    @MainActor
    func notPersisted() throws {
        let (manager, state) = try makeManager()
        manager.registerInlinePort(id: "p1", html: "<div/>", spaceId: "s1",
                                    createdBy: nil, title: nil, anchorMessageId: "m1")
        let saved = try state.db.fetchPortPanels()
        #expect(!saved.contains(where: { $0.id == "p1" }))
    }

    @Test("classic undock flips presentation to floating")
    @MainActor
    func promotes() throws {
        let (manager, _) = try makeManager()
        manager.registerInlinePort(id: "p1", html: "<div/>", spaceId: "s1",
                                    createdBy: nil, title: nil, anchorMessageId: "m1")
        manager.undockInline(id: "p1", in: CGSize(width: 800, height: 600), shellMode: false)
        let panel = try #require(manager.panels.first(where: { $0.id == "p1" }))
        #expect(panel.presentation == "floating")
        // The same webview survives — promotion re-parents, never recreates.
        #expect(manager.webViews["p1"] != nil)
    }

    @Test("promotion persists the now-floating port")
    @MainActor
    func promotionPersists() throws {
        let (manager, state) = try makeManager()
        manager.registerInlinePort(id: "p1", html: "<div/>", spaceId: "s1",
                                    createdBy: nil, title: nil, anchorMessageId: "m1")
        manager.undockInline(id: "p1", in: CGSize(width: 800, height: 600), shellMode: false)
        let saved = try state.db.fetchPortPanels()
        #expect(saved.contains(where: { $0.id == "p1" }))
    }

    @Test("promotion gives a real floating size (was tiny inline)")
    @MainActor
    func promotionResizes() throws {
        let (manager, _) = try makeManager()
        manager.registerInlinePort(id: "p1", html: "<div/>", spaceId: "s1",
                                    createdBy: nil, title: nil, anchorMessageId: "m1")
        let inlineSize = try #require(manager.panels.first(where: { $0.id == "p1" })).size
        #expect(inlineSize.width < 200)  // registered tiny
        manager.undockInline(id: "p1", in: CGSize(width: 800, height: 600), shellMode: false)
        let floatingSize = try #require(manager.panels.first(where: { $0.id == "p1" })).size
        #expect(floatingSize.width >= 200)
        #expect(floatingSize.height >= 150)
    }
}
