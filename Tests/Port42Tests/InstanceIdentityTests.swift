import Testing
import Foundation
@testable import Port42Lib

/// Nautilus Phase 4, step 4.2: each instance has one Ed25519 key, handed to the gateway on stdin only;
/// the gateway derives the peer id and tells the app; an address naming this instance resolves here;
/// another instance can be enrolled as a `peer` client by its key.
@Suite("Instance identity (Phase 4, 4.2)")
@MainActor
struct InstanceIdentityTests {

    static let mine = "25njqamcweflpvkl73j4szahhihoc4xt3ktcgjnpaingr5yhkena"
    static let theirs = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"

    @Test("the seed is 32 bytes, stable for an instance, and different between instances")
    func seedIsPerInstance() throws {
        let a = try #require(InstanceKey.seed(instance: "IdentityTestA"))
        #expect(Data(base64Encoded: a)?.count == 32, "an Ed25519 seed is 32 bytes")
        #expect(InstanceKey.seed(instance: "IdentityTestA") == a, "the key must not change between calls")
        #expect(InstanceKey.seed(instance: "IdentityTestB") != a, "two instances must be two peers")
    }

    @Test("the handover is the host credential, then the seed, one per line")
    func handoverShape() {
        #expect(GatewayProcess.handover(host: "HOST", peerSeed: "SEED", attestKey: "ATTEST") == "HOST\nSEED\nATTEST\n",
                "the gateway reads the credential from line one and the key from line two")
    }

    @Test("relays reach the gateway as arguments only when the instance names some")
    func relayArguments() throws {
        let d = try #require(UserDefaults(suiteName: "port42-relay-args-test"))
        d.removeObject(forKey: "PORT42_RELAYS")
        #expect(GatewayProcess.relayArguments(d).isEmpty, "no relay unless one is configured")
        d.set("wss://relay1.port42.ai/v1", forKey: "PORT42_RELAYS")
        #expect(GatewayProcess.relayArguments(d) == ["-relay", "wss://relay1.port42.ai/v1"])
        d.removePersistentDomain(forName: "port42-relay-args-test")
    }

    @Test("the key reaches the gateway only through the stdin handover")
    func keyOnlyOnStdin() throws {
        // The seed is read in exactly one place, the handover written to the gateway's stdin. Anywhere
        // else (the environment, which `ps -E` publishes, or the arguments) would be a second path.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var uses: [String] = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in e where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), t.contains("InstanceKey.seed(") else { continue }
                uses.append("\(url.lastPathComponent):\(n + 1)  \(t)")
            }
        }
        #expect(uses.count == 1 && uses[0].contains("handover(") && uses[0].hasPrefix("GatewayProcess.swift"),
                "the instance key is read outside the stdin handover: \(uses)")
    }

    @Test("the gateway's welcome tells the app its peer id")
    func welcomeSetsLocalPeer() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        #expect(state.localPeerID == nil)
        state.door.receive(#"{"type":"welcome","sender_id":"host","self_peer":"\#(Self.mine)"}"#)
        #expect(state.localPeerID == Self.mine)
    }

    @Test("an address naming this instance resolves to its port; one naming another does not")
    func ownAddressResolves() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        _ = state.portWindows.registerTiledPort(id: "id-port", html: "<p>x</p>", spaceId: nil,
                                                createdBy: nil, title: "t", position: nil)
        let udid = try #require(state.portWindows.panels.first { $0.id == "id-port" }?.udid)
        state.door.receive(#"{"type":"welcome","sender_id":"host","self_peer":"\#(Self.mine)"}"#)

        #expect(state.resolvePortRef("port42://\(Self.mine)/\(udid)")?.key == udid,
                "an address naming this instance must reach its own port")
        #expect(state.resolvePortRef("port42://\(Self.theirs)/\(udid)") == nil,
                "an address naming another instance reached a local port with the same id")
    }

    @Test("another instance is enrolled as a peer by its key, once, and found by it")
    func peerClientRoundTrip() throws {
        let db = try DatabaseService(inMemory: true)
        try db.upsertPeerClient(id: "peer-ada", name: "Ada", peerKey: Self.theirs)
        let c = try #require(try db.client(peerKey: Self.theirs))
        #expect(c.kind == .peer && c.id == "peer-ada" && c.peerKey == Self.theirs)
        #expect(try db.client(peerKey: Self.mine) == nil)

        // Re-enrolling keeps the row; a second row cannot claim the same key.
        try db.upsertPeerClient(id: "peer-ada", name: "Ada L.", peerKey: Self.theirs)
        #expect(try db.client(peerKey: Self.theirs)?.name == "Ada L.")
        #expect(throws: (any Error).self) {
            try db.upsertPeerClient(id: "peer-impostor", name: "x", peerKey: Self.theirs)
        }
        // Every other kind has no key.
        try db.upsertClient(id: "cli", name: "cli", kind: "installed")
        #expect(try db.client(id: "cli")?.peerKey == nil)
    }
}
