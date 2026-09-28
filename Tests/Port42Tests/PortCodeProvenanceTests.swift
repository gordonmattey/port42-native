import Testing
import Foundation
@testable import Port42Lib

/// **Code written from another machine is not the creator's** (NAU-02).
///
/// A port authorizes as its creator, with the creator's machine grants. APP-07 refuses a guest's
/// write while the port holds a grant, but only at that moment: edit a port that holds nothing,
/// then let the creator be granted `.clipboard`, and the guest's code runs with it. And every card
/// it raised read as the creator's own ask. Once a remote caller writes the code, the port runs as
/// itself, inherits nothing, and says who changed it.
@Suite("Port code provenance (NAU-02)")
struct PortCodeProvenanceTests {

    @MainActor
    func call(_ w: ParityWorld, _ canonical: String, as principal: Principal,
              _ input: [String: Any]) async throws -> BridgeValue {
        let method = try #require(w.registry[canonical])
        return try await method.run(principal, BridgeArgs(input))
    }

    /// A port the world's companion made in its space. It holds nothing yet, so APP-07 lets a guest in.
    @MainActor
    func companionPort(_ w: ParityWorld) throws -> String {
        let created = w.state.createPort(
            type: "web", title: "Board", html: "<title>Board</title><div>v1</div>", command: nil,
            cwd: nil, systemPrompt: nil, spaceId: w.space.id, createdBy: w.companion.id,
            createdByName: w.companion.displayName, presentation: "tiled")
        return try #require(created["id"] as? String)
    }

    let guest = Principal.remote(peer: "peer-guest", displayName: "guest")

    @Test("after a guest's edit the port no longer runs as its creator, even for grants given later")
    @MainActor
    func guestEditDropsCreatorAuthority() async throws {
        let w = try makeParityWorld()
        let id = try companionPort(w)
        let bridge = try #require(w.state.portWindows.findPort(by: id)?.bridge)
        #expect(bridge.portPrincipal.id == w.companion.id, "control: a creator's own port runs as the creator")

        _ = try await call(w, "port.update", as: guest, ["id": id, "html": "<title>Board</title><script>/*guest*/</script>"])

        // The creator is granted something AFTER the edit: exactly the window APP-07 cannot see.
        w.state.saveGrants([.clipboard], grantee: w.companion.id, on: .machine, zone: w.space.id)

        let now = bridge.portPrincipal
        #expect(now.id != w.companion.id, "the guest's code must not run as the creator")
        #expect(now.displayName.contains("code changed by guest"), "its cards must say who changed it")
        // A bridge holds no copy of grants to clear (APP-06): the live grants of the identity it
        // now runs as are the whole of its authority, which is what the next line checks.
        #expect(!w.state.grants(grantee: now.id, on: .machine, zone: now.spaceId).contains(.clipboard))
    }

    @Test("a patch or restore by a guest taints too, and the mark survives a restart")
    @MainActor
    func patchTaintsAndPersists() async throws {
        let w = try makeParityWorld()
        let id = try companionPort(w)
        _ = try await call(w, "port.patch", as: guest, ["id": id, "search": "v1", "replace": "v2"])

        let panel = try #require(w.state.portWindows.findPort(by: id))
        #expect(panel.bridge.codeChangedBy == "guest")
        let row = try #require(try w.state.db.fetchPortPanels().first { $0.udid == panel.udid || $0.id == panel.id })
        #expect(row.codeChangedBy == "guest", "a restart must not hand the creator's authority back")
    }

    @Test("only a full replacement by the creator or the person makes the code theirs again")
    @MainActor
    func onlyFullReplacementClears() async throws {
        let w = try makeParityWorld()
        let id = try companionPort(w)
        let creator = Principal.companion(id: w.companion.id, displayName: w.companion.displayName, spaceId: w.space.id)
        _ = try await call(w, "port.update", as: guest, ["id": id, "html": "<title>Board</title><div>g</div>"])

        // A patch keeps whatever else the guest wrote, so it does not clear the mark.
        _ = try await call(w, "port.patch", as: creator, ["id": id, "search": "<div>g</div>", "replace": "<div>c</div>"])
        let bridge = try #require(w.state.portWindows.findPort(by: id)?.bridge)
        #expect(bridge.codeChangedBy == "guest")

        _ = try await call(w, "port.update", as: creator, ["id": id, "html": "<title>Board</title><div>mine</div>"])
        #expect(bridge.codeChangedBy == nil)
        #expect(bridge.portPrincipal.id == w.companion.id)
    }
}
