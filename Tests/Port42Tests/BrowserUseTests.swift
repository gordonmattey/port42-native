import Testing
import Foundation
import AppKit
import WebKit
@testable import Port42Lib

/// Browser use, Phase 2 (docs/plan-browser-use.md): a companion looks at a browser port and acts on it
/// with real input, asked once per site, and yields to the person's own hands.
@Suite("Browser use: look, act, the site card and right of way", .serialized)
@MainActor
struct BrowserUseTests {

    static let page = """
    <html><body style="margin:0;font:14px sans-serif">
    <button id=go style="position:absolute;left:40px;top:30px;width:120px;height:36px">Search</button>
    <input id=q placeholder="Find mail" style="position:absolute;left:40px;top:100px;width:220px;height:28px">
    <input id=pw type=password value="hunter2" style="position:absolute;left:40px;top:150px;width:220px;height:28px">
    <a href="#next" style="position:absolute;left:40px;top:200px">Next page</a>
    <script>
      window.log = [];
      go.addEventListener('click', e => log.push('click:' + e.isTrusted));
      q.addEventListener('keydown', e => log.push('key:' + e.key + ':' + e.isTrusted));
      q.addEventListener('input', e => log.push('input:' + e.isTrusted));
    </script></body></html>
    """

    let agent = Principal.peer(id: "browser-agent", displayName: "calm-moth")

    /// A browser port showing the test page from http://localhost, in an offscreen window as a tile is.
    private func world(grant: Bool = true) async throws -> (ParityWorld, String, WKWebView, NSWindow) {
        let w = try makeParityWorld()
        // A new AppState restores saved ports half a second in, which rebuilds a web view made before it.
        for _ in 0..<200 where !w.state.portPanelsRestored { try await Task.sleep(nanoseconds: 20_000_000) }
        let r = w.state.createPort(type: "browser", title: "b", html: "about:blank", command: nil, cwd: nil,
                                   systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let id = try #require(r["id"] as? String)
        let panel = try #require(w.state.portWindows.panels.first { $0.id == id || $0.udid == id })
        let wv = try #require(w.state.portWindows.webViews[panel.id])
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false                 // the test holds it; closing must not free it
        wv.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView?.addSubview(wv)
        window.orderFront(nil)
        wv.loadHTMLString(Self.page, baseURL: URL(string: "http://localhost/"))
        for _ in 0..<200 where wv.isLoading || wv.url?.host != "localhost" { try await Task.sleep(nanoseconds: 20_000_000) }
        if grant { try w.state.db.saveGrants([.browser], grantee: agent.id, object: AppState.siteObject("localhost"), zone: "") }
        return (w, panel.udid, wv, window)
    }

    private func call(_ w: ParityWorld, _ m: String, _ args: [String: Any], as p: Principal? = nil) async throws -> [String: BridgeValue] {
        guard case .object(let o) = try await w.state.runBridgeMethod(m, principal: p ?? agent, args: BridgeArgs(args)) else { return [:] }
        return o
    }

    private func pageLog(_ wv: WKWebView) async throws -> [String] {
        (try await wv.evaluateJavaScript("window.log") as? [String]) ?? []
    }

    private func element(_ look: [String: BridgeValue], labelled label: String) -> Int? {
        guard case .array(let els)? = look["elements"] else { return nil }
        for case .object(let e) in els where e["label"] == .string(label) { if case .int(let n)? = e["n"] { return n } }
        return nil
    }

    @Test("a look numbers what can be acted on, draws them, and never returns a password")
    func look() async throws {
        let (w, udid, wv, window) = try await world()
        defer { window.close() }
        let look = try await call(w, "port.look", ["id": udid])
        #expect(element(look, labelled: "Search") != nil, "the button was not found: \(String(describing: look["elements"]))")
        #expect(element(look, labelled: "Find mail") != nil, "the field was not labelled by its placeholder")
        #expect(element(look, labelled: "Next page") != nil)
        if case .array(let els)? = look["elements"] {
            for case .object(let e) in els where e["type"] == .string("password") {
                #expect(e["value"] == nil, "a password's value was returned")
            }
        }
        guard case .string(let path)? = look["image"] else { Issue.record("no image"); return }
        #expect(NSImage(contentsOfFile: path) != nil, "the look's picture is not an image")
        #expect(look["token"] != nil)
        // The numbering lives in Port42's own script world: the page cannot see it.
        let seen = try await wv.evaluateJavaScript("typeof globalThis.__port42marks") as? String
        #expect(seen == "undefined", "the page can see Port42's marks")
    }

    @Test("a click on an element is a trusted click; typing and a key reach the field as the person's would")
    func act() async throws {
        let (w, udid, wv, window) = try await world()
        defer { window.close() }
        var look = try await call(w, "port.look", ["id": udid])
        let go = try #require(element(look, labelled: "Search"))
        var act = try await call(w, "port.act", ["id": udid, "action": "click", "n": go, "token": look["token"]!.stringValue!])
        let afterClick = try await pageLog(wv)
        #expect(afterClick.contains("click:true"), "the click did not arrive as trusted: \(afterClick)")

        look = try await call(w, "port.look", ["id": udid])
        let q = try #require(element(look, labelled: "Find mail"))
        act = try await call(w, "port.act", ["id": udid, "action": "type", "n": q, "text": "invoices",
                                             "token": look["token"]!.stringValue!])
        let typed = try await wv.evaluateJavaScript("q.value") as? String
        #expect(typed == "invoices")
        let afterType = try await pageLog(wv)
        #expect(afterType.contains("input:true"), "the typing was not trusted input")
        _ = try await call(w, "port.act", ["id": udid, "action": "key", "key": "enter", "token": act["token"]!.stringValue!])
        let afterKey = try await pageLog(wv)
        #expect(afterKey.contains("key:Enter:true"), "Enter did not reach the field: \(afterKey)")
    }

    @Test("a port that is not on the desktop cannot be acted on, and says to show it")
    func hiddenPortRefused() async throws {
        let (w, udid, wv, window) = try await world()
        wv.removeFromSuperview()
        window.close()
        do {
            _ = try await call(w, "port.look", ["id": udid])
            Issue.record("a port with no window was looked at")
        } catch let e as BridgeError {
            #expect(e.code == "no_surface")
        }
    }

    @Test("a companion is asked once per site; a no refuses; the person is never asked")
    func siteCard() async throws {
        let (w, udid, _, window) = try await world(grant: false)
        defer { window.close() }
        let pending = Task { @MainActor in try await self.call(w, "port.look", ["id": udid]) }
        for _ in 0..<400 where w.state.permissions.current == nil { await Task.yield() }
        #expect(w.state.permissions.current?.detail?.contains("localhost") == true, "the card did not name the site")
        w.state.permissions.resolveCurrent(granted: true)
        _ = try await pending.value
        _ = try await call(w, "port.look", ["id": udid])                 // remembered: no second card
        #expect(w.state.permissions.current == nil)

        let other = Principal.peer(id: "another-agent", displayName: "brave-ibis")
        let refused = Task { @MainActor in try await self.call(w, "port.look", ["id": udid], as: other) }
        for _ in 0..<400 where w.state.permissions.current == nil { await Task.yield() }
        w.state.permissions.resolveCurrent(granted: false)
        await #expect(throws: BridgeError.self) { _ = try await refused.value }

        let person = try #require(w.state.humanPrincipal)
        _ = try await call(w, "port.look", ["id": udid], as: person)
        #expect(w.state.permissions.current == nil, "the person was asked about their own browser")
    }

    @Test("Port42's input for a companion is not the person driving; the person's own input makes the next act stale")
    func rightOfWay() async throws {
        let (w, udid, _, window) = try await world()
        defer { window.close() }
        let look = try await call(w, "port.look", ["id": udid])
        let go = try #require(element(look, labelled: "Search"))
        let act = try await call(w, "port.act", ["id": udid, "action": "click", "n": go, "token": look["token"]!.stringValue!])
        let token = try #require(act["token"]?.stringValue)
        w.state.humanInteracted(with: udid)                               // the companion's own click, as the tap reports it
        #expect(w.state.portInput.token(for: udid) == token, "the companion's own click counted as the person")

        w.state.agentInputUntil[udid] = nil                               // later: the person clicks the page
        w.state.humanInteracted(with: udid)
        await #expect(throws: BridgeError.self) {
            _ = try await self.call(w, "port.act", ["id": udid, "action": "click", "n": go, "token": token])
        }
    }

    @Test("keys by name, with modifiers")
    func keys() {
        #expect(BrowserAct.key("Enter")?.code == 36)
        #expect(BrowserAct.key("e")?.chars == "e")
        #expect(BrowserAct.key("nonsense") == nil)
        #expect(BrowserAct.modifiers(["cmd", "shift"]) == [.command, .shift])
        #expect(BrowserAct.viewPoint(cssX: 10, cssY: 20, magnification: 1.5) == CGPoint(x: 15, y: 30))
    }
}

private extension BridgeValue {
    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
}
