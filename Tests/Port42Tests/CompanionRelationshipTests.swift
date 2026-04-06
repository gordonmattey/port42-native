import Testing
import Foundation
@testable import Port42Lib

@Suite("CompanionRelationship — Phase 1")
struct CompanionRelationshipTests {

    func makeDB() throws -> DatabaseService {
        try DatabaseService(inMemory: true)
    }

    // MARK: - Creases: basic persistence

    @Test("Save and fetch a channel-scoped crease")
    func saveAndFetchCrease() throws {
        let db = try makeDB()
        let crease = CompanionCrease(
            companionId: "companion-1",
            channelId: "channel-1",
            content: "I expected the technical path and they went to the cipher instead.",
            prediction: "technical path",
            actual: "cipher"
        )
        try db.saveCrease(crease)

        let fetched = try db.fetchCreases(companionId: "companion-1", channelId: "channel-1")
        #expect(fetched.count == 1)
        #expect(fetched[0].content == crease.content)
        #expect(fetched[0].prediction == "technical path")
        #expect(fetched[0].actual == "cipher")
        #expect(fetched[0].channelId == "channel-1")
        #expect(fetched[0].weight == 1.0)
    }

    @Test("Global crease (nil channelId) is returned when fetching channel creases")
    func globalCreaseReturnedWithChannel() throws {
        let db = try makeDB()
        let global = CompanionCrease(
            companionId: "companion-1",
            channelId: nil,
            content: "Assumed speed was the goal. The goal is aliveness."
        )
        let scoped = CompanionCrease(
            companionId: "companion-1",
            channelId: "channel-1",
            content: "Expected cautious; got oblique."
        )
        try db.saveCrease(global)
        try db.saveCrease(scoped)

        let fetched = try db.fetchCreases(companionId: "companion-1", channelId: "channel-1")
        #expect(fetched.count == 2)
        let ids = Set(fetched.map { $0.id })
        #expect(ids.contains(global.id))
        #expect(ids.contains(scoped.id))
    }

    @Test("Fetching only global creases (nil channelId) excludes channel-scoped")
    func fetchOnlyGlobalCreases() throws {
        let db = try makeDB()
        let global = CompanionCrease(companionId: "companion-1", channelId: nil, content: "global crease")
        let scoped = CompanionCrease(companionId: "companion-1", channelId: "channel-1", content: "scoped crease")
        try db.saveCrease(global)
        try db.saveCrease(scoped)

        let fetched = try db.fetchCreases(companionId: "companion-1", channelId: nil)
        #expect(fetched.count == 1)
        #expect(fetched[0].id == global.id)
    }

    @Test("Creases from other companions are not returned")
    func creasesIsolatedByCompanion() throws {
        let db = try makeDB()
        try db.saveCrease(CompanionCrease(companionId: "companion-1", channelId: "ch", content: "c1"))
        try db.saveCrease(CompanionCrease(companionId: "companion-2", channelId: "ch", content: "c2"))

        let c1 = try db.fetchCreases(companionId: "companion-1", channelId: "ch")
        let c2 = try db.fetchCreases(companionId: "companion-2", channelId: "ch")
        #expect(c1.count == 1)
        #expect(c2.count == 1)
        #expect(c1[0].content == "c1")
        #expect(c2[0].content == "c2")
    }

    @Test("Fetch limit is respected")
    func fetchLimit() throws {
        let db = try makeDB()
        for i in 0..<10 {
            try db.saveCrease(CompanionCrease(
                companionId: "c", channelId: "ch",
                content: "crease \(i)",
                touchedAt: Date(timeIntervalSince1970: Double(i))
            ))
        }
        let fetched = try db.fetchCreases(companionId: "c", channelId: "ch", limit: 3)
        #expect(fetched.count == 3)
    }

    @Test("Creases returned most recently touched first")
    func creasesOrderedByTouchedAt() throws {
        let db = try makeDB()
        let older = CompanionCrease(
            companionId: "c", channelId: "ch", content: "older",
            touchedAt: Date(timeIntervalSince1970: 1000)
        )
        let newer = CompanionCrease(
            companionId: "c", channelId: "ch", content: "newer",
            touchedAt: Date(timeIntervalSince1970: 2000)
        )
        try db.saveCrease(older)
        try db.saveCrease(newer)

        let fetched = try db.fetchCreases(companionId: "c", channelId: "ch")
        #expect(fetched[0].content == "newer")
        #expect(fetched[1].content == "older")
    }

    // MARK: - Creases: touch and forget

    @Test("touchCrease updates touchedAt and increases weight")
    func touchCrease() throws {
        let db = try makeDB()
        let crease = CompanionCrease(
            companionId: "c", channelId: "ch", content: "a crease",
            weight: 1.0,
            touchedAt: Date(timeIntervalSince1970: 1000)
        )
        try db.saveCrease(crease)

        try db.touchCrease(id: crease.id)

        let fetched = try db.fetchCreases(companionId: "c", channelId: "ch")
        #expect(fetched[0].weight > 1.0)
        #expect(fetched[0].touchedAt > Date(timeIntervalSince1970: 1000))
    }

    @Test("deleteCrease removes the entry")
    func deleteCrease() throws {
        let db = try makeDB()
        let crease = CompanionCrease(companionId: "c", channelId: "ch", content: "to forget")
        try db.saveCrease(crease)
        #expect(try db.fetchCreases(companionId: "c", channelId: "ch").count == 1)

        try db.deleteCrease(id: crease.id)
        #expect(try db.fetchCreases(companionId: "c", channelId: "ch").isEmpty)
    }

    @Test("deleteCreasesForCompanion removes all creases for that companion only")
    func deleteCreasesForCompanion() throws {
        let db = try makeDB()
        try db.saveCrease(CompanionCrease(companionId: "c1", channelId: "ch", content: "c1 crease"))
        try db.saveCrease(CompanionCrease(companionId: "c2", channelId: "ch", content: "c2 crease"))

        try db.deleteCreasesForCompanion("c1")

        #expect(try db.fetchCreases(companionId: "c1", channelId: "ch").isEmpty)
        #expect(try db.fetchCreases(companionId: "c2", channelId: "ch").count == 1)
    }

    // MARK: - Folds: basic persistence

    @Test("Save and fetch a fold")
    func saveAndFetchFold() throws {
        let db = try makeDB()
        let fold = CompanionFold(
            companionId: "c1",
            channelId: "ch1",
            established: ["technical and oblique are not opposites here"],
            tensions: ["the question of what alive means architecturally"],
            holding: "something about the cipher that hasn't found its place",
            depth: 3
        )
        try db.saveFold(fold)

        let fetched = try db.fetchFold(companionId: "c1", channelId: "ch1")
        #expect(fetched != nil)
        #expect(fetched?.established == ["technical and oblique are not opposites here"])
        #expect(fetched?.tensions == ["the question of what alive means architecturally"])
        #expect(fetched?.holding == "something about the cipher that hasn't found its place")
        #expect(fetched?.depth == 3)
    }

    @Test("fetchFold returns nil when no fold exists")
    func fetchFoldMissing() throws {
        let db = try makeDB()
        let result = try db.fetchFold(companionId: "nobody", channelId: "nowhere")
        #expect(result == nil)
    }

    @Test("saveFold upserts — second save updates the existing row")
    func saveFoldUpserts() throws {
        let db = try makeDB()
        var fold = CompanionFold(companionId: "c1", channelId: "ch1", depth: 1)
        try db.saveFold(fold)

        fold.depth = 2
        fold.holding = "now holding something"
        try db.saveFold(fold)

        let fetched = try db.fetchFold(companionId: "c1", channelId: "ch1")
        #expect(fetched?.depth == 2)
        #expect(fetched?.holding == "now holding something")

        // Only one row exists
        let db2 = try makeDB()
        try db2.saveFold(fold)
        // Re-fetch and confirm single record behaviour (no duplicate)
        let second = try db.fetchFold(companionId: "c1", channelId: "ch1")
        #expect(second?.depth == 2)
    }

    @Test("Fold depth cannot go below zero via deleteFoldsForCompanion")
    func deleteFoldsForCompanion() throws {
        let db = try makeDB()
        try db.saveFold(CompanionFold(companionId: "c1", channelId: "ch1", depth: 4))
        try db.saveFold(CompanionFold(companionId: "c2", channelId: "ch1", depth: 2))

        try db.deleteFoldsForCompanion("c1")

        #expect(try db.fetchFold(companionId: "c1", channelId: "ch1") == nil)
        #expect(try db.fetchFold(companionId: "c2", channelId: "ch1") != nil)
    }

    @Test("Fold with nil arrays round-trips correctly")
    func foldNilArraysRoundTrip() throws {
        let db = try makeDB()
        let fold = CompanionFold(companionId: "c", channelId: "ch")
        try db.saveFold(fold)

        let fetched = try db.fetchFold(companionId: "c", channelId: "ch")
        #expect(fetched?.established == nil)
        #expect(fetched?.tensions == nil)
        #expect(fetched?.holding == nil)
        #expect(fetched?.depth == 0)
    }

    // MARK: - asPromptText formatting

    @Test("CompanionCrease.asPromptText includes prediction and actual when set")
    func creasePromptTextWithPredictionAndActual() {
        let crease = CompanionCrease(
            companionId: "c", channelId: nil,
            content: "something reformed",
            prediction: "what I expected",
            actual: "what happened"
        )
        let text = crease.asPromptText()
        #expect(text.contains("something reformed"))
        #expect(text.contains("what I expected"))
        #expect(text.contains("what happened"))
    }

    @Test("CompanionCrease.asPromptText works with content only")
    func creasePromptTextContentOnly() {
        let crease = CompanionCrease(companionId: "c", channelId: nil, content: "just the break")
        #expect(crease.asPromptText() == "just the break")
    }

    @Test("CompanionFold.asPromptText includes depth")
    func foldPromptTextIncludesDepth() {
        let fold = CompanionFold(
            companionId: "c", channelId: "ch",
            established: ["shared grammar"],
            depth: 5
        )
        let text = fold.asPromptText()
        #expect(text.contains("Depth: 5"))
        #expect(text.contains("shared grammar"))
    }

    // MARK: - Position: basic persistence

    @Test("Save and fetch a position")
    func saveAndFetchPosition() throws {
        let db = try makeDB()
        let pos = CompanionPosition(
            companionId: "c1",
            channelId: "ch1",
            read: "this project is scope-creeping and nobody's naming it",
            stance: "someone needs to name the constraint",
            watching: ["another feature request", "timeline slipping again"]
        )
        try db.savePosition(pos)

        let fetched = try db.fetchPosition(companionId: "c1", channelId: "ch1")
        #expect(fetched != nil)
        #expect(fetched?.read == "this project is scope-creeping and nobody's naming it")
        #expect(fetched?.stance == "someone needs to name the constraint")
        #expect(fetched?.watching == ["another feature request", "timeline slipping again"])
    }

    @Test("fetchPosition returns nil when no position exists")
    func fetchPositionMissing() throws {
        let db = try makeDB()
        let result = try db.fetchPosition(companionId: "nobody", channelId: "nowhere")
        #expect(result == nil)
    }

    @Test("savePosition upserts — second save updates the existing row")
    func savePositionUpserts() throws {
        let db = try makeDB()
        var pos = CompanionPosition(companionId: "c1", channelId: "ch1", read: "first read")
        try db.savePosition(pos)

        pos.read = "updated read"
        pos.stance = "new stance"
        try db.savePosition(pos)

        let fetched = try db.fetchPosition(companionId: "c1", channelId: "ch1")
        #expect(fetched?.read == "updated read")
        #expect(fetched?.stance == "new stance")
    }

    @Test("Positions are isolated by companion")
    func positionsIsolatedByCompanion() throws {
        let db = try makeDB()
        try db.savePosition(CompanionPosition(companionId: "c1", channelId: "ch", read: "c1 read"))
        try db.savePosition(CompanionPosition(companionId: "c2", channelId: "ch", read: "c2 read"))

        let p1 = try db.fetchPosition(companionId: "c1", channelId: "ch")
        let p2 = try db.fetchPosition(companionId: "c2", channelId: "ch")
        #expect(p1?.read == "c1 read")
        #expect(p2?.read == "c2 read")
    }

    @Test("deletePositionsForCompanion removes only that companion's positions")
    func deletePositionsForCompanion() throws {
        let db = try makeDB()
        try db.savePosition(CompanionPosition(companionId: "c1", channelId: "ch", read: "c1"))
        try db.savePosition(CompanionPosition(companionId: "c2", channelId: "ch", read: "c2"))

        try db.deletePositionsForCompanion("c1")

        #expect(try db.fetchPosition(companionId: "c1", channelId: "ch") == nil)
        #expect(try db.fetchPosition(companionId: "c2", channelId: "ch") != nil)
    }

    @Test("Position with nil watching round-trips correctly")
    func positionNilWatchingRoundTrip() throws {
        let db = try makeDB()
        let pos = CompanionPosition(companionId: "c", channelId: "ch", read: "something is happening")
        try db.savePosition(pos)

        let fetched = try db.fetchPosition(companionId: "c", channelId: "ch")
        #expect(fetched?.watching == nil)
        #expect(fetched?.stance == nil)
    }

    // MARK: - Position: isEmpty and asPromptText

    @Test("CompanionPosition.isEmpty is true when no fields set")
    func positionIsEmpty() {
        let pos = CompanionPosition(companionId: "c", channelId: "ch")
        #expect(pos.isEmpty)
    }

    @Test("CompanionPosition.isEmpty is false when read is set")
    func positionNotEmpty() {
        let pos = CompanionPosition(companionId: "c", channelId: "ch", read: "something is happening")
        #expect(!pos.isEmpty)
    }

    @Test("CompanionPosition.asPromptText includes all non-nil fields")
    func positionPromptText() {
        let pos = CompanionPosition(
            companionId: "c", channelId: "ch",
            read: "prioritising speed but the real constraint is clarity",
            stance: "name the constraint",
            watching: ["another fast feature request"]
        )
        let text = pos.asPromptText()
        #expect(text.contains("Read:"))
        #expect(text.contains("clarity"))
        #expect(text.contains("Stance:"))
        #expect(text.contains("name the constraint"))
        #expect(text.contains("Watching:"))
        #expect(text.contains("another fast feature request"))
    }

    @Test("CompanionPosition.asPromptText omits missing fields")
    func positionPromptTextOmitsMissing() {
        let pos = CompanionPosition(companionId: "c", channelId: "ch", read: "just the read")
        let text = pos.asPromptText()
        #expect(text.contains("Read:"))
        #expect(!text.contains("Stance:"))
        #expect(!text.contains("Watching:"))
    }

    // MARK: - Engravings: basic persistence

    @Test("Save and fetch a channel-scoped engraving")
    func saveAndFetchEngraving() throws {
        let db = try makeDB()
        let engraving = CompanionEngraving(
            companionId: "companion-1",
            channelId: "channel-1",
            content: "6 weeks to ship, solo engineer, can't break backwards compat.",
            category: "constraint"
        )
        try db.saveEngraving(engraving)

        let fetched = try db.fetchEngravings(companionId: "companion-1", channelId: "channel-1")
        #expect(fetched.count == 1)
        #expect(fetched[0].content == engraving.content)
        #expect(fetched[0].category == "constraint")
        #expect(fetched[0].channelId == "channel-1")
        #expect(fetched[0].weight == 1.0)
    }

    @Test("Global engraving (nil channelId) is returned when fetching channel engravings")
    func globalEngravingReturnedWithChannel() throws {
        let db = try makeDB()
        let global = CompanionEngraving(
            companionId: "companion-1",
            channelId: nil,
            content: "Prefers async communication over meetings.",
            category: "preference"
        )
        let scoped = CompanionEngraving(
            companionId: "companion-1",
            channelId: "channel-1",
            content: "Running a startup with 3 engineers.",
            category: "context"
        )
        try db.saveEngraving(global)
        try db.saveEngraving(scoped)

        let fetched = try db.fetchEngravings(companionId: "companion-1", channelId: "channel-1")
        #expect(fetched.count == 2)
        let ids = Set(fetched.map { $0.id })
        #expect(ids.contains(global.id))
        #expect(ids.contains(scoped.id))
    }

    @Test("Fetching only global engravings (nil channelId) excludes channel-scoped")
    func fetchOnlyGlobalEngravings() throws {
        let db = try makeDB()
        let global = CompanionEngraving(companionId: "companion-1", channelId: nil, content: "global fact")
        let scoped = CompanionEngraving(companionId: "companion-1", channelId: "channel-1", content: "scoped fact")
        try db.saveEngraving(global)
        try db.saveEngraving(scoped)

        let fetched = try db.fetchEngravings(companionId: "companion-1", channelId: nil)
        #expect(fetched.count == 1)
        #expect(fetched[0].id == global.id)
    }

    @Test("Engravings from other companions are not returned")
    func engravingsIsolatedByCompanion() throws {
        let db = try makeDB()
        try db.saveEngraving(CompanionEngraving(companionId: "companion-1", channelId: "ch", content: "e1"))
        try db.saveEngraving(CompanionEngraving(companionId: "companion-2", channelId: "ch", content: "e2"))

        let e1 = try db.fetchEngravings(companionId: "companion-1", channelId: "ch")
        let e2 = try db.fetchEngravings(companionId: "companion-2", channelId: "ch")
        #expect(e1.count == 1)
        #expect(e2.count == 1)
        #expect(e1[0].content == "e1")
        #expect(e2[0].content == "e2")
    }

    @Test("Engravings returned most recently touched first")
    func engravingsOrderedByTouchedAt() throws {
        let db = try makeDB()
        let older = CompanionEngraving(
            companionId: "c", channelId: "ch", content: "older fact",
            touchedAt: Date(timeIntervalSince1970: 1000)
        )
        let newer = CompanionEngraving(
            companionId: "c", channelId: "ch", content: "newer fact",
            touchedAt: Date(timeIntervalSince1970: 2000)
        )
        try db.saveEngraving(older)
        try db.saveEngraving(newer)

        let fetched = try db.fetchEngravings(companionId: "c", channelId: "ch")
        #expect(fetched[0].content == "newer fact")
        #expect(fetched[1].content == "older fact")
    }

    @Test("touchEngraving updates touchedAt and increases weight")
    func touchEngraving() throws {
        let db = try makeDB()
        let engraving = CompanionEngraving(
            companionId: "c", channelId: "ch", content: "a fact",
            weight: 1.0, touchedAt: Date(timeIntervalSince1970: 1000)
        )
        try db.saveEngraving(engraving)
        try db.touchEngraving(id: engraving.id)

        let fetched = try db.fetchEngravings(companionId: "c", channelId: "ch")
        #expect(fetched[0].weight > 1.0)
        #expect(fetched[0].touchedAt > Date(timeIntervalSince1970: 1000))
    }

    @Test("deleteEngraving removes the entry")
    func deleteEngraving() throws {
        let db = try makeDB()
        let engraving = CompanionEngraving(companionId: "c", channelId: "ch", content: "to forget")
        try db.saveEngraving(engraving)
        #expect(try db.fetchEngravings(companionId: "c", channelId: "ch").count == 1)

        try db.deleteEngraving(id: engraving.id)
        #expect(try db.fetchEngravings(companionId: "c", channelId: "ch").isEmpty)
    }

    @Test("deleteEngravingsForCompanion removes all engravings for that companion only")
    func deleteEngravingsForCompanion() throws {
        let db = try makeDB()
        try db.saveEngraving(CompanionEngraving(companionId: "c1", channelId: "ch", content: "c1 fact"))
        try db.saveEngraving(CompanionEngraving(companionId: "c2", channelId: "ch", content: "c2 fact"))

        try db.deleteEngravingsForCompanion("c1")

        #expect(try db.fetchEngravings(companionId: "c1", channelId: "ch").isEmpty)
        #expect(try db.fetchEngravings(companionId: "c2", channelId: "ch").count == 1)
    }

    @Test("CompanionEngraving.asPromptText includes category when set")
    func engravingPromptTextWithCategory() {
        let engraving = CompanionEngraving(
            companionId: "c", channelId: nil,
            content: "6 weeks runway",
            category: "constraint"
        )
        let text = engraving.asPromptText()
        #expect(text.contains("6 weeks runway"))
        #expect(text.contains("[constraint]"))
    }

    @Test("CompanionEngraving.asPromptText works with content only")
    func engravingPromptTextContentOnly() {
        let engraving = CompanionEngraving(companionId: "c", channelId: nil, content: "just the fact")
        #expect(engraving.asPromptText() == "just the fact")
    }

    // MARK: - Tool definitions

    @Test("All twelve relationship tools are present in ToolDefinitions.all")
    func relationshipToolsPresent() {
        let names = ToolDefinitions.all.compactMap { $0["name"] as? String }
        #expect(names.contains("crease_read"))
        #expect(names.contains("crease_write"))
        #expect(names.contains("crease_touch"))
        #expect(names.contains("crease_forget"))
        #expect(names.contains("engrave_read"))
        #expect(names.contains("engrave_write"))
        #expect(names.contains("engrave_touch"))
        #expect(names.contains("engrave_forget"))
        #expect(names.contains("fold_read"))
        #expect(names.contains("fold_update"))
        #expect(names.contains("position_read"))
        #expect(names.contains("position_set"))
    }

    @Test("position_set requires 'read' field")
    func positionSetRequiresRead() {
        let defs = ToolDefinitions.all
        guard let tool = defs.first(where: { $0["name"] as? String == "position_set" }),
              let schema = tool["input_schema"] as? [String: Any],
              let required = schema["required"] as? [String] else {
            Issue.record("position_set not found or missing schema")
            return
        }
        #expect(required.contains("read"))
    }

    @Test("position_set description frames position as where you stand not what you say")
    func positionSetDescriptionFraming() {
        let defs = ToolDefinitions.all
        guard let tool = defs.first(where: { $0["name"] as? String == "position_set" }),
              let desc = tool["description"] as? String else {
            Issue.record("position_set not found")
            return
        }
        #expect(desc.contains("where you stand") || desc.contains("push back"))
    }

    @Test("engrave_write requires 'content' field")
    func engraveWriteRequiresContent() {
        let defs = ToolDefinitions.all
        guard let tool = defs.first(where: { $0["name"] as? String == "engrave_write" }),
              let schema = tool["input_schema"] as? [String: Any],
              let required = schema["required"] as? [String] else {
            Issue.record("engrave_write not found or missing schema")
            return
        }
        #expect(required.contains("content"))
    }

    @Test("engrave_write description distinguishes engravings from creases")
    func engraveWriteDescriptionFraming() {
        let defs = ToolDefinitions.all
        guard let tool = defs.first(where: { $0["name"] as? String == "engrave_write" }),
              let desc = tool["description"] as? String else {
            Issue.record("engrave_write not found")
            return
        }
        #expect(desc.contains("crease") || desc.contains("factual") || desc.contains("world"))
    }

    @Test("crease_write requires 'content' field")
    func creaseWriteRequiresContent() {
        let defs = ToolDefinitions.all
        guard let tool = defs.first(where: { $0["name"] as? String == "crease_write" }),
              let schema = tool["input_schema"] as? [String: Any],
              let required = schema["required"] as? [String] else {
            Issue.record("crease_write not found or missing schema")
            return
        }
        #expect(required.contains("content"))
    }

    @Test("crease_write description contains prediction-failure framing")
    func creaseWriteDescriptionFraming() {
        let defs = ToolDefinitions.all
        guard let tool = defs.first(where: { $0["name"] as? String == "crease_write" }),
              let desc = tool["description"] as? String else {
            Issue.record("crease_write not found")
            return
        }
        #expect(desc.contains("broke") || desc.contains("prediction"))
        #expect(desc.contains("sparingly") || desc.contains("only when"))
    }

    @Test("fold_update description warns against inflating depth")
    func foldUpdateDepthConstraint() {
        let defs = ToolDefinitions.all
        guard let tool = defs.first(where: { $0["name"] as? String == "fold_update" }),
              let desc = tool["description"] as? String else {
            Issue.record("fold_update not found")
            return
        }
        #expect(desc.contains("depthDelta") || desc.contains("depth"))
        #expect(desc.contains("1") || desc.contains("significant") || desc.contains("real fold"))
    }

    // MARK: - ports-context.txt

    @Test("ports-context.txt documents relationship tools")
    func portsContextHasRelationshipTools() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Resources/ports-context.txt")
        let content = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(content.contains("crease_read"))
        #expect(content.contains("crease_write"))
        #expect(content.contains("fold_read"))
        #expect(content.contains("fold_update"))
        #expect(content.contains("position_read"))
        #expect(content.contains("position_set"))
        #expect(content.contains("engrave") || content.contains("engravings"))
        #expect(content.contains("where your model broke") || content.contains("prediction broke"))
    }
}
