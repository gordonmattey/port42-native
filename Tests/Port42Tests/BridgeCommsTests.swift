import Testing
import Foundation
@testable import Port42Lib

// Phase 1, batch 4: identity / spaces / companions / messages / bus. Read-mostly, DB-backed. Clean
// contract: reads are structured arrays/objects, sends return {ok} and are checked by side effect.

@Suite("Bridge — comms")
struct BridgeCommsTests {

    @MainActor
    func call(_ w: ParityWorld, _ canonical: String, _ input: [String: Any]) async throws -> BridgeValue {
        let method = try #require(w.registry[canonical])
        return try await method.run(w.principal, BridgeArgs(input))
    }

    @Test("user.get returns the signed-in user; none throws")
    @MainActor
    func userGet() async throws {
        let w = try makeParityWorld()
        let u = try await call(w, "user.get", [:])
        guard case let .object(o) = u else { Issue.record("expected object"); return }
        #expect(o["displayName"] == .string("Alice"))
        w.state.currentUser = nil
        await #expect(throws: BridgeError.self) { _ = try await call(w, "user.get", [:]) }
    }

    @Test("space.list returns id+name objects for all spaces")
    @MainActor
    func spaceList() async throws {
        let w = try makeParityWorld()
        let listed = try await call(w, "space.list", [:])
        guard case let .array(items) = listed else { Issue.record("expected array"); return }
        #expect(items.contains(.object(["id": .string(w.space.id), "name": .string(w.space.name)])))
    }

    @Test("space.current reports the space and member count")
    @MainActor
    func spaceCurrent() async throws {
        let w = try makeParityWorld()
        w.state.currentSpace = w.space
        let cur = try await call(w, "space.current", ["space_id": w.space.id])
        guard case let .object(o) = cur else { Issue.record("expected object"); return }
        #expect(o["id"] == .string(w.space.id))
        #expect(o["name"] == .string(w.space.name))
        if case .array = o["members"] {} else { Issue.record("members should be an array") }
    }

    @Test("companions.list + companions.get")
    @MainActor
    func companions() async throws {
        let w = try makeParityWorld()
        let got = try await call(w, "companions.get", ["id": w.companion.id])
        guard case let .object(o) = got else { Issue.record("expected object"); return }
        #expect(o["id"] == .string(w.companion.id))
        #expect(o["name"] == .string(w.companion.displayName))
        await #expect(throws: BridgeError.self) { _ = try await call(w, "companions.get", ["id": "nope"]) }
    }

    // MARK: - Tail item 2: space.switchTo

    @Test("space.switchTo flips the current space")
    @MainActor
    func spaceSwitchToFlips() async throws {
        let w = try makeParityWorld()
        let second = Space.create(name: "second")
        try w.state.db.saveSpace(second)
        w.state.spaces.append(second)
        w.state.currentSpace = w.space
        let r = try await call(w, "space.switchTo", ["space_id": second.id])
        #expect(r == .object(["ok": .bool(true)]))
        #expect(w.state.currentSpace?.id == second.id)
    }

    @Test("space.switchTo with an unknown id throws not_found")
    @MainActor
    func spaceSwitchToUnknown() async throws {
        let w = try makeParityWorld()
        w.state.currentSpace = w.space
        await #expect(throws: BridgeError.self) {
            _ = try await call(w, "space.switchTo", ["space_id": "definitely-not-a-space"])
        }
        #expect(w.state.currentSpace?.id == w.space.id)
    }
}
