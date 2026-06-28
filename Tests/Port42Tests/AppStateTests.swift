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

    /// makeState with a pre-created user (required before calling completeSetup).
    @MainActor
    func makeStateWithUser(displayName: String = "Gordon") throws -> AppState {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let user = AppUser.createForTesting(displayName: displayName)
        try db.saveUser(user)
        state.currentUser = user
        return state
    }

    /// makeState with user + completeSetup + navigate to general space.
    @MainActor
    func makeStateReady(displayName: String = "Test") throws -> AppState {
        let state = try makeStateWithUser(displayName: displayName)
        state.completeSetup(displayName: displayName)
        let general = state.spaces.first { !$0.isSwim }!
        state.selectSpace(general)
        return state
    }

    // MARK: - Setup

    @Test("Initial state before setup")
    @MainActor
    func initialState() throws {
        let state = try makeState()
        #expect(state.isSetupComplete == false)
        #expect(state.currentUser == nil)
        #expect(state.currentSpace == nil)
    }

    @Test("Complete setup creates user, space, companion, and swim session")
    @MainActor
    func completeSetup() throws {
        let state = try makeStateWithUser(displayName: "Gordon")
        state.completeSetup(displayName: "Gordon")

        // Setup is not yet complete; the onboarding swim phase handles that
        #expect(state.isSetupComplete == false)
        #expect(state.currentUser?.displayName == "Gordon")

        let allSpaces = try state.db.getAllSpaces()
        let generalSpace = allSpaces.first { $0.type != "direct" }
        #expect(generalSpace?.name == "general")

        // Companion created during onboarding
        #expect(state.companions.count == 1)
        #expect(state.companions.first?.displayName == "echo")
        #expect(state.companions.first?.mode == .llm)
        #expect(state.companions.first?.model == "claude-opus-4-6")

        // Swim opened with companion (a DM is a `direct` space)
        #expect(state.activeSwimCompanion != nil)
        #expect(state.currentSpace?.type == "direct")
    }

    // MARK: - Spaces

    @Test("Create space")
    @MainActor
    func createSpace() throws {
        let state = try makeStateReady()

        state.createSpace(name: "Builders Club")

        let spaces = try state.db.getAllSpaces()
        // general + swim + builders-club
        #expect(spaces.count == 3)
        #expect(state.currentSpace?.name == "builders-club")
    }

    @Test("Create space normalizes name")
    @MainActor
    func spaceNameNormalization() throws {
        let state = try makeStateReady()

        state.createSpace(name: "  My Cool Space  ")
        #expect(state.currentSpace?.name == "my-cool-space")
    }

    @Test("Empty space name is rejected")
    @MainActor
    func emptySpaceName() throws {
        let state = try makeStateReady()

        state.createSpace(name: "   ")
        let spaces = try state.db.getAllSpaces()
        #expect(spaces.count == 2) // general + swim
    }

    @Test("Delete space switches to another")
    @MainActor
    func deleteSpace() throws {
        let state = try makeStateReady()
        state.createSpace(name: "temp")

        let spaces = try state.db.getAllSpaces()
        let temp = spaces.first(where: { $0.name == "temp" })!
        state.selectSpace(temp)
        state.deleteSpace(temp)

        let remaining = try state.db.getAllSpaces()
        #expect(remaining.count == 2) // general + swim
        #expect(state.currentSpace?.name == "general")
    }

    @Test("Cannot delete last space")
    @MainActor
    func cannotDeleteLastSpace() throws {
        let state = try makeStateReady()

        // Delete general; swim space remains
        let general = state.spaces.first { !$0.isSwim }!
        state.deleteSpace(general)
        #expect(try state.db.getAllSpaces().count == 1)
    }

    // MARK: - Messages

    @Test("Send message")
    @MainActor
    func sendMessage() throws {
        let state = try makeStateReady(displayName: "Gordon")

        state.sendMessage(content: "hello world")
        let messages = try state.db.getMessages(spaceId: state.currentSpace!.id)
        #expect(messages.count == 2) // welcome + hello
        #expect(messages.last?.content == "hello world")
        #expect(messages.last?.senderName == "Gordon")
        #expect(messages.last?.senderType == "human")
    }

    @Test("Empty message is not sent")
    @MainActor
    func emptyMessage() throws {
        let state = try makeStateReady()

        state.sendMessage(content: "   ")
        let messages = try state.db.getMessages(spaceId: state.currentSpace!.id)
        #expect(messages.count == 1) // only welcome
    }

    @Test("Messages are per space")
    @MainActor
    func messagesPerSpace() throws {
        let state = try makeStateReady()

        let generalId = state.currentSpace!.id
        state.sendMessage(content: "in general")

        state.createSpace(name: "other")
        let otherId = state.currentSpace!.id
        state.sendMessage(content: "in other")

        let generalMsgs = try state.db.getMessages(spaceId: generalId)
        let otherMsgs = try state.db.getMessages(spaceId: otherId)

        #expect(generalMsgs.count == 2) // welcome + "in general"
        #expect(otherMsgs.count == 1) // "in other"
    }

    // MARK: - Drafts

    @Test("Draft preserved per space")
    @MainActor
    func draftPreservation() throws {
        let state = try makeStateReady()
        state.createSpace(name: "other")

        let spaces = try state.db.getAllSpaces()
        let general = spaces.first(where: { $0.name == "general" })!
        let other = spaces.first(where: { $0.name == "other" })!

        state.selectSpace(general)
        state.saveDraft("draft in general")

        state.selectSpace(other)
        state.saveDraft("draft in other")

        state.selectSpace(general)
        #expect(state.currentDraft() == "draft in general")

        state.selectSpace(other)
        #expect(state.currentDraft() == "draft in other")
    }

    @Test("No draft returns empty string")
    @MainActor
    func noDraft() throws {
        let state = try makeStateReady()
        #expect(state.currentDraft() == "")
    }

    // MARK: - Persistence

    @Test("Data survives database query")
    @MainActor
    func persistence() throws {
        let state = try makeStateReady(displayName: "Persist")
        state.sendMessage(content: "remember me")

        let messages = try state.db.getMessages(spaceId: state.currentSpace!.id)
        let user = try state.db.getLocalUser()

        #expect(user?.displayName == "Persist")
        #expect(messages.count == 2) // welcome + message
        #expect(messages.last?.content == "remember me")
    }
}
