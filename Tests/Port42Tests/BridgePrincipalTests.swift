import Testing
import Foundation
@testable import Port42Lib

// Phase 3 — the real principal. Permission grants key on WHO is calling (a stable id), not a display
// label. These cover the display/id split and the persistence-keying mechanism the gateway path relies
// on. The full end-to-end proof of the three edits (gateway stable SenderID, onCallReceived label
// removal, RemoteToolExecutor keying) is the Go test (gateway_httpcall_test.go) plus the live two-caller
// matrix in Port42Dev — the executor's internals are `private` and cannot be asserted by reaching in.
@Suite("Bridge — principal (Phase 3)")
struct BridgePrincipalTests {

    // MARK: - display / id split

    @Test("local gateway caller has the stable local-http id")
    func localGatewayID() {
        #expect(Principal.localGatewayID == "local-http")
    }

    @Test("gatewayDisplayName: local-http reads friendly, a peer shows its id, label is not the key")
    func gatewayDisplayName() {
        #expect(Principal.gatewayDisplayName(for: "local-http") == "Local (gateway)")
        #expect(Principal.gatewayDisplayName(for: "peer-abc") == "peer-abc")
        // the friendly label must differ from the id it stands for — display is never the permission key
        #expect(Principal.gatewayDisplayName(for: "local-http") != Principal.localGatewayID)
    }

    @Test("a peer principal coalesces and persists on its id, label rides only as displayName")
    func peerPrincipalKeysOnId() {
        let p = Principal(id: Principal.localGatewayID, displayName: "Local (gateway)",
                          spaceId: nil, kind: .peer)
        #expect(p.id == "local-http")
        #expect(p.displayName == "Local (gateway)")
        let req = p.permissionRequester
        #expect(req.id == "local-http")       // coalescing key
        #expect(req.createdBy == "local-http") // grant persistence key — the id, not the label
    }

    // MARK: - keying mechanism (the persistence the gateway old + registry paths share)

    @Test("grants persist per principal id and isolate across distinct ids (global scope)")
    @MainActor
    func grantsKeyOnId() async throws {
        let w = try makeParityWorld()
        let a = "test-peer-A-grantsKeyOnId"
        let b = "test-peer-B-grantsKeyOnId"
        defer {
            w.state.saveCompanionPermissions([], createdBy: a, spaceId: nil)
            w.state.saveCompanionPermissions([], createdBy: b, spaceId: nil)
        }

        w.state.saveCompanionPermissions([.screen], createdBy: a, spaceId: nil)

        // A is granted; B (a different id) is a separate bucket — no shared label collapse.
        #expect(w.state.companionPermissions(createdBy: a, spaceId: nil).contains(.screen))
        #expect(!w.state.companionPermissions(createdBy: b, spaceId: nil).contains(.screen))
        // A second read still resolves: the grant persists (the property a per-call synthetic id lacked).
        #expect(w.state.companionPermissions(createdBy: a, spaceId: nil).contains(.screen))
    }

    @Test("a nil-space (gateway) caller keys under the global bucket, not a space bucket")
    @MainActor
    func gatewayCallerUsesGlobalBucket() async throws {
        let w = try makeParityWorld()
        let id = "test-local-http-globalBucket"
        defer {
            w.state.saveCompanionPermissions([], createdBy: id, spaceId: nil)
            w.state.saveCompanionPermissions([], createdBy: id, spaceId: "some-space")
        }

        // Grant with spaceId: nil, as RemoteToolExecutor does for a gateway caller.
        w.state.saveCompanionPermissions([.terminal], createdBy: id, spaceId: nil)
        #expect(w.state.companionPermissions(createdBy: id, spaceId: nil).contains(.terminal))
        // The same id in a real space is a different bucket (global is not space-wide).
        #expect(!w.state.companionPermissions(createdBy: id, spaceId: "some-space").contains(.terminal))
    }
}
