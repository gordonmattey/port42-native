import Testing
import Foundation
import WebKit
@testable import Port42Lib

/// A page knows its own port id (`port42.self.id`), so a page that acts on itself survives a fork or a
/// move, which give it a new id (Gordon, 2026-09-27: a fork's +1 was driving the original).
@Suite("A page knows its own port")
@MainActor
struct PortSelfTests {

    @Test("every page of a port is handed its own id before its script runs")
    func pageGetsItsId() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        _ = state.portWindows.registerTiledPort(id: "p-1", html: "<p>x</p>", spaceId: nil, createdBy: nil,
                                                title: "p", position: nil)
        let bridge = try #require(state.portWindows.panels.first { $0.id == "p-1" }?.bridge)
        let config = WKWebViewConfiguration()
        bridge.attach(to: config)
        let scripts = config.userContentController.userScripts.map(\.source)
        let own = try #require(scripts.firstIndex { $0.contains("__port42Self") }, "the page was not told its id")
        #expect(scripts[own].contains("\"p-1\""))
        let ns = try #require(scripts.firstIndex { $0.contains("window.port42 =") })
        #expect(own < ns, "the id arrives after the namespace that reads it")
        #expect(PortBridge.bridgeJS.contains("self: window.__port42Self"), "port42.self is not wired")
        #expect(PortBridge.selfScript(#"a"b"#)?.contains(#"\""#) == true, "an id is not escaped into the script")
    }

    @Test("port.info on a copy of someone else's port answers from the copy, like port42.self")
    func infoStaysOnTheCopy() {
        #expect(AppState.mirrorLocalMethods.contains("port.info"))
    }
}
