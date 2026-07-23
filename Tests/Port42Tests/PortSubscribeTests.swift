import Testing
import Foundation
@testable import Port42Lib

// Phase L1: port.subscribe end to end (docs/plan-port42-protocol-local-bus.md). Subscribing registers
// on the port's topic, a publish is yielded to the caller, and cancelling the stream unsubscribes.
@MainActor
final class NotifyCollector {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}

@Suite("port.subscribe (L1)")
@MainActor
struct PortSubscribeTests {

    @Test("subscribe yields published notifies, and cancel unsubscribes")
    func subscribeYieldsAndCleansUp() async throws {
        let w = try makeParityWorld()
        let collected = NotifyCollector()

        let task = Task { @MainActor in
            _ = try? await w.state.runBridgeStream(
                "port.subscribe",
                principal: w.principal,
                args: BridgeArgs(["id": "PSUB"]),
                yield: { collected.add($0) })
        }

        // Let the subscription register.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(w.state.notifyBus.hasSubscribers("port:PSUB"))

        // A publish on the port's topic reaches the subscriber as a { topic, kind, payload } envelope.
        w.state.notifyBus.publish(topic: "port:PSUB", kind: "terminal.output", payload: "line one")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(collected.items.contains(where: { $0.contains("terminal.output") && $0.contains("line one") }))

        // Cancelling the stream unsubscribes (the poll loop exits and the defer runs).
        task.cancel()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!w.state.notifyBus.hasSubscribers("port:PSUB"))
    }
}
