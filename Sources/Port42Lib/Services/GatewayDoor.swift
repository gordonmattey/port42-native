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

/// What the gateway says about a call from another machine: who, and its proof it said so.
public struct RemoteClaim: Equatable {
    public let peer: String
    public let attestation: String
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
    /// This instance's peer id, in the gateway's `welcome` to the host (nautilus Phase 4, 4.2).
    var selfPeer: String?
    /// A remote caller's authenticated peer id and the gateway's HMAC over it (4.3).
    var remotePeer: String?
    var remoteAttest: String?

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
        case selfPeer = "self_peer"
        case remotePeer = "remote_peer"
        case remoteAttest = "remote_attest"
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

    /// The gateway told us this instance's peer id (derived from the key we handed it).
    public var onSelfPeer: (@MainActor (String) -> Void)?

    /// The app's answer to a call: `(senderId, callId, method, input, credential, emit)`.
    ///
    /// `senderId` addresses and never authorizes; the CREDENTIAL decides who is calling, and the app
    /// both mints and verifies it. `emit` is how a streaming method sends a frame before it
    /// finishes; nil when the caller's door cannot carry mid-call frames (HTTP), so the method can
    /// refuse rather than emit into nothing.
    public var onCallReceived: (@MainActor (String, String, String, [String: Any], String?,
                                            (@MainActor (Any) -> Void)?) async -> Any)?

    /// A call from ANOTHER MACHINE (nautilus Phase 4, 4.3): the gateway's remote door stamped the
    /// peer id its transport authenticated and an HMAC over it. It carries no credential, and it never
    /// reaches `onCallReceived`. With no handler installed it is refused.
    public var onRemoteCallReceived: (@MainActor (RemoteClaim, String, [String: Any],
                                                  (@MainActor (Any) -> Void)?) async -> Any)?

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
        webSocket = task
        task.resume()
        // The local gateway needs no challenge, so identify at once rather than waiting for `no_auth`.
        send(DoorEnvelope(type: "identify", senderId: senderId, senderName: senderName, isHost: true,
                          hostCredential: GatewayProcess.shared.hostCredential))
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
        sendText(text)
    }

    private func sendText(_ text: String) {
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
        if let id = envelope.callId, pendingRemote[id] != nil {
            settleRemote(id, envelope)
            return
        }
        switch envelope.type {
        case "welcome":
            isConnected = true
            p42log("[door] open as host \(envelope.senderId ?? "?")")
            if let peer = envelope.selfPeer, !peer.isEmpty { onSelfPeer?(peer) }
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
            if let peer = envelope.remotePeer, !peer.isEmpty {
                let claim = RemoteClaim(peer: peer, attestation: envelope.remoteAttest ?? "")
                if let handler = onRemoteCallReceived {
                    result = await handler(claim, method, envelope.argsAsAny, emit)
                } else {
                    result = ["error": "this instance takes no remote callers",
                              "code": BridgeErrorCode.notGranted.wire]
                }
            } else if let handler = onCallReceived {
                result = await handler(senderId, callId, method, envelope.argsAsAny, envelope.credential, emit)
            } else {
                result = ["error": "method not implemented", "code": BridgeErrorCode.unsupported.wire]
            }
            send(Self.frame("response", callId: callId, to: senderId, content: Self.jsonContent(from: result)))
        }
    }

    // MARK: - Calling another instance (nautilus Phase 4, 4.6)

    private struct PendingRemote {
        let resume: (Result<Any, Error>) -> Void
        let onStream: (@MainActor (Any) -> Void)?
    }
    private var pendingRemote: [String: PendingRemote] = [:]

    /// Call `method` on another instance, reached through `relays`, as this instance. The gateway
    /// dials it (Noise, this instance's key) and hands back every frame for the call. A streaming
    /// method's events go to `onStream`; the call returns with the final response, or throws the
    /// other instance's refusal. Cancelling the task stops waiting.
    public func remoteCall(to peer: String, relays: [String], method: String, args: [String: Any],
                           onStream: (@MainActor (Any) -> Void)? = nil) async throws -> Any {
        let id = "out-" + UUID().uuidString
        let frame: [String: Any] = ["type": "remote_call", "call_id": id, "method": method, "args": args,
                                    "to_peer": peer, "relays": relays]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else {
            throw BridgeError.badArg("these arguments cannot be sent to another instance")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
                pendingRemote[id] = PendingRemote(resume: { cont.resume(with: $0) }, onStream: onStream)
                sendText(text)
            }
        } onCancel: {
            Task { @MainActor in
                if let p = self.pendingRemote.removeValue(forKey: id) { p.resume(.failure(CancellationError())) }
            }
        }
    }

    private func settleRemote(_ id: String, _ envelope: DoorEnvelope) {
        func content() -> Any? {
            guard let c = envelope.payload?.content else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(c.utf8), options: [.fragmentsAllowed])) ?? c
        }
        switch envelope.type {
        case "stream":
            if let value = content() { pendingRemote[id]?.onStream?(value) }
        case "response":
            guard let p = pendingRemote.removeValue(forKey: id) else { return }
            let value = content() ?? NSNull()
            if let o = value as? [String: Any], let code = o["code"] as? String, let message = o["error"] as? String {
                // Every other field comes back too: a refused write's `current` is what lets the
                // writer retry once, and it is lost if only the code and message are kept.
                var details: [String: String] = [:]
                for (k, v) in o where k != "code" && k != "error" { details[k] = v as? String ?? "\(v)" }
                p.resume(.failure(BridgeError(rawCode: code, message: message, details: details)))
            } else {
                p.resume(.success(value))
            }
        case "error":
            guard let p = pendingRemote.removeValue(forKey: id) else { return }
            p.resume(.failure(BridgeError(rawCode: envelope.code ?? BridgeErrorCode.transportFailed.wire,
                                          message: envelope.error ?? "the other instance could not be reached")))
        default:
            break
        }
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
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
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
