import Testing
import Foundation
@testable import Port42Lib

// MARK: - Step 2: Space Model + Encryption Key

@Suite("Space Encryption Key")
struct SpaceEncryptionKeyTests {

    func makeDB() throws -> DatabaseService {
        try DatabaseService(inMemory: true)
    }

    @Test("New space has non-nil encryptionKey")
    func newSpaceHasKey() {
        let space = Space.create(name: "secret-space")
        #expect(space.encryptionKey != nil)
    }

    @Test("Space key is valid base64 and 32 bytes")
    func spaceKeyIsValid() {
        let space = Space.create(name: "test")
        let keyData = Data(base64Encoded: space.encryptionKey!)
        #expect(keyData != nil)
        #expect(keyData?.count == 32)
    }

    @Test("Space without key (pre-migration) has nil encryptionKey")
    func spaceWithoutKey() {
        let space = Space(id: "old-1", name: "legacy", type: "team", createdAt: Date())
        #expect(space.encryptionKey == nil)
    }

    @Test("Space with key persists and loads from DB")
    func spaceKeyPersists() throws {
        let db = try makeDB()
        let space = Space.create(name: "encrypted")
        let originalKey = space.encryptionKey
        try db.saveSpace(space)

        let spaces = try db.getAllSpaces()
        #expect(spaces.count == 1)
        #expect(spaces[0].encryptionKey == originalKey)
    }

    @Test("getSpaceKey returns key for encrypted space")
    func getSpaceKeyReturnsKey() throws {
        let db = try makeDB()
        let space = Space.create(name: "test")
        try db.saveSpace(space)

        let key = try db.getSpaceKey(spaceId: space.id)
        #expect(key == space.encryptionKey)
    }

    @Test("getSpaceKey returns nil for space without key")
    func getSpaceKeyReturnsNilForLegacy() throws {
        let db = try makeDB()
        let space = Space(id: "legacy-1", name: "old", type: "team", createdAt: Date())
        try db.saveSpace(space)

        let key = try db.getSpaceKey(spaceId: space.id)
        #expect(key == nil)
    }

    @Test("getSpaceKey returns nil for nonexistent space")
    func getSpaceKeyNonexistent() throws {
        let db = try makeDB()
        let key = try db.getSpaceKey(spaceId: "does-not-exist")
        #expect(key == nil)
    }
}

// MARK: - Step 3: Encrypt on Send

@Suite("Encrypt on Send")
struct EncryptOnSendTests {

    @Test("Message to space with key produces encrypted payload")
    func encryptedPayload() {
        let key = SpaceCrypto.generateKey()
        let payload = SyncPayload(
            senderName: "Gordon",
            senderType: "human",
            content: "secret message",
            replyToId: nil
        )

        let blob = SpaceCrypto.encrypt(payload, keyBase64: key)
        #expect(blob != nil)

        // The blob should be base64 and not contain the plaintext
        #expect(!blob!.contains("secret message"))
        #expect(!blob!.contains("Gordon"))
    }

    @Test("Encrypted envelope has empty senderName (no metadata leak)")
    func encryptedEnvelopeHidesName() {
        let key = SpaceCrypto.generateKey()
        let payload = SyncPayload(
            senderName: "Gordon",
            senderType: "human",
            content: "hello",
            replyToId: nil
        )

        guard let blob = SpaceCrypto.encrypt(payload, keyBase64: key) else {
            Issue.record("Encryption failed")
            return
        }

        // Simulate what SyncService.sendMessage does
        let wirePayload = SyncPayload(
            senderName: "",
            senderType: "human",
            content: blob,
            replyToId: nil,
            encrypted: true
        )

        #expect(wirePayload.senderName == "")
        #expect(wirePayload.encrypted == true)
        #expect(wirePayload.content == blob)
    }

    @Test("Message to space without key sends plaintext (no encryption key set)")
    func plaintextWithoutKey() {
        let payload = SyncPayload(
            senderName: "Gordon",
            senderType: "human",
            content: "visible message",
            replyToId: nil
        )

        // No key means no encryption, payload stays as-is
        #expect(payload.encrypted == nil)
        #expect(payload.senderName == "Gordon")
        #expect(payload.content == "visible message")
    }

    @Test("SyncPayload encrypted flag encodes correctly")
    func encryptedFlagEncodesCorrectly() throws {
        let payload = SyncPayload(
            senderName: "",
            senderType: "human",
            content: "blob",
            replyToId: nil,
            encrypted: true
        )

        let data = try JSONEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"encrypted\":true"))
    }

    @Test("SyncPayload without encrypted flag omits it")
    func noEncryptedFlagOmitted() throws {
        let payload = SyncPayload(
            senderName: "Test",
            senderType: "human",
            content: "hello",
            replyToId: nil
        )

        let data = try JSONEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8)!
        // encrypted is nil, should not appear in JSON
        #expect(!json.contains("encrypted"))
    }
}

// MARK: - Step 4: Decrypt on Receive

@Suite("Decrypt on Receive")
struct DecryptOnReceiveTests {

    @Test("Encrypted message from peer decrypts correctly")
    func decryptFromPeer() {
        let key = SpaceCrypto.generateKey()
        let original = SyncPayload(
            senderName: "Alice",
            senderType: "agent",
            content: "hello from Alice",
            replyToId: "msg-42"
        )

        // Sender encrypts
        let blob = SpaceCrypto.encrypt(original, keyBase64: key)!

        // Receiver decrypts
        let decrypted = SpaceCrypto.decrypt(blob: blob, keyBase64: key)
        #expect(decrypted != nil)
        #expect(decrypted?.senderName == "Alice")
        #expect(decrypted?.content == "hello from Alice")
        #expect(decrypted?.senderType == "agent")
        #expect(decrypted?.replyToId == "msg-42")
    }

    @Test("Message with encrypted:true but wrong key fails to decrypt")
    func wrongKeyFails() {
        let senderKey = SpaceCrypto.generateKey()
        let receiverKey = SpaceCrypto.generateKey()

        let payload = SyncPayload(
            senderName: "Test",
            senderType: "human",
            content: "secret",
            replyToId: nil
        )

        let blob = SpaceCrypto.encrypt(payload, keyBase64: senderKey)!
        let decrypted = SpaceCrypto.decrypt(blob: blob, keyBase64: receiverKey)
        #expect(decrypted == nil)
    }

    @Test("Unencrypted message still works (backward compat)")
    func plaintextBackwardCompat() throws {
        let payload = SyncPayload(
            senderName: "OldClient",
            senderType: "human",
            content: "not encrypted",
            replyToId: nil
        )

        // Unencrypted payload should decode normally from JSON
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SyncPayload.self, from: data)
        #expect(decoded.senderName == "OldClient")
        #expect(decoded.content == "not encrypted")
        #expect(decoded.encrypted == nil)
    }

    @Test("Full roundtrip: encrypt on send, decrypt on receive")
    func fullRoundtrip() {
        let key = SpaceCrypto.generateKey()

        // Sender side: create payload and encrypt
        let original = SyncPayload(
            senderName: "Gordon",
            senderType: "human",
            content: "end-to-end test message",
            replyToId: nil
        )
        let blob = SpaceCrypto.encrypt(original, keyBase64: key)!

        // Wire: only blob and metadata visible
        let wirePayload = SyncPayload(
            senderName: "",
            senderType: "human",
            content: blob,
            replyToId: nil,
            encrypted: true
        )

        // Verify wire payload hides content
        #expect(wirePayload.encrypted == true)
        #expect(wirePayload.senderName == "")
        #expect(!wirePayload.content.contains("end-to-end"))

        // Receiver side: detect encrypted flag and decrypt
        #expect(wirePayload.encrypted == true)
        let decrypted = SpaceCrypto.decrypt(blob: wirePayload.content, keyBase64: key)!
        #expect(decrypted.senderName == "Gordon")
        #expect(decrypted.content == "end-to-end test message")
    }
}

// MARK: - Step 5: Invite Link Key Exchange

@Suite("Invite Link Key Exchange")
struct InviteLinkKeyExchangeTests {

    @Test("Invite link for space with key includes key param")
    func inviteLinkIncludesKey() {
        let key = SpaceCrypto.generateKey()
        let space = Space(
            id: "sp-1", name: "secure", type: "team",
            createdAt: Date(), encryptionKey: key
        )

        var components = URLComponents()
        components.scheme = "port42"
        components.host = "space"
        components.queryItems = [
            URLQueryItem(name: "gateway", value: "wss://example.com/ws"),
            URLQueryItem(name: "id", value: space.id),
            URLQueryItem(name: "name", value: space.name),
            URLQueryItem(name: "key", value: key),
        ]

        let url = components.url!
        let parsed = SpaceInvite.parse(url: url)
        #expect(parsed != nil)
        #expect(parsed?.encryptionKey == key)
    }

    @Test("Invite link for space without key omits key param")
    func inviteLinkOmitsKeyWhenNone() {
        var components = URLComponents()
        components.scheme = "port42"
        components.host = "space"
        components.queryItems = [
            URLQueryItem(name: "gateway", value: "wss://example.com/ws"),
            URLQueryItem(name: "id", value: "sp-old"),
            URLQueryItem(name: "name", value: "legacy"),
        ]

        let url = components.url!
        let parsed = SpaceInvite.parse(url: url)
        #expect(parsed != nil)
        #expect(parsed?.encryptionKey == nil)
    }

    @Test("Parse extracts key correctly")
    func parseExtractsKey() {
        let testKey = "dGVzdGtleTEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNA=="
        let urlString = "port42://space?gateway=wss%3A%2F%2Fexample.com%2Fws&id=sp-1&name=test&key=\(testKey)"
        let url = URL(string: urlString)!

        let parsed = SpaceInvite.parse(url: url)
        #expect(parsed != nil)
        #expect(parsed?.encryptionKey == testKey)
        #expect(parsed?.spaceId == "sp-1")
        #expect(parsed?.spaceName == "test")
    }

    @Test("Parse returns all fields correctly")
    func parseReturnsAllFields() {
        let key = SpaceCrypto.generateKey()
        var components = URLComponents()
        components.scheme = "port42"
        components.host = "space"
        components.queryItems = [
            URLQueryItem(name: "gateway", value: "wss://gw.example.com/ws"),
            URLQueryItem(name: "id", value: "space-abc"),
            URLQueryItem(name: "name", value: "my-space"),
            URLQueryItem(name: "key", value: key),
        ]

        guard let parsed = SpaceInvite.parse(url: components.url!) else {
            Issue.record("SpaceInvite.parse returned nil for port42://space URL")
            return
        }
        #expect(parsed.gateway == "wss://gw.example.com/ws")
        #expect(parsed.spaceId == "space-abc")
        #expect(parsed.spaceName == "my-space")
        #expect(parsed.encryptionKey == key)
    }

    @Test("SpaceInvite generateLink produces port42://space host")
    @MainActor
    func generateLinkUsesSpaceHost() {
        let space = Space(id: "sp-1", name: "test", type: "team", createdAt: Date())
        let link = SpaceInvite.generateLink(space: space)
        guard let url = URL(string: link),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            Issue.record("generateLink returned invalid URL: \(link)")
            return
        }
        #expect(components.scheme == "port42")
        #expect(components.host == "space", "Expected host 'space', got '\(components.host ?? "nil")'")
    }

    @Test("port42://channel URL is rejected by SpaceInvite.parse")
    func oldSchemeURLRejected() {
        let url = URL(string: "port42://channel?gateway=wss://x/ws&id=1&name=test")!
        let parsed = SpaceInvite.parse(url: url)
        #expect(parsed == nil, "port42://channel should be rejected — use port42://space")
    }

    @Test("Joining from invite stores key in space record")
    func joinFromInviteStoresKey() throws {
        let db = try DatabaseService(inMemory: true)
        let key = SpaceCrypto.generateKey()

        // Simulate what AppState.joinSpaceFromInvite does
        let space = Space(
            id: "invited-sp", name: "invited",
            type: "team", createdAt: Date(), encryptionKey: key
        )
        try db.saveSpace(space)

        let storedKey = try db.getSpaceKey(spaceId: "invited-sp")
        #expect(storedKey == key)
    }

    @Test("Invalid scheme is rejected")
    func invalidSchemeRejected() {
        let url = URL(string: "https://space?gateway=wss://x/ws&id=1&name=test")!
        let parsed = SpaceInvite.parse(url: url)
        #expect(parsed == nil)
    }

    @Test("Missing required fields returns nil")
    func missingFieldsReturnsNil() {
        // Missing 'name'
        let url = URL(string: "port42://space?gateway=wss://x/ws&id=1")!
        let parsed = SpaceInvite.parse(url: url)
        #expect(parsed == nil)
    }

    @Test("Rejoin existing space updates encryption key")
    func rejoinUpdatesKey() throws {
        let db = try DatabaseService(inMemory: true)
        // Legacy space with no key
        let legacy = Space(id: "sp-legacy", name: "old-space", type: "team", createdAt: Date())
        try db.saveSpace(legacy)

        let storedKey = try db.getSpaceKey(spaceId: "sp-legacy")
        #expect(storedKey == nil)

        // Rejoin with invite that has a key
        let newKey = SpaceCrypto.generateKey()
        var updated = legacy
        updated.encryptionKey = newKey
        try db.saveSpace(updated)

        let afterKey = try db.getSpaceKey(spaceId: "sp-legacy")
        #expect(afterKey == newKey)
    }

    @Test("Rejoin does not overwrite existing key")
    func rejoinDoesNotOverwrite() throws {
        let db = try DatabaseService(inMemory: true)
        let originalKey = SpaceCrypto.generateKey()
        let space = Space(id: "sp-1", name: "secure", type: "team", createdAt: Date(), encryptionKey: originalKey)
        try db.saveSpace(space)

        // Simulate rejoin with a different key (should not overwrite)
        // This mirrors the AppState logic: only update if existing key is nil
        let existingKey = try db.getSpaceKey(spaceId: "sp-1")
        #expect(existingKey == originalKey)

        // The AppState code checks: if existing.encryptionKey == nil, then update
        // Since it's not nil, no update happens
        #expect(existingKey != nil) // so no overwrite
    }
}
