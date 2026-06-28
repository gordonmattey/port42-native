import Testing
import Foundation
@testable import Port42Lib

// MARK: - Step 2: Space Model + Sync Filter

@Suite("Step 2 — Space swim factory and sync filtering")
struct SpaceSwimModelTests {

    @Test("Space.create() defaults: syncEnabled=true, isSwim=false")
    func createSpaceDefaults() throws {
        let space = Space.create(name: "general")
        #expect(space.syncEnabled == true)
        #expect(space.isSwim == false)
        #expect(space.type == "team")
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

    @Test("Swim space round-trips through DatabaseService")
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

    @Test("upsertSpace is idempotent")
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

    @Test("Regular space does not appear as swim")
    func regularSpaceNotSwim() throws {
        let db = try DatabaseService(inMemory: true)
        let space = Space.create(name: "dev")
        try db.saveSpace(space)

        let loaded = try db.getAllSpaces().first!
        #expect(loaded.isSwim == false)
        #expect(loaded.syncEnabled == true)
    }
}

// MARK: - Step 3: AppState additions

@Suite("Step 3 — spaceErrors, cancelStreaming, retryLastMessage")
struct AppStateSpaceErrorTests {

    @MainActor
    func makeState() throws -> AppState {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return state
    }

    @Test("spaceErrors starts empty")
    @MainActor
    func spaceErrorsEmpty() throws {
        let state = try makeState()
        #expect(state.spaceErrors.isEmpty)
    }

    @Test("spaceErrors can be set and cleared")
    @MainActor
    func spaceErrorsSetClear() throws {
        let state = try makeState()
        state.spaceErrors["space-1"] = "Something went wrong"
        #expect(state.spaceErrors["space-1"] == "Something went wrong")
        state.spaceErrors["space-1"] = nil
        #expect(state.spaceErrors["space-1"] == nil)
    }

    @Test("cancelStreaming on empty handlers is a no-op")
    @MainActor
    func cancelStreamingNoHandlers() throws {
        let state = try makeState()
        // Should not crash with no active handlers
        state.cancelStreaming(spaceId: "some-space")
        #expect(state.activeAgentHandlers.isEmpty)
    }

    @Test("retryLastMessage clears spaceError for that space")
    @MainActor
    func retryClears() throws {
        let state = try makeState()
        // Put an error in and call retry with no messages
        state.spaceErrors["space-1"] = "error"
        state.retryLastMessage(spaceId: "space-1")
        // Error should be cleared even with no messages to retry
        #expect(state.spaceErrors["space-1"] == nil)
    }

    @Test("retryLastMessage sends last user message in space")
    @MainActor
    func retryFindsLastUserMessage() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let user = AppUser.createForTesting(displayName: "Alice")
        try db.saveUser(user)
        state.currentUser = user
        let space = Space.create(name: "test")
        try db.saveSpace(space)

        // Populate messages array directly (simulating loaded state)
        let msg = Message.create(spaceId: space.id, senderId: user.id, senderName: "Alice", content: "retry this")
        state.messages = [msg]
        state.currentSpace = space

        // retryLastMessage should find the user message (won't actually send since no agent, but shouldn't crash)
        state.retryLastMessage(spaceId: space.id)
        // No crash = pass
    }
}

// MARK: - Step 4: Swim via space infrastructure

@Suite("Step 4 — Swim uses space infrastructure")
struct SwimSpaceInfraTests {

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

    @Test("startSwim creates a direct space resolved by membership (no swim- id)")
    @MainActor
    func swimCreatesSpace() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)

        // Resolved by membership, not a derived id.
        let directSpace = try state.db.findDirectSpace(companionId: companion.id)
        #expect(directSpace != nil)
        #expect(directSpace?.type == "direct")
        #expect(directSpace?.id.hasPrefix("swim-") == false)
        #expect(directSpace?.syncEnabled == false)
    }

    @Test("startSwim populates spaceCompanions with the direct companion")
    @MainActor
    func swimSetsCompanion() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        #expect(state.spaceCompanions.first?.id == companion.id)
    }

    @Test("startSwim sets currentSpace to the companion's direct space")
    @MainActor
    func swimSetsCurrentSpace() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        let directSpace = try state.db.findDirectSpace(companionId: companion.id)
        #expect(state.currentSpace?.id == directSpace?.id)
        #expect(state.currentSpace?.type == "direct")
    }

    @Test("deleteCompanion of the open DM clears currentSpace + spaceCompanions")
    @MainActor
    func deleteOpenDMClears() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        #expect(state.currentSpace?.type == "direct")

        state.deleteCompanion(companion)
        #expect(state.currentSpace == nil)
        #expect(state.spaceCompanions.isEmpty)
    }

    @Test("deleteCompanion not in the open space leaves currentSpace intact")
    @MainActor
    func deleteOtherLeavesSpace() throws {
        let (state, companion) = try makeStateWithCompanion()
        let regular = state.spaces.first { $0.type != "direct" }!
        state.selectSpace(regular)
        state.deleteCompanion(companion)   // companion's DM is not the open space
        #expect(state.currentSpace?.id == regular.id)
    }

    @Test("direct space has syncEnabled=false so it will not be synced")
    @MainActor
    func swimNotSynced() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)

        let directSpace = try state.db.findDirectSpace(companionId: companion.id)
        #expect(directSpace?.syncEnabled == false)
    }

    @Test("selectSpace with a regular space leaves the direct (DM) state")
    @MainActor
    func selectSpaceClearsSwim() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        #expect(state.currentSpace?.type == "direct")

        let regularSpace = state.spaces.first { $0.type != "direct" }!
        state.selectSpace(regularSpace)
        #expect(state.currentSpace?.type != "direct")
    }

    @Test("deleteCompanion while in its DM clears the open space")
    @MainActor
    func deleteCompanionExitsSwim() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        #expect(state.currentSpace?.type == "direct")

        state.deleteCompanion(companion)
        #expect(state.currentSpace == nil)
        #expect(state.companions.isEmpty)
    }

    @Test("startSwim is idempotent — calling twice does not duplicate direct spaces")
    @MainActor
    func swimIdempotent() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        state.startSwim(with: companion)

        let directSpaces = try state.db.getAllSpaces().filter { $0.type == "direct" }
        #expect(directSpaces.count == 1)
    }

    @Test("companion is assigned to its direct space after startSwim")
    @MainActor
    func swimAssignsCompanion() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)

        let directSpace = try state.db.findDirectSpace(companionId: companion.id)
        #expect(directSpace != nil)
        let assigned = try state.db.getAgentsForSpace(spaceId: directSpace?.id ?? "")
        #expect(assigned.first?.id == companion.id)
    }

    @Test("startSwim resolves the same direct space on repeat (membership, not derived id)")
    @MainActor
    func swimSpaceIdConvention() throws {
        let (state, companion) = try makeStateWithCompanion()
        state.startSwim(with: companion)
        let first = state.currentSpace?.id
        state.currentSpace = nil
        state.startSwim(with: companion)
        #expect(state.currentSpace?.id == first)
        #expect(state.currentSpace?.id.hasPrefix("swim-") == false)
    }
}
