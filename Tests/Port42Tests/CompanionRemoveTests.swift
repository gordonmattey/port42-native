import Testing
import Foundation
@testable import Port42Lib

// #131: the API could make a companion (companions.create) but not take it off a space's roster, so
// an agent that made one for a job could not remove it when the job was done. companions.remove does
// what the card's "Remove from this space" does: off the roster, its ports and files kept.

@Suite("companions.remove (#131)")
@MainActor
struct CompanionRemoveTests {

    func call(_ w: ParityWorld, _ p: Principal, _ args: [String: Any]) async throws -> [String: Any] {
        let v = try await w.state.runBridgeMethod("companions.remove", principal: p, args: BridgeArgs(args))
        return v.toJSONObject() as? [String: Any] ?? [:]
    }

    /// A companion of the person, saved and on the world's space roster.
    func member(_ w: ParityWorld, _ name: String) throws -> AgentConfig {
        let a = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: name, command: "claude",
                                          systemPrompt: nil, trigger: .mentionOnly)
        try w.state.db.saveAgent(a)
        w.state.companions.append(a)
        w.state.joinCompanionToSpace(a, spaceId: w.space.id)
        return a
    }

    func onRoster(_ w: ParityWorld, _ a: AgentConfig) throws -> Bool {
        try w.state.db.getAgentsForSpace(spaceId: w.space.id).contains { $0.id == a.id }
    }

    func isNotFound(_ e: Error) -> Bool { (e as? BridgeError)?.code == BridgeErrorCode.notFound.wire }

    @Test("a companion is taken off the caller's space by name, and it and its ports are kept")
    func removeByName() async throws {
        let w = try makeParityWorld()
        let spike = try member(w, "watch-spike")
        let port = w.state.createPort(type: "web", title: "spike", html: "<title>spike</title>", command: nil, cwd: nil,
                                      systemPrompt: nil, spaceId: w.space.id, createdBy: spike.id,
                                      createdByName: spike.displayName, presentation: "tiled")
        let portId = try #require(port["id"] as? String)
        #expect(try onRoster(w, spike), "precondition: on the roster")

        let out = try await call(w, w.principal, ["companion": "watch-spike"])
        #expect(out["ok"] as? Bool == true)
        #expect(try !onRoster(w, spike), "still on the space's roster")
        #expect(w.state.companions.contains { $0.id == spike.id }, "the companion itself must be kept")
        #expect(w.state.portWindows.findPort(by: portId) != nil, "its ports must be kept")
    }

    @Test("by id, and from a space named with space_id")
    func removeByIdAndSpace() async throws {
        let w = try makeParityWorld()
        let spike = try member(w, "desk-1")
        let person = Principal.human(id: "alice", displayName: "Alice", spaceId: nil)
        _ = try await call(w, person, ["companion": spike.id, "space_id": w.space.id])
        #expect(try !onRoster(w, spike))
    }

    @Test("a companion that is not on the space's roster is not_found, not a silent ok")
    func notAMember() async throws {
        let w = try makeParityWorld()
        let spike = try member(w, "desk-2")
        _ = try await call(w, w.principal, ["companion": spike.id])
        do {
            _ = try await call(w, w.principal, ["companion": spike.id])
            Issue.record("removing a companion twice answered ok")
        } catch { #expect(isNotFound(error)) }
        await #expect(throws: BridgeError.self) { _ = try await call(w, w.principal, ["companion": "nobody"]) }
    }

    @Test("a companion in one space cannot take companions off another space's roster")
    func otherSpaceRefused() async throws {
        let w = try makeParityWorld()
        let spike = try member(w, "desk-3")
        let outsider = Principal.companion(id: "c-x", displayName: "x", spaceId: "another-space")
        do {
            _ = try await call(w, outsider, ["companion": spike.id, "space_id": w.space.id])
            Issue.record("a caller outside the space removed a companion from it")
        } catch { #expect(isNotFound(error)) }
        #expect(try onRoster(w, spike))
    }
}
