import Testing
import Foundation
@testable import Port42Lib

// MARK: - Phase 1a: membership-based DM resolution

@Suite("Phase 1a — findDirectSpace / getOrCreateDirectSpace")
struct DirectSpaceLookupTests {

    /// A fresh in-memory DB with one persisted owner user + one persisted companion.
    func makeDBWithCompanion(displayName: String = "Echo") throws -> (DatabaseService, AgentConfig) {
        let db = try DatabaseService(inMemory: true)
        let user = AppUser.createForTesting(displayName: "Alice")
        try db.saveUser(user)
        let companion = AgentConfig.createLLM(
            ownerId: user.id, displayName: displayName,
            systemPrompt: "hi", provider: .anthropic,
            model: "claude-opus-4-6", trigger: .mentionOnly
        )
        try db.saveAgent(companion)
        return (db, companion)
    }

    @Test("DM hit: a direct space with the companion as sole agent member is returned")
    func dmHit() throws {
        let (db, companion) = try makeDBWithCompanion()
        let space = Space(id: UUID().uuidString, name: "Echo", type: "direct",
                          createdAt: Date(), syncEnabled: false, isSwim: false)
        try db.saveSpace(space)
        try db.assignAgentToSpace(agentId: companion.id, spaceId: space.id)

        let found = try db.findDirectSpace(companionId: companion.id)
        #expect(found?.id == space.id)
    }

    @Test("Team space ignored: a team space with the companion as member is not returned")
    func teamSpaceIgnored() throws {
        let (db, companion) = try makeDBWithCompanion()
        let team = Space.create(name: "dev")  // type "team"
        try db.saveSpace(team)
        try db.assignAgentToSpace(agentId: companion.id, spaceId: team.id)

        #expect(try db.findDirectSpace(companionId: companion.id) == nil)
    }

    @Test("Two-agent direct ignored: a direct space with 2 agent members is not a 1:1 DM")
    func twoAgentDirectIgnored() throws {
        let (db, companion) = try makeDBWithCompanion()
        let other = AgentConfig.createLLM(
            ownerId: companion.ownerId, displayName: "Nova",
            systemPrompt: "hi", provider: .anthropic,
            model: "claude-opus-4-6", trigger: .mentionOnly
        )
        try db.saveAgent(other)
        let space = Space(id: UUID().uuidString, name: "pair", type: "direct",
                          createdAt: Date(), syncEnabled: false, isSwim: false)
        try db.saveSpace(space)
        try db.assignAgentToSpace(agentId: companion.id, spaceId: space.id)
        try db.assignAgentToSpace(agentId: other.id, spaceId: space.id)

        #expect(try db.findDirectSpace(companionId: companion.id) == nil)
    }

    @Test("None → nil")
    func noneReturnsNil() throws {
        let (db, companion) = try makeDBWithCompanion()
        #expect(try db.findDirectSpace(companionId: companion.id) == nil)
    }

    @Test("Dup DMs → oldest wins")
    func dupReturnsOldest() throws {
        let (db, companion) = try makeDBWithCompanion()
        let older = Space(id: "older", name: "Echo", type: "direct",
                          createdAt: Date(timeIntervalSince1970: 1000), syncEnabled: false, isSwim: false)
        let newer = Space(id: "newer", name: "Echo", type: "direct",
                          createdAt: Date(timeIntervalSince1970: 2000), syncEnabled: false, isSwim: false)
        try db.saveSpace(newer)  // insert out of order to prove ordering isn't insertion order
        try db.saveSpace(older)
        try db.assignAgentToSpace(agentId: companion.id, spaceId: older.id)
        try db.assignAgentToSpace(agentId: companion.id, spaceId: newer.id)

        #expect(try db.findDirectSpace(companionId: companion.id)?.id == "older")
    }

    @Test("getOrCreate creates once: two calls return the same space, exactly one direct space exists")
    func getOrCreateOnce() throws {
        let (db, companion) = try makeDBWithCompanion()
        let first = try db.getOrCreateDirectSpace(companion: companion)
        let second = try db.getOrCreateDirectSpace(companion: companion)

        #expect(first.id == second.id)
        #expect(first.type == "direct")
        #expect(first.isSwim == false)
        #expect(first.syncEnabled == false)

        let directs = try db.getAllSpaces().filter { $0.type == "direct" }
        #expect(directs.count == 1)
        let members = try db.getAgentsForSpace(spaceId: first.id)
        #expect(members.map(\.id) == [companion.id])
    }
}
