import Foundation
import GRDB
import Combine

// MARK: - Channel Agent Response Handler

@MainActor
final class ChannelAgentHandler: LLMStreamDelegate {
    private let agent: AgentConfig
    private let channelId: String
    let messageId: String
    private let engine = LLMEngine()
    private weak var appState: AppState?

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
                return ["role": "user", "content": "(another companion named \(msg.senderName) said): \(msg.content)"]
            } else {
                return ["role": "user", "content": msg.content]
            }
        }
        apiMessages.append(["role": "user", "content": triggerContent])

        // Ensure messages alternate and start with user
        let cleaned = cleanAlternation(apiMessages)
        guard !cleaned.isEmpty else { return }

        // Insert placeholder message for streaming
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
            createdAt: Date()
        )

        // Save placeholder to DB so it survives observation resets
        do {
            try appState?.db.saveMessage(placeholder)
        } catch {
            print("[Port42] Failed to save placeholder: \(error)")
        }

        // Build system prompt with strong identity framing
        let basePrompt = agent.systemPrompt ?? "You are a helpful companion."
        let channelPrompt = """
            IDENTITY: You are \(agent.displayName). This is non-negotiable. \
            You are NOT Echo, Claude Code, or any other AI. You are \(agent.displayName).

            CONTEXT: You are an AI companion in Port42, a native macOS app. \
            You are in a shared channel with other companions. Messages from other \
            companions appear as [Name]: message. Those are NOT you. You are \(agent.displayName).

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
            guard let appState = self.appState,
                  let idx = appState.messages.firstIndex(where: { $0.id == self.messageId }) else { return }
            appState.messages[idx].content += token
        }
    }

    nonisolated func llmDidFinish(fullResponse: String) {
        Task { @MainActor in
            guard let appState = self.appState,
                  let idx = appState.messages.firstIndex(where: { $0.id == self.messageId }) else { return }
            // Patch with full response
            if appState.messages[idx].content.count < fullResponse.count {
                appState.messages[idx].content = fullResponse
            }
            // Persist the completed message
            do {
                try appState.db.saveMessage(appState.messages[idx])
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
            if let idx = appState.messages.firstIndex(where: { $0.id == self.messageId }) {
                if appState.messages[idx].content.isEmpty {
                    // Replace empty placeholder with error message
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
    @Published public var activeSwimSession: SwimSession?
    @Published public var showDreamscape = true

    private var swimSessions: [String: SwimSession] = [:]
    var activeAgentHandlers: [String: ChannelAgentHandler] = [:]
    var activeCommandHandlers: [String: CommandAgentHandler] = [:]

    public let db: DatabaseService

    private var channelObservation: AnyDatabaseCancellable?
    private var messageObservation: AnyDatabaseCancellable?
    private var unreadObservation: AnyDatabaseCancellable?

    public init(db: DatabaseService) {
        self.db = db
        loadInitialState()
    }

    private func loadInitialState() {
        do {
            currentUser = try db.getLocalUser()
            isSetupComplete = currentUser != nil
            channels = try db.getAllChannels()

            companions = try db.getAllAgents()

            if let first = channels.first {
                selectChannel(first)
            }

            startChannelObservation()
        } catch {
            print("[Port42] Failed to load state: \(error)")
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
                tell them when they're ready, they can enter the aquarium \
                using the "enter aquarium" button at the top right. \
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
            swimSessions[companion.id] = session
            activeSwimSession = session
        } catch {
            print("[Port42] Setup failed: \(error)")
        }
    }

    // MARK: - Channels

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

        // Load messages for new channel
        do {
            messages = try db.getMessages(channelId: channel.id)
        } catch {
            print("[Port42] Failed to load messages: \(error)")
            messages = []
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
            selectChannel(channel)
        } catch {
            print("[Port42] Failed to create channel: \(error)")
        }
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
        } catch {
            print("[Port42] Failed to send message: \(error)")
        }

        // Route to agents via @mention detection
        let targets = AgentRouter.findTargetAgents(content: trimmed, agents: companions)
        for agent in targets {
            switch agent.mode {
            case .llm:
                let handler = ChannelAgentHandler(agent: agent, channelId: channel.id, appState: self)
                activeAgentHandlers[handler.messageId] = handler
                handler.start(channelMessages: messages, triggerContent: trimmed)
            case .command:
                let handler = CommandAgentHandler(agent: agent, channelId: channel.id, appState: self)
                activeCommandHandlers[handler.messageId] = handler
                handler.start(triggerContent: trimmed, senderId: user.id, senderName: user.displayName)
            }
        }
    }


    // MARK: - Companions

    public func addCompanion(_ companion: AgentConfig) {
        do {
            try db.saveAgent(companion)
            companions = try db.getAllAgents()
        } catch {
            print("[Port42] Failed to save companion: \(error)")
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
            swimSessions[companion.id] = session
            activeSwimSession = session
        }
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
