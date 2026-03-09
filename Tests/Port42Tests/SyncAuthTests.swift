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
