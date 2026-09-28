import Testing
import Foundation
@testable import Port42Lib

// APP-06: a port copied its creator's grants into `grantedPermissions` when its bridge was built,
// saved that copy on the port row, restored it at launch, and passed it to every call as a
// pregrant. A snapshot, so a grant the person revoked kept working for the port, and code written
// into the port later ran with it. The first two tests fail on the snapshot and pass without it;
// the third holds the share card to the same identity the port runs as.

@Suite("A port has no pregrant (APP-06)")
@MainActor
struct PortPregrantTests {

    /// Where the call's answer lands, so the test can keep answering cards until it has one.
    final class Outcome { var value: Any? }

    @Test("a grant revoked after the port was built is asked for again, not honored from a copy",
          .timeLimit(.minutes(10)))
    func revokedGrantNotHonored() async throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        state.permissions.canPrompt = { true }   // the shell is up, so a card can be seen (APP-16)
        state.saveGrants([.clipboard], grantee: "comp-1", on: .machine, zone: "space-1")
        let bridge = PortBridge(appState: state, spaceId: "space-1", messageId: "m1", createdBy: "comp-1")

        // The person withdraws it after the port exists.
        state.saveGrants([], grantee: "comp-1", on: .machine, zone: "space-1")

        // clipboard.write is gated on .clipboard; with no data its body only fails on the argument,
        // so a call that gets past the gate never touches the clipboard.
        let outcome = Outcome()
        let call = Task { outcome.value = await bridge.handleMethod("clipboard.write", args: []) }
        // Answer every card until the call returns. A card can take many seconds to appear when the
        // full suite runs under load, and a wait with a deadline left a late card unanswered and the
        // call hanging.
        var asked = false
        while outcome.value == nil {
            if state.permissions.current != nil {
                asked = true
                state.permissions.resolveCurrent(granted: false)
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        _ = await call.value
        #expect(asked, "the port must ask again, not run on the grant it copied at construction")
    }

    @Test("a saved port row carries no grants")
    func rowCarriesNoGrants() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        state.saveGrants([.terminal], grantee: "comp-1", on: .machine, zone: "space-1")
        let created = state.createPort(
            type: "web", title: "Tool", html: "<title>Tool</title>", command: nil, cwd: nil,
            systemPrompt: nil, spaceId: "space-1", createdBy: "comp-1", createdByName: "comp",
            presentation: "tiled")
        let id = try #require(created["id"] as? String)
        let panel = try #require(state.portWindows.findPort(by: id))
        #expect(PersistedPortPanel(from: panel).grantedPermissions == nil,
                "a grant saved on the row comes back at launch even after it is revoked")
    }

    @Test("the share card discloses the grants of the identity a port runs as, creator or not")
    func disclosureFollowsPrincipal() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let created = state.createPort(
            type: "web", title: "Mine", html: "<title>Mine</title>", command: nil, cwd: nil,
            systemPrompt: nil, spaceId: "space-1", createdBy: nil, createdByName: nil,
            presentation: "tiled")
        let id = try #require(created["id"] as? String)
        let panel = try #require(state.portWindows.findPort(by: id))
        // A port with no creator runs as itself, and a grant it was given lands on that identity.
        state.saveGrants([.camera], grantee: panel.bridge.portPrincipal.id, on: .machine,
                         zone: panel.spaceId)
        #expect(state.portMachineGrants(panel.udid) == [.camera],
                "a guest who drives this port can make it use the camera, so sharing must say so")
    }
}
