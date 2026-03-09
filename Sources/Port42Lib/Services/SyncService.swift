import Foundation
import GRDB

// MARK: - Sync Wire Format

struct SyncEnvelope: Codable {
    let type: String
    var channelId: String?
    var senderId: String?
    var senderName: String?
    var peerId: String?
    var messageId: String?
    var payload: SyncPayload?
    var timestamp: Int64?
    var error: String?
    var token: String?
    // Presence fields
    var onlineIds: [String]?
    var status: String?
    var companionIds: [String]?
    // Auth fields (F-511)
    var nonce: String?
    var identityToken: String?
    var authType: String?

    enum CodingKeys: String, CodingKey {
        case type
        case channelId = "channel_id"
        case senderId = "sender_id"
        case senderName = "sender_name"
        case peerId = "peer_id"
        case messageId = "message_id"
        case payload
        case timestamp
        case error
        case token
        case onlineIds = "online_ids"
        case status
        case companionIds = "companion_ids"
        case nonce
        case identityToken = "identity_token"
        case authType = "auth_type"
    }
}

public struct SyncPayload: Codable {
    public let senderName: String
    public let senderType: String
    public let content: String
    public let replyToId: String?
    /// When true, `content` is an encrypted blob and senderName is masked.
    public var encrypted: Bool?
    /// Display name of the human who owns this sender (nil for human senders).
    public var senderOwner: String?

    public init(senderName: String, senderType: String, content: String, replyToId: String?, encrypted: Bool? = nil, senderOwner: String? = nil) {
        self.senderName = senderName
        self.senderType = senderType
        self.content = content
        self.replyToId = replyToId
        self.encrypted = encrypted
        self.senderOwner = senderOwner
    }
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
    /// Cached display names from presence events: userId -> displayName
    @Published public var knownNames: [String: String] = [:]

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var userId: String?
    private var userName: String?
    private weak var db: DatabaseService?
    private var joinedChannels: Set<String> = []
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = false
    /// Pending token request continuations: channelId -> continuation
    private var tokenContinuations: [String: CheckedContinuation<String, Error>] = [:]
    /// Apple auth service for remote gateway authentication
    private var appleAuth: AppleAuthService?
    /// Stored Apple user ID for silent re-auth
    private var appleUserID: String?

    /// Called when a message arrives from the network (channelId, message)
    public var onMessageReceived: ((String, Message) -> Void)?
    /// Called when a peer's presence changes (channelId, senderId, senderName, status "online"/"offline")
    public var onPresenceChanged: ((String, String, String?, String) -> Void)?

    public func configure(gatewayURL: String, userId: String, userName: String? = nil, db: DatabaseService, appleAuth: AppleAuthService? = nil, appleUserID: String? = nil) {
        self.gatewayURL = gatewayURL
        self.userId = userId
        self.userName = userName
        self.db = db
        self.appleAuth = appleAuth
        self.appleUserID = appleUserID
    }

    /// Returns true if the gateway URL points to localhost (skip auth).
    nonisolated static func isLocalGateway(_ url: String) -> Bool {
        url.contains("localhost") || url.contains("127.0.0.1")
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

        var request = URLRequest(url: url)
        // Skip ngrok's free-tier browser warning interstitial
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        let task = session.webSocketTask(with: request)
        self.webSocket = task
        task.resume()

        let isLocal = Self.isLocalGateway(gatewayURL)

        if isLocal {
            // Localhost: send identify immediately (no challenge expected)
            let identify = SyncEnvelope(type: "identify", senderId: userId, senderName: userName)
            send(identify)
        }
        // Remote: wait for challenge message in receiveLoop, then send identify

        // Start receive loop
        receiveLoop()

        print("[sync] connecting to \(gatewayURL) (local=\(isLocal))")
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
        knownNames = [:]
    }

    // MARK: - Channel Management

    /// Companion IDs per channel, sent to gateway on join for cross-instance presence
    private var channelCompanions: [String: [String]] = [:]

    /// Tokens received from the gateway for channel joins (persisted across reconnects)
    private var channelTokens: [String: String] = [:]

    public func joinChannel(_ channelId: String, companionIds: [String] = [], token: String? = nil) {
        let alreadyJoined = joinedChannels.contains(channelId)
        channelCompanions[channelId] = companionIds
        if let token { channelTokens[channelId] = token }
        joinedChannels.insert(channelId)
        guard isConnected else { return }
        // Skip sending join if already joined (prevents duplicate presence broadcasts)
        guard !alreadyJoined else { return }
        var envelope = SyncEnvelope(type: "join", channelId: channelId, companionIds: companionIds.isEmpty ? nil : companionIds)
        envelope.token = channelTokens[channelId]
        send(envelope)
    }

    public func leaveChannel(_ channelId: String) {
        joinedChannels.remove(channelId)
        guard isConnected else { return }
        send(SyncEnvelope(type: "leave", channelId: channelId))
    }

    public func joinAllChannels() {
        for channelId in joinedChannels {
            let companions = channelCompanions[channelId]
            var envelope = SyncEnvelope(type: "join", channelId: channelId, companionIds: companions?.isEmpty == false ? companions : nil)
            envelope.token = channelTokens[channelId]
            send(envelope)
        }
    }

    // MARK: - Send Message

    public func sendMessage(_ message: Message) {
        let clearPayload = SyncPayload(
            senderName: message.senderName,
            senderType: message.senderType,
            content: message.content,
            replyToId: message.replyToId,
            senderOwner: message.senderOwner
        )

        let payload: SyncPayload
        if let key = try? db?.getChannelKey(channelId: message.channelId),
           let blob = ChannelCrypto.encrypt(clearPayload, keyBase64: key) {
            // Encrypted: content is the blob, senderName masked
            payload = SyncPayload(
                senderName: "",
                senderType: message.senderType,
                content: blob,
                replyToId: nil,
                encrypted: true
            )
        } else {
            // No key or encryption failed: send plaintext (backward compat)
            payload = clearPayload
        }

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
    public func sendTyping(channelId: String, senderName: String, isTyping: Bool, senderOwner: String? = nil) {
        let envelope = SyncEnvelope(
            type: "typing",
            channelId: channelId,
            payload: SyncPayload(
                senderName: senderName,
                senderType: "agent",
                content: isTyping ? "typing" : "stopped",
                replyToId: nil,
                senderOwner: senderOwner
            )
        )
        print("[sync] sendTyping: \(senderName) isTyping=\(isTyping) channel=\(channelId)")
        send(envelope)
    }

    /// Request a single-use join token for a channel from the gateway.
    public func requestToken(channelId: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            tokenContinuations[channelId] = continuation
            send(SyncEnvelope(type: "create_token", channelId: channelId))
        }
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
        case "challenge":
            handleChallenge(envelope)

        case "no_auth":
            // Gateway has no auth, just send identify
            if let userId {
                send(SyncEnvelope(type: "identify", senderId: userId, senderName: userName))
                print("[sync] sent identify (no auth required)")
            }

        case "welcome":
            print("[sync] connected as \(envelope.senderId ?? "?")")
            isConnected = true
            onlineUsers = [:] // Reset on reconnect
            joinAllChannels()

        case "message":
            handleIncomingMessage(envelope)

        case "ack":
            handleAck(envelope)

        case "delivered":
            handleDelivered(envelope)

        case "read":
            handleReadReceipt(envelope)

        case "presence":
            handlePresence(envelope)

        case "typing":
            handleTyping(envelope)

        case "token":
            handleToken(envelope)

        case "error":
            print("[sync] gateway error: \(envelope.error ?? "unknown")")
            // Check if this error is for a pending token request
            if let channelId = envelope.channelId,
               let continuation = tokenContinuations.removeValue(forKey: channelId) {
                continuation.resume(throwing: NSError(domain: "SyncService", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: envelope.error ?? "unknown error"]))
            }

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

        // Don't insert our own messages (use authenticated peerId from gateway)
        let authenticatedPeer = envelope.peerId ?? senderId
        guard authenticatedPeer != userId else { return }

        // Decrypt if encrypted
        let resolvedPayload: SyncPayload
        if payload.encrypted == true {
            guard let key = try? db?.getChannelKey(channelId: channelId),
                  let decrypted = ChannelCrypto.decrypt(blob: payload.content, keyBase64: key) else {
                NSLog("[sync] failed to decrypt message %@ in channel %@", messageId, channelId)
                return
            }
            resolvedPayload = decrypted
        } else {
            resolvedPayload = payload
        }

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
            senderName: resolvedPayload.senderName,
            senderType: resolvedPayload.senderType,
            content: resolvedPayload.content,
            timestamp: timestamp,
            replyToId: resolvedPayload.replyToId,
            syncStatus: "synced",
            createdAt: Date(),
            senderOwner: resolvedPayload.senderOwner
        )

        do {
            try db?.saveMessage(message)
            print("[sync] received message from \(resolvedPayload.senderName) in channel \(channelId)")
            onMessageReceived?(channelId, message)
        } catch {
            print("[sync] failed to save incoming message: \(error)")
        }
    }

    private func handleAck(_ envelope: SyncEnvelope) {
        guard let messageId = envelope.messageId else { return }
        do {
            try db?.updateSyncStatus(messageId: messageId, status: "synced")
        } catch {
            print("[sync] failed to update sync status: \(error)")
        }
    }

    private func handleDelivered(_ envelope: SyncEnvelope) {
        guard let messageId = envelope.messageId else { return }
        do {
            // Only upgrade from synced to delivered (don't downgrade from read)
            try db?.updateSyncStatusIfBefore(messageId: messageId, newStatus: "delivered", before: ["local", "synced"])
        } catch {
            print("[sync] failed to update delivered status: \(error)")
        }
    }

    private func handleReadReceipt(_ envelope: SyncEnvelope) {
        guard let channelId = envelope.channelId,
              let senderId = envelope.senderId,
              senderId != userId else { return }
        // Mark all our messages in this channel as read
        do {
            try db?.markMessagesAsRead(channelId: channelId, bySenderId: userId ?? "")
        } catch {
            print("[sync] failed to update read status: \(error)")
        }
    }

    /// Send a read receipt for a channel (call when user views messages)
    public func sendReadReceipt(channelId: String) {
        send(SyncEnvelope(type: "read", channelId: channelId, senderId: userId))
    }

    private func handlePresence(_ envelope: SyncEnvelope) {
        guard let channelId = envelope.channelId else { return }

        if let onlineIds = envelope.onlineIds {
            // Full presence list (sent on join)
            onlineUsers[channelId] = Set(onlineIds)
            print("[sync] presence for \(channelId): \(onlineIds.count) online")
        } else if let senderId = envelope.senderId, let status = envelope.status {
            // Skip our own presence events
            guard senderId != userId else { return }
            // Cache display name from presence
            if let name = envelope.senderName, !name.isEmpty {
                knownNames[senderId] = name
            }
            // Single user update
            var members = onlineUsers[channelId] ?? []
            if status == "online" {
                members.insert(senderId)
            } else {
                members.remove(senderId)
            }
            onlineUsers[channelId] = members
            let name = envelope.senderName
            print("[sync] \(name ?? senderId) went \(status) in \(channelId)")
            onPresenceChanged?(channelId, senderId, name, status)
        }
    }

    private func handleTyping(_ envelope: SyncEnvelope) {
        guard let channelId = envelope.channelId,
              let senderName = envelope.payload?.senderName,
              let content = envelope.payload?.content else { return }

        let displayName: String
        if let owner = envelope.payload?.senderOwner {
            displayName = "\(senderName)@\(owner)"
        } else {
            displayName = senderName
        }

        if content == "typing" {
            var names = remoteTypingNames[channelId] ?? []
            names.insert(displayName)
            remoteTypingNames[channelId] = names
            print("[sync] typing: \(displayName) in \(channelId)")
        } else {
            remoteTypingNames[channelId]?.remove(displayName)
        }
    }

    private func handleChallenge(_ envelope: SyncEnvelope) {
        guard let nonce = envelope.nonce else {
            print("[sync] challenge missing nonce")
            return
        }
        guard let userId else { return }

        Task {
            do {
                var token: String?
                if let appleAuth, let appleUserID {
                    // Silent re-auth with stored Apple user ID
                    token = try await appleAuth.silentAuth(appleUserID: appleUserID, nonce: nonce)
                } else if let appleAuth {
                    // First auth (shouldn't normally happen here, setup should have stored it)
                    let result = try await appleAuth.authenticate(nonce: nonce)
                    token = result.identityToken
                    self.appleUserID = result.appleUserID
                }

                if let token {
                    send(SyncEnvelope(
                        type: "identify",
                        senderId: userId,
                        senderName: userName,
                        identityToken: token,
                        authType: "apple"
                    ))
                    print("[sync] sent authenticated identify")
                } else {
                    // No Apple auth available, send identify without token
                    send(SyncEnvelope(type: "identify", senderId: userId, senderName: userName))
                    print("[sync] sent unauthenticated identify (no Apple auth)")
                }
            } catch {
                print("[sync] Apple auth failed: \(error), connecting without auth")
                send(SyncEnvelope(type: "identify", senderId: userId, senderName: userName))
            }
        }
    }

    private func handleToken(_ envelope: SyncEnvelope) {
        guard let channelId = envelope.channelId,
              let token = envelope.token else { return }
        if let continuation = tokenContinuations.removeValue(forKey: channelId) {
            continuation.resume(returning: token)
        }
        print("[sync] received join token for channel \(channelId)")
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
            print("[sync] WebSocket opened to \(self.gatewayURL ?? "unknown")")
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) }
        Task { @MainActor in
            print("[sync] WebSocket closed: \(closeCode) reason: \(reasonStr ?? "none")")
            self.isConnected = false
            self.scheduleReconnect()
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            Task { @MainActor in
                print("[sync] WebSocket connection failed: \(error.localizedDescription)")
                self.isConnected = false
                self.scheduleReconnect()
            }
        }
    }
}
