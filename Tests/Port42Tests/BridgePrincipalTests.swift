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
        // Since the collapse the Principal goes straight to the coordinator: `id` is both the
        // coalescing key and the grant persistence key; the label is display only.
        #expect(p.id == "local-http")
        #expect(p.displayName == "Local (gateway)")
        #expect(p.id != p.displayName)
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

    // MARK: - the negative gate (the label can never be a key again)

    // Source-scan (Spike-B technique, per-file walk of Sources/Port42Lib). 157439c removed the
    // label-identity constructors; these gates keep them out. Acid-tested at birth: reintroducing
    // `let id = "remote-\(senderId.prefix(8))"` names the offending file.

    /// Every .swift file under Sources/Port42Lib as (fileName, source).
    static func libSources() throws -> [(file: String, source: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/Port42Tests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/Port42Lib")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("no source constructs a remote-<prefix> label identity")
    func noLabelIdentityConstructor() throws {
        // The interpolated form is the constructor shape; a prose mention ("remote-<prefix>") is not.
        let offenders = try Self.libSources()
            .filter { $0.source.contains(#""remote-\("#) }
            .map(\.file)
        #expect(offenders.isEmpty, "label identity constructed in: \(offenders)")
    }

    @Test("every remote-http consumer is a deliberate, documented mapping")
    func remoteHTTPConsumersAreAllowlisted() throws {
        // ShellDesktop.who() maps the pre-Phase-3 flattened label for old port-version rows. Any
        // NEW file touching the string must be reviewed into this list, not silently matched.
        let allowlist: Set<String> = ["ShellDesktop.swift"]
        let offenders = try Self.libSources()
            .filter { $0.source.contains("remote-http") && !allowlist.contains($0.file) }
            .map(\.file)
        #expect(offenders.isEmpty, "undocumented remote-http consumer in: \(offenders)")
    }

    // MARK: - the collapse (Principal IS the permission identity)

    @Test("PermissionRequester is gone — Principal is the only permission identity")
    func permissionRequesterCollapsed() throws {
        // The accidental first draft (PermissionRequester) must not survive as a parallel identity
        // type: one caller identity, one type, one keying. The coordinator takes a Principal.
        let offenders = try Self.libSources()
            .filter { $0.source.contains("struct PermissionRequester") }
            .map(\.file)
        #expect(offenders.isEmpty, "PermissionRequester still declared in: \(offenders)")
    }

    // MARK: - port principal resolution (GM decision 2026-07-19: a port acts as its creator)

    // A companion-created port IS its companion for authorization: one grant bucket per author per
    // space (P-260 both ways), one storage namespace (todo #6). A human-created port keys on its
    // own port id. Space-scoped by construction: the principal carries the port's spaceId.

    @Test("a companion-created port's principal resolves to its creator; a human port keys on itself")
    @MainActor
    func portPrincipalResolvesToCreator() throws {
        let w = try makeParityWorld()
        let companionPort = PortBridge(appState: w.state, spaceId: "space-1",
                                       messageId: "msg-port-1", createdBy: "echo", title: "shader")
        #expect(companionPort.portPrincipal.id == "echo")
        #expect(companionPort.portPrincipal.spaceId == "space-1")
        #expect(companionPort.portPrincipal.kind == .port)

        let humanPort = PortBridge(appState: w.state, spaceId: "space-1",
                                   messageId: "msg-port-2", createdBy: nil, title: "pad")
        #expect(humanPort.portPrincipal.id == "msg-port-2")
    }

    @Test("PortBridge dispatches as ONE identity — no divergent inline Principal")
    func portBridgeHasOneIdentityConstruction() throws {
        // portPrincipal must BE the dispatch identity: if handleMethod builds its own Principal
        // inline, the card identity and the grant identity can drift apart again.
        let src = try #require(Self.libSources().first { $0.file == "PortBridge.swift" }).source
        let constructions = src.components(separatedBy: "Principal(").count - 1
        #expect(constructions == 1,
                "PortBridge constructs Principal \(constructions) times; portPrincipal must be the only one")
    }

    @Test("a companion and its port share one storage namespace")
    @MainActor
    func portAndCompanionShareStorage() async throws {
        let w = try makeParityWorld()
        let port = PortBridge(appState: w.state, spaceId: "space-1",
                              messageId: "msg-port-3", createdBy: "echo", title: "probe")
        let companion = Principal(id: "echo", displayName: "echo", spaceId: "space-1", kind: .companion)

        _ = try await w.state.runBridgeMethod("storage.set", principal: port.portPrincipal,
                                              args: BridgeArgs(["key": "pipeline", "value": "state-ok"]))
        let read = try await w.state.runBridgeMethod("storage.get", principal: companion,
                                                     args: BridgeArgs(["key": "pipeline"]))
        // Before the resolution the port wrote under its message id and this read returned null.
        let dict = read.toJSONObject() as? [String: Any]
        #expect(dict?["value"] as? String == "state-ok", "companion must read what its port wrote")
    }
}
