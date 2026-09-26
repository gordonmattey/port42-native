import Testing
import Foundation
import WebKit
@testable import Port42Lib

// Not every write to a port reloads it (GM, 2026-09-26). A reload loses the page's live state, so
// identical HTML does nothing, a change confined to <style> is applied in place, and any other
// change is offered to the page first, reloading only when the page does not take it.
@Suite("Port writes reload only when they must")
struct PortLiveUpdateTests {

    let page = "<title>t</title><style>body{color:red}</style><div id=a>hi</div><script>window.n=1</script>"

    @Test("identical HTML is unchanged")
    func identical() {
        #expect(PortLiveUpdate.plan(old: page, new: page) == .unchanged)
    }

    @Test("a change inside <style> only is a styles update carrying the new CSS")
    func stylesOnly() {
        let new = page.replacingOccurrences(of: "color:red", with: "color:blue")
        #expect(PortLiveUpdate.plan(old: page, new: new) == .styles(["body{color:blue}"]))
    }

    @Test("markup, script, attribute or style-count changes are offered to the page")
    func everythingElseOffered() {
        for new in [page.replacingOccurrences(of: ">hi<", with: ">bye<"),
                    page.replacingOccurrences(of: "window.n=1", with: "window.n=2"),
                    page.replacingOccurrences(of: "<style>", with: "<style media=print>"),
                    page + "<style>p{}</style>"] {
            #expect(PortLiveUpdate.plan(old: page, new: new) == .offer, "\(new)")
        }
    }

    // MARK: - Live, in a real web view

    @MainActor
    func world() throws -> (AppState, PortWindowManager) {
        let state = AppState(db: try DatabaseService(inMemory: true))
        return (state, state.portWindows)
    }

    @MainActor
    func js(_ wv: WKWebView, _ src: String) async -> Any? {
        try? await wv.callAsyncJavaScript(src, arguments: [:], in: nil, contentWorld: .page)
    }

    /// Registers a port and waits until its script has run and marked the page.
    @MainActor
    func load(_ pw: PortWindowManager, _ html: String) async throws -> WKWebView {
        pw.registerTiledPort(id: "p", html: html, spaceId: "s", createdBy: nil, title: "t",
                             position: CGPoint(x: 40, y: 40))
        let wv = try #require(pw.webViews["p"])
        for _ in 0..<100 where await js(wv, "return window.n ?? null") as? Int == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = await js(wv, "window.mark = 'kept'; return true")
        return wv
    }

    @Test("a CSS change is applied in place: the style changes and the page keeps its state")
    @MainActor
    func stylesInPlace() async throws {
        let (state, pw) = try world()
        defer { withExtendedLifetime(state) {} }
        let wv = try await load(pw, page)
        let udid = try #require(pw.panels.first { $0.id == "p" }?.udid)

        let out = await pw.updatePort(idOrTitle: udid, html: page.replacingOccurrences(of: "color:red", with: "color:blue"))
        #expect(out == .styles)
        #expect(await js(wv, "return window.mark") as? String == "kept", "the page was reloaded")
        #expect(await js(wv, "return getComputedStyle(document.getElementById('a')).color") as? String
                == "rgb(0, 0, 255)", "the new CSS is not live")
    }

    @Test("a script change reloads a page that does not take the update")
    @MainActor
    func scriptReloads() async throws {
        let (state, pw) = try world()
        defer { withExtendedLifetime(state) {} }
        let wv = try await load(pw, page)
        let udid = try #require(pw.panels.first { $0.id == "p" }?.udid)

        let out = await pw.updatePort(idOrTitle: udid, html: page.replacingOccurrences(of: "window.n=1", with: "window.n=2"))
        #expect(out == .reloaded)
        #expect(await js(wv, "return window.mark ?? null") as? String == nil, "a reload clears the page")
        #expect(await js(wv, "return window.n") as? Int == 2)
    }

    @Test("a page that takes port42:update keeps its state and gets the new HTML")
    @MainActor
    func pageTakesIt() async throws {
        let (state, pw) = try world()
        defer { withExtendedLifetime(state) {} }
        let taker = page.replacingOccurrences(of: "window.n=1", with:
            "window.n=1; window.addEventListener('port42:update', e => { window.got = e.detail.html; e.preventDefault() })")
        let wv = try await load(pw, taker)
        let udid = try #require(pw.panels.first { $0.id == "p" }?.udid)

        let new = taker.replacingOccurrences(of: ">hi<", with: ">bye<")
        let out = await pw.updatePort(idOrTitle: udid, html: new)
        #expect(out == .handledByPage)
        #expect(await js(wv, "return window.mark") as? String == "kept", "the page was reloaded")
        #expect(await js(wv, "return window.got") as? String == new)
        #expect(pw.panels.first { $0.id == "p" }?.html == new, "the stored HTML is the new HTML")
    }

    @Test("identical HTML touches nothing, not even the version history")
    @MainActor
    func identicalTouchesNothing() async throws {
        let (state, pw) = try world()
        defer { withExtendedLifetime(state) {} }
        let wv = try await load(pw, page)
        let udid = try #require(pw.panels.first { $0.id == "p" }?.udid)
        let before = (try? state.db.fetchPortVersions(portUdid: udid).count) ?? 0

        #expect(await pw.updatePort(idOrTitle: udid, html: page) == .unchanged)
        #expect(await js(wv, "return window.mark") as? String == "kept")
        #expect(((try? state.db.fetchPortVersions(portUdid: udid).count) ?? 0) == before)
    }
}
