import Testing
import Foundation
@testable import Port42Lib

// Phase 1, batch 1: the relationship-memory family (crease / engrave / fold / position). Each test
// proves the registry body matches `ToolExecutor` — the read shape on identical seeded data, the
// write side effect, and the error text. Tool-only methods, so the tool rendering is the whole
// contract.

@Suite("Bridge parity — relationship memory")
struct BridgeParityMemoryTests {

    // MARK: creases

    @Test("crease.read: empty state matches")
    @MainActor
    func creaseReadEmpty() async throws {
        let w = try makeParityWorld()
        #expect(await oldOutput(w, tool: "crease_read", input: [:])
             == (await newOutput(w, canonical: "crease.read", input: [:])))
    }

    @Test("crease.read: seeded data matches (same rows, same ids)")
    @MainActor
    func creaseReadSeeded() async throws {
        let w = try makeParityWorld()
        try w.state.db.saveCrease(CompanionCrease(id: "cr-1", companionId: w.companion.id, spaceId: w.space.id, content: "predicted quiet, got a flood"))
        try w.state.db.saveCrease(CompanionCrease(id: "cr-2", companionId: w.companion.id, spaceId: nil, content: "a global one"))
        let old = await oldOutput(w, tool: "crease_read", input: [:])
        let new = await newOutput(w, canonical: "crease.read", input: [:])
        #expect(old == new)
        // and it actually rendered the global marker (guards against an empty match)
        #expect(old.first?.contains("(global)") == true)
    }

    @Test("crease.write: side effect matches across two worlds")
    @MainActor
    func creaseWriteSideEffect() async throws {
        let a = try makeParityWorld()
        let b = try makeParityWorld()
        let input: [String: Any] = ["content": "team insight", "prediction": "calm", "actual": "storm"]
        let newRet = await newOutput(b, canonical: "crease.write", input: input)
        _ = await oldOutput(a, tool: "crease_write", input: input)

        let ca = try a.state.db.fetchCreases(companionId: a.companion.id, spaceId: a.space.id)
        let cb = try b.state.db.fetchCreases(companionId: b.companion.id, spaceId: b.space.id)
        #expect(ca.count == 1 && cb.count == 1)
        #expect(ca.first?.content == cb.first?.content)
        // each world has its own space UUID, so parity is "each wrote to its own current space"
        #expect(ca.first?.spaceId == a.space.id)
        #expect(cb.first?.spaceId == b.space.id)
        #expect(ca.first?.prediction == cb.first?.prediction)
        #expect(ca.first?.actual == cb.first?.actual)
        // the new return carries ok:true (id differs by construction, so it isn't compared)
        #expect(newRet.first?.contains("\"ok\":true") == true)
    }

    @Test("crease.write: missing content errors identically")
    @MainActor
    func creaseWriteError() async throws {
        let w = try makeParityWorld()
        #expect(await oldOutput(w, tool: "crease_write", input: [:])
             == (await newOutput(w, canonical: "crease.write", input: [:])))
    }

    @Test("crease.touch / crease.forget match")
    @MainActor
    func creaseTouchForget() async throws {
        let w = try makeParityWorld()
        try w.state.db.saveCrease(CompanionCrease(id: "cr-9", companionId: w.companion.id, spaceId: w.space.id, content: "x"))
        #expect(await oldOutput(w, tool: "crease_touch", input: ["id": "cr-9"])
             == (await newOutput(w, canonical: "crease.touch", input: ["id": "cr-9"])))
        // forget in two worlds, then both should have zero
        let a = try makeParityWorld(); let b = try makeParityWorld()
        try a.state.db.saveCrease(CompanionCrease(id: "z", companionId: a.companion.id, spaceId: a.space.id, content: "x"))
        try b.state.db.saveCrease(CompanionCrease(id: "z", companionId: b.companion.id, spaceId: b.space.id, content: "x"))
        _ = await oldOutput(a, tool: "crease_forget", input: ["id": "z"])
        _ = await newOutput(b, canonical: "crease.forget", input: ["id": "z"])
        #expect(try a.state.db.fetchCreases(companionId: a.companion.id, spaceId: a.space.id).isEmpty)
        #expect(try b.state.db.fetchCreases(companionId: b.companion.id, spaceId: b.space.id).isEmpty)
    }

    // MARK: engravings

    @Test("engrave.read: empty + seeded match")
    @MainActor
    func engraveRead() async throws {
        let w = try makeParityWorld()
        #expect(await oldOutput(w, tool: "engrave_read", input: [:])
             == (await newOutput(w, canonical: "engrave.read", input: [:])))
        try w.state.db.saveEngraving(CompanionEngraving(id: "e-1", companionId: w.companion.id, spaceId: w.space.id, content: "they ship at night"))
        #expect(await oldOutput(w, tool: "engrave_read", input: [:])
             == (await newOutput(w, canonical: "engrave.read", input: [:])))
    }

    @Test("engrave.write: side effect matches")
    @MainActor
    func engraveWrite() async throws {
        let a = try makeParityWorld(); let b = try makeParityWorld()
        let input: [String: Any] = ["content": "prefers terseness", "category": "style"]
        _ = await oldOutput(a, tool: "engrave_write", input: input)
        _ = await newOutput(b, canonical: "engrave.write", input: input)
        let ea = try a.state.db.fetchEngravings(companionId: a.companion.id, spaceId: a.space.id)
        let eb = try b.state.db.fetchEngravings(companionId: b.companion.id, spaceId: b.space.id)
        #expect(ea.first?.content == eb.first?.content)
        #expect(ea.first?.category == eb.first?.category)
    }

    // MARK: fold

    @Test("fold.read: empty + seeded match (structured object)")
    @MainActor
    func foldRead() async throws {
        let w = try makeParityWorld()
        #expect(await oldOutput(w, tool: "fold_read", input: [:])
             == (await newOutput(w, canonical: "fold.read", input: [:])))
        // seed via the old update path, then both reads see the same row
        _ = await oldOutput(w, tool: "fold_update", input: [
            "established": ["we default to shipping"], "tensions": ["scope vs polish"],
            "holding": "the demo", "depthDelta": 2
        ])
        let old = await oldOutput(w, tool: "fold_read", input: [:])
        let new = await newOutput(w, canonical: "fold.read", input: [:])
        #expect(old == new)
        #expect(old.first?.contains("\"depth\":2") == true)
    }

    @Test("fold.update: side effect matches")
    @MainActor
    func foldUpdate() async throws {
        let a = try makeParityWorld(); let b = try makeParityWorld()
        let input: [String: Any] = ["established": ["a", "b"], "holding": "the thread", "depthDelta": 3]
        _ = await oldOutput(a, tool: "fold_update", input: input)
        _ = await newOutput(b, canonical: "fold.update", input: input)
        let fa = try a.state.db.fetchFold(companionId: a.companion.id, spaceId: a.space.id)
        let fb = try b.state.db.fetchFold(companionId: b.companion.id, spaceId: b.space.id)
        #expect(fa?.established == fb?.established)
        #expect(fa?.holding == fb?.holding)
        #expect(fa?.depth == fb?.depth)
        #expect(fa?.depth == 3)
    }

    // MARK: position

    @Test("position.read: empty + seeded match")
    @MainActor
    func positionRead() async throws {
        let w = try makeParityWorld()
        #expect(await oldOutput(w, tool: "position_read", input: [:])
             == (await newOutput(w, canonical: "position.read", input: [:])))
        _ = await oldOutput(w, tool: "position_set", input: [
            "read": "they're stuck on scope", "stance": "cut one thing", "watching": ["energy", "clock"]
        ])
        let old = await oldOutput(w, tool: "position_read", input: [:])
        let new = await newOutput(w, canonical: "position.read", input: [:])
        #expect(old == new)
        #expect(old.first?.contains("they're stuck on scope") == true)
    }

    @Test("position.set: side effect + missing-read error match")
    @MainActor
    func positionSet() async throws {
        let a = try makeParityWorld(); let b = try makeParityWorld()
        let input: [String: Any] = ["read": "r", "stance": "s", "watching": ["w1"]]
        _ = await oldOutput(a, tool: "position_set", input: input)
        _ = await newOutput(b, canonical: "position.set", input: input)
        let pa = try a.state.db.fetchPosition(companionId: a.companion.id, spaceId: a.space.id)
        let pb = try b.state.db.fetchPosition(companionId: b.companion.id, spaceId: b.space.id)
        #expect(pa?.read == pb?.read)
        #expect(pa?.stance == pb?.stance)
        #expect(pa?.watching == pb?.watching)
        // error parity
        let w = try makeParityWorld()
        #expect(await oldOutput(w, tool: "position_set", input: [:])
             == (await newOutput(w, canonical: "position.set", input: [:])))
    }

    // MARK: coverage

    @Test("every memory-family canonical has a registry entry")
    @MainActor
    func coverage() throws {
        let w = try makeParityWorld()
        let family = ["crease.read", "crease.write", "crease.touch", "crease.forget",
                      "engrave.read", "engrave.write", "engrave.touch", "engrave.forget",
                      "fold.read", "fold.update", "position.read", "position.set"]
        for c in family {
            #expect(w.registry[c] != nil, "missing registry entry: \(c)")
        }
    }
}
