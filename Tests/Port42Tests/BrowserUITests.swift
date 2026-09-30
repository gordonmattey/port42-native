import Testing
import Foundation
import WebKit
@testable import Port42Lib

/// Browser use, Phase 1 (docs/plan-browser-use.md): a browser port handles the windows its pages open,
/// so a "Sign in with Google" popup works, and it names Safari so Google's sign-in lets it in.
@Suite("Browser ports: popups, window.close and a Safari user agent")
@MainActor
struct BrowserUITests {

    private func browserPort() throws -> (ParityWorld, String, WKWebView) {
        let w = try makeParityWorld()
        let r = w.state.createPort(type: "browser", title: "b", html: "about:blank", command: nil, cwd: nil,
                                   systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let id = try #require(r["id"] as? String)
        let pw = w.state.portWindows
        let panel = try #require(pw.panels.first { $0.id == id || $0.udid == id })
        let wv = try #require(pw.webViews[panel.id])
        return (w, panel.id, wv)
    }

    @Test("a window asked for with a size is a popup; a plain new-window link is not")
    func popupOrLink() {
        #expect(PortBrowserUI.opensAsPopup(width: 500, height: 600))
        #expect(PortBrowserUI.opensAsPopup(width: nil, height: 600))
        #expect(!PortBrowserUI.opensAsPopup(width: nil, height: nil))
    }

    @Test("a browser port names Safari in its user agent; a web port does not need to")
    func safariUserAgent() throws {
        let (_, _, wv) = try browserPort()
        #expect(wv.configuration.applicationNameForUserAgent?.contains("Safari/") == true,
                "Google's sign-in refuses a browser port that does not name a browser")
        #expect(BrowserUserAgent.suffix(safariVersion: "18.6") == "Version/18.6 Safari/605.1.15")
    }

    @Test("a popup is drawn over its port, and goes when the site closes it or the person does")
    func popupLifecycle() throws {
        let (w, id, wv) = try browserPort()
        let ui = try #require(wv.uiDelegate as? PortBrowserUI, "a browser port has no UI delegate, so popups do nothing")
        let pw = w.state.portWindows

        let first = WKWebView()
        ui.onPopup?(first)
        #expect(pw.browserPopups[id] === first)

        ui.webViewDidClose(first)                            // the site's window.close
        #expect(pw.browserPopups[id] == nil, "a popup the site closed stayed up")

        let second = WKWebView()
        ui.onPopup?(second)
        pw.closeBrowserPopup(port: id)                       // the close button
        #expect(pw.browserPopups[id] == nil)

        let third = WKWebView()
        ui.onPopup?(third)
        pw.close(id)
        #expect(pw.browserPopups[id] == nil, "a closed port left its popup behind")
    }

    @Test("a second popup replaces the first, and the first closing late does not take the second down")
    func secondReplacesFirst() throws {
        let (w, id, wv) = try browserPort()
        let ui = try #require(wv.uiDelegate as? PortBrowserUI)
        let first = WKWebView(), second = WKWebView()
        ui.onPopup?(first)
        ui.onPopup?(second)
        #expect(w.state.portWindows.browserPopups[id] === second)
        ui.webViewDidClose(first)
        #expect(w.state.portWindows.browserPopups[id] === second)
    }
}
