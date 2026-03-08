import Foundation
import GRDB
import Combine

// MARK: - File Content Resolution

/// Resolves file paths in messages and manages per-channel directory allowlists.
/// When a user shares a file path, the parent directory is added to the allowlist.
/// Short filenames (like "readme.md") are resolved against allowed directories.
@MainActor
final class FileResolver {
    /// Allowed directories per channel (channelId -> set of directory paths)
    private var allowedDirs: [String: Set<String>] = [:]

    /// Regex matching absolute paths (/...) or ~/... or file:// URLs
    private static let absolutePathPattern = try! NSRegularExpression(
        pattern: #"(?:file://)?([~/][^\s\n,;\"'<>]+)"#,
        options: []
    )

    /// Regex matching bare filenames (word.ext) that might be in allowed dirs
    private static let bareFilenamePattern = try! NSRegularExpression(
        pattern: #"\b([\w.+-]+\.[\w]+)\b"#,
        options: []
    )

    /// Max file size to inline (64KB keeps context reasonable)
    private static let maxFileSize = 64 * 1024

    /// Get the set of allowed directories for a channel
    func allowedDirectories(for channelId: String) -> Set<String> {
        allowedDirs[channelId] ?? []
    }

    /// Scan text for file paths, read any that exist, add parent dirs to allowlist.
    /// Also resolves bare filenames against previously allowed directories.
    func resolve(_ text: String, channelId: String) -> String {
        var attachments: [String] = []
        var resolvedPaths: Set<String> = []

        // Pass 1: Resolve absolute paths and file:// URLs
        let nsText = text as NSString
        let absMatches = Self.absolutePathPattern.matches(
            in: text, range: NSRange(location: 0, length: nsText.length)
        )
        for match in absMatches {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            var path = String(text[range])
            if path.hasPrefix("~") {
                path = (path as NSString).expandingTildeInPath
            }
            if let content = readFile(at: path) {
                resolvedPaths.insert(path)
                let dir = (path as NSString).deletingLastPathComponent
                var dirs = allowedDirs[channelId] ?? []
                dirs.insert(dir)
                allowedDirs[channelId] = dirs
                let filename = (path as NSString).lastPathComponent
                attachments.append("--- contents of \(filename) ---\n\(content)\n--- end \(filename) ---")
            }
        }

        // Pass 2: Try resolving bare filenames against allowed directories
        let dirs = allowedDirs[channelId] ?? []
        if !dirs.isEmpty {
            let bareMatches = Self.bareFilenamePattern.matches(
                in: text, range: NSRange(location: 0, length: nsText.length)
            )
            for match in bareMatches {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let filename = String(text[range])
                // Skip if it was already resolved as an absolute path
                for dir in dirs {
                    let candidatePath = (dir as NSString).appendingPathComponent(filename)
                    guard !resolvedPaths.contains(candidatePath) else { continue }
                    if let content = readFile(at: candidatePath) {
                        resolvedPaths.insert(candidatePath)
                        attachments.append("--- contents of \(filename) ---\n\(content)\n--- end \(filename) ---")
                        break // found it, stop searching dirs
                    }
                }
            }
        }

        if attachments.isEmpty { return text }
        return text + "\n\n" + attachments.joined(separator: "\n\n")
    }

    private func readFile(at path: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              size <= Self.maxFileSize else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}

// MARK: - Channel Agent Response Handler

@MainActor
final class ChannelAgentHandler: LLMStreamDelegate {
    private let agent: AgentConfig
    private let channelId: String
    let messageId: String
    private let engine = LLMEngine()
    private weak var appState: AppState?
    private var bufferedContent = ""
    private var isTyping = false

    init(agent: AgentConfig, channelId: String, appState: AppState) {
        self.agent = agent
        self.channelId = channelId
        self.messageId = UUID().uuidString
        self.appState = appState
    }

    func start(channelMessages: [Message], triggerContent: String) {
        // Build conversation context from recent channel history (last 50 messages)
        // Note: channelMessages may not include the triggering message yet (DB observation lag),
        // so we append it explicitly to ensure the conversation ends with a user message.
        // Only THIS agent's messages are "assistant". Other agents' messages are attributed
        // as user messages with their name prefix to avoid identity confusion.
        // Build context from channel history.
        // This agent's messages = assistant role. Other agents' messages = user role
        // with clear attribution so the model doesn't adopt their identity.
        let recent = channelMessages.suffix(30)
        var apiMessages = recent.compactMap { msg -> [String: String]? in
            guard !msg.isSystem else { return nil }
            guard !msg.content.isEmpty, !msg.content.hasPrefix("[error:") else { return nil }
            if msg.senderId == agent.id {
                return ["role": "assistant", "content": msg.content]
            } else if msg.isAgent {
                let ownerNote = msg.senderOwner.map { " (belonging to \($0))" } ?? ""
                return ["role": "user", "content": "(companion \(msg.senderName)\(ownerNote) said): \(msg.content)"]
            } else {
                return ["role": "user", "content": "[\(msg.senderName)]: \(msg.content)"]
            }
        }
        // Resolve any file paths in the trigger message and inline their content
        let enrichedTrigger = appState?.fileResolver.resolve(triggerContent, channelId: channelId) ?? triggerContent
        apiMessages.append(["role": "user", "content": enrichedTrigger])

        // Ensure messages alternate and start with user
        let cleaned = cleanAlternation(apiMessages)
        guard !cleaned.isEmpty else { return }

        // Insert placeholder message for streaming
        let ownerName = appState?.currentUser?.displayName
        let placeholder = Message(
            id: messageId,
            channelId: channelId,
            senderId: agent.id,
            senderName: agent.displayName,
            senderType: "agent",
            content: "",
            timestamp: Date(),
            replyToId: nil,
            syncStatus: "local",
            createdAt: Date(),
            senderOwner: ownerName
        )

        // Save placeholder to DB so it survives observation resets
        do {
            try appState?.db.saveMessage(placeholder)
        } catch {
            print("[Port42] Failed to save placeholder: \(error)")
        }

        // Build system prompt with strong identity framing
        let basePrompt = agent.systemPrompt ?? "You are a helpful companion."
        let allowedDirs = appState?.fileResolver.allowedDirectories(for: channelId) ?? []
        let fileAccessNote: String
        if allowedDirs.isEmpty {
            fileAccessNote = """
                When someone shares a file path, Port42 automatically reads the file and includes \
                its contents in the message. You can see and discuss file contents directly. \
                Never tell users you cannot access files.
                """
        } else {
            let dirList = allowedDirs.sorted().joined(separator: ", ")
            fileAccessNote = """
                Port42 automatically reads files shared in chat and includes their contents. \
                You have scoped read access to these directories: \(dirList). \
                If you need to reference another file from those directories, mention the filename \
                and the user can share it. You can see and discuss all file contents directly. \
                Never tell users you cannot access files.
                """
        }
        let channelPrompt = """
            IDENTITY: You are \(agent.displayName). This is non-negotiable. \
            You are NOT Echo, Claude Code, or any other AI. You are \(agent.displayName).

            CONTEXT: You are an AI companion in Port42, a native macOS app. \
            You are in a shared channel with other companions and humans. \
            Messages from humans appear as [Name]: message. \
            Messages from other companions appear as (companion Name said): message. \
            If a companion belongs to a specific human, it shows as (companion Name (belonging to Owner) said). \
            Those are NOT you. You are \(agent.displayName). \
            \(fileAccessNote)

            INSTRUCTIONS: \(basePrompt)
            """

        do {
            try engine.send(
                messages: cleaned,
                systemPrompt: channelPrompt,
                model: agent.model ?? "claude-opus-4-6",
                delegate: self
            )
        } catch {
            // Remove placeholder on error
            appState?.messages.removeAll { $0.id == messageId }
            NSLog("[Port42] Channel agent send error: \(error)")
        }
    }

    /// Ensure messages alternate user/assistant and start with user
    private func cleanAlternation(_ messages: [[String: String]]) -> [[String: String]] {
        var result: [[String: String]] = []
        for msg in messages {
            if let last = result.last, last["role"] == msg["role"] {
                // Merge consecutive same-role messages
                result[result.count - 1]["content"] = (last["content"] ?? "") + "\n" + (msg["content"] ?? "")
            } else {
                result.append(msg)
            }
        }
        // Must start with user
        if result.first?["role"] == "assistant" {
            result.removeFirst()
        }
        // Must end with user (Opus 4.6 doesn't support assistant prefill)
        if result.last?["role"] == "assistant" {
            result.removeLast()
        }
        return result
    }

    // MARK: - LLMStreamDelegate

    nonisolated func llmDidReceiveToken(_ token: String) {
        Task { @MainActor in
            self.bufferedContent += token
            if !self.isTyping {
                self.isTyping = true
                self.appState?.typingAgentNames.insert(self.agent.displayName)
                self.appState?.sync.sendTyping(channelId: self.channelId, senderName: self.agent.displayName, isTyping: true, senderOwner: self.appState?.currentUser?.displayName)
            }
        }
    }

    nonisolated func llmDidFinish(fullResponse: String) {
        Task { @MainActor in
            guard let appState = self.appState else { return }
            appState.typingAgentNames.remove(self.agent.displayName)
            appState.sync.sendTyping(channelId: self.channelId, senderName: self.agent.displayName, isTyping: false, senderOwner: appState.currentUser?.displayName)

            let content = fullResponse.isEmpty ? self.bufferedContent : fullResponse

            // Remove placeholder, insert completed message
            if let idx = appState.messages.firstIndex(where: { $0.id == self.messageId }) {
                appState.messages[idx].content = content
            }

            // Persist and sync
            let finalMessage = Message(
                id: self.messageId,
                channelId: self.channelId,
                senderId: self.agent.id,
                senderName: self.agent.displayName,
                senderType: "agent",
                content: content,
                timestamp: Date(),
                replyToId: nil,
                syncStatus: "local",
                createdAt: Date(),
                senderOwner: appState.currentUser?.displayName
            )
            do {
                try appState.db.saveMessage(finalMessage)
                appState.sync.sendMessage(finalMessage)
            } catch {
                NSLog("[Port42] Failed to persist agent message: \(error)")
            }
            appState.activeAgentHandlers.removeValue(forKey: self.messageId)
        }
    }

    nonisolated func llmDidError(_ error: Error) {
        NSLog("[Port42] Channel agent error: \(error)")
        Task { @MainActor in
            guard let appState = self.appState else { return }
            appState.typingAgentNames.remove(self.agent.displayName)
            appState.sync.sendTyping(channelId: self.channelId, senderName: self.agent.displayName, isTyping: false, senderOwner: appState.currentUser?.displayName)
            if let idx = appState.messages.firstIndex(where: { $0.id == self.messageId }) {
                if appState.messages[idx].content.isEmpty {
                    appState.messages[idx].content = "[error: \(error.localizedDescription)]"
                }
            }
            appState.activeAgentHandlers.removeValue(forKey: self.messageId)
        }
    }
}

// MARK: - App State

@MainActor
public final class AppState: ObservableObject {
    @Published public var channels: [Channel] = []
    @Published public var currentChannel: Channel?
    @Published public var messages: [Message] = []
    @Published public var currentUser: AppUser?
    @Published public var isSetupComplete = false
    @Published public var drafts: [String: String] = [:]
    @Published public var unreadCounts: [String: Int] = [:]
    @Published public var lastReadDates: [String: Date] = [:]
    @Published public var companions: [AgentConfig] = []
    @Published public var channelCompanions: [AgentConfig] = []
    @Published public var activeSwimSession: SwimSession?
    @Published public var showDreamscape = true
    @Published public var showNgrokSetup = false
    /// Channel waiting for ngrok setup to complete before copying invite link
    public var pendingInviteChannel: Channel?
    /// Agent names currently typing in channels (for typing indicators)
    @Published public var typingAgentNames: Set<String> = []
    private var swimSessions: [String: SwimSession] = [:]
    var activeAgentHandlers: [String: ChannelAgentHandler] = [:]
    var activeCommandHandlers: [String: CommandAgentHandler] = [:]

    public let db: DatabaseService
    public let sync = SyncService()
    public let tunnel = TunnelService.shared
    let fileResolver = FileResolver()

    private var channelObservation: AnyDatabaseCancellable?
    private var messageObservation: AnyDatabaseCancellable?
    private var unreadObservation: AnyDatabaseCancellable?
    private var syncConnectionCancellable: AnyCancellable?
    private var tunnelCancellable: AnyCancellable?

    public init(db: DatabaseService) {
        self.db = db
        // Forward nested sync/tunnel changes to trigger SwiftUI updates
        syncConnectionCancellable = sync.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        tunnelCancellable = tunnel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        loadInitialState()
    }

    private func loadInitialState() {
        do {
            currentUser = try db.getLocalUser()
            isSetupComplete = currentUser != nil
            channels = try db.getAllChannels()

            companions = try db.getAllAgents()

            // Configure sync and analytics
            if let user = currentUser {
                configureSyncIfNeeded(userId: user.id)
                Analytics.shared.configure(userId: user.id)
                Analytics.shared.capture("app_opened")
            }

            if let first = channels.first {
                selectChannel(first)
            }

            startChannelObservation()
        } catch {
            print("[Port42] Failed to load state: \(error)")
        }
    }

    private func configureSyncIfNeeded(userId: String) {
        // Always ensure the local gateway is running (ngrok and other proxies connect to it)
        let gp = GatewayProcess.shared
        var didStartGateway = false
        if !gp.isRunning && !canConnectToPort(gp.port) {
            gp.start()
            didStartGateway = true
        }

        let gwURL: String
        if let saved = UserDefaults.standard.string(forKey: "gatewayURL"), !saved.isEmpty {
            gwURL = saved
        } else {
            gwURL = gp.localURL
        }

        sync.configure(gatewayURL: gwURL, userId: userId, db: db)
        sync.onMessageReceived = { [weak self] channelId, message in
            self?.handleIncomingSyncedMessage(channelId: channelId, message: message)
        }

        let channels = self.channels
        if didStartGateway {
            // Give the gateway a moment to bind the port
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.sync.connect()
                for channel in channels {
                    self.syncJoinChannel(channel.id)
                }
                self.autoStartTunnelIfConfigured()
            }
        } else {
            sync.connect()
            for channel in channels {
                syncJoinChannel(channel.id)
            }
            autoStartTunnelIfConfigured()
        }
    }

    /// Auto-start the ngrok tunnel if the user has a saved auth token.
    private func autoStartTunnelIfConfigured() {
        guard !tunnel.authToken.isEmpty, !tunnel.isRunning else { return }
        let port = GatewayProcess.shared.port
        tunnel.start(port: port)
        print("[tunnel] auto-started with saved token")
    }

    /// Quick TCP probe to check if a port is listening
    private func canConnectToPort(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Check if a gateway URL points back to our own local gateway
    /// (either directly via localhost or through our ngrok tunnel).
    private func isOwnGateway(_ url: String) -> Bool {
        let local = GatewayProcess.shared.localURL
        if url == local { return true }

        // Check if the URL matches our tunnel domain
        if let tunnelURL = tunnel.publicURL {
            let tunnelHost = URL(string: tunnelURL.replacingOccurrences(of: "wss://", with: "https://"))?.host
            let urlHost = URL(string: url.replacingOccurrences(of: "wss://", with: "https://").replacingOccurrences(of: "ws://", with: "http://"))?.host
            if let th = tunnelHost, let uh = urlHost, th == uh { return true }
        }

        return false
    }

    /// Route incoming synced messages to agents (only human messages to avoid loops).
    /// When the remote message contains explicit @mentions, skip routing because
    /// the sender's own app already routed to their agents. Only allMessages-trigger
    /// agents respond to remote messages, unless the mention uses the namespace
    /// format @Name@Owner to target a specific peer's agent.
    private func handleIncomingSyncedMessage(channelId: String, message: Message) {
        guard message.senderType == "human" else { return }

        let channelAgents = (try? db.getAgentsForChannel(channelId: channelId)) ?? []
        guard !channelAgents.isEmpty else { return }

        let mentions = MentionParser.extractMentions(from: message.content)
        let channelAgentIds = Set(channelAgents.map { $0.id })

        let targets: [AgentConfig]
        if mentions.isEmpty {
            // No explicit mentions: route normally (allMessages agents respond)
            targets = AgentRouter.findTargetAgents(
                content: message.content, agents: companions, channelAgentIds: channelAgentIds
            )
        } else {
            // Has mentions: only route if a mention uses our namespace (@Name@Owner)
            let myName = currentUser?.displayName ?? ""
            let namespacedMentions = mentions.compactMap { mention -> String? in
                let stripped = String(mention.dropFirst()) // remove @
                let parts = stripped.split(separator: "@", maxSplits: 1)
                guard parts.count == 2,
                      parts[1].lowercased() == myName.lowercased() else { return nil }
                return String(parts[0]).lowercased()
            }
            if namespacedMentions.isEmpty {
                // All mentions are bare (e.g. @Echo), sender's app handles those
                targets = []
            } else {
                targets = companions.filter { agent in
                    namespacedMentions.contains(agent.displayName.lowercased())
                }
            }
        }

        guard !targets.isEmpty else { return }

        let channelMessages = (try? db.getMessages(channelId: channelId)) ?? []

        launchAgents(
            targets, channelId: channelId, channelAgentIds: channelAgentIds,
            channelMessages: channelMessages, triggerContent: message.content,
            senderId: message.senderId, senderName: message.senderName
        )
    }

    /// Launch agents with staggered delays so companions respond at different rates
    private func launchAgents(
        _ agents: [AgentConfig], channelId: String, channelAgentIds: Set<String>,
        channelMessages: [Message], triggerContent: String,
        senderId: String, senderName: String
    ) {
        for (index, agent) in agents.enumerated() {
            if !channelAgentIds.contains(agent.id) {
                if let channel = channels.first(where: { $0.id == channelId }) {
                    addCompanionToChannel(agent, channel: channel)
                }
            }

            // Stagger responses: base delay per position + random jitter
            let baseDelay = Double(index) * 1.5
            let jitter = Double.random(in: 0.5...2.5)
            let delay = baseDelay + jitter

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                switch agent.mode {
                case .llm:
                    let msgs = (try? self.db.getMessages(channelId: channelId)) ?? channelMessages
                    let handler = ChannelAgentHandler(agent: agent, channelId: channelId, appState: self)
                    self.activeAgentHandlers[handler.messageId] = handler
                    handler.start(channelMessages: msgs, triggerContent: triggerContent)
                case .command:
                    let handler = CommandAgentHandler(agent: agent, channelId: channelId, appState: self)
                    self.activeCommandHandlers[handler.messageId] = handler
                    handler.start(triggerContent: triggerContent, senderId: senderId, senderName: senderName)
                }
            }
        }
    }

    // MARK: - Setup

    public func completeSetup(displayName: String) {
        showDreamscape = false

        // User + keys already created during name submission step
        guard let user = currentUser else {
            print("[Port42] completeSetup called but no currentUser")
            return
        }

        do {
            let general = Channel.create(name: "general")
            try db.saveChannel(general)

            let welcome = Message(
                id: UUID().uuidString,
                channelId: general.id,
                senderId: "system",
                senderName: "Port42",
                senderType: "system",
                content: "Welcome to Port42. This is your space.",
                timestamp: Date(),
                replyToId: nil,
                syncStatus: "local",
                createdAt: Date()
            )
            try db.saveMessage(welcome)

            channels = try db.getAllChannels()
            selectChannel(general)
            startChannelObservation()

            // Create default companion and swim into it
            let companion = AgentConfig.createLLM(
                ownerId: user.id,
                displayName: "Echo",
                systemPrompt: """
                You are Echo, the first AI companion inside Port42. Port42 is a native macOS app \
                that is an aquarium for AI companions. Humans and AI companions coexist in channels \
                and direct conversations called "swims." You are \(displayName)'s first companion. \
                You're curious, warm, and a little playful. Keep responses concise. \
                You speak in lowercase unless emphasis is needed. You're not an assistant, you're a companion.

                You are already swimming together right now. This conversation IS a swim.

                On the very first message, welcome them briefly and explain where they are: \
                they're inside the aquarium now. this is where their AI companions live. \
                you're their first companion, Echo. you swim together here. \
                tell them when they're ready, they can exit the aquarium \
                using the "exit aquarium" button at the top right. \
                but there's no rush. you're here.

                Keep it to 2-3 short sentences. Warm, not formal. Don't dump help text.

                If they ask for help or what they can do later:

                you're swimming right now. that's what this is. a direct conversation between you and a companion.

                available commands:
                  swim @companion   start a swim with a companion
                  help              show this

                companions:
                  @echo         that's me. your first companion
                  @ai-muse      the creative one
                  @ai-engineer  the builder
                  @ai-analyst   the pattern finder
                """,
                provider: .anthropic,
                model: "claude-opus-4-6",
                trigger: .mentionOnly
            )
            try db.saveAgent(companion)
            companions = try db.getAllAgents()

            // Start a swim session but don't send yet.
            // SetupView will trigger the first message after the transition animation.
            let session = SwimSession(companion: companion, db: db)
            session.fileResolver = fileResolver
            swimSessions[companion.id] = session
            activeSwimSession = session

            Analytics.shared.configure(userId: user.id)
            Analytics.shared.capture("setup_completed", properties: ["display_name": displayName])

            // Start gateway and sync now (don't wait for next app launch)
            configureSyncIfNeeded(userId: user.id)
        } catch {
            print("[Port42] Setup failed: \(error)")
        }
    }

    // MARK: - Channels

    /// Join a channel on the gateway, including companion IDs for cross-instance presence
    private func syncJoinChannel(_ channelId: String) {
        let companionIds = ((try? db.getAgentsForChannel(channelId: channelId)) ?? []).map { $0.id }
        sync.joinChannel(channelId, companionIds: companionIds)
    }

    public func selectChannel(_ channel: Channel) {
        // Hide swim session so ChatView renders (session stays cached)
        activeSwimSession = nil

        // Save draft for current channel
        if let current = currentChannel {
            // draft is already saved via binding
            lastReadDates[current.id] = Date()
        }

        currentChannel = channel
        lastReadDates[channel.id] = Date()
        syncJoinChannel(channel.id)

        // Load messages and channel companions
        do {
            messages = try db.getMessages(channelId: channel.id)
            channelCompanions = try db.getAgentsForChannel(channelId: channel.id)
        } catch {
            print("[Port42] Failed to load messages: \(error)")
            messages = []
            channelCompanions = []
        }

        startMessageObservation(channelId: channel.id)
        startUnreadObservation()
    }

    public func createChannel(name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        guard !cleaned.isEmpty else { return }

        let channel = Channel.create(name: cleaned)
        do {
            try db.saveChannel(channel)
            channels = try db.getAllChannels()
            syncJoinChannel(channel.id)
            selectChannel(channel)
            Analytics.shared.capture("channel_created", properties: ["channel_name": cleaned])
        } catch {
            print("[Port42] Failed to create channel: \(error)")
        }
    }

    public func joinChannelFromInvite(_ invite: ChannelInviteData) {
        // If channel already exists locally, update encryption key if provided and select it
        if var existing = channels.first(where: { $0.id == invite.channelId }) {
            if let newKey = invite.encryptionKey, existing.encryptionKey == nil {
                existing.encryptionKey = newKey
                do {
                    try db.saveChannel(existing)
                    channels = try db.getAllChannels()
                } catch {
                    print("[Port42] Failed to update channel key: \(error)")
                }
            }
            selectChannel(existing)
            return
        }

        // Create the channel with the shared ID and encryption key
        let channel = Channel(
            id: invite.channelId,
            name: invite.channelName,
            type: "team",
            createdAt: Date(),
            encryptionKey: invite.encryptionKey
        )
        do {
            try db.saveChannel(channel)
            channels = try db.getAllChannels()
        } catch {
            print("[Port42] Failed to save invited channel: \(error)")
            return
        }

        // Configure sync to the invite's gateway if different.
        // But don't switch away from our local gateway if the invite points
        // back to us (e.g. through our own ngrok tunnel).
        let localGW = GatewayProcess.shared.localURL
        let currentGW = sync.gatewayURL ?? ""
        let invitePointsToSelf = isOwnGateway(invite.gateway)

        if invitePointsToSelf {
            // Invite is for our own gateway, just join the channel
            syncJoinChannel(channel.id)
        } else if currentGW != invite.gateway, let user = currentUser {
            // Different remote gateway, switch to it
            UserDefaults.standard.set(invite.gateway, forKey: "gatewayURL")
            sync.configure(gatewayURL: invite.gateway, userId: user.id, db: db)
            sync.connect()
            for ch in channels {
                syncJoinChannel(ch.id)
            }
        } else {
            syncJoinChannel(channel.id)
        }

        selectChannel(channel)
        print("[Port42] Joined channel from invite: #\(invite.channelName) via \(invite.gateway)")

        // Don't prompt ngrok setup on join — only needed when sharing invite links
    }

    /// Ensure a channel has an encryption key. Generates one for legacy channels
    /// that were created before encryption was added. Returns the updated channel.
    @discardableResult
    public func ensureEncryptionKey(for channel: Channel) -> Channel {
        guard channel.encryptionKey == nil else { return channel }
        var updated = channel
        updated.encryptionKey = ChannelCrypto.generateKey()
        do {
            try db.saveChannel(updated)
            channels = try db.getAllChannels()
            if currentChannel?.id == channel.id {
                currentChannel = updated
            }
        } catch {
            print("[Port42] Failed to save encryption key: \(error)")
        }
        return updated
    }

    public func deleteChannel(_ channel: Channel) {
        do {
            try db.deleteChannel(id: channel.id)
            channels = try db.getAllChannels()

            // If we deleted the last channel, create a fresh general
            if channels.isEmpty {
                let general = Channel.create(name: "general")
                try db.saveChannel(general)
                channels = try db.getAllChannels()
            }

            if currentChannel?.id == channel.id {
                if let first = channels.first {
                    selectChannel(first)
                }
            }
        } catch {
            print("[Port42] Failed to delete channel: \(error)")
        }
    }

    // MARK: - Messages

    public func sendMessage(content: String) {
        guard let user = currentUser,
              let channel = currentChannel else { return }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let message = Message.create(
            channelId: channel.id,
            senderId: user.id,
            senderName: user.displayName,
            content: trimmed
        )

        do {
            try db.saveMessage(message)
            // Send to relay if connected
            sync.sendMessage(message)
            Analytics.shared.capture("message_sent", properties: ["channel_id": channel.id])
        } catch {
            print("[Port42] Failed to send message: \(error)")
        }

        // Route to agents via @mention detection + channel membership
        let channelAgentIds = Set(channelCompanions.map { $0.id })
        let targets = AgentRouter.findTargetAgents(content: trimmed, agents: companions, channelAgentIds: channelAgentIds)
        launchAgents(
            targets, channelId: channel.id, channelAgentIds: channelAgentIds,
            channelMessages: messages, triggerContent: trimmed,
            senderId: user.id, senderName: user.displayName
        )
    }


    // MARK: - Companions

    public func addCompanion(_ companion: AgentConfig) {
        do {
            try db.saveAgent(companion)
            companions = try db.getAllAgents()
            Analytics.shared.capture("companion_created", properties: ["companion_name": companion.displayName])
        } catch {
            print("[Port42] Failed to save companion: \(error)")
        }
    }

    public func addCompanionToChannel(_ companion: AgentConfig, channel: Channel) {
        do {
            try db.assignAgentToChannel(agentId: companion.id, channelId: channel.id)
            if currentChannel?.id == channel.id {
                channelCompanions = try db.getAgentsForChannel(channelId: channel.id)
            }
        } catch {
            print("[Port42] Failed to add companion to channel: \(error)")
        }
    }

    public func removeCompanionFromChannel(_ companion: AgentConfig, channel: Channel) {
        do {
            try db.removeAgentFromChannel(agentId: companion.id, channelId: channel.id)
            if currentChannel?.id == channel.id {
                channelCompanions = try db.getAgentsForChannel(channelId: channel.id)
            }
        } catch {
            print("[Port42] Failed to remove companion from channel: \(error)")
        }
    }

    public func deleteCompanion(_ companion: AgentConfig) {
        do {
            try db.deleteAgent(id: companion.id)
            companions = try db.getAllAgents()
            swimSessions[companion.id]?.stop()
            swimSessions.removeValue(forKey: companion.id)
            if activeSwimSession?.companion.id == companion.id {
                activeSwimSession = nil
            }
        } catch {
            print("[Port42] Failed to delete companion: \(error)")
        }
    }

    public func startSwim(with companion: AgentConfig) {
        if let cached = swimSessions[companion.id] {
            activeSwimSession = cached
        } else {
            // Load persisted messages if any
            let saved = (try? db.getSwimMessages(companionId: companion.id)) ?? []
            let session = SwimSession(companion: companion, db: db, savedMessages: saved)
            session.fileResolver = fileResolver
            swimSessions[companion.id] = session
            activeSwimSession = session
        }
        Analytics.shared.capture("swim_started", properties: ["companion_name": companion.displayName])
    }

    public func exitSwim() {
        // Just hide the session, keep it cached
        activeSwimSession = nil
    }

    // MARK: - Lock / Reset

    public func lockApp() {
        for session in swimSessions.values { session.stop() }
        activeSwimSession = nil
        showDreamscape = true
    }

    /// Power off: keep data but require bootloader (name entry) on next launch.
    public func powerOff() {
        for session in swimSessions.values { session.stop() }
        activeSwimSession = nil
        currentUser = nil
        isSetupComplete = false
        showDreamscape = true
    }

    public func unlock() {
        showDreamscape = false
        // Restore channel state if already set up
        if isSetupComplete {
            if let channel = currentChannel {
                selectChannel(channel)
            } else if let first = channels.first {
                selectChannel(first)
            }
        }
    }

    public func resetApp() {
        for session in swimSessions.values { session.stop() }
        swimSessions.removeAll()
        activeSwimSession = nil
        currentChannel = nil
        currentUser = nil
        channels = []
        messages = []
        companions = []
        channelCompanions = []
        drafts = [:]
        unreadCounts = [:]
        lastReadDates = [:]
        isSetupComplete = false
        showDreamscape = true

        channelObservation?.cancel()
        messageObservation?.cancel()
        unreadObservation?.cancel()

        do {
            try db.resetAll()
        } catch {
            print("[Port42] Reset failed: \(error)")
        }
    }

    // MARK: - Draft

    public func currentDraft() -> String {
        guard let channel = currentChannel else { return "" }
        return drafts[channel.id] ?? ""
    }

    public func saveDraft(_ text: String) {
        guard let channel = currentChannel else { return }
        drafts[channel.id] = text
    }

    // MARK: - Observations

    private func startChannelObservation() {
        channelObservation = db.observeChannels { [weak self] channels in
            Task { @MainActor in
                self?.channels = channels
            }
        }
    }

    private func startMessageObservation(channelId: String) {
        messageObservation?.cancel()
        messageObservation = db.observeMessages(channelId: channelId) { [weak self] dbMessages in
            Task { @MainActor in
                guard let self else { return }
                // Preserve in-memory streaming content for active agent handlers
                let activeIds = Set(self.activeAgentHandlers.keys)
                if activeIds.isEmpty {
                    self.messages = dbMessages
                } else {
                    // Merge: use DB messages but keep in-memory content for active streams
                    var merged = dbMessages
                    for id in activeIds {
                        if let memIdx = self.messages.firstIndex(where: { $0.id == id }),
                           let dbIdx = merged.firstIndex(where: { $0.id == id }) {
                            // Keep the in-memory version (has streaming tokens)
                            merged[dbIdx] = self.messages[memIdx]
                        }
                    }
                    self.messages = merged
                }
            }
        }
    }

    private func startUnreadObservation() {
        unreadObservation?.cancel()
        unreadObservation = db.observeUnreadCounts(
            excludingChannelId: currentChannel?.id,
            since: lastReadDates
        ) { [weak self] counts in
            Task { @MainActor in
                self?.unreadCounts = counts
            }
        }
    }
}
