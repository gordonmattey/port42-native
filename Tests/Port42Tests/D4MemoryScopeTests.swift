import Testing
import Foundation
@testable import Port42Lib

// MARK: - Phase 2 (D4): relationship memory is space-scoped, not DM-pinned

@Suite("Phase 2 D4 — relationship memory follows the current space")
struct D4MemoryScopeTests {

    @MainActor
    func setup() throws -> (AppState, AgentConfig, Space) {
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
        let team = Space.create(name: "project")
        try db.saveSpace(team)
        return (state, companion, team)
    }

    @Test("crease_write stores under the current (team) space; other spaces don't see it")
    @MainActor
    func writesToCurrentSpace() async throws {
        let (state, companion, team) = try setup()
        let exec = ToolExecutor(appState: state, spaceId: team.id, createdBy: companion.id)
        _ = await exec.execute(name: "crease_write", input: ["content": "team insight"])

        let inTeam = try state.db.fetchCreases(companionId: companion.id, spaceId: team.id)
        #expect(inTeam.count == 1)
        #expect(inTeam.first?.spaceId == team.id)

        // A different space sees nothing (so it wasn't written global or to the DM).
        let other = Space.create(name: "other")
        try state.db.saveSpace(other)
        let inOther = try state.db.fetchCreases(companionId: companion.id, spaceId: other.id)
        #expect(inOther.isEmpty)
    }

    @Test("crease_read in a team space returns that space's creases, not the DM's")
    @MainActor
    func readsCurrentSpace() async throws {
        let (state, companion, team) = try setup()
        // Seed a DM crease and a team crease.
        let dm = try state.db.getOrCreateDirectSpace(companion: companion)
        try state.db.saveCrease(CompanionCrease(companionId: companion.id, spaceId: dm.id, content: "dm only"))
        try state.db.saveCrease(CompanionCrease(companionId: companion.id, spaceId: team.id, content: "team only"))

        let teamExec = ToolExecutor(appState: state, spaceId: team.id, createdBy: companion.id)
        let out = await teamExec.execute(name: "crease_read", input: [:])
        let text = (out.first?["text"] as? String) ?? ""
        #expect(text.contains("team only"))
        #expect(!text.contains("dm only"))
    }

    @Test("headless (no current space) write falls back to the companion's DM")
    @MainActor
    func headlessFallsBackToDM() async throws {
        let (state, companion, _) = try setup()
        let exec = ToolExecutor(appState: state, spaceId: nil, createdBy: companion.id)
        _ = await exec.execute(name: "crease_write", input: ["content": "dm insight"])

        let dm = try state.db.findDirectSpace(companionId: companion.id)
        #expect(dm != nil)
        let inDM = try state.db.fetchCreases(companionId: companion.id, spaceId: dm?.id)
        #expect(inDM.contains { $0.content == "dm insight" })
    }

    @Test("fold_update writes the fold to the current space")
    @MainActor
    func foldWritesCurrentSpace() async throws {
        let (state, companion, team) = try setup()
        let exec = ToolExecutor(appState: state, spaceId: team.id, createdBy: companion.id)
        _ = await exec.execute(name: "fold_update", input: ["depthDelta": 2])

        let fold = try state.db.fetchFold(companionId: companion.id, spaceId: team.id)
        #expect(fold?.depth == 2)
        // The DM has no fold from this turn.
        let dm = try state.db.getOrCreateDirectSpace(companion: companion)
        #expect(try state.db.fetchFold(companionId: companion.id, spaceId: dm.id) == nil)
    }
}
