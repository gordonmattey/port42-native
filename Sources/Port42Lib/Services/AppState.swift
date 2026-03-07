import Foundation
import GRDB
import Combine

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
        messageObservation = db.observeMessages(channelId: channelId) { [weak self] messages in
            Task { @MainActor in
                self?.messages = messages
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
