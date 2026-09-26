import Testing
import Foundation
import WebKit
@testable import Port42Lib

// A web view configuration with no process pool makes its own, and that setup ran on the main thread
// waiting on a system service; with agents making ports under load the app hung there (Dev4,
// 2026-09-26). Every port shares one pool.
@Suite("Ports share one WebKit process pool")
@MainActor
struct SharedProcessPoolTests {
    @Test("two ports' web views are on the same process pool")
    func shared() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        defer { withExtendedLifetime(state) {} }
        let pw = state.portWindows
        for id in ["a", "b"] {
            pw.registerTiledPort(id: id, html: "<title>\(id)</title>", spaceId: "s", createdBy: nil,
                                 title: id, position: CGPoint(x: 40, y: 40))
        }
        let a = try #require(pw.webViews["a"]), b = try #require(pw.webViews["b"])
        #expect(a.configuration.processPool === b.configuration.processPool)
        #expect(a.configuration.processPool === PortWebViewFactory.sharedProcessPool)
    }
}
