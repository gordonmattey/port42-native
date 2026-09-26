import Testing
import Foundation
@testable import Port42Lib

/// A port's console lives in its chrome (GM, 2026-09-25: the ">" the page drew in its own lower-right
/// corner sat on top of the port's UI and read as part of it).
@Suite("Port console in the chrome")
@MainActor
struct PortConsoleChromeTests {

    @Test("the error count the chrome shows moves only on errors, and clears with the port")
    func errorCount() {
        let c = PortConsole()
        c.append(portId: "p", level: "log", text: "hello")
        c.append(portId: "p", level: "warn", text: "careful")
        #expect(c.errorCounts["p"] == nil)
        c.append(portId: "p", level: "error", text: "TypeError: x")
        c.append(portId: "p", level: "error", text: "TypeError: y")
        #expect(c.errorCounts["p"] == 2)
        c.clear(portId: "p")
        #expect(c.errorCounts["p"] == nil)
    }

    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Port42Lib/Views")

    @Test("the scripts injected into a port draw no console of their own")
    func nothingDrawnInThePage() throws {
        #expect(!PortWebViewFactory.consoleJS.contains("createElement"))
        #expect(!PortWebViewFactory.consoleJS.contains("appendChild"))
        #expect(PortWebViewFactory.consoleJS.contains("portConsole.postMessage"), "the console is still forwarded")
        // The inline copy in PortView too, by source: the same drawer lived there.
        let view = try String(contentsOf: Self.sources.appendingPathComponent("PortView.swift"), encoding: .utf8)
        #expect(!view.contains("_toggle"), "PortView still draws the in-page console toggle")
    }
}
