import Testing
import Foundation
import WebKit
@testable import Port42Lib

// A clock for ports, paced by where the port is (#259).

@Suite("#259: port timers", .serialized)
@MainActor
struct PortTimersTests {
    final class Fired { var ticks: [String] = [] }

    func timers(onScreen: Set<String> = ["P"], gone: Set<String> = [], fired: Fired) -> PortTimers {
        let t = PortTimers()
        t.fullRate = { onScreen.contains($0) }
        t.deliver = { port, id in
            guard !gone.contains(port) else { return false }
            fired.ticks.append("\(port):\(id)"); return true
        }
        return t
    }

    @Test("on screen a timer ticks at its own rate")
    func fullRate() throws {
        let f = Fired(), t = timers(fired: f)
        let start = Date()
        let id = try t.add(port: "P", seconds: 1, once: false, id: "a", now: start)
        t.tick(now: start.addingTimeInterval(0.5))
        #expect(f.ticks.isEmpty)
        t.tick(now: start.addingTimeInterval(1))
        t.tick(now: start.addingTimeInterval(2))
        #expect(f.ticks == ["P:\(id)", "P:\(id)"])
    }

    @Test("only a paused port slows: another space, off screen or running keeps full rate (Gordon, 2026-10-04)")
    func rule() {
        #expect(PortTimers.fullRate(PortPresentation(state: .tiled, visible: false)), "a port in another space lost time")
        #expect(PortTimers.fullRate(PortPresentation(state: .hidden, visible: false)), "a running port lost time")
        #expect(PortTimers.fullRate(PortPresentation(state: .tiled, visible: true, w: 100, h: 100)))
        #expect(!PortTimers.fullRate(PortPresentation(state: .parked, visible: false)), "a paused port ran at full rate")
    }

    @Test("a copy of a shared port keeps its timers on this computer")
    func copyLocal() {
        #expect(AppState.mirrorLocalMethods.isSuperset(of: ["timer.every", "timer.after", "timer.cancel"]))
    }

    @Test("a slowed (paused) timer ticks about once a minute, and fires at once when shown again")
    func slowedAndCatchUp() throws {
        var onScreen: Set<String> = []
        let f = Fired()
        let t = PortTimers()
        t.fullRate = { onScreen.contains($0) }
        t.deliver = { port, id in f.ticks.append("\(port):\(id)"); return true }
        let start = Date()
        _ = try t.add(port: "P", seconds: 1, once: false, id: "a", now: start)
        for s in 1...30 { t.tick(now: start.addingTimeInterval(Double(s))) }
        #expect(f.ticks.isEmpty, "a hidden port's timer ticked every second: \(f.ticks.count)")
        onScreen = ["P"]
        t.tick(now: start.addingTimeInterval(31))
        #expect(f.ticks.count == 1, "the port came back into view and its timer did not catch up")
        onScreen = []
        t.tick(now: start.addingTimeInterval(91))
        #expect(f.ticks.count == 2, "a hidden timer did not tick once a minute")
    }

    @Test("after fires once; cancel stops a timer; a gone port's timers are dropped")
    func onceCancelGone() throws {
        let f = Fired(), t = timers(onScreen: ["P", "Q"], gone: ["Q"], fired: f)
        let start = Date()
        _ = try t.add(port: "P", seconds: 1, once: true, id: "once", now: start)
        _ = try t.add(port: "P", seconds: 1, once: false, id: "every", now: start)
        _ = try t.add(port: "Q", seconds: 1, once: false, id: "q", now: start)
        t.tick(now: start.addingTimeInterval(1))
        t.cancel("every", port: "P")
        t.tick(now: start.addingTimeInterval(2))
        #expect(f.ticks == ["P:once", "P:every"] || f.ticks == ["P:every", "P:once"], "\(f.ticks)")
        #expect(t.entries.isEmpty, "a timer outlived its once, its cancel or its port: \(t.entries.keys)")
    }

    @Test("two ports may use the same id; one port cannot cancel another's; a port has at most twenty")
    func scoped() throws {
        let f = Fired(), t = timers(onScreen: ["P", "Q"], fired: f)
        let start = Date()
        _ = try t.add(port: "P", seconds: 1, once: false, id: "x", now: start)
        _ = try t.add(port: "Q", seconds: 1, once: false, id: "x", now: start)
        t.cancel("x", port: "Q")
        t.tick(now: start.addingTimeInterval(1))
        #expect(f.ticks == ["P:x"], "\(f.ticks)")
        for i in 1..<PortTimers.maxPerPort { _ = try t.add(port: "P", seconds: 1, once: false, id: "n\(i)", now: start) }
        #expect(throws: BridgeError.self) { _ = try t.add(port: "P", seconds: 1, once: false, now: start) }
    }

    @Test("timer.every is a port page's: a companion or the person is refused, a page gets its timer")
    func bridge() async throws {
        let w = try makeParityWorld()
        let made = w.state.createPort(type: "web", title: "clock", html: "<title>clock</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        let id = try #require(made["id"] as? String)
        let panel = try #require(w.state.portWindows.panels.first { $0.id == id || $0.udid == id })
        let page = panel.bridge.portPrincipal
        let out = try await w.state.runBridgeMethod("timer.every", principal: page, args: BridgeArgs(["seconds": 1, "id": "tick"]))
        #expect((out.toJSONObject() as? [String: Any])?["id"] as? String == "tick")
        #expect(w.state.portTimers.entries.values.contains { $0.id == "tick" })
        await #expect(throws: BridgeError.self) {
            _ = try await w.state.runBridgeMethod("timer.every", principal: w.principal, args: BridgeArgs(["seconds": 1]))
        }
        _ = try await w.state.runBridgeMethod("timer.cancel", principal: page, args: BridgeArgs(["id": "tick"]))
        #expect(!w.state.portTimers.entries.values.contains { $0.id == "tick" })
    }

    // MARK: - In a real page

    func js(_ wv: WKWebView, _ src: String) async -> Any? {
        try? await wv.callAsyncJavaScript(src, arguments: [:], in: nil, contentWorld: .page)
    }

    func until(_ wv: WKWebView, _ src: String, equals want: Int) async throws {
        for _ in 0..<200 where await js(wv, src) as? Int != want { try await Task.sleep(nanoseconds: 25_000_000) }
    }

    @Test("a real page's timer.every calls its function each tick, after calls once, and a reloaded page cancels a timer it no longer has")
    func inAPage() async throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let html = """
            <title>clock</title><script>
            window.count = 0; window.once = 0;
            port42.timer.every(1, () => { window.count++ }).then(id => { window.everyId = id });
            port42.timer.after(1, () => { window.once++ }).then(id => { window.afterId = id });
            </script>
            """
        state.portWindows.registerTiledPort(id: "clock", html: html, spaceId: "s", createdBy: nil, title: "clock",
                                            position: CGPoint(x: 40, y: 40))
        let wv = try #require(state.portWindows.webViews["clock"])
        for _ in 0..<200 where state.portTimers.entries.count < 2 { try await Task.sleep(nanoseconds: 25_000_000) }
        #expect(state.portTimers.entries.count == 2, "the page's every and after did not reach Port42")

        let start = Date()
        state.portTimers.tick(now: start.addingTimeInterval(2))
        try await until(wv, "return window.count", equals: 1)
        try await until(wv, "return window.once", equals: 1)
        state.portTimers.tick(now: start.addingTimeInterval(4))
        try await until(wv, "return window.count", equals: 2)
        let count = await js(wv, "return window.count") as? Int, once = await js(wv, "return window.once") as? Int
        #expect(count == 2, "every did not call the page's function each tick")
        #expect(once == 1, "after fired more than once")
        #expect(state.portTimers.entries.count == 1, "after was kept after it fired")

        // The page reloads: its script sets new timers, and the old one is now a timer it does not know. The next
        // tick reaches the page, which cancels it, and only the reloaded page's timers stay.
        let oldId = try #require(await js(wv, "return window.everyId") as? String)
        state.portWindows.reloadPort("clock")
        for _ in 0..<200 where state.portTimers.entries.count < 3 { try await Task.sleep(nanoseconds: 25_000_000) }
        #expect(state.portTimers.entries.count == 3, "the reloaded page did not set its own timers")
        state.portTimers.tick(now: start.addingTimeInterval(8))
        for _ in 0..<200 where state.portTimers.entries.values.contains(where: { $0.id == oldId }) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(!state.portTimers.entries.values.contains { $0.id == oldId },
                "a reloaded page kept getting ticks for a timer it no longer had")
        #expect(state.portTimers.entries.values.contains { $0.id != oldId && !$0.once }, "the reloaded page's own timer went too")
    }
}
