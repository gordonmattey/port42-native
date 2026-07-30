import Foundation

// MARK: - PortNotify — WHAT A PORT EVENT IS (the output seam's payload)
//
// `PortEventKind` gave an event's NAME one definition. This gives its BODY one, and the two together
// are what the slice-02 Part 0 OUTPUT row asks for.
//
// **The payload used to be `Any`.** Six `notifyBus.publish` sites and eleven `pushEvent` callers each
// handed in whatever dictionary, string or number they liked; `JSONSerialization` flattened it, and
// the local subscriber coped because it is in the same process and already knew what to expect. That
// is sound exactly as long as both ends are the same program.
//
// **`Any` cannot cross a wire.** At the wire half a subscriber on instance B decodes bytes with no
// access to what A was thinking, so a gossipsub topic needs one payload definition or every
// subscriber needs bespoke per-emitter parsing — which is the thing "one publish, many subscribers"
// exists not to be.
//
// **The type is `BridgeValue`, not a new one**, and that is the whole point. It is already the single
// result shape every bridge method returns, it already round-trips JSON both ways, it already crosses
// the gateway, and its `.data(base64:mime:)` case already carries binary — which matters here because
// `screen.frame` and `camera.frame` push frames. A purpose-built Notify payload type would have had
// to solve all of that a second time and could then disagree with the request side. Requests were
// typed, responses were typed, events were not; now one value type covers everything that moves.
//
// **The envelope carries the port's TOKEN, and that is not decoration.** A Notify used to say what
// changed but not what state it left the port in, so a remote subscriber that wanted to write next
// had to call `getHtml` first — every write must carry the token it was composed against (R5). That
// is a second round trip, against an acceptance row that says a delta must reach B *within one*.
//
// It also answers O-4's remaining half for free. That open question is Notify ordering for DISPLAY;
// the token is already `<epoch>:<seq>`, monotonic per port, so it IS the ordering key and no separate
// sequence field is needed.
//
// **The bus resolves the token, not the caller** (see `tokenForTopic`). A publish site that had to
// remember to attach one would be a to-do list, and the register's own rule is that a guarantee
// depending on every emitter doing the right thing is not a guarantee. Resolving it inside `publish`
// means a site added tomorrow carries a token by construction.

/// One event on a port's Notify topic. The single definition of what leaves a port.
public struct PortNotify: Equatable {
    /// `port:<PortRef.key>` today; peer-qualifiable at the wire half without changing this shape.
    public let topic: String
    /// A system kind (`PortEventKind.wire`) or a port's own, already namespaced under `port.`.
    public let kind: String
    /// The body. `BridgeValue` rather than `Any`, so both ends of a wire agree on what arrives.
    public let payload: BridgeValue
    /// The port's activity token at the instant this was emitted: what state the event left it in.
    /// Optional only because a topic that is not a port's has no token.
    public let token: String?

    public init(topic: String, kind: String, payload: BridgeValue, token: String?) {
        self.topic = topic
        self.kind = kind
        self.payload = payload
        self.token = token
    }

    /// The wire form. One encoder, so a local subscriber and a remote one receive identical bytes.
    /// `token` is omitted rather than sent as null when there is none, matching the rest of the API.
    public func toJSONObject() -> [String: Any] {
        var out: [String: Any] = ["topic": topic, "kind": kind, "payload": payload.toJSONObject()]
        if let token { out[PortActivity.tokenKey] = token }
        return out
    }

    public func jsonString() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: toJSONObject(),
                                                     options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// The port key a topic names, or nil if the topic is not a port's (`chat`, `ports`).
    /// One parser, so the token lookup and any future wire routing cannot disagree about it.
    public static let portTopicPrefix = "port:"

    public static func portKey(fromTopic topic: String) -> String? {
        guard topic.hasPrefix(portTopicPrefix) else { return nil }
        let key = String(topic.dropFirst(portTopicPrefix.count))
        return key.isEmpty ? nil : key
    }

    public static func topic(forPortKey key: String) -> String { "\(portTopicPrefix)\(key)" }

    // MARK: - Published from the struct, never restated in prose
    //
    // **THIS EXISTS BECAUSE THE DOCS WENT STALE THE DAY `token` WAS ADDED.** Both `llms.txt` and
    // `ports-context.txt` described the envelope as `{ topic, kind, payload }` and neither noticed a
    // new field, because both were prose a human had typed. The `llms.txt` freshness gate did not
    // help: it asserts the artifact matches what the REGISTRY generates, which is a consistency
    // check, and the registry's own description string was the thing that was wrong. Generated from
    // wrong is still wrong, byte-for-byte consistently.
    //
    // Same answer the error codes already got (`BridgeErrorCode.docsMarker`): render the fact from
    // the structure so restating it is not possible. Add a field below and both documents gain it
    // with no regeneration step to forget.

    public static let docsMarker = "{{NOTIFY_ENVELOPE}}"

    /// The envelope, described from the type. One line per field, in wire order.
    public static func publishedShape(indent: String = "  ") -> String {
        let fields: [(String, String)] = [
            ("topic", "`port:<id>` — which port emitted this"),
            ("kind", "the event name: a system kind, or a port's own under `port.`"),
            ("payload", "the body. Any JSON value; binary arrives as base64"),
            (PortActivity.tokenKey,
             "the port's state token AT THAT MOMENT — write straight back with it, no re-read"),
        ]
        let width = fields.map(\.0.count).max() ?? 0
        return fields.map { name, note in
            indent + name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + note
        }.joined(separator: "\n")
    }

    public static func publish(into text: String, indent: String = "  ") -> String {
        text.replacingOccurrences(of: docsMarker, with: publishedShape(indent: indent))
    }
}

// MARK: - NotifyBus
//
// The in-memory 1:N Notify bus of the local port bus (docs/plan-port42-protocol-local-bus.md, Phase L1).
// A port's stream-out is published to a topic (`port:<id>`); render, an agent-observer, and persist all
// subscribe to the same topic and each receive every event. One publish, many subscribers — the
// unified-subscription facet, minimally. The envelope is `PortNotify`, encoded once and delivered to
// each subscriber (which renders it for its surface).

@MainActor
public final class NotifyBus {
    // topic -> subscriberId -> deliver(envelopeJSON)
    private var subscribers: [String: [Int: @MainActor (String) -> Void]] = [:]
    private var nextId = 0

    /// Resolves a topic to the emitting port's current activity token. Injected by `AppState` at
    /// wiring time rather than read here, so the bus stays free of app state and remains testable
    /// with no `AppState` at all.
    ///
    /// **Injected rather than passed per call on purpose.** A `token:` parameter on `publish` would
    /// be one more thing every emitter has to remember, and an emitter that forgot would produce an
    /// envelope that looks complete and is not.
    public var tokenForTopic: ((String) -> String?)?

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
    ///
    /// Takes `BridgeValue`, never `Any`: an emitter that cannot express its payload as one is an
    /// emitter whose output could not have crossed a wire, and that is a compile error rather than a
    /// surprise at slice-02.
    public func publish(topic: String, kind: String, payload: BridgeValue) {
        guard let subs = subscribers[topic], !subs.isEmpty else { return }
        let notify = PortNotify(topic: topic, kind: kind, payload: payload,
                                token: tokenForTopic?(topic))
        guard let json = notify.jsonString() else { return }
        for deliver in subs.values { deliver(json) }
    }
}
