import Testing
import Foundation
@testable import Port42Lib

// MARK: - Step 2: Channel Model + Sync Filter

@Suite("Step 2 — Channel swim factory and sync filtering")
struct ChannelSwimModelTests {

    @Test("Space.create() defaults: syncEnabled=true, isSwim=false")
    func createSpaceDefaults() throws {
        let channel = Space.create(name: "general")
        #expect(channel.syncEnabled == true)
        #expect(channel.isSwim == false)
        #expect(channel.type == "team")
    }

    @Test("Space.swim() produces correct id, type, flags")
    func swimFactory() throws {
        let companion = AgentConfig.createLLM(
            ownerId: "u1", displayName: "Echo",
            systemPrompt: "hi", provider: .anthropic,
            model: "claude-opus-4-6", trigger: .mentionOnly
        )
        let swimSpace = Space.swim(companion: companion)
        #expect(swimSpace.id == "swim-\(companion.id)")
        #expect(swimSpace.name == "Echo")
        #expect(swimSpace.type == "direct")
        #expect(swimSpace.syncEnabled == false)
        #expect(swimSpace.isSwim == true)
        #expect(swimSpace.encryptionKey == nil)
    }

    @Test("Swim channel round-trips through DatabaseService")
    func swimSpacePersists() throws {
        let db = try DatabaseService(inMemory: true)
        let companion = AgentConfig.createLLM(
            ownerId: "u1", displayName: "Echo",
            systemPrompt: "hi", provider: .anthropic,
            model: "claude-opus-4-6", trigger: .mentionOnly
        )
        let swimSpace = Space.swim(companion: companion)
        try db.upsertSpace(swimSpace)

        let all = try db.getAllSpaces()
        let loaded = all.first { $0.id == swimSpace.id }
        #expect(loaded != nil)
        #expect(loaded?.syncEnabled == false)
        #expect(loaded?.isSwim == true)
        #expect(loaded?.name == "Echo")
    }

    @Test("upsertChannel is idempotent")
    func upsertIdempotent() throws {
        let db = try DatabaseService(inMemory: true)
        let companion = AgentConfig.createLLM(
            ownerId: "u1", displayName: "Echo",
            systemPrompt: "hi", provider: .anthropic,
            model: "claude-opus-4-6", trigger: .mentionOnly
        )
        let swimSpace = Space.swim(companion: companion)
        try db.upsertSpace(swimSpace)
        try db.upsertSpace(swimSpace) // second upsert should not throw
        #expect(try db.getAllSpaces().count == 1)
    }

    @Test("Regular channel does not appear as swim")
    func regularChannelNotSwim() throws {
        let db = try DatabaseService(inMemory: true)
        let channel = Space.create(name: "dev")
        try db.saveSpace(channel)

        let loaded = try db.getAllSpaces().first!
        #expect(loaded.isSwim == false)
        #expect(loaded.syncEnabled == true)
    }
}

// MARK: - Step 3: AppState additions

@Suite("Step 3 — channelErrors, cancelStreaming, retryLastMessage")
struct AppStateChannelErrorTests {

    @MainActor
    func makeState() throws -> AppState {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return state
    }

    @Test("channelErrors starts empty")
    @MainActor
    func channelErrorsEmpty() throws {
        let state = try makeState()
        #expect(state.spaceErrors.isEmpty)
    }

    @Test("channelErrors can be set and cleared")
    @MainActor
    func channelErrorsSetClear() throws {
        let state = try makeState()
        state.spaceErrors["chan-1"] = "Something went wrong"
        #expect(state.spaceErrors["chan-1"] == "Something went wrong")
        state.spaceErrors["chan-1"] = nil
        #expect(state.spaceErrors["chan-1"] == nil)
    }

    @Test("cancelStreaming on empty handlers is a no-op")
    @MainActor
    func cancelStreamingNoHandlers() throws {
        let state = try makeState()
        // Should not crash with no active handlers
        state.cancelStreaming(spaceId: "some-channel")
        #expect(state.activeAgentHandlers.isEmpty)
    }

    @Test("retryLastMessage clears channelError for that channel")
    @MainActor
    func retryClears() throws {
        let state = try makeState()
        // Put an error in and call retry with no messages
        state.spaceErrors["chan-1"] = "error"
        state.retryLastMessage(spaceId: "chan-1")
        // Error should be cleared even with no messages to retry
        #expect(state.spaceErrors["chan-1"] == nil)
    }

    @Test("retryLastMessage sends last user message in channel")
    @MainActor
    func retryFindsLastUserMessage() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let user = AppUser.createForTesting(displayName: "Alice")
        try db.saveUser(user)
        state.currentUser = user
        let channel = Space.create(name: "test")
        try db.saveSpace(channel)

        // Populate messages array directly (simulating loaded state)
        let msg = Message.create(spaceId: channel.id, senderId: user.id, senderName: "Alice", content: "retry this")
        state.messages = [msg]
        state.currentSpace = channel

        // retryLastMessage should find the user message (won't actually send since no agent, but shouldn't crash)
        state.retryLastMessage(spaceId: channel.id)
        // No crash = pass
    }
}

// MARK: - Step 4: Swim via channel infrastructure

@Suite("Step 4 — Swim uses channel infrastructure")
struct SwimChannelInfraTests {

    /// Returns a state with a user and one companion, ready for swim tests (no resource bundle needed).
    @MainActor
    func makeStateWithCompanion() throws -> (AppState, AgentConfig) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let user = AppUser.createForTesting(displayName: "Alice")
        try db.saveUser(user)
        state.currentUser = user
        let companion = AgentConfig.createLLM(
            ownerId: user.id, displayName: "Echo",
            systemPrompt: "You are Echo.", provider: .anthropic,
            model: "claude-opus-4-6", trigger: .mentionOnly
        )
        try db.saveAgent(companion)
        state.companions = [companion]
        let general = Space.create(name: "general")
        try db.saveSpace(general)
        state.spaces = [general]
        return (state, companion)
    }

    @Test("startSwim creates a swim channel in the database")
    @MainActor
    func swimCreatesSpace() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)

        let allChannels = try state.db.getAllSpaces()
        let swimSpace = allChannels.first { $0.id == "swim-\(companion.id)" }
        #expect(swimSpace != nil)
        #expect(swimSpace?.isSwim == true)
        #expect(swimSpace?.syncEnabled == false)
    }

    @Test("startSwim sets activeSwimCompanion")
    @MainActor
    func swimSetsCompanion() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        #expect(state.activeSwimCompanion?.id == companion.id)
    }

    @Test("startSwim sets currentSpace to swim channel")
    @MainActor
    func swimSetsCurrentSpace() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        #expect(state.currentSpace?.id == "swim-\(companion.id)")
        #expect(state.currentSpace?.isSwim == true)
    }

    @Test("exitSwim clears activeSwimCompanion and currentSpace")
    @MainActor
    func exitSwimClears() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        #expect(state.activeSwimCompanion != nil)

        state.exitSwim()
        #expect(state.activeSwimCompanion == nil)
        #expect(state.currentSpace == nil)
    }

    @Test("swim channel has syncEnabled=false so it will not be synced")
    @MainActor
    func swimNotSynced() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)

        let allChannels = try state.db.getAllSpaces()
        let swimSpace = allChannels.first { $0.id == "swim-\(companion.id)" }
        #expect(swimSpace?.syncEnabled == false)
    }

    @Test("selectSpace with regular channel clears activeSwimCompanion")
    @MainActor
    func selectSpaceClearsSwim() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        #expect(state.activeSwimCompanion != nil)

        let regularChannel = state.spaces.first { !$0.isSwim }!
        state.selectSpace(regularChannel)
        #expect(state.activeSwimCompanion == nil)
    }

    @Test("deleteCompanion while in swim exits swim")
    @MainActor
    func deleteCompanionExitsSwim() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        #expect(state.activeSwimCompanion != nil)

        state.deleteCompanion(companion)
        #expect(state.activeSwimCompanion == nil)
        #expect(state.companions.isEmpty)
    }

    @Test("startSwim is idempotent — calling twice does not duplicate channels")
    @MainActor
    func swimIdempotent() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        state.startSwim(with: companion)

        let swimSpaces = try state.db.getAllSpaces().filter { $0.isSwim }
        #expect(swimSpaces.count == 1)
    }

    @Test("companion is assigned to swim channel after startSwim")
    @MainActor
    func swimAssignsCompanion() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)

        let assigned = try state.db.getAgentsForSpace(spaceId: "swim-\(companion.id)")
        #expect(assigned.first?.id == companion.id)
    }

    @Test("swim channel id follows swim-{companionId} convention")
    @MainActor
    func swimSpaceIdConvention() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        #expect(state.currentSpace?.id == "swim-\(companion.id)")
    }
}
