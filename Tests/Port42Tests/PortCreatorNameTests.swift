import Testing
import Foundation
@testable import Port42Lib

/// A port lists WHO made it, not only an id (audit F7). A companion's terminal client id is
/// `terminal-<panel>-<space>`, which tells a person nothing; its registered name does.
@Suite("Port creator name")
@MainActor
struct PortCreatorNameTests {
    @Test("ports.list names the client that created a port")
    func namesTheCreator() async throws {
        let w = try makeParityWorld()
        // The row only: `register` would also write a token file to the real token directory.
        let id = "terminal-abc-def"
        try w.state.db.upsertClient(id: id, name: "swift-otter", kind: Port42Client.Kind.child.rawValue)
        let caller = Principal.peer(id: id, displayName: id)
        _ = try await w.state.runBridgeMethod("port.create", principal: caller,
                                              args: BridgeArgs(["type": "web", "title": "made by otter",
                                                                "html": "<title>made by otter</title>"]))
        guard case let .array(list) = try await w.state.runBridgeMethod(
            "ports.list", principal: w.principal, args: BridgeArgs([:])) else {
            Issue.record("ports.list should return a list"); return
        }
        let row = list.compactMap { v -> [String: BridgeValue]? in
            if case let .object(o) = v, case .string("made by otter")? = o["title"] { return o }
            return nil
        }.first
        #expect(row?["createdBy"] == .string(id))
        #expect(row?["createdByName"] == .string("swift-otter"))
    }
}
