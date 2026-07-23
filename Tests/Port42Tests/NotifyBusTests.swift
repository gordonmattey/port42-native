import Testing
import Foundation
@testable import Port42Lib

// Phase L1 (docs/plan-port42-protocol-local-bus.md): the NotifyBus is the 1:N fan-out under
// port.subscribe. These cover the core: one publish reaches many subscribers, topics are isolated,
// unsubscribe stops delivery, and publishing to an empty topic is a cheap no-op.
@Suite("NotifyBus")
@MainActor
struct NotifyBusTests {

    @Test("one publish reaches every subscriber of the topic (1:N)")
    func fanOut() {
        let bus = NotifyBus()
        var a: [String] = []
        var b: [String] = []
        _ = bus.subscribe(topic: "port:X") { a.append($0) }
        _ = bus.subscribe(topic: "port:X") { b.append($0) }
        bus.publish(topic: "port:X", kind: "push", payload: ["n": 1])
        #expect(a.count == 1)
        #expect(b.count == 1)
        // The envelope shape: { topic, kind, payload }.
        #expect(a[0].contains("\"topic\":\"port:X\""))
        #expect(a[0].contains("\"kind\":\"push\""))
    }

    @Test("a subscriber only hears its own topic")
    func topicIsolation() {
        let bus = NotifyBus()
        var got: [String] = []
        _ = bus.subscribe(topic: "port:X") { got.append($0) }
        bus.publish(topic: "port:Y", kind: "push", payload: 1)
        #expect(got.isEmpty)
    }

    @Test("unsubscribe stops delivery and clears the topic")
    func unsubscribeStops() {
        let bus = NotifyBus()
        var got: [String] = []
        let id = bus.subscribe(topic: "port:X") { got.append($0) }
        bus.publish(topic: "port:X", kind: "a", payload: 1)
        bus.unsubscribe(id: id, topic: "port:X")
        bus.publish(topic: "port:X", kind: "b", payload: 2)
        #expect(got.count == 1)
        #expect(!bus.hasSubscribers("port:X"))
    }

    @Test("publishing to a topic with no subscribers is a cheap no-op")
    func noSubscribersNoOp() {
        let bus = NotifyBus()
        bus.publish(topic: "port:none", kind: "x", payload: 1)   // must not crash
        #expect(!bus.hasSubscribers("port:none"))
    }
}
