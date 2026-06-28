import Testing
import Foundation
import GRDB
@testable import Port42Lib

// MARK: - Phase 1b: v35 swim→direct migration (repointSpaceId + migrateLegacySwim)

@Suite("Phase 1b — swim→direct migration")
struct SwimMigrationTests {

    /// In-memory DB with one persisted owner user + one persisted companion.
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

    /// Seed a legacy swim space (`swim-<id>`, isSwim=1, type=direct) with the given member.
    func seedSwim(_ db: DatabaseService, id: String, member companionId: String?) throws {
        let swim = Space(id: id, name: "echo", type: "direct", createdAt: Date(),
                         syncEnabled: false, isSwim: true)
        try db.saveSpace(swim)
        if let companionId { try db.assignAgentToSpace(agentId: companionId, spaceId: id) }
    }

    func repoint(_ db: DatabaseService, from oldId: String, to newId: String) throws {
        try db.dbQueue.write { database in
            try DatabaseService.repointSpaceId(database, from: oldId, to: newId)
        }
    }

    func migrate(_ db: DatabaseService, oldId: String) throws {
        try db.dbQueue.write { database in
            try DatabaseService.migrateLegacySwim(database, oldId: oldId)
        }
    }

    @Test("full repoint: space + all child rows move to the new id; isSwim forced 0")
    func fullRepoint() throws {
        let (db, companion) = try makeDBWithCompanion()
        let oldId = "swim-\(companion.id)"
        try seedSwim(db, id: oldId, member: companion.id)
        try db.saveMessage(Message.create(spaceId: oldId, senderId: companion.id,
                                          senderName: "Echo", content: "hi", senderType: "agent"))
        try db.saveCrease(CompanionCrease(companionId: companion.id, spaceId: oldId, content: "c"))
        try db.saveFold(CompanionFold(companionId: companion.id, spaceId: oldId))

        try repoint(db, from: oldId, to: "NEW")

        let all = try db.getAllSpaces()
        #expect(all.contains { $0.id == "NEW" })
        #expect(!all.contains { $0.id == oldId })
        #expect(all.first { $0.id == "NEW" }?.isSwim == false)
        #expect(try db.getMessages(spaceId: "NEW").count == 1)
        #expect(try db.fetchCreases(companionId: companion.id, spaceId: "NEW").count == 1)
        #expect(try db.fetchFold(companionId: companion.id, spaceId: "NEW") != nil)
        #expect(try db.getAgentsForSpace(spaceId: "NEW").first?.id == companion.id)
    }

    @Test("FK intact: deleting the new space cascades its children")
    func fkCascadeSurvives() throws {
        let (db, companion) = try makeDBWithCompanion()
        let oldId = "swim-\(companion.id)"
        try seedSwim(db, id: oldId, member: companion.id)
        try db.saveMessage(Message.create(spaceId: oldId, senderId: companion.id,
                                          senderName: "Echo", content: "hi", senderType: "agent"))
        try repoint(db, from: oldId, to: "NEW")

        try db.deleteSpace(id: "NEW")
        #expect(try db.getMessages(spaceId: "NEW").isEmpty)
    }

    @Test("findDirectSpace resolves the companion to the repointed id")
    func resolvesPostRepoint() throws {
        let (db, companion) = try makeDBWithCompanion()
        let oldId = "swim-\(companion.id)"
        try seedSwim(db, id: oldId, member: companion.id)
        try repoint(db, from: oldId, to: "NEW")
        #expect(try db.findDirectSpace(companionId: companion.id)?.id == "NEW")
    }

    @Test("no-children swim repoints cleanly")
    func noChildren() throws {
        let (db, companion) = try makeDBWithCompanion()
        let oldId = "swim-\(companion.id)"
        try seedSwim(db, id: oldId, member: companion.id)
        try repoint(db, from: oldId, to: "NEW")
        #expect(try db.getAllSpaces().contains { $0.id == "NEW" })
        #expect(try db.getMessages(spaceId: "NEW").isEmpty)
    }

    @Test("migrateLegacySwim drops a dead swim (no member + agent gone)")
    func dropsDeadSwim() throws {
        let db = try DatabaseService(inMemory: true)
        // Swim whose embedded companion never existed and has no membership.
        try seedSwim(db, id: "swim-GHOST", member: nil)
        try db.saveMessage(Message.create(spaceId: "swim-GHOST", senderId: "x",
                                          senderName: "x", content: "orphan"))

        try migrate(db, oldId: "swim-GHOST")

        #expect(try db.getAllSpaces().isEmpty)                 // dropped, not repointed
        #expect(try db.getMessages(spaceId: "swim-GHOST").isEmpty) // cascaded
        #expect(try db.findDirectSpace(companionId: "GHOST") == nil)
    }

    @Test("migrateLegacySwim backfills membership when the embedded agent still exists")
    func backfillsMembership() throws {
        let (db, companion) = try makeDBWithCompanion()
        // Legacy swim with the embedded id but NO agentSpaces row.
        try seedSwim(db, id: "swim-\(companion.id)", member: nil)

        try migrate(db, oldId: "swim-\(companion.id)")

        // Repointed to a UUID, resolvable by membership, no swim- id left.
        let resolved = try db.findDirectSpace(companionId: companion.id)
        #expect(resolved != nil)
        #expect(resolved?.id.hasPrefix("swim-") == false)
        #expect(try db.getAllSpaces().contains { $0.id.hasPrefix("swim-") } == false)
    }

    @Test("migrateLegacySwim repoints a healthy swim to a UUID direct space")
    func repointsHealthy() throws {
        let (db, companion) = try makeDBWithCompanion()
        try seedSwim(db, id: "swim-\(companion.id)", member: companion.id)

        try migrate(db, oldId: "swim-\(companion.id)")

        let resolved = try db.findDirectSpace(companionId: companion.id)
        #expect(resolved?.type == "direct")
        #expect(resolved?.isSwim == false)
        #expect(resolved?.id.hasPrefix("swim-") == false)
    }
}
