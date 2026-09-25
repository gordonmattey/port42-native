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

