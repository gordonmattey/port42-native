import Testing
import Foundation
@testable import Port42Lib

/// The call door on its own connection (nautilus Phase 0 step 2, docs/plan-nautilus-phase0.md).
///
/// Every external call reaches the app through `GatewayDoor`. These drive it frame by frame with no
/// gateway: `receive` takes what the gateway would send, and `sendOverride` collects what the door
/// sends back.
@Suite("Gateway door")
@MainActor
struct GatewayDoorTests {

    final class Wire {
        var sent: [[String: Any]] = []
        func record(_ text: String) {
            if let d = text.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { sent.append(o) }
        }
        func frames(_ type: String) -> [[String: Any]] { sent.filter { $0["type"] as? String == type } }
    }

    func door(_ wire: Wire) -> GatewayDoor {
        let d = GatewayDoor()
        d.sendOverride = { wire.record($0) }
        return d
    }

    func settle(_ wire: Wire, until: () -> Bool) async {
        for _ in 0..<200 where !until() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    static func call(_ id: String, method: String, args: String = "{}", credential: String? = "p42_tok",
                     streamable: Bool = false) -> String {
        var fields = ["\"type\":\"call\"", "\"call_id\":\"\(id)\"", "\"sender_id\":\"caller-1\"",
                      "\"method\":\"\(method)\"", "\"args\":\(args)"]
        if let credential { fields.append("\"credential\":\"\(credential)\"") }
        if streamable { fields.append("\"streamable\":true") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    static func content(_ frame: [String: Any]) -> Any? {
        guard let p = frame["payload"] as? [String: Any], let c = p["content"] as? String,
              let d = c.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    @Test("a call reaches the handler with its method, args, sender and credential, and its response returns on the same call id")
    func callAndResponse() async {
        let wire = Wire(), d = door(wire)
        var seen: (String, String, String, [String: Any], String?)?
        d.onCallReceived = { sender, callId, method, input, credential, _ in
            seen = (sender, callId, method, input, credential)
            return ["ok": true, "token": "abc:1"]
        }
        d.receive(Self.call("c-1", method: "port.update", args: "{\"id\":\"P\",\"token\":\"abc:0\"}"))
        await settle(wire) { !wire.frames("response").isEmpty }

        #expect(seen?.0 == "caller-1")
        #expect(seen?.1 == "c-1")
        #expect(seen?.2 == "port.update")
        #expect(seen?.3["id"] as? String == "P")
        #expect(seen?.4 == "p42_tok")
        let r = try? #require(wire.frames("response").first)
        #expect(r?["call_id"] as? String == "c-1")
        #expect(r?["target_id"] as? String == "caller-1")
        #expect((Self.content(r ?? [:]) as? [String: Any])?["token"] as? String == "abc:1")
    }

    @Test("the response payload is exactly the published /call shape: content, senderName, senderType")
    func publishedShape() async {
        let wire = Wire(), d = door(wire)
        d.onCallReceived = { _, _, _, _, _, _ in 42 }   // a bare scalar must not wedge the encoder
        d.receive(Self.call("c-2", method: "x"))
        await settle(wire) { !wire.frames("response").isEmpty }
        let payload = wire.frames("response").first?["payload"] as? [String: Any]
        #expect(Set(payload?.keys.map { $0 } ?? []) == ["content", "senderName", "senderType"])
        #expect(payload?["content"] as? String == "42")
        #expect(payload?["senderName"] as? String == "host")
    }

    @Test("a streamable call's frames arrive as stream envelopes, in order, before its response")
    func streamFrames() async {
        let wire = Wire(), d = door(wire)
        d.onCallReceived = { _, _, _, _, _, emit in
            emit?(["kind": "state", "n": 1])
            emit?(["kind": "state", "n": 2])
            return ["ok": true]
        }
        d.receive(Self.call("s-1", method: "port.subscribe", streamable: true))
        await settle(wire) { !wire.frames("response").isEmpty }

        let types = wire.sent.compactMap { $0["type"] as? String }
        #expect(types == ["stream", "stream", "response"])
        let ns = wire.frames("stream").compactMap { (Self.content($0) as? [String: Any])?["n"] as? Int }
        #expect(ns == [1, 2])
        #expect(wire.frames("stream").allSatisfy { $0["call_id"] as? String == "s-1" })
    }

    @Test("a call from a door that cannot stream gets no emit, so a streaming method can refuse")
    func noEmitWithoutStreamable() async {
        let wire = Wire(), d = door(wire)
        var hadEmit = true
        d.onCallReceived = { _, _, _, _, _, emit in hadEmit = (emit != nil); return ["ok": true] }
        d.receive(Self.call("h-1", method: "port.subscribe", streamable: false))
        await settle(wire) { !wire.frames("response").isEmpty }
        #expect(hadEmit == false)
        #expect(wire.frames("stream").isEmpty)
    }

    @Test("with no handler a call is answered unsupported, never left hanging")
    func noHandler() async {
        let wire = Wire(), d = door(wire)
        d.receive(Self.call("n-1", method: "anything"))
        await settle(wire) { !wire.frames("response").isEmpty }
        #expect((Self.content(wire.frames("response").first ?? [:]) as? [String: Any])?["code"] as? String
                == BridgeErrorCode.unsupported.wire)
    }

    @Test("welcome marks the door connected; nothing else does")
    func welcomeConnects() {
        let wire = Wire(), d = door(wire)
        d.receive("{\"type\":\"no_auth\"}")
        #expect(d.isConnected == false)
        d.receive("{\"type\":\"welcome\",\"sender_id\":\"app\"}")
        #expect(d.isConnected == true)
    }

    @Test("every DoorEnvelope field survives the wire (explicit CodingKeys drop an unlisted one silently)")
    func codingKeysComplete() throws {
        let wire = """
        {"type":"call","sender_id":"s","sender_name":"n","is_host":true,"host_credential":"h",
         "credential":"c","streamable":true,"method":"m","args":{"a":1},"call_id":"i","target_id":"t",
         "payload":{"senderName":"host","senderType":"host","content":"x"},"error":"e","code":"k"}
        """
        let e = try JSONDecoder().decode(DoorEnvelope.self, from: Data(wire.utf8))
        let values: [Any?] = [e.senderId, e.senderName, e.isHost, e.hostCredential, e.credential, e.streamable,
                              e.method, e.args, e.callId, e.targetId, e.payload, e.error, e.code]
        #expect(values.allSatisfy { $0 != nil }, "a DoorEnvelope field did not decode")
    }

    @Test("a gateway that dies unasked is respawned, at most five times a minute")
    func respawnPolicy() {
        let now = Date()
        #expect(GatewayProcess.shouldRespawn(after: [], now: now))
        let four = (1...4).map { now.addingTimeInterval(TimeInterval(-$0)) }
        #expect(GatewayProcess.shouldRespawn(after: four, now: now))
        let five = four + [now.addingTimeInterval(-10)]
        #expect(!GatewayProcess.shouldRespawn(after: five, now: now), "a sixth death inside a minute stays down")
        let old = (1...5).map { now.addingTimeInterval(TimeInterval(-60 - $0)) }
        #expect(GatewayProcess.shouldRespawn(after: old, now: now), "deaths older than the window do not count")
    }

}
