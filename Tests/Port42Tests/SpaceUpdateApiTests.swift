import Testing
import Foundation
@testable import Port42Lib

// API parity, Phase C (docs/plan-api-parity.md): space.update, rest, wake, reorder, and space.list's new fields.

@Suite("space.update, rest, wake and reorder")
@MainActor
struct SpaceUpdateApiTests {
    func call(_ w: ParityWorld, _ method: String, _ args: [String: Any], as p: Principal? = nil) async throws -> BridgeValue {
        try await w.state.runBridgeMethod(method, principal: p ?? .peer(id: "cli", displayName: "cli"), args: BridgeArgs(args))
    }
    func extra(_ w: ParityWorld, _ name: String) throws -> Space {
        let s = Space.create(name: name)
        try w.state.db.saveSpace(s)
        w.state.spaces.append(s)
        return s
    }
    func space(_ w: ParityWorld, _ id: String) -> Space? { w.state.spaces.first { $0.id == id } }

    @Test("update renames (lowercase, dashes) and recolors, and space.list reports both")
    func updateAndList() async throws {
        let w = try makeParityWorld()
        _ = try await call(w, "space.update", ["space_id": w.space.id, "name": "Big Plans", "accent": "#abcdef"])
        let s = try #require(space(w, w.space.id))
        #expect(s.name == "big-plans")
        #expect(s.accent == "#ABCDEF")
        guard case .array(let list) = try await call(w, "space.list", [:]) else { Issue.record("no list"); return }
        var seen = false
        for case .object(let o) in list where o["id"] == .string(w.space.id) {
            seen = true
            #expect(o["accent"] == .string("#ABCDEF"))
            #expect(o["resting"] == .bool(false))
        }
        #expect(seen)
    }

    @Test("update refuses a name another space holds, a bad accent, an empty name and a no-op")
    func updateRefusals() async throws {
        let w = try makeParityWorld()
        let other = try extra(w, "taken")
        for args: [String: Any] in [
            ["space_id": w.space.id, "name": other.name],
            ["space_id": w.space.id, "accent": "teal"],
            ["space_id": w.space.id, "name": "   "],
            ["space_id": w.space.id, "name": w.space.name],
        ] {
            await #expect(throws: BridgeError.self) { _ = try await self.call(w, "space.update", args) }
        }
    }

    @Test("rest and wake flip the space, and each refuses the wrong state")
    func restAndWake() async throws {
        let w = try makeParityWorld()
        let other = try extra(w, "second")
        _ = try await call(w, "space.rest", ["space_id": other.id])
        #expect(space(w, other.id)?.isResting == true)
        await #expect(throws: BridgeError.self) { _ = try await self.call(w, "space.rest", ["space_id": other.id]) }
        _ = try await call(w, "space.wake", ["space_id": other.id])
        #expect(space(w, other.id)?.isResting == false)
        await #expect(throws: BridgeError.self) { _ = try await self.call(w, "space.wake", ["space_id": other.id]) }
    }

    @Test("reorder puts a space before another, or last")
    func reorder() async throws {
        let w = try makeParityWorld()
        let b = try extra(w, "bee"), c = try extra(w, "sea")
        let first = w.state.spaces.map(\.id)
        _ = try await call(w, "space.reorder", ["space_id": c.id, "before": first[0]])
        #expect(w.state.spaces.first?.id == c.id, "the space did not move to the front")
        _ = try await call(w, "space.reorder", ["space_id": c.id])
        #expect(w.state.spaces.last?.id == c.id, "the space did not move to the end")
        _ = b
    }

    @Test("a companion acting in one space cannot change another, and unknown ids are refused")
    func scope() async throws {
        let w = try makeParityWorld()
        let other = try extra(w, "away")
        let caller = Principal.companion(id: w.companion.id, displayName: w.companion.displayName, spaceId: w.space.id)
        for (m, a) in [("space.update", ["space_id": other.id, "name": "mine"]), ("space.rest", ["space_id": other.id])] as [(String, [String: Any])] {
            do { _ = try await call(w, m, a, as: caller) } catch {}
        }
        #expect(space(w, other.id)?.name == "away", "a companion renamed a space it does not act in")
        #expect(space(w, other.id)?.isResting == false, "a companion rested a space it does not act in")
        await #expect(throws: BridgeError.self) { _ = try await self.call(w, "space.wake", ["space_id": "nope"]) }
    }
}
