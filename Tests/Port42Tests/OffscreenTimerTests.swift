import Testing
import Foundation
import WebKit
@testable import Port42Lib

// #244: a port that was not on screen stopped running its timers altogether, not slowed as the manual
// says. WebKit let the page's content process be suspended between timer fires, so a page left alone
// froze until something called into it; the board's 4 s poll and the Launch desk's schedules stopped
// whenever nobody was looking. A test's web view is in no window, which WebKit treats as unseen: the
// case to measure.
//
// Calling into the page wakes it, so the test never does: the page reports each tick itself, through
// its console, which travels out of the page and wakes nothing. And it waits for ticks rather than
// counting them over a fixed time: an unseen page runs at low priority, so on a busy machine (the full
// suite, dozens of suites at once) a 2 s timer fell to 1 to 3 ticks in 30 s without being frozen
// (measured: 7 of 9 alone with ten busy loops beside it, 1 to 3 with 30 or more suites, none frozen).
// A frozen page never gets there however long it waits; a slow one does.
//
// It runs in its own pass, not inside the full suite (#244, reopened). A test process is not a
// foreground app, so macOS puts an unseen page's web process in its lowest CPU band (priority 4,
// sampled with ps), and with hundreds of tests running the page sat runnable for 80 s and more
// without CPU: alive, not suspended (WebKit said so), no tick. That is the machine's scheduling, not the
// freeze this guards; neither WebKit's throttle state nor setpriority lifts it from outside. So the
// suite skips it unless PORT42_TIMING_TESTS=1, and the timing pass runs it alone:
//     PORT42_TIMING_TESTS=1 swift test --filter "OffscreenTimerTests|HiddenTimerTests"
@Suite("Ports off screen keep their timers running (#244)")
struct OffscreenTimerTests {

    @MainActor
    func js(_ wv: WKWebView, _ src: String) async -> Any? {
        try? await wv.callAsyncJavaScript(src, arguments: [:], in: nil, contentWorld: .page)
    }

    @Test("a tiled port left alone off screen keeps ticking, slowed but not frozen",
          .enabled(if: ProcessInfo.processInfo.environment["PORT42_TIMING_TESTS"] == "1",
                   "a timing test: run it alone with PORT42_TIMING_TESTS=1 (see the note above)"))
    @MainActor
    func tiledKeepsTicking() async throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let pw = state.portWindows
        defer { withExtendedLifetime(state) {} }
        pw.registerTiledPort(id: "poll", html: "<title>poll</title><script>let n = 0; setInterval(() => console.log('tick ' + (++n)), 2000)</script>",
                             spaceId: "elsewhere", createdBy: nil, title: "poll", position: CGPoint(x: 40, y: 40))
        let panel = try #require(pw.panels.first { $0.id == "poll" })
        let key = PortConsole.key(udid: panel.udid, id: panel.id, messageId: panel.messageId)
        func ticks() -> Int { PortConsole.shared.recent(portId: key, tail: 100).filter { $0.text.hasPrefix("tick ") }.count }
        // Six ticks of a 2 s timer: 12 s at full rate, longer slowed or on a busy machine, never if frozen.
        let deadline = Date().addingTimeInterval(120)
        while ticks() < 6, Date() < deadline { try await Task.sleep(nanoseconds: 500_000_000) }
        #expect(ticks() >= 6, "a 2 s timer reported \(ticks()) ticks in 2 minutes off screen; it should slow, not stop")
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
