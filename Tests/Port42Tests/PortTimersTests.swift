import Testing
import Foundation
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

    @Test("out of sight it slows to once a minute, and fires at once when shown again")
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
}
