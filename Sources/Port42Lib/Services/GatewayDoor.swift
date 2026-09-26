import Foundation

// MARK: - GatewayDoor
//
// THE CALL DOOR, ON ITS OWN CONNECTION (nautilus Phase 0 step 2, docs/plan-nautilus-phase0.md).
//
// Every external call (the CLI, a companion's curl, a browser guest) reaches the app one way: the
// gateway forwards it over a WebSocket to whichever peer identified as host. That peer used to be
// `SyncService`, which is also the messaging hub's client, so the door and the hub were one
// connection and the hub could not be removed without closing the door. This is the door alone:
// connect to the LOCAL gateway, identify as host with the per-spawn host credential, answer `call`
// envelopes, send `response` and `stream` frames back, reconnect. It knows nothing about spaces,
// channels, messages, typing or presence.
//
// Always the local gateway, never a saved remote `gatewayURL`: being host means being the thing the
// local `/call` door forwards to, which is only ever this machine's own gateway.

/// Codable wrapper for arbitrary JSON values so RPC call args can carry full JSON objects.
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Undecodable JSON value")) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// The door's wire format: the envelope fields the call path uses and nothing else. The gateway's
/// envelope has more (channel, presence, nonce), and a decoder ignores what it does not name.
struct DoorEnvelope: Codable {
    let type: String
    var senderId: String?
    var senderName: String?
    var isHost: Bool?
    var hostCredential: String?
    var credential: String?
    var streamable: Bool?
    var method: String?
    var args: [String: JSONValue]?
    var callId: String?
    var targetId: String?
    var payload: DoorPayload?
    var error: String?
    var code: String?

    var argsAsAny: [String: Any] { args?.mapValues(\.anyValue) ?? [:] }

    // Explicit, so every field is listed. An explicit CodingKeys that forgets a property decodes it
    // as nil forever without a word; that is how `streamable` was once lost on the sync envelope.
    enum CodingKeys: String, CodingKey {
        case type
        case senderId = "sender_id"
        case senderName = "sender_name"
        case isHost = "is_host"
        case hostCredential = "host_credential"
        case credential
        case streamable
        case method
        case args
        case callId = "call_id"
        case targetId = "target_id"
        case payload
        case error
        case code
    }
}

/// A response or stream frame's body. The HTTP door hands `payload` to the caller as-is, so these
/// three keys ARE the published `/call` response shape (`{"content": …, "senderName": "host", …}`).
struct DoorPayload: Codable {
    let senderName: String
    let senderType: String
    let content: String
}

@MainActor
public final class GatewayDoor: NSObject, ObservableObject {
    @Published public private(set) var isConnected = false

    /// The app's answer to a call: `(senderId, callId, method, input, credential, emit)`.
    ///
    /// `senderId` addresses and never authorizes; the CREDENTIAL decides who is calling, and the app
    /// both mints and verifies it. `emit` is how a streaming method sends a frame before it
    /// finishes; nil when the caller's door cannot carry mid-call frames (HTTP), so the method can
    /// refuse rather than emit into nothing.
    public var onCallReceived: (@MainActor (String, String, String, [String: Any], String?,
                                            (@MainActor (Any) -> Void)?) async -> Any)?

    /// The host credential sent at identify. Nil: the running gateway's (tests set their own).
    var hostCredentialOverride: String?

    private var url: URL?
    private var senderId: String?
    private var senderName: String?
    private var shouldReconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?

    /// Tests replace the socket with this: every frame the door would send lands here instead.
    var sendOverride: ((String) -> Void)?

    public func configure(gatewayURL: String, senderId: String, senderName: String?) {
        self.url = URL(string: gatewayURL + "/ws")
        self.senderId = senderId
        self.senderName = senderName
    }

    public func connect() {
        guard let url, let senderId else {
            p42log("[door] not configured")
            return
        }
        disconnect()
        shouldReconnect = true
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        let task = session.webSocketTask(with: URLRequest(url: url))
        // The gateway takes frames up to its own limit; URLSession's default is half that, and a
        // bigger call closed the door with "Message too long" (GatewayStallTests).
        task.maximumMessageSize = Self.maxFrameBytes
        webSocket = task
        task.resume()
        // The local gateway needs no challenge, so identify at once rather than waiting for `no_auth`.
        send(DoorEnvelope(type: "identify", senderId: senderId, senderName: senderName, isHost: true,
                          hostCredential: hostCredentialOverride ?? GatewayProcess.shared.hostCredential))
        receiveLoop()
        p42log("[door] connecting to \(url.absoluteString)")
    }

    public func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
    }

    // MARK: Wire

    func send(_ envelope: DoorEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope),
              let text = String(data: data, encoding: .utf8) else { return }
        if let sendOverride { sendOverride(text); return }
        webSocket?.send(.string(text)) { error in
            if let error { p42log("[door] send error: \(error)") }
        }
    }

    private func receiveLoop() {
        guard let ws = webSocket else { return }
        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self, ws === self.webSocket else { return }
                switch result {
                case .success(.string(let text)):
                    self.receive(text)
                    self.receiveLoop()
                case .success(.data(let data)):
                    if let text = String(data: data, encoding: .utf8) { self.receive(text) }
                    self.receiveLoop()
                case .success:
                    self.receiveLoop()
                case .failure(let error):
                    p42log("[door] receive error: \(error)")
                    self.connectionLost()
                }
            }
        }
    }

    /// One inbound frame. Internal so tests can drive the door without a gateway.
    func receive(_ text: String) {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(DoorEnvelope.self, from: data) else {
            p42log("[door] undecodable frame")
            return
        }
        switch envelope.type {
        case "welcome":
            isConnected = true
            p42log("[door] open as host \(envelope.senderId ?? "?")")
        case "call":
            handleCall(envelope)
        case "error":
            p42log("[door] gateway error: \(envelope.error ?? "?") \(envelope.code ?? "")")
        default:
            break   // `no_auth`, `challenge`: the local door identifies at connect and needs neither
        }
    }

    private func handleCall(_ envelope: DoorEnvelope) {
        guard let callId = envelope.callId, let method = envelope.method,
              let senderId = envelope.senderId else { return }
        Task { @MainActor in
            // A streaming method emits through here, as `stream` frames on the same call_id, but only
            // when the gateway said the caller's door can carry them.
            var emit: (@MainActor (Any) -> Void)?
            if envelope.streamable == true {
                emit = { [weak self] event in
                    self?.send(Self.frame("stream", callId: callId, to: senderId, content: Self.jsonContent(from: event)))
                }
            }
            let result: Any
            if let handler = onCallReceived {
                result = await handler(senderId, callId, method, envelope.argsAsAny, envelope.credential, emit)
            } else {
                result = ["error": "method not implemented", "code": BridgeErrorCode.unsupported.wire]
            }
            send(Self.response(callId: callId, to: senderId, content: Self.jsonContent(from: result)))
        }
    }

    /// The gateway's per-frame read limit (`maxMessageSize` in gateway.go). A frame over it closes
    /// the host's connection there, and its caller waits until it times out.
    static let maxFrameBytes = 2 * 1024 * 1024

    /// A call's response, or a `too_large` error in its place when it would not fit in one frame.
    static func response(callId: String, to target: String, content: String) -> DoorEnvelope {
        let frame = frame("response", callId: callId, to: target, content: content)
        let size = (try? JSONEncoder().encode(frame).count) ?? 0
        guard size > maxFrameBytes else { return frame }
        let refusal = ["error": "the result is \(size) bytes, over the \(maxFrameBytes)-byte limit of one frame. "
                           + "Ask for less: a tail, a limit, a selector, or one part at a time.",
                       "code": BridgeErrorCode.tooLarge.wire]
        return Self.frame("response", callId: callId, to: target, content: jsonContent(from: refusal))
    }

    static func frame(_ type: String, callId: String, to target: String, content: String) -> DoorEnvelope {
        var e = DoorEnvelope(type: type)
        e.callId = callId
        e.targetId = target
        e.payload = DoorPayload(senderName: "host", senderType: "host", content: content)
        return e
    }

    /// One encoder for a call's result and each of its stream frames, so a subscriber parses both
    /// the same way. `.fragmentsAllowed`: a method can return a bare number or bool, and without it
    /// JSONSerialization raises an ObjC exception that `try?` cannot catch, which wedges the main
    /// queue for good.
    static func jsonContent(from value: Any) -> String {
        if let str = value as? String { return str }
        if let data = SafeJSON.data(value),
           let json = String(data: data, encoding: .utf8) { return json }
        return "{\"error\":\"unserializable result\"}"
    }

    // MARK: Reconnect

    private func connectionLost() {
        isConnected = false
        guard shouldReconnect, reconnectTask == nil else { return }
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            reconnectTask = nil
            guard !Task.isCancelled, shouldReconnect else { return }
            p42log("[door] reconnecting")
            connect()
        }
    }
}

extension GatewayDoor: URLSessionWebSocketDelegate {
    nonisolated public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                       didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            guard webSocketTask === self.webSocket else { return }
            p42log("[door] closed: \(closeCode)")
            self.connectionLost()
        }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            guard (task as? URLSessionWebSocketTask) === self.webSocket else { return }
            p42log("[door] connection failed: \(error.localizedDescription)")
            self.connectionLost()
        }
    }
}
