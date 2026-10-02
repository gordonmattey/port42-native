import Testing
import Foundation
import WebKit
@testable import Port42Lib

// A hidden port exists to do background work, so WebKit's clamp on unseen pages (one timer tick a
// second, measured in Phase 3.0) is lifted for it; a parked or resting port keeps the clamp. A test's
// web view sits in no window, so WebKit already treats it as unseen: exactly the case to measure.
@Suite("Hidden ports run their timers at full rate")
struct HiddenTimerTests {

    @MainActor
    func js(_ wv: WKWebView, _ src: String) async -> Any? {
        try? await wv.callAsyncJavaScript(src, arguments: [:], in: nil, contentWorld: .page)
    }

    /// Ticks of a 50 ms interval over `seconds`.
    @MainActor
    func ticks(_ wv: WKWebView, over seconds: Double) async throws -> Int {
        let a = (await js(wv, "return window.n") as? Int) ?? 0
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return ((await js(wv, "return window.n") as? Int) ?? 0) - a
    }

    @Test("an unseen port is clamped; hidden, it runs at its own rate; shown, the clamp is back",
          .enabled(if: ProcessInfo.processInfo.environment["PORT42_TIMING_TESTS"] == "1",
                   "a timing test: it measures wall-clock ticks, so it runs in the timing pass (scripts/test-gate.sh), not the full suite"))
    @MainActor
    func hiddenUnclamped() async throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let pw = state.portWindows
        defer { withExtendedLifetime(state) {} }
        pw.registerTiledPort(id: "p", html: "<title>p</title><script>window.n=0; setInterval(()=>window.n++, 50)</script>",
                             spaceId: "s", createdBy: nil, title: "p", position: CGPoint(x: 40, y: 40))
        let wv = try #require(pw.webViews["p"])
        for _ in 0..<100 where await js(wv, "return window.n ?? null") as? Int == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)          // let WebKit apply its clamp
        let clamped = try await ticks(wv, over: 2)
        pw.minimize("p")
        let hidden = try await ticks(wv, over: 2)
        #expect(hidden >= 15, "a hidden port's 50 ms timer ticked \(hidden) times in 2 s (clamped: \(clamped))")
        #expect(clamped <= 6, "an unseen tiled port was not clamped (\(clamped) ticks); the test measures nothing")
        _ = pw.restore("p")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let shown = try await ticks(wv, over: 2)
        #expect(shown <= 6, "showing the port did not restore the clamp (\(shown) ticks)")
    }
}
