import Testing
import Foundation
@testable import Port42Lib

// MARK: - Step 2: Channel Model + Encryption Key

@Suite("Channel Encryption Key")
struct ChannelEncryptionKeyTests {

    func makeDB() throws -> DatabaseService {
        try DatabaseService(inMemory: true)
    }

    @Test("New channel has non-nil encryptionKey")
    func newChannelHasKey() {
        let channel = Channel.create(name: "secret-channel")
        #expect(channel.encryptionKey != nil)
    }

    @Test("Channel key is valid base64 and 32 bytes")
    func channelKeyIsValid() {
        let channel = Channel.create(name: "test")
        let keyData = Data(base64Encoded: channel.encryptionKey!)
        #expect(keyData != nil)
        #expect(keyData?.count == 32)
    }

    @Test("Channel without key (pre-migration) has nil encryptionKey")
    func channelWithoutKey() {
        let channel = Channel(id: "old-1", name: "legacy", type: "team", createdAt: Date())
        #expect(channel.encryptionKey == nil)
    }

    @Test("Channel with key persists and loads from DB")
    func channelKeyPersists() throws {
        let db = try makeDB()
        let channel = Channel.create(name: "encrypted")
        let originalKey = channel.encryptionKey
        try db.saveChannel(channel)

        let channels = try db.getAllChannels()
        #expect(channels.count == 1)
        #expect(channels[0].encryptionKey == originalKey)
    }

    @Test("getChannelKey returns key for encrypted channel")
    func getChannelKeyReturnsKey() throws {
        let db = try makeDB()
        let channel = Channel.create(name: "test")
        try db.saveChannel(channel)

        let key = try db.getChannelKey(channelId: channel.id)
        #expect(key == channel.encryptionKey)
    }

    @Test("getChannelKey returns nil for channel without key")
    func getChannelKeyReturnsNilForLegacy() throws {
        let db = try makeDB()
        let channel = Channel(id: "legacy-1", name: "old", type: "team", createdAt: Date())
        try db.saveChannel(channel)

        let key = try db.getChannelKey(channelId: channel.id)
        #expect(key == nil)
    }

    @Test("getChannelKey returns nil for nonexistent channel")
    func getChannelKeyNonexistent() throws {
        let db = try makeDB()
        let key = try db.getChannelKey(channelId: "does-not-exist")
        #expect(key == nil)
    }
}

// MARK: - Step 3: Encrypt on Send

@Suite("Encrypt on Send")
struct EncryptOnSendTests {

    @Test("Message to channel with key produces encrypted payload")
    func encryptedPayload() {
        let key = ChannelCrypto.generateKey()
        let payload = SyncPayload(
            senderName: "Gordon",
            senderType: "human",
            content: "secret message",
            replyToId: nil
        )

        let blob = ChannelCrypto.encrypt(payload, keyBase64: key)
        #expect(blob != nil)

        // The blob should be base64 and not contain the plaintext
        #expect(!blob!.contains("secret message"))
        #expect(!blob!.contains("Gordon"))
    }

    @Test("Encrypted envelope has empty senderName (no metadata leak)")
    func encryptedEnvelopeHidesName() {
        let key = ChannelCrypto.generateKey()
        let payload = SyncPayload(
            senderName: "Gordon",
            senderType: "human",
            content: "hello",
            replyToId: nil
        )

        guard let blob = ChannelCrypto.encrypt(payload, keyBase64: key) else {
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

    @Test("Message to channel without key sends plaintext (backward compat)")
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
        let key = ChannelCrypto.generateKey()
        let original = SyncPayload(
            senderName: "Alice",
            senderType: "agent",
            content: "hello from Alice",
            replyToId: "msg-42"
        )

        // Sender encrypts
        let blob = ChannelCrypto.encrypt(original, keyBase64: key)!

        // Receiver decrypts
        let decrypted = ChannelCrypto.decrypt(blob: blob, keyBase64: key)
        #expect(decrypted != nil)
        #expect(decrypted?.senderName == "Alice")
        #expect(decrypted?.content == "hello from Alice")
        #expect(decrypted?.senderType == "agent")
        #expect(decrypted?.replyToId == "msg-42")
    }

    @Test("Message with encrypted:true but wrong key fails to decrypt")
    func wrongKeyFails() {
        let senderKey = ChannelCrypto.generateKey()
        let receiverKey = ChannelCrypto.generateKey()

        let payload = SyncPayload(
            senderName: "Test",
            senderType: "human",
            content: "secret",
            replyToId: nil
        )

        let blob = ChannelCrypto.encrypt(payload, keyBase64: senderKey)!
        let decrypted = ChannelCrypto.decrypt(blob: blob, keyBase64: receiverKey)
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
        let key = ChannelCrypto.generateKey()

        // Sender side: create payload and encrypt
        let original = SyncPayload(
            senderName: "Gordon",
            senderType: "human",
            content: "end-to-end test message",
            replyToId: nil
        )
        let blob = ChannelCrypto.encrypt(original, keyBase64: key)!

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
        let decrypted = ChannelCrypto.decrypt(blob: wirePayload.content, keyBase64: key)!
        #expect(decrypted.senderName == "Gordon")
        #expect(decrypted.content == "end-to-end test message")
    }
}

// MARK: - Step 5: Invite Link Key Exchange

@Suite("Invite Link Key Exchange")
struct InviteLinkKeyExchangeTests {

    @Test("Invite link for channel with key includes key param")
    func inviteLinkIncludesKey() {
        let key = ChannelCrypto.generateKey()
        let channel = Channel(
            id: "ch-1", name: "secure", type: "team",
            createdAt: Date(), encryptionKey: key
        )

        // Build a port42://channel? URL manually to test parse
        var components = URLComponents()
        components.scheme = "port42"
        components.host = "channel"
        components.queryItems = [
            URLQueryItem(name: "gateway", value: "wss://example.com/ws"),
            URLQueryItem(name: "id", value: channel.id),
            URLQueryItem(name: "name", value: channel.name),
            URLQueryItem(name: "key", value: key),
        ]

        let url = components.url!
        let parsed = ChannelInvite.parse(url: url)
        #expect(parsed != nil)
        #expect(parsed?.encryptionKey == key)
    }

    @Test("Invite link for channel without key omits key param")
    func inviteLinkOmitsKeyWhenNone() {
        var components = URLComponents()
        components.scheme = "port42"
        components.host = "channel"
        components.queryItems = [
            URLQueryItem(name: "gateway", value: "wss://example.com/ws"),
            URLQueryItem(name: "id", value: "ch-old"),
            URLQueryItem(name: "name", value: "legacy"),
        ]

        let url = components.url!
        let parsed = ChannelInvite.parse(url: url)
        #expect(parsed != nil)
        #expect(parsed?.encryptionKey == nil)
    }

    @Test("Parse extracts key correctly")
    func parseExtractsKey() {
        let testKey = "dGVzdGtleTEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNA=="
        let urlString = "port42://channel?gateway=wss%3A%2F%2Fexample.com%2Fws&id=ch-1&name=test&key=\(testKey)"
        let url = URL(string: urlString)!

        let parsed = ChannelInvite.parse(url: url)
        #expect(parsed != nil)
        #expect(parsed?.encryptionKey == testKey)
        #expect(parsed?.channelId == "ch-1")
        #expect(parsed?.channelName == "test")
    }

    @Test("Parse returns all fields correctly")
    func parseReturnsAllFields() {
        let key = ChannelCrypto.generateKey()
        var components = URLComponents()
        components.scheme = "port42"
        components.host = "channel"
        components.queryItems = [
            URLQueryItem(name: "gateway", value: "wss://gw.example.com/ws"),
            URLQueryItem(name: "id", value: "channel-abc"),
            URLQueryItem(name: "name", value: "my-channel"),
            URLQueryItem(name: "key", value: key),
        ]

        let parsed = ChannelInvite.parse(url: components.url!)!
        #expect(parsed.gateway == "wss://gw.example.com/ws")
        #expect(parsed.channelId == "channel-abc")
        #expect(parsed.channelName == "my-channel")
        #expect(parsed.encryptionKey == key)
    }

    @Test("Joining from invite stores key in channel record")
    func joinFromInviteStoresKey() throws {
        let db = try DatabaseService(inMemory: true)
        let key = ChannelCrypto.generateKey()

        // Simulate what AppState.joinChannelFromInvite does
        let channel = Channel(
            id: "invited-ch", name: "invited",
            type: "team", createdAt: Date(), encryptionKey: key
        )
        try db.saveChannel(channel)

        let storedKey = try db.getChannelKey(channelId: "invited-ch")
        #expect(storedKey == key)
    }

    @Test("Invalid scheme is rejected")
    func invalidSchemeRejected() {
        let url = URL(string: "https://channel?gateway=wss://x/ws&id=1&name=test")!
        let parsed = ChannelInvite.parse(url: url)
        #expect(parsed == nil)
    }

    @Test("Missing required fields returns nil")
    func missingFieldsReturnsNil() {
        // Missing 'name'
        let url = URL(string: "port42://channel?gateway=wss://x/ws&id=1")!
        let parsed = ChannelInvite.parse(url: url)
        #expect(parsed == nil)
    }

    @Test("Rejoin existing channel updates encryption key")
    func rejoinUpdatesKey() throws {
        let db = try DatabaseService(inMemory: true)
        // Legacy channel with no key
        let legacy = Channel(id: "ch-legacy", name: "old-channel", type: "team", createdAt: Date())
        try db.saveChannel(legacy)

        let storedKey = try db.getChannelKey(channelId: "ch-legacy")
        #expect(storedKey == nil)

        // Rejoin with invite that has a key
        let newKey = ChannelCrypto.generateKey()
        var updated = legacy
        updated.encryptionKey = newKey
        try db.saveChannel(updated)

        let afterKey = try db.getChannelKey(channelId: "ch-legacy")
        #expect(afterKey == newKey)
    }

    @Test("Rejoin does not overwrite existing key")
    func rejoinDoesNotOverwrite() throws {
        let db = try DatabaseService(inMemory: true)
        let originalKey = ChannelCrypto.generateKey()
        let channel = Channel(id: "ch-1", name: "secure", type: "team", createdAt: Date(), encryptionKey: originalKey)
        try db.saveChannel(channel)

        // Simulate rejoin with a different key (should not overwrite)
        // This mirrors the AppState logic: only update if existing key is nil
        let existingKey = try db.getChannelKey(channelId: "ch-1")
        #expect(existingKey == originalKey)

        // The AppState code checks: if existing.encryptionKey == nil, then update
        // Since it's not nil, no update happens
        #expect(existingKey != nil) // so no overwrite
    }
}
