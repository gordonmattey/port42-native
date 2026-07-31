import Testing
import Foundation
@testable import Port42Lib

@Suite("SyncAuth")
struct SyncAuthTests {

    // MARK: - SyncEnvelope auth fields

    @Test("SyncEnvelope encodes auth fields correctly")
    func envelopeEncodesAuth() throws {
        let envelope = SyncEnvelope(
            type: "identify",
            senderId: "peer-1",
            senderName: "Test",
            identityToken: "jwt-token-here",
            authType: "apple"
        )
        let data = try JSONEncoder().encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["identity_token"] as? String == "jwt-token-here")
        #expect(json["auth_type"] as? String == "apple")
    }

    @Test("SyncEnvelope decodes challenge with nonce")
    func envelopeDecodesChallenge() throws {
        let json = """
        {"type":"challenge","nonce":"abc123def456"}
        """
        let data = json.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(SyncEnvelope.self, from: data)

        #expect(envelope.type == "challenge")
        #expect(envelope.nonce == "abc123def456")
    }

    @Test("SyncEnvelope auth fields omitted when nil")
    func envelopeOmitsNilAuth() throws {
        let envelope = SyncEnvelope(type: "welcome", senderId: "peer-1")
        let data = try JSONEncoder().encode(envelope)
        let text = String(data: data, encoding: .utf8)!

        #expect(!text.contains("nonce"))
        #expect(!text.contains("identity_token"))
        #expect(!text.contains("auth_type"))
    }

    @Test("SyncEnvelope round-trips all auth fields")
    func envelopeRoundTrip() throws {
        let original = SyncEnvelope(
            type: "identify",
            senderId: "peer-1",
            senderName: "Test",
            nonce: "nonce-value",
            identityToken: "token-value",
            authType: "apple"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SyncEnvelope.self, from: data)

        #expect(decoded.nonce == "nonce-value")
        #expect(decoded.identityToken == "token-value")
        #expect(decoded.authType == "apple")
    }

    // MARK: - Localhost detection

    @Test("Localhost URL detected as local")
    func localhostDetected() {
        #expect(SyncService.isLocalGateway("ws://localhost:4242") == true)
    }

    @Test("127.0.0.1 URL detected as local")
    func loopbackDetected() {
        #expect(SyncService.isLocalGateway("ws://127.0.0.1:4242") == true)
    }

    @Test("Remote URL not detected as local")
    func remoteNotLocal() {
        #expect(SyncService.isLocalGateway("wss://abc123.ngrok.io") == false)
    }

    @Test("HTTPS remote URL not detected as local")
    func httpsRemoteNotLocal() {
        #expect(SyncService.isLocalGateway("wss://gateway.port42.ai") == false)
    }

    // MARK: - Nonce hashing (shared with AppleAuthService)

    @Test("hashNonce matches known SHA256 vector")
    func nonceHashVector() {
        // SHA256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        let hash = hashNonce("hello")
        #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}

// MARK: - Every field survives the wire
//
// `SyncEnvelope` declares EXPLICIT `CodingKeys`, which means a property left out of that list is
// silently never coded. It compiles, it runs, and the value is always nil.
//
// That is not hypothetical. `streamable` was added 2026-07-30 and omitted from the list, so every
// WebSocket caller decoded as non-streamable and was refused a subscription on the one door that
// supports it. Nothing failed; the field was simply always absent.
//
// So the gate is on the CLASS, not on that field: populate every property, round-trip through JSON,
// and report any that came back nil.
@Suite("SyncEnvelope — CodingKeys completeness")
struct SyncEnvelopeCodingTests {

    /// An envelope with every single property set to something non-nil.
    static func fullyPopulated() -> SyncEnvelope {
        var e = SyncEnvelope(type: "call")
        e.spaceId = "space-1"
        e.senderId = "sender-1"
        e.senderName = "Sender One"
        e.peerId = "peer-1"
        e.messageId = "msg-1"
        e.payload = SyncPayload(senderName: "host", senderType: "host",
                                content: "body", replyToId: "reply-1",
                                encrypted: false, senderOwner: "owner-1")
        e.timestamp = 1_700_000_000
        e.error = "an error"
        e.token = "tok-1"
        e.onlineIds = ["a"]
        e.status = "online"
        e.companionIds = ["c"]
        e.nonce = "nonce-1"
        e.identityToken = "identity-1"
        e.authType = "apple"
        e.isHost = true
        e.hostCredential = "hostcred-1"
        e.credential = "clientcred-1"
        e.streamable = true
        e.method = "port.subscribe"
        e.args = ["id": .string("port-1")]
        e.callId = "call-1"
        e.targetId = "target-1"
        return e
    }

    @Test("no property is dropped by CodingKeys: everything set comes back set")
    func everyPropertyRoundTrips() throws {
        let original = Self.fullyPopulated()

        // Precondition: the fixture really does set everything. If a property is added to the
        // envelope and not to `fullyPopulated`, this catches THAT too, so the fixture cannot rot
        // into passing vacuously.
        let unsetInFixture = Mirror(reflecting: original).children.compactMap { child -> String? in
            isNilValue(child.value) ? (child.label ?? "?") : nil
        }
        #expect(unsetInFixture.isEmpty, """
            fullyPopulated() does not set: \(unsetInFixture.joined(separator: ", "))
            Set them, or this gate passes without checking those fields.
            """)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SyncEnvelope.self, from: data)

        let dropped = Mirror(reflecting: decoded).children.compactMap { child -> String? in
            isNilValue(child.value) ? (child.label ?? "?") : nil
        }
        #expect(dropped.isEmpty, """
            these did not survive a JSON round-trip: \(dropped.joined(separator: ", "))
            They are missing from SyncEnvelope.CodingKeys, which is explicit — an omitted property \
            is never coded and reads as nil forever. That is how `streamable` shipped broken.
            """)
    }

    /// The specific field, named, so a failure says what broke rather than only that something did.
    @Test("streamable survives the wire, because a WS caller's whole door depends on it")
    func streamableRoundTrips() throws {
        let wire = #"{"type":"call","method":"port.subscribe","streamable":true}"#
        let decoded = try JSONDecoder().decode(SyncEnvelope.self, from: Data(wire.utf8))
        #expect(decoded.streamable == true,
                "the gateway sets this on the WS door; dropped, every WS caller looks like an HTTP one")
    }

    private func isNilValue(_ value: Any) -> Bool {
        let m = Mirror(reflecting: value)
        return m.displayStyle == .optional && m.children.isEmpty
    }
}
