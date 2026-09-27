import Testing
import Foundation
@testable import Port42Lib

/// Nautilus Phase 4, step 4.6a: this instance calling a port on ANOTHER. The door sends a
/// `remote_call` to its gateway and settles on the frames that come back; `invite.accept` redeems a
/// link as this instance and remembers the port; any call naming a port on another instance is
/// forwarded there, with the other instance's own rights deciding. Headless: a scripted gateway answers.
@Suite("Remote ports (Phase 4, 4.6)")
@MainActor
struct RemotePortTests {

    static let me = "25njqamcweflpvkl73j4szahhihoc4xt3ktcgjnpaingr5yhkena"
    static let host = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"

    /// A gateway that answers each remote_call with `reply(method, args)`: frames to send back.
    @MainActor final class ScriptedGateway {
        var calls: [[String: Any]] = []
        /// Unscripted calls are answered with an error rather than silence, so a call that should never
        /// have been sent fails its test instead of hanging it.
        var reply: (String, [String: Any]) -> [[String: Any]] = { _, _ in
            [["type": "error", "code": "transport_failed", "error": "unscripted remote call"]]
        }
        func install(on door: GatewayDoor) {
            door.sendOverride = { [weak self, weak door] text in
                guard let self, let door,
                      let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                      o["type"] as? String == "remote_call", let id = o["call_id"] as? String else { return }
                self.calls.append(o)
                let frames = self.reply(o["method"] as? String ?? "", o["args"] as? [String: Any] ?? [:])
                Task { @MainActor in
                    for var f in frames {
                        f["call_id"] = id
                        let d = try! JSONSerialization.data(withJSONObject: f)
                        door.receive(String(decoding: d, as: UTF8.self))
                    }
                }
            }
        }
    }

    static func response(_ content: Any) -> [String: Any] {
        let c = String(decoding: try! JSONSerialization.data(withJSONObject: content, options: [.fragmentsAllowed]), as: UTF8.self)
        return ["type": "response", "payload": ["senderName": "host", "senderType": "host", "content": c]]
    }

    func world() throws -> (AppState, ScriptedGateway) {
        let state = AppState(db: try DatabaseService(inMemory: true))
        state.door.receive(#"{"type":"welcome","sender_id":"host","self_peer":"\#(Self.me)"}"#)
        let gw = ScriptedGateway()
        gw.install(on: state.door)
        return (state, gw)
    }

    func invite(port: String = "P", code: Bool = false) -> String {
        InviteCoupon(host: Self.host, relays: ["wss://relay.test/v1"], port: port, rights: ["see", "use"],
                     nonce: "nonce-1", exp: Int(Date().timeIntervalSince1970) + 600, hostName: "Gordon",
                     portTitle: "shared chart", code: code).link
    }

    @Test("a remote call names the peer and its relays, streams events, and returns the response")
    func doorRoundTrip() async throws {
        let (state, gw) = try world()
        gw.reply = { _, _ in [["type": "stream", "payload": ["senderName": "host", "senderType": "host", "content": "{\"n\":1}"]],
                              Self.response(["ok": true])] }
        var events: [Any] = []
        let out = try await state.door.remoteCall(to: Self.host, relays: ["wss://r/v1"], method: "port.subscribe",
                                                  args: ["id": "P"], onStream: { events.append($0) })
        #expect((out as? [String: Any])?["ok"] as? Bool == true)
        #expect(events.count == 1)
        let sent = try #require(gw.calls.first)
        #expect(sent["to_peer"] as? String == Self.host && sent["relays"] as? [String] == ["wss://r/v1"])
        #expect((sent["args"] as? [String: Any])?["id"] as? String == "P")
    }

    @Test("the other instance's refusal, and a gateway error, arrive as errors with their codes")
    func refusalsThrow() async throws {
        let (state, gw) = try world()
        gw.reply = { _, _ in [Self.response(["code": "stale_write", "error": "moved", "current": "abc:7"])] }
        do { _ = try await state.door.remoteCall(to: Self.host, relays: ["r"], method: "port.update", args: [:]); Issue.record("no throw") }
        catch let e as BridgeError {
            #expect(e.code == "stale_write")
            #expect(e.details["current"] == "abc:7", "a refused write lost the token the writer retries with")
        }
        gw.reply = { _, _ in [["type": "error", "code": "host_offline", "error": "gone"]] }
        do { _ = try await state.door.remoteCall(to: Self.host, relays: ["r"], method: "ports.list", args: [:]); Issue.record("no throw") }
        catch let e as BridgeError { #expect(e.code == "host_offline") }
    }

    @Test("accepting an invite redeems it as this instance and remembers the port and its relays")
    func accept() async throws {
        let (state, gw) = try world()
        gw.reply = { method, args in
            method == "invite.redeem" && args["nonce"] as? String == "nonce-1"
                ? [Self.response(["port": "P", "title": "shared chart", "rights": ["see", "use"]])]
                : [Self.response(["code": "invite_invalid", "error": "no"])]
        }
        let person = Principal.human(id: "u", displayName: "Ada", spaceId: nil)
        let out = try await state.runBridgeMethod("invite.accept", principal: person, args: BridgeArgs(["link": invite()]))
        let o = try #require(out.toJSONObject() as? [String: Any])
        #expect(o["address"] as? String == "port42://\(Self.host)/P")
        let row = try #require(try state.db.remotePorts().first)
        #expect(row.peerKey == Self.host && row.portKey == "P" && row.relays == ["wss://relay.test/v1"])
        #expect(row.rights == [.see, .use])
    }

    @Test("a call naming a port on another instance is forwarded there, with the port's own id")
    func forwarding() async throws {
        let (state, gw) = try world()
        try state.db.upsertRemotePort(.init(peerKey: Self.host, portKey: "P", title: "t", rights: [.see],
                                            relays: ["wss://relay.test/v1"], hostName: "Gordon"))
        gw.reply = { method, args in [Self.response(method == "port.getHtml" && args["id"] as? String == "P" ? "<p>theirs</p>" : "wrong")] }
        let cli = Principal.peer(id: "cli", displayName: "cli")
        let out = try await state.runBridgeMethod("port.getHtml", principal: cli,
                                                  args: BridgeArgs(["id": "port42://\(Self.host)/P"]))
        #expect(out.toJSONObject() as? String == "<p>theirs</p>")
        #expect(gw.calls.first?["to_peer"] as? String == Self.host)
    }

    @Test("a port on another instance with no invite is not reached; a remote caller's is never forwarded")
    func notForwarded() async throws {
        let (state, gw) = try world()
        do {
            _ = try await state.runBridgeMethod("port.getHtml", principal: .peer(id: "cli", displayName: "cli"),
                                                args: BridgeArgs(["id": "port42://\(Self.host)/P"]))
            Issue.record("reached an instance with no invite")
        } catch let e as BridgeError { #expect(e.code == "not_found") }

        try state.db.upsertRemotePort(.init(peerKey: Self.host, portKey: "P", title: "t", rights: [.see],
                                            relays: ["r"], hostName: "Gordon"))
        let guest = Principal.remote(peer: "someone-elsewhere", displayName: "x")
        do {
            _ = try await state.runBridgeMethod("port.getHtml", principal: guest,
                                                args: BridgeArgs(["id": "port42://\(Self.host)/P"]))
            Issue.record("a remote caller was relayed on to a third instance")
        } catch let e as BridgeError { #expect(e.code == "not_granted") }
        #expect(gw.calls.isEmpty, "something was sent out")
    }

    @Test("the gateway's relay_state frames tell the app whether it is registered on each relay")
    func relayState() throws {
        let (state, _) = try world()
        state.door.receive(#"{"type":"relay_state","relays":["wss://relay1.port42.ai/v1"],"code":"registered"}"#)
        #expect(state.relayStates["wss://relay1.port42.ai/v1"] == true)
        state.door.receive(#"{"type":"relay_state","relays":["wss://relay1.port42.ai/v1"],"code":"not_registered"}"#)
        #expect(state.relayStates["wss://relay1.port42.ai/v1"] == false)
    }
}
