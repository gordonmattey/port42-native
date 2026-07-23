import Foundation

// MARK: - NotifyBus
//
// The in-memory 1:N Notify bus of the local port bus (docs/plan-port42-protocol-local-bus.md, Phase L1).
// A port's stream-out is published to a topic (`port:<id>`); render, an agent-observer, and persist all
// subscribe to the same topic and each receive every event. One publish, many subscribers — the
// unified-subscription facet, minimally. Envelope: { topic, kind, payload }, encoded once as JSON and
// delivered to each subscriber (which renders it for its surface).

@MainActor
public final class NotifyBus {
    // topic -> subscriberId -> deliver(envelopeJSON)
    private var subscribers: [String: [Int: @MainActor (String) -> Void]] = [:]
    private var nextId = 0

    public init() {}

    /// Register a subscriber for a topic; returns its id (pass to `unsubscribe`).
    public func subscribe(topic: String, deliver: @escaping @MainActor (String) -> Void) -> Int {
        nextId += 1
        let id = nextId
        subscribers[topic, default: [:]][id] = deliver
        return id
    }

    public func unsubscribe(id: Int, topic: String) {
        subscribers[topic]?.removeValue(forKey: id)
        if subscribers[topic]?.isEmpty == true { subscribers.removeValue(forKey: topic) }
    }

    /// True if a topic has at least one subscriber, so a producer can skip work when nobody listens.
    public func hasSubscribers(_ topic: String) -> Bool {
        !(subscribers[topic]?.isEmpty ?? true)
    }

    /// Publish a Notify to every subscriber of the topic. No subscribers → a cheap no-op (the common
    /// case, so a producer can call this unconditionally).
    public func publish(topic: String, kind: String, payload: Any) {
        guard let subs = subscribers[topic], !subs.isEmpty else { return }
        let env: [String: Any] = ["topic": topic, "kind": kind, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: env, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        for deliver in subs.values { deliver(json) }
    }
}
