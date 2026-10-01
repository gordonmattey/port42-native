import Testing
import Foundation
import WebKit
@testable import Port42Lib

// #244: a port that was not on screen stopped running its timers altogether, not slowed as the manual
// says. WebKit let the page's content process be suspended between timer fires, so a page left alone
// froze until something called into it; the board's 4 s poll and the Launch desk's schedules stopped
// whenever nobody was looking. A test's web view is in no window, which WebKit treats as unseen: the
// case to measure. Reading the page wakes it, so the page is left alone for the whole wait and read once.
@Suite("Ports off screen keep their timers running (#244)")
struct OffscreenTimerTests {

    @MainActor
    func js(_ wv: WKWebView, _ src: String) async -> Any? {
        try? await wv.callAsyncJavaScript(src, arguments: [:], in: nil, contentWorld: .page)
    }

    @Test("a tiled port left alone off screen keeps ticking, slowed but not frozen")
    @MainActor
    func tiledKeepsTicking() async throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let pw = state.portWindows
        defer { withExtendedLifetime(state) {} }
        pw.registerTiledPort(id: "poll", html: "<title>poll</title><script>window.n=0; setInterval(()=>window.n++, 2000)</script>",
                             spaceId: "elsewhere", createdBy: nil, title: "poll", position: CGPoint(x: 40, y: 40))
        let wv = try #require(pw.webViews["poll"])
        for _ in 0..<100 where await js(wv, "return window.n ?? null") as? Int == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let before = (await js(wv, "return window.n") as? Int) ?? 0
        try await Task.sleep(nanoseconds: 30_000_000_000)             // nothing calls into the page meanwhile
        let ticks = ((await js(wv, "return window.n") as? Int) ?? 0) - before
        #expect(ticks >= 9, "a 2 s timer ticked \(ticks) times in 30 s off screen; it should slow, not stop")
    }

    @Test("every off-screen switch this WebKit has is set: no suspension, no App Nap, no growing clamp")
    @MainActor
    func switchesSet() throws {
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let slowed = PortWebViewFactory.setOffscreenTimers(.slowed, on: wv)
        #expect(slowed.contains("_setPageVisibilityBasedProcessSuppressionEnabled:"))
        #expect(slowed.contains("_setHiddenPageDOMTimerThrottlingAutoIncreases:"))
        let prefs = wv.configuration.preferences
        #expect(prefs.value(forKey: "_pageVisibilityBasedProcessSuppressionEnabled") as? Bool == false)
        #expect(prefs.value(forKey: "_hiddenPageDOMTimerThrottlingEnabled") as? Bool == true, "a slowed port is still clamped")
        PortWebViewFactory.setOffscreenTimers(.running, on: wv)
        #expect(prefs.value(forKey: "_hiddenPageDOMTimerThrottlingEnabled") as? Bool == false, "a running port is not clamped")
    }
}
