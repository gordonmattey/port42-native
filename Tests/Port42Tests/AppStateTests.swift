import Testing
import Foundation
@testable import Port42Lib

@Suite("AppState")
struct AppStateTests {

    @MainActor
    func makeState() throws -> AppState {
        let db = try DatabaseService(inMemory: true)
        return AppState(db: db)
    }

    // MARK: - Setup

    @Test("Initial state before setup")
    @MainActor
    func initialState() throws {
        let state = try makeState()
        #expect(state.isSetupComplete == false)
        #expect(state.currentUser == nil)
        #expect(state.currentChannel == nil)
    }

    @Test("Complete setup creates user, channel, companion, and swim session")
    @MainActor
    func completeSetup() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Gordon")

        // Setup is not yet complete; the onboarding swim phase handles that
        #expect(state.isSetupComplete == false)
        #expect(state.currentUser?.displayName == "Gordon")
        #expect(state.currentChannel?.name == "general")

        let channels = try state.db.getAllChannels()
        #expect(channels.count == 1)
        #expect(channels.first?.name == "general")

        let messages = try state.db.getMessages(channelId: state.currentChannel!.id)
        #expect(messages.count == 1)
        #expect(messages.first?.senderType == "system")

        // Companion created during onboarding
        #expect(state.companions.count == 1)
        #expect(state.companions.first?.displayName == "Claude")
        #expect(state.companions.first?.mode == .llm)
        #expect(state.companions.first?.model == "claude-opus-4-6")

        // Swim session started with intro message
        #expect(state.activeSwimSession != nil)
        #expect(state.activeSwimSession?.companion.displayName == "Claude")
        #expect(state.activeSwimSession?.messages.count == 2) // user intro + assistant placeholder
        #expect(state.activeSwimSession?.messages.first?.role == .user)
        #expect(state.activeSwimSession?.messages.first?.content.contains("Gordon") == true)
    }

    // MARK: - Channels

    @Test("Create channel")
    @MainActor
    func createChannel() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        state.createChannel(name: "Builders Club")

        let channels = try state.db.getAllChannels()
        #expect(channels.count == 2)
        #expect(state.currentChannel?.name == "builders-club")
    }

    @Test("Create channel normalizes name")
    @MainActor
    func channelNameNormalization() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        state.createChannel(name: "  My Cool Channel  ")
        #expect(state.currentChannel?.name == "my-cool-channel")
    }

    @Test("Empty channel name is rejected")
    @MainActor
    func emptyChannelName() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        state.createChannel(name: "   ")
        let channels = try state.db.getAllChannels()
        #expect(channels.count == 1) // only general
    }

    @Test("Delete channel switches to another")
    @MainActor
    func deleteChannel() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")
        state.createChannel(name: "temp")

        let channels = try state.db.getAllChannels()
        let temp = channels.first(where: { $0.name == "temp" })!
        state.selectChannel(temp)
        state.deleteChannel(temp)

        let remaining = try state.db.getAllChannels()
        #expect(remaining.count == 1)
        #expect(state.currentChannel?.name == "general")
    }

    @Test("Cannot delete last channel")
    @MainActor
    func cannotDeleteLastChannel() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        let channels = try state.db.getAllChannels()
        state.deleteChannel(channels.first!)
        #expect(try state.db.getAllChannels().count == 1)
    }

    // MARK: - Messages

    @Test("Send message")
    @MainActor
    func sendMessage() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Gordon")

        state.sendMessage(content: "hello world")
        let messages = try state.db.getMessages(channelId: state.currentChannel!.id)
        #expect(messages.count == 2) // welcome + hello
        #expect(messages.last?.content == "hello world")
        #expect(messages.last?.senderName == "Gordon")
        #expect(messages.last?.senderType == "human")
    }

    @Test("Empty message is not sent")
    @MainActor
    func emptyMessage() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        state.sendMessage(content: "   ")
        let messages = try state.db.getMessages(channelId: state.currentChannel!.id)
        #expect(messages.count == 1) // only welcome
    }

    @Test("Messages are per-channel")
    @MainActor
    func messagesPerChannel() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")

        let generalId = state.currentChannel!.id
        state.sendMessage(content: "in general")

        state.createChannel(name: "other")
        let otherId = state.currentChannel!.id
        state.sendMessage(content: "in other")

        let generalMsgs = try state.db.getMessages(channelId: generalId)
        let otherMsgs = try state.db.getMessages(channelId: otherId)

        #expect(generalMsgs.count == 2) // welcome + "in general"
        #expect(otherMsgs.count == 1) // "in other"
    }

    // MARK: - Drafts

    @Test("Draft preserved per channel")
    @MainActor
    func draftPreservation() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")
        state.createChannel(name: "other")

        let channels = try state.db.getAllChannels()
        let general = channels.first(where: { $0.name == "general" })!
        let other = channels.first(where: { $0.name == "other" })!

        state.selectChannel(general)
        state.saveDraft("draft in general")

        state.selectChannel(other)
        state.saveDraft("draft in other")

        state.selectChannel(general)
        #expect(state.currentDraft() == "draft in general")

        state.selectChannel(other)
        #expect(state.currentDraft() == "draft in other")
    }

    @Test("No draft returns empty string")
    @MainActor
    func noDraft() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Test")
        #expect(state.currentDraft() == "")
    }

    // MARK: - Persistence

    @Test("Data survives database query")
    @MainActor
    func persistence() throws {
        let state = try makeState()
        state.completeSetup(displayName: "Persist")
        state.sendMessage(content: "remember me")

        let messages = try state.db.getMessages(channelId: state.currentChannel!.id)
        let user = try state.db.getLocalUser()

        #expect(user?.displayName == "Persist")
        #expect(messages.count == 2) // welcome + message
        #expect(messages.last?.content == "remember me")
    }
}
