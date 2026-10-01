import Testing
import Foundation
@testable import Port42Lib

// API parity, Phase B (docs/plan-api-parity.md): port.manage showIn and hideFrom, and alsoIn in ports.list,
// so an agent can do what the port menu's "Spaces…" row does (#128).

@Suite("port.manage showIn and hideFrom")
@MainActor
struct ShowInSpaceApiTests {
    func call(_ w: ParityWorld, _ method: String, _ args: [String: Any], as p: Principal? = nil) async throws -> BridgeValue {
        try await w.state.runBridgeMethod(method, principal: p ?? .peer(id: "cli", displayName: "cli"), args: BridgeArgs(args))
    }
    func token(_ w: ParityWorld, _ id: String) -> String { w.state.portInput.token(for: id) }

    func world() throws -> (ParityWorld, Space, String) {
        let w = try makeParityWorld()
        let other = Space.create(name: "elsewhere")
        try w.state.db.saveSpace(other)
        w.state.spaces.append(other)
        let r = w.state.createPort(type: "web", title: "desk", html: "<title>desk</title>", command: nil, cwd: nil,
                                   systemPrompt: nil, spaceId: w.space.id, createdBy: nil, createdByName: nil)
        return (w, other, try #require(r["id"] as? String))
    }

    func adopted(_ w: ParityWorld, _ id: String) -> [String] {
        w.state.portWindows.findPort(by: id)?.adoptedSpaceIds ?? []
    }

    @Test("showIn adopts the port into another space, hideFrom takes it back, and the answer says where it is shown")
    func showAndHide() async throws {
        let (w, other, id) = try world()
        let shown = try await call(w, "port.manage", ["id": id, "action": "showIn", "space_id": other.id, "token": token(w, id)])
        #expect(shown.toJSONObject() as? [String: Any] != nil)
        #expect(adopted(w, id) == [other.id], "the port was not shown in the other space")
        _ = try await call(w, "port.manage", ["id": id, "action": "hideFrom", "space_id": other.id, "token": token(w, id)])
        #expect(adopted(w, id).isEmpty, "the port is still shown there")
    }

    @Test("ports.list reports where a port is also shown")
    func alsoInListed() async throws {
        let (w, other, id) = try world()
        _ = try await call(w, "port.manage", ["id": id, "action": "showIn", "space_id": other.id, "token": token(w, id)])
        guard case .array(let ports) = try await call(w, "ports.list", [:]) else { Issue.record("no list"); return }
        var found = false
        for case .object(let o) in ports where o["id"] == .string(id) {
            found = true
            #expect(o["alsoIn"] == .array([.string(other.id)]), "alsoIn missing: \(o)")
        }
        #expect(found)
    }

    @Test("the port's own space, an unknown space and a missing space_id are refused")
    func refusals() async throws {
        let (w, _, id) = try world()
        await #expect(throws: BridgeError.self) {
            _ = try await self.call(w, "port.manage", ["id": id, "action": "showIn", "space_id": w.space.id, "token": self.token(w, id)])
        }
        await #expect(throws: BridgeError.self) {
            _ = try await self.call(w, "port.manage", ["id": id, "action": "showIn", "space_id": "no-such-space", "token": self.token(w, id)])
        }
        await #expect(throws: BridgeError.self) {
            _ = try await self.call(w, "port.manage", ["id": id, "action": "showIn", "token": self.token(w, id)])
        }
        #expect(adopted(w, id).isEmpty)
    }

    @Test("a companion acting in one space cannot show a port into a space it does not act in")
    func writeScope() async throws {
        let (w, other, id) = try world()
        let caller = Principal.companion(id: w.companion.id, displayName: w.companion.displayName, spaceId: w.space.id)
        do {
            _ = try await call(w, "port.manage", ["id": id, "action": "showIn", "space_id": other.id, "token": token(w, id)], as: caller)
        } catch {}
        #expect(adopted(w, id).isEmpty, "a companion pushed a port into a space it does not act in")
    }
}
