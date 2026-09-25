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
        let general = state.spaces.first { $0.type != "direct" }!
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

    /// The first run is a terminal (nautilus Phase 1 step 3): setup makes genesis, puts Echo in it as a
    /// command companion on the CLI the person chose, and spawns Echo's terminal for the shell to focus.
    @Test("Complete setup makes genesis and Echo as a command companion on the chosen CLI")
    @MainActor
    func completeSetup() throws {
        let state = try makeStateWithUser(displayName: "Gordon")
        state.completeSetup(displayName: "Gordon", cli: "codex")

        #expect(state.isSetupComplete == false, "the shell's hand-off completes setup, not this")
        #expect(state.currentSpace?.name == "genesis")
        #expect(state.currentSpace?.type != "direct", "no direct messages: genesis is an ordinary space")

        #expect(state.companions.count == 1)
        let echo = try #require(state.companions.first)
        #expect(echo.displayName == "echo")
        #expect(echo.mode == .command)
        #expect(echo.command == "codex")
        #expect(echo.openInTerminal)
        #expect(echo.systemPrompt?.contains("Gordon") == true, "the brief is personalised")
        #expect(state.spaceCompanions.first?.displayName == "echo")
        #expect(state.onboardingFocusPortId != nil, "Echo's terminal exists for the shell to focus")
    }

    // MARK: - Spaces

    @Test("Create space")
    @MainActor
    func createSpace() throws {
        let state = try makeStateReady()

        state.createSpace(name: "Builders Club")

        let spaces = try state.db.getAllSpaces()
        // genesis + builders-club
        #expect(spaces.count == 2)
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
        #expect(spaces.count == 1) // genesis
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
        #expect(remaining.count == 1) // genesis
        #expect(state.currentSpace?.name == "genesis")
    }

    @Test("Deleting the last space recreates a home general")
    @MainActor
    func deletingLastTeamSpaceRecreatesGeneral() throws {
        let state = try makeStateReady()

        // Delete the only space (genesis). deleteSpace recreates a fresh "general" so there is always
        // a home world, and we land on it.
        let only = state.spaces.first { $0.type != "direct" }!
        state.deleteSpace(only)

        let all = try state.db.getAllSpaces()
        #expect(all.count == 1)                        // a freshly created general
        #expect(all.contains { $0.type != "direct" })  // a regular/home space exists again
        #expect(state.currentSpace?.type != "direct")  // landed on the home space, not the DM
    }

    // MARK: - Messages

    // MARK: - Drafts

    @Test("Draft preserved per space")
    @MainActor
    func draftPreservation() throws {
        let state = try makeStateReady()
        state.createSpace(name: "other")

        let spaces = try state.db.getAllSpaces()
        let general = spaces.first(where: { $0.name == "genesis" })!
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
        let user = try state.db.getLocalUser()

        #expect(user?.displayName == "Persist")
    }
}
