import Testing
import Foundation
@testable import Port42Lib

// The rules that turn a port's events into a companion's turns (nautilus Phase 3.3): one turn at a
// time, a burst as one turn, each watch's floor, and a ceiling that pauses a runaway watch.
@Suite("Wake queue")
struct WakeQueueTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func e(_ w: String = "c|p", _ kind: String = "port.tick", at s: Double) -> WakeQueue.Event {
        .init(watchId: w, kind: kind, payload: "{}", at: t0.addingTimeInterval(s))
    }
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func delivered(_ a: [WakeQueue.Action]) -> [WakeQueue.Event]? {
        for x in a { if case .deliver(let es) = x { return es } }
        return nil
    }

    @Test("one event after a quiet spell waits the gather, then wakes once")
    func gatherThenWake() {
        var q = WakeQueue()
        #expect(q.receive(e(at: 0)) == [.wakeAt(at(1))])
        #expect(q.tick(now: at(0.5)).isEmpty, "woke before the gather ended")
        #expect(delivered(q.tick(now: at(1)))?.count == 1)
        #expect(q.isBusy)
    }

    @Test("a burst that arrives together is one turn")
    func burstIsOne() {
        var q = WakeQueue()
        _ = q.receive(e(at: 0)); _ = q.receive(e(at: 0.2)); _ = q.receive(e(at: 0.4))
        #expect(delivered(q.tick(now: at(1)))?.count == 3)
    }

    @Test("five events during a turn arrive as one message when it ends, not five")
    func heldDuringTurn() {
        var q = WakeQueue()
        _ = q.receive(e(at: 0)); _ = q.tick(now: at(1))              // turn 1 running
        _ = q.receive(e(at: 2))                                      // schedules only the timeout wake
        for i in 1..<5 { #expect(q.receive(e(at: 2 + Double(i))).isEmpty, "a held event scheduled another wake") }
        #expect(q.tick(now: at(10)).isEmpty, "delivered while a turn was running")
        #expect(delivered(q.turnEnded(now: at(20)))?.count == 5)
    }

    @Test("a turn started elsewhere (a mention) holds events too")
    func mentionTurnHolds() {
        var q = WakeQueue()
        q.turnStarted(now: at(0))
        _ = q.receive(e(at: 1))
        #expect(delivered(q.turnEnded(now: at(5)))?.count == 1)
    }

    @Test("a watch's floor holds its next wake until the floor has passed")
    func floorHolds() {
        var q = WakeQueue()
        q.floors["c|p"] = 30
        _ = q.receive(e(at: 0)); _ = q.tick(now: at(1)); _ = q.turnEnded(now: at(2))
        _ = q.receive(e(at: 5))
        let held = q.tick(now: at(6))
        #expect(delivered(held) == nil)
        #expect(held.contains(.wakeAt(at(31))))
        #expect(delivered(q.tick(now: at(31)))?.count == 1)
    }

    @Test("past the ceiling a watch pauses, drops its events, and a resume starts a fresh hour")
    func ceilingPauses() {
        var q = WakeQueue()
        q.ceilingPerHour = 3
        var t = 0.0
        for _ in 0..<3 {
            _ = q.receive(e(at: t)); _ = q.tick(now: at(t + 1)); _ = q.turnEnded(now: at(t + 2)); t += 10
        }
        _ = q.receive(e(at: t))
        let a = q.tick(now: at(t + 1))
        #expect(a.contains(.paused(watchId: "c|p")))
        #expect(delivered(a) == nil)
        #expect(q.receive(e(at: t + 5)).isEmpty, "a paused watch still queued events")
        q.resume("c|p")
        _ = q.receive(e(at: t + 6))
        #expect(delivered(q.tick(now: at(t + 7)))?.count == 1)
    }

    @Test("an hour later the ceiling has room again")
    func ceilingIsPerHour() {
        var q = WakeQueue()
        q.ceilingPerHour = 1
        _ = q.receive(e(at: 0)); _ = q.tick(now: at(1)); _ = q.turnEnded(now: at(2))
        _ = q.receive(e(at: 3700))
        #expect(delivered(q.tick(now: at(3701)))?.count == 1)
    }

    @Test("one watch at its ceiling does not stop another watch's events")
    func ceilingIsPerWatch() {
        var q = WakeQueue()
        q.ceilingPerHour = 1
        _ = q.receive(e("c|a", at: 0)); _ = q.tick(now: at(1)); _ = q.turnEnded(now: at(2))
        _ = q.receive(e("c|a", at: 3)); _ = q.receive(e("c|b", at: 3))
        let a = q.tick(now: at(4))
        #expect(a.contains(.paused(watchId: "c|a")))
        #expect(delivered(a)?.map(\.watchId) == ["c|b"])
    }

    @Test("a turn that never ends: what it held goes when the turn times out")
    func stuckTurnTimesOut() {
        var q = WakeQueue()
        q.turnTimeout = 60
        _ = q.receive(e(at: 0)); _ = q.tick(now: at(1))               // turn starts at 1
        #expect(q.receive(e(at: 2)) == [.wakeAt(at(61))], "nothing will wake the queue if the turn never ends")
        #expect(delivered(q.tick(now: at(30))) == nil)
        #expect(delivered(q.tick(now: at(61)))?.count == 1, "held events stranded behind a dead turn")
    }

    @Test("a turn that ends normally delivers at once, not at the timeout")
    func normalEndBeatsTimeout() {
        var q = WakeQueue()
        _ = q.receive(e(at: 0)); _ = q.tick(now: at(1))
        _ = q.receive(e(at: 2))
        #expect(delivered(q.turnEnded(now: at(10)))?.count == 1)
    }

    @Test("kinds: 'port' is the port's own events; never the keystroke and frame streams")
    func kinds() throws {
        #expect(WatchKinds.matches(kind: "port.tick", watched: ["port"]))
        #expect(!WatchKinds.matches(kind: "console", watched: ["port"]))
        #expect(WatchKinds.matches(kind: "console", watched: ["console"]))
        #expect(WatchKinds.matches(kind: "port.alert", watched: ["port.alert"]))
        #expect(!WatchKinds.matches(kind: "port.tick", watched: ["port.alert"]))
        #expect(!WatchKinds.matches(kind: "terminal.output", watched: ["terminal.output", "port"]))
        #expect(throws: BridgeError.self) { _ = try WatchKinds.validate(["terminal.output"]) }
        #expect(try WatchKinds.validate([]) == ["port"])
    }
}
