import Foundation
import GRDB

// MARK: - Sync Wire Format

struct SyncEnvelope: Codable {
    let type: String
    var channelId: String?
    var senderId: String?
    var messageId: String?
    var payload: SyncPayload?
    var timestamp: Int64?
    var error: String?
    // Presence fields
    var onlineIds: [String]?
    var status: String?
    var companionIds: [String]?

    enum CodingKeys: String, CodingKey {
        case type
        case channelId = "channel_id"
        case senderId = "sender_id"
        case messageId = "message_id"
        case payload
        case timestamp
        case error
        case onlineIds = "online_ids"
        case status
        case companionIds = "companion_ids"
    }
}

struct SyncPayload: Codable {
    let senderName: String
    let senderType: String
    let content: String
    let replyToId: String?
}

// MARK: - Sync Service

@MainActor
public final class SyncService: NSObject, ObservableObject {
    @Published public var isConnected = false
    @Published public var gatewayURL: String?
    /// Online user IDs per channel
    @Published public var onlineUsers: [String: Set<String>] = [:]
    /// Remote typing indicators: channel -> set of sender names currently typing
    @Published public var remoteTypingNames: [String: Set<String>] = [:]

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var userId: String?
    private weak var db: DatabaseService?
    private var joinedChannels: Set<String> = []
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = false

    /// Called when a message arrives from the network (channelId, message)
    public var onMessageReceived: ((String, Message) -> Void)?

    public func configure(gatewayURL: String, userId: String, db: DatabaseService) {
        self.gatewayURL = gatewayURL
        self.userId = userId
        self.db = db
    }

    public func connect() {
        guard let gatewayURL, let url = URL(string: gatewayURL + "/ws") else {
            print("[sync] no gateway URL configured")
            return
        }
        guard let userId else {
            print("[sync] no user ID")
            return
        }

        disconnect(reconnect: false)
        shouldReconnect = true

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.urlSession = session

        let task = session.webSocketTask(with: url)
        self.webSocket = task
        task.resume()

        // Send identify
        let identify = SyncEnvelope(type: "identify", senderId: userId)
        send(identify)

        // Start receive loop
        receiveLoop()

        print("[sync] connecting to \(gatewayURL)")
    }

    public func disconnect(reconnect: Bool = false) {
        if !reconnect {
            shouldReconnect = false
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        onlineUsers = [:]
    }

    // MARK: - Channel Management

    /// Companion IDs per channel, sent to gateway on join for cross-instance presence
    private var channelCompanions: [String: [String]] = [:]

    public func joinChannel(_ channelId: String, companionIds: [String] = []) {
        channelCompanions[channelId] = companionIds
        guard isConnected else {
            joinedChannels.insert(channelId)
            return
        }
        joinedChannels.insert(channelId)
        send(SyncEnvelope(type: "join", channelId: channelId, companionIds: companionIds.isEmpty ? nil : companionIds))
    }

    public func leaveChannel(_ channelId: String) {
        joinedChannels.remove(channelId)
        guard isConnected else { return }
        send(SyncEnvelope(type: "leave", channelId: channelId))
    }

    public func joinAllChannels() {
        for channelId in joinedChannels {
            let companions = channelCompanions[channelId]
            send(SyncEnvelope(type: "join", channelId: channelId, companionIds: companions?.isEmpty == false ? companions : nil))
        }
    }

    // MARK: - Send Message

    public func sendMessage(_ message: Message) {
        let payload = SyncPayload(
            senderName: message.senderName,
            senderType: message.senderType,
            content: message.content,
            replyToId: message.replyToId
        )

        let envelope = SyncEnvelope(
            type: "message",
            channelId: message.channelId,
            senderId: message.senderId,
            messageId: message.id,
            payload: payload,
            timestamp: Int64(message.timestamp.timeIntervalSince1970 * 1000)
        )

        send(envelope)
    }

    /// Broadcast typing indicator to other peers
    public func sendTyping(channelId: String, senderName: String, isTyping: Bool) {
        let envelope = SyncEnvelope(
            type: "typing",
            channelId: channelId,
            payload: SyncPayload(
                senderName: senderName,
                senderType: "agent",
                content: isTyping ? "typing" : "stopped",
                replyToId: nil
            )
        )
        send(envelope)
    }

    // MARK: - Private

    private func send(_ envelope: SyncEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocket?.send(.string(text)) { error in
            if let error {
                NSLog("[sync] send error: \(error)")
            }
        }
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }

                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    // Continue receiving
                    self.receiveLoop()

                case .failure(let error):
                    NSLog("[sync] receive error: \(error)")
                    self.isConnected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: data) else {
            print("[sync] failed to decode message")
            return
        }

        switch envelope.type {
        case "welcome":
            print("[sync] connected as \(envelope.senderId ?? "?")")
            isConnected = true
            onlineUsers = [:] // Reset on reconnect
            joinAllChannels()

        case "message":
            handleIncomingMessage(envelope)

        case "ack":
            handleAck(envelope)

        case "presence":
            handlePresence(envelope)

        case "typing":
            handleTyping(envelope)

        case "error":
            print("[sync] gateway error: \(envelope.error ?? "unknown")")

        default:
            break
        }
    }

    private func handleIncomingMessage(_ envelope: SyncEnvelope) {
        guard let channelId = envelope.channelId,
              let senderId = envelope.senderId,
              let messageId = envelope.messageId,
              let payload = envelope.payload else {
            print("[sync] incomplete message envelope")
            return
        }

        // Don't insert our own messages
        guard senderId != userId else { return }

        let timestamp: Date
        if let ts = envelope.timestamp {
            timestamp = Date(timeIntervalSince1970: Double(ts) / 1000.0)
        } else {
            timestamp = Date()
        }

        let message = Message(
            id: messageId,
            channelId: channelId,
            senderId: senderId,
            senderName: payload.senderName,
            senderType: payload.senderType,
            content: payload.content,
            timestamp: timestamp,
            replyToId: payload.replyToId,
            syncStatus: "synced",
            createdAt: Date()
        )

        do {
            try db?.saveMessage(message)
            print("[sync] received message from \(payload.senderName) in channel \(channelId)")
            onMessageReceived?(channelId, message)
        } catch {
            print("[sync] failed to save incoming message: \(error)")
        }
    }

    private func handleAck(_ envelope: SyncEnvelope) {
        guard let messageId = envelope.messageId else { return }
        // Update sync status
        do {
            try db?.updateSyncStatus(messageId: messageId, status: "synced")
        } catch {
            print("[sync] failed to update sync status: \(error)")
        }
    }

    private func handlePresence(_ envelope: SyncEnvelope) {
        guard let channelId = envelope.channelId else { return }

        if let onlineIds = envelope.onlineIds {
            // Full presence list (sent on join)
            onlineUsers[channelId] = Set(onlineIds)
            print("[sync] presence for \(channelId): \(onlineIds.count) online")
        } else if let senderId = envelope.senderId, let status = envelope.status {
            // Single user update
            var members = onlineUsers[channelId] ?? []
            if status == "online" {
                members.insert(senderId)
            } else {
                members.remove(senderId)
            }
            onlineUsers[channelId] = members
            print("[sync] \(senderId) went \(status) in \(channelId)")
        }
    }

    private func handleTyping(_ envelope: SyncEnvelope) {
        guard let channelId = envelope.channelId,
              let senderName = envelope.payload?.senderName,
              let content = envelope.payload?.content else { return }

        if content == "typing" {
            var names = remoteTypingNames[channelId] ?? []
            names.insert(senderName)
            remoteTypingNames[channelId] = names
        } else {
            remoteTypingNames[channelId]?.remove(senderName)
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            guard !Task.isCancelled, shouldReconnect else { return }
            print("[sync] reconnecting...")
            connect()
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension SyncService: URLSessionWebSocketDelegate {
    nonisolated public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            print("[sync] WebSocket opened")
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            print("[sync] WebSocket closed: \(closeCode)")
            self.isConnected = false
            self.scheduleReconnect()
        }
    }
}
