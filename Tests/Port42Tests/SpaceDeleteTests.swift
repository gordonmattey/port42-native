import Testing
import Foundation
@testable import Port42Lib

// Deleting a space used to remove only its rows: its live ports and terminals, agents' CLIs included,
// kept running under a space that no longer existed. GM asked for `space.delete` to clear Dev4's test
// spaces (2026-09-26); it and the galaxy's Delete are one path.
@Suite("Deleting a space")
@MainActor
struct SpaceDeleteTests {

    @Test("space.delete closes the space's own ports, keeps ports that live elsewhere, and removes the space")
    func deletes() async throws {
        let w = try makeParityWorld()
        let doomed = try #require(w.state.createSpace(name: "old test", select: false))
        w.state.portWindows.registerTiledPort(id: "mine", html: "<title>mine</title>", spaceId: doomed.id,
                                              createdBy: nil, title: "mine", position: CGPoint(x: 40, y: 40))
        w.state.portWindows.registerTiledPort(id: "theirs", html: "<title>theirs</title>", spaceId: w.space.id,
                                              createdBy: nil, title: "theirs", position: CGPoint(x: 40, y: 40))
        let person = Principal.human(id: w.state.currentUser!.id, displayName: "Alice", spaceId: w.space.id)
        _ = try await w.state.runBridgeMethod("space.delete", principal: person, args: BridgeArgs(["space_id": doomed.id]))
        #expect(!w.state.portWindows.panels.contains { $0.id == "mine" }, "the space's own port kept running")
        #expect(w.state.portWindows.panels.contains { $0.id == "theirs" }, "a port in another space was closed")
        #expect(!(try w.state.db.getAllSpaces()).contains { $0.id == doomed.id })
        await #expect(throws: BridgeError.self) {
            _ = try await w.state.runBridgeMethod("space.delete", principal: person, args: BridgeArgs(["space_id": doomed.id]))
        }
    }
}
