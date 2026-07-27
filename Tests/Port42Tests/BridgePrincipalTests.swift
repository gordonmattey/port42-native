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
        let p = Principal.peer(id: Principal.localGatewayID, displayName: "Local (gateway)")
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

    // MARK: - the registry is the ONLY permission table

    @Test("permissionForMethod is gone — the registry declares every method's permission")
    func permissionTableCollapsed() throws {
        // The last parallel permission table. Its only production caller gated fs.drop, which maps
        // to nil, so it guarded nothing; the registry's method.permission is what actually gates.
        let offenders = try Self.libSources()
            .filter { $0.source.contains("permissionForMethod") }
            .map(\.file)
        #expect(offenders.isEmpty, "permissionForMethod still referenced in: \(offenders)")
    }

    @Test("the registry permission map matches the gated families")
    @MainActor
    func registryPermissionMap() throws {
        let w = try makeParityWorld()
        let stream = buildBridgeStreamRegistry(w.state)
        let expected: [(String, PortPermission?)] = [
            ("terminal.exec", .terminal), ("clipboard.read", .clipboard), ("clipboard.write", .clipboard),
            ("fs.read", .filesystem), ("fs.write", .filesystem), ("fs.pick", .filesystem),
            ("screen.capture", .screen), ("screen.windows", .screen), ("screen.stream", .screen),
            ("camera.capture", .camera), ("camera.stream", .camera),
            ("audio.capture", .microphone),
            ("notify.send", .notification),
            ("automation.runAppleScript", .automation), ("automation.runJXA", .automation),
            ("rest.call", .rest),
            ("browser.open", .browser), ("browser.text", .browser), ("browser.close", .browser),
            ("user.get", nil), ("ports.list", nil), ("messages.recent", nil), ("storage.set", nil),
            ("audio.speak", nil), ("camera.stopStream", nil), ("screen.stopStream", nil),
            ("audio.stopCapture", .microphone),
        ]
        for (name, perm) in expected {
            let m = try #require(w.registry[name], "\(name) missing from registry")
            #expect(m.permission == perm, "\(name) permission should be \(String(describing: perm))")
        }
        let ai = try #require(stream["ai.complete"], "ai.complete missing from stream registry")
        #expect(ai.permission == .ai)
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

    // MARK: - I1.2 · one constructor
    //
    // Supersedes the old per-file check ("PortBridge constructs Principal exactly once"). That was
    // the right property scoped to one file, and scoping a property about identity to one file is
    // the mistake I1.1 measured: the two live holes were in a rung that LOOKED attributed and at two
    // sites nobody had counted. The gate is now the whole package.

    @Test("the memberwise Principal init is private: every identity comes from a named factory")
    func principalHasOneConstructor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Assembled at runtime so this file does not match its own scan. Spelled literally, the
        // needle makes the gate flag itself and it can never pass.
        let needle = "Principal" + "(id:"
        var offenders: [String] = []
        for dir in ["Sources", "Tests"] {
            let files = FileManager.default
                .enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)!
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Principal.swift" }
            for f in files {
                let src = try String(contentsOf: f, encoding: .utf8)
                // The construction shape anchors on the first memberwise label. A bare `Principal(`
                // also matches helper names like `selfPrincipal(`, which are not constructions.
                guard src.contains(needle) else { continue }
                offenders.append(f.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, """
            Principal constructed directly in: \(offenders.sorted()).
            Use a factory in Principal.swift. A memberwise init taking any String cannot tell a heap \
            address from an identity, nor an inherited SHARED id from an authored one, which is both \
            of the holes I1.1 measured.
            """)
    }

    @Test("PortBridge dispatches as ONE identity, resolved by one policy factory")
    func portBridgeHasOneIdentityConstruction() throws {
        // portPrincipal must BE the dispatch identity: if handleMethod resolves its own identity
        // inline, the card identity and the grant identity can drift apart again.
        let src = try #require(Self.libSources().first { $0.file == "PortBridge.swift" }).source
        let resolves = src.components(separatedBy: "Principal.forPortBridge(").count - 1
        #expect(resolves == 1,
                "PortBridge resolves an identity \(resolves) times; portPrincipal must be the only one")
    }

    @Test("the ObjectIdentifier rung is passed in, never minted inside Principal (I1.4 has one site)")
    func heapAddressRungIsNamedAtItsCallSite() throws {
        // `instanceFallback` is a parameter so the defect is greppable and I1.4 can find every caller.
        // If Principal.swift ever computes it itself, the rung goes invisible again.
        let principalSrc = try #require(Self.libSources().first { $0.file == "Principal.swift" }).source
        #expect(!principalSrc.contains("ObjectIdentifier"),
                "Principal.swift mints its own instance fallback; it must be passed by the caller")
    }

    @Test("a dropped file is granted to the port's PRINCIPAL, so its fs.read actually succeeds")
    @MainActor
    func dropGrantFollowsThePrincipal() async throws {
        let w = try makeParityWorld()
        let bridge = PortBridge(appState: w.state, spaceId: "space-1",
                                messageId: "msg-drop-1", createdBy: "echo", title: "dropzone")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-drop-\(UUID().uuidString).txt")
        try "dropped".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        await bridge.handleFileDrop([tmp.path])

        // The port dispatches fs.read as portPrincipal (id = createdBy since the resolution), so
        // the grant must be recorded under THAT id — a messageId-keyed grant is invisible to it.
        let read = try await w.state.runBridgeMethod(
            "fs.read", principal: bridge.portPrincipal,
            args: BridgeArgs(["path": tmp.path]), pregrant: [.filesystem])
        let dict = read.toJSONObject() as? [String: Any]
        #expect(dict?["content"] as? String == "dropped" || (dict?["data"] as? String)?.isEmpty == false,
                "the dropped path must be readable by the dropping port's principal")
    }

    @Test("a companion and its port share one storage namespace")
    @MainActor
    func portAndCompanionShareStorage() async throws {
        let w = try makeParityWorld()
        let port = PortBridge(appState: w.state, spaceId: "space-1",
                              messageId: "msg-port-3", createdBy: "echo", title: "probe")
        let companion = Principal.companion(id: "echo", displayName: "echo", spaceId: "space-1")

        _ = try await w.state.runBridgeMethod("storage.set", principal: port.portPrincipal,
                                              args: BridgeArgs(["key": "pipeline", "value": "state-ok"]))
        let read = try await w.state.runBridgeMethod("storage.get", principal: companion,
                                                     args: BridgeArgs(["key": "pipeline"]))
        // Before the resolution the port wrote under its message id and this read returned null.
        let dict = read.toJSONObject() as? [String: Any]
        #expect(dict?["value"] as? String == "state-ok", "companion must read what its port wrote")
    }
}
