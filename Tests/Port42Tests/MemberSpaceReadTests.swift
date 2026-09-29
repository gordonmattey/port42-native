import Testing
import Foundation
@testable import Port42Lib

/// A companion reads the spaces the person made it a member of, as well as the one it works in (GM,
/// 2026-09-29): a lead in one space coordinates a team in another. Nothing else widens: a plain terminal
/// or a port's page still reads only its own space.
@Suite("A companion reads the spaces it is a member of")
@MainActor
struct MemberSpaceReadTests {

    struct World {
        let w: ParityWorld
        let team: Space        // the companion is a member here
        let closed: Space      // and not here
        let terminal: Principal
    }

    func world() throws -> World {
        let w = try makeParityWorld()
        let team = try #require(w.state.createSpace(name: "issues", select: false))
        let closed = try #require(w.state.createSpace(name: "private", select: false))
        try w.state.db.assignAgentToSpace(agentId: w.companion.id, spaceId: w.space.id)
        try w.state.db.assignAgentToSpace(agentId: w.companion.id, spaceId: team.id)
        let terminal = Principal.forGatewayClient(
            clientId: ClientRegistry.childId(companionId: w.companion.id, spaceId: w.space.id),
            displayName: w.companion.displayName,
            spawn: .init(companionId: w.companion.id, spaceId: w.space.id))
        return World(w: w, team: team, closed: closed, terminal: terminal)
    }

    func readChat(_ w: ParityWorld, _ who: Principal, _ space: Space) async -> Bool {
        (try? await w.state.runBridgeMethod("chat.read", principal: who, args: BridgeArgs(["port": space.id]))) != nil
    }

    @Test("its terminal reads a member space's chat, and not a space it is not in")
    func terminalReadsMemberSpace() async throws {
        let t = try world()
        #expect(await readChat(t.w, t.terminal, t.w.space), "its own space")
        #expect(await readChat(t.w, t.terminal, t.team), "a space it is a member of")
        #expect(!(await readChat(t.w, t.terminal, t.closed)), "a space it is not a member of")
    }

    @Test("in the app too; and a port's page gains nothing from its author's memberships")
    func inAppAndPages() async throws {
        let t = try world()
        let inApp = Principal.companion(id: t.w.companion.id, displayName: t.w.companion.displayName, spaceId: t.w.space.id)
        #expect(await readChat(t.w, inApp, t.team))
        #expect(!(await readChat(t.w, inApp, t.closed)))
        let page = Principal.port(id: "page-1", displayName: "a page", spaceId: t.w.space.id)
        #expect(!(await readChat(t.w, page, t.team)), "a page reads only its own space")
    }

    @Test("whoami and companions.get list the spaces a companion is a member of")
    func listsSpaces() async throws {
        let t = try world()
        func names(_ v: BridgeValue) -> Set<String> {
            guard case let .object(o) = v, case let .array(a)? = o["spaces"] else { return [] }
            return Set(a.compactMap { if case let .object(s) = $0, case let .string(n)? = s["name"] { return n }; return nil })
        }
        let me = try await t.w.state.runBridgeMethod("whoami", principal: t.terminal, args: BridgeArgs([:]))
        #expect(names(me) == [t.w.space.name, "issues"])
        let got = try await t.w.state.runBridgeMethod("companions.get", principal: .human(id: "me", displayName: "me", spaceId: nil),
                                                     args: BridgeArgs(["id": t.w.companion.id]))
        #expect(names(got) == [t.w.space.name, "issues"])
    }
}
