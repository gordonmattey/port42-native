import Testing
import Foundation
@testable import Port42Lib

/// A space's companions are the same whichever call asks (GM, 2026-09-27: asking for a space's
/// companions by its id came back without them). `companions.list` read the database; `space.current`
/// and whoami read a cache filled later by an observer, so right after a companion joined a space, or
/// before the observer ran, they said it had none.
@Suite("A space's members, from every call")
@MainActor
struct SpaceMembersTests {
    @Test("space.current by id lists a companion that joined that space, at once")
    func spaceCurrentById() async throws {
        let w = try makeParityWorld()
        let other = Space.create(name: "other")
        try w.state.db.saveSpace(other)
        w.state.spaces = try w.state.db.getRegularSpaces()
        var b = AgentConfig.createCommand(ownerId: try #require(w.state.currentUser?.id), displayName: "beta", command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        b.openInTerminal = true
        try w.state.db.saveAgent(b)
        w.state.companions = try w.state.db.getAllAgents()
        try w.state.db.assignAgentToSpace(agentId: b.id, spaceId: other.id)
        let v = try await w.state.runBridgeMethod("space.current", principal: .peer(id: "t", displayName: "t"),
                                                  args: BridgeArgs(["space_id": other.id]))
        let o = try #require(v.toJSONObject() as? [String: Any])
        let names = (o["members"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(names.contains("beta"), "space.current missed the space's companion: \(names)")
        let list = try await w.state.runBridgeMethod("companions.list", principal: .peer(id: "t", displayName: "t"),
                                                     args: BridgeArgs(["space_id": other.id]))
        let listed = (list.toJSONObject() as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(listed == ["beta"])
        withExtendedLifetime(w.state) {}
    }
}
