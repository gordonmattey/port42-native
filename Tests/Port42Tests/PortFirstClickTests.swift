import Testing
import AppKit
import WebKit
@testable import Port42Lib

/// A click on a port in a Port42 window that is not in front reaches the page, rather than only
/// bringing the window forward. Found clicking one shared port in two instances side by side: every
/// switch between the windows lost a click.
@Suite("Port first click")
@MainActor
struct PortFirstClickTests {

    @Test("a port's web view takes the click that brings its window forward")
    func firstClickReachesPage() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        _ = state.portWindows.registerTiledPort(id: "p", html: "<button>go</button>", spaceId: nil, createdBy: nil,
                                                title: "p", position: nil)
        let wv = try #require(state.portWindows.panels.first { $0.id == "p" }?.bridge.webView)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        #expect(wv.acceptsFirstMouse(for: down), "the first click on an inactive window's port never reaches the page")
    }
}
