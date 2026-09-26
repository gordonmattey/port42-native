import Testing
import Foundation
@testable import Port42Lib

/// Nautilus Phase 4, step 4.3: a call from another machine reaches the app with the peer id the
/// transport authenticated and the gateway's HMAC over it. The app forms a remote principal only when
/// the HMAC verifies with this spawn's stdin-only key and the peer is enrolled and not revoked; a
/// remote call never reaches the local handler.
@Suite("Remote caller (Phase 4, 4.3)")
@MainActor
struct RemoteCallerTests {

    static let key = "attest-key-for-this-spawn"
    static let peer = "guest-instance"
    /// Computed outside both implementations and checked by gateway/remote_test.go too.
    static let vector = "T2rMErKZVK7NvW0X3uCUcu0ulJ8bgLHakoL7VQ0QRYo="

    func world(enrol: Bool = true) throws -> AppState {
        let state = AppState(db: try DatabaseService(inMemory: true))
        state.remoteAttestKey = { Self.key }
        if enrol { try state.db.upsertPeerClient(id: "peer-ada", name: "Ada", peerKey: Self.peer) }
        return state
    }

    func claim(_ peer: String = Self.peer, key: String = Self.key) -> RemoteClaim {
        RemoteClaim(peer: peer, attestation: AppState.attest(key: key, peer: peer))
    }

    func refusal(_ state: AppState, _ c: RemoteClaim) -> String? {
        do { _ = try state.resolveRemoteCaller(c); return nil } catch let e as BridgeError { return e.code } catch { return "?" }
    }

    @Test("the app's attestation matches the gateway's, by a vector neither computed")
    func sharedVector() {
        #expect(AppState.attest(key: Self.key, peer: Self.peer) == Self.vector)
    }

    @Test("an enrolled peer with a valid attestation becomes a remote principal keyed on its peer id")
    func verifiedPeer() throws {
        let p = try world().resolveRemoteCaller(claim())
        #expect(p.kind == .remote && p.id == Self.peer && p.displayName == "Ada")
    }

    @Test("the peer id is not believed without this spawn's attestation")
    func refusals() throws {
        let state = try world()
        #expect(refusal(state, RemoteClaim(peer: Self.peer, attestation: "")) == "auth_required",
                "a peer id asserted with no attestation")
        #expect(refusal(state, claim(key: "a key this app never issued")) == "auth_required",
                "an attestation made with another key")
        let other = RemoteClaim(peer: "someone-else", attestation: claim().attestation)
        #expect(refusal(state, other) == "auth_required", "an attestation replayed onto another peer")
        state.remoteAttestKey = { nil }
        #expect(refusal(state, claim()) == "auth_required", "no key this spawn, yet a peer was believed")
    }

    @Test("a peer must be enrolled, and a revoked one is refused on its next call")
    func enrolment() throws {
        #expect(refusal(try world(enrol: false), claim()) == "auth_required", "an unenrolled peer was served")
        let state = try world()
        #expect(refusal(state, claim()) == nil)
        try state.db.revokeClient(id: "peer-ada")
        #expect(refusal(state, claim()) == "auth_revoked", "a revoked peer was served")
    }

    // MARK: - Through the door

    final class Wire {
        var sent: [[String: Any]] = []
        func frames() -> [[String: Any]] { sent.filter { $0["type"] as? String == "response" } }
    }

    func remoteCall(_ id: String, method: String, args: String = "{}", attestation: String) -> String {
        #"{"type":"call","call_id":"\#(id)","sender_id":"remote-1","method":"\#(method)","args":\#(args),"remote_peer":"\#(Self.peer)","remote_attest":"\#(attestation)"}"#
    }

    func content(_ frame: [String: Any]) -> Any? {
        guard let p = frame["payload"] as? [String: Any], let c = p["content"] as? String,
              let d = c.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    @Test("a remote call never reaches the local handler, and without a remote handler it is refused")
    func doorRouting() async {
        let wire = Wire()
        let door = GatewayDoor()
        door.sendOverride = { t in
            if let d = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                wire.sent.append(o)
            }
        }
        var local = 0
        door.onCallReceived = { _, _, _, _, _, _ in local += 1; return ["ok": true] }
        door.receive(remoteCall("r1", method: "ports.list", attestation: "x"))
        for _ in 0..<200 where wire.frames().isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(local == 0, "a call from another machine ran through the local handler")
        #expect((content(wire.frames().first ?? [:]) as? [String: Any])?["code"] as? String == "not_granted")
    }

    @Test("end to end in the app: a verified guest lists only the port it was granted")
    func endToEnd() async throws {
        let state = try world()
        let wire = Wire()
        state.door.sendOverride = { t in
            if let d = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                wire.sent.append(o)
            }
        }
        _ = state.portWindows.registerTiledPort(id: "rc-p", html: "<p>p</p>", spaceId: nil, createdBy: nil, title: "p", position: nil)
        _ = state.portWindows.registerTiledPort(id: "rc-q", html: "<p>q</p>", spaceId: nil, createdBy: nil, title: "q", position: nil)
        let p = try #require(state.portWindows.panels.first { $0.id == "rc-p" }?.udid)
        state.grantRemoteRights([.see], to: Self.peer, onPort: p)

        state.door.receive(remoteCall("r2", method: "ports.list", attestation: claim().attestation))
        for _ in 0..<200 where wire.frames().isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        let first = try #require(wire.frames().first)
        let rows = try #require(content(first) as? [[String: Any]])
        #expect(rows.compactMap { $0["id"] as? String } == [p], "the guest saw \(rows)")

        // The same call with a forged attestation is refused before anything runs.
        state.door.receive(remoteCall("r3", method: "ports.list", attestation: "forged"))
        for _ in 0..<200 where wire.frames().count < 2 { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect((content(wire.frames()[1]) as? [String: Any])?["code"] as? String == "auth_required")
    }
}
