import Testing
import Foundation
@testable import Port42Lib

@Suite("ChannelCrypto")
struct ChannelCryptoTests {

    // MARK: - Key Generation

    @Test("Generated key is valid 32-byte base64")
    func generatedKeyIsValid() {
        let key = ChannelCrypto.generateKey()
        let data = Data(base64Encoded: key)
        #expect(data != nil)
        #expect(data?.count == 32)
    }

    @Test("Generated keys are unique")
    func generatedKeysAreUnique() {
        let key1 = ChannelCrypto.generateKey()
        let key2 = ChannelCrypto.generateKey()
        #expect(key1 != key2)
    }

    // MARK: - Encrypt / Decrypt Roundtrip

    @Test("Encrypt then decrypt roundtrip")
    func roundtrip() {
        let key = ChannelCrypto.generateKey()
        let payload = SyncPayload(
            senderName: "Gordon",
            senderType: "human",
            content: "hello world",
            replyToId: nil
        )

        let blob = ChannelCrypto.encrypt(payload, keyBase64: key)
        #expect(blob != nil)

        let decrypted = ChannelCrypto.decrypt(blob: blob!, keyBase64: key)
        #expect(decrypted != nil)
        #expect(decrypted?.senderName == "Gordon")
        #expect(decrypted?.content == "hello world")
        #expect(decrypted?.senderType == "human")
        #expect(decrypted?.replyToId == nil)
    }

    @Test("Roundtrip preserves replyToId")
    func roundtripWithReplyToId() {
        let key = ChannelCrypto.generateKey()
        let payload = SyncPayload(
            senderName: "Alice",
            senderType: "agent",
            content: "replying",
            replyToId: "msg-123"
        )

        let blob = ChannelCrypto.encrypt(payload, keyBase64: key)!
        let decrypted = ChannelCrypto.decrypt(blob: blob, keyBase64: key)!
        #expect(decrypted.replyToId == "msg-123")
    }

    @Test("Roundtrip with empty content")
    func roundtripEmptyContent() {
        let key = ChannelCrypto.generateKey()
        let payload = SyncPayload(
            senderName: "Bot",
            senderType: "agent",
            content: "",
            replyToId: nil
        )

        let blob = ChannelCrypto.encrypt(payload, keyBase64: key)!
        let decrypted = ChannelCrypto.decrypt(blob: blob, keyBase64: key)!
        #expect(decrypted.content == "")
    }

    @Test("Roundtrip with unicode content")
    func roundtripUnicode() {
        let key = ChannelCrypto.generateKey()
        let payload = SyncPayload(
            senderName: "test",
            senderType: "human",
            content: "hello there friend",
            replyToId: nil
        )

        let blob = ChannelCrypto.encrypt(payload, keyBase64: key)!
        let decrypted = ChannelCrypto.decrypt(blob: blob, keyBase64: key)!
        #expect(decrypted.content == "hello there friend")
    }

    // MARK: - Nonce Uniqueness

    @Test("Encrypt produces different ciphertext each time (random nonce)")
    func differentCiphertextEachTime() {
        let key = ChannelCrypto.generateKey()
        let payload = SyncPayload(
            senderName: "test",
            senderType: "human",
            content: "same message",
            replyToId: nil
        )

        let blob1 = ChannelCrypto.encrypt(payload, keyBase64: key)!
        let blob2 = ChannelCrypto.encrypt(payload, keyBase64: key)!
        #expect(blob1 != blob2)
    }

    // MARK: - Failure Cases

    @Test("Decrypt with wrong key returns nil")
    func decryptWrongKey() {
        let key1 = ChannelCrypto.generateKey()
        let key2 = ChannelCrypto.generateKey()
        let payload = SyncPayload(
            senderName: "test",
            senderType: "human",
            content: "secret",
            replyToId: nil
        )

        let blob = ChannelCrypto.encrypt(payload, keyBase64: key1)!
        let decrypted = ChannelCrypto.decrypt(blob: blob, keyBase64: key2)
        #expect(decrypted == nil)
    }

    @Test("Decrypt with corrupted data returns nil")
    func decryptCorrupted() {
        let key = ChannelCrypto.generateKey()
        let decrypted = ChannelCrypto.decrypt(blob: "not-valid-base64!!!", keyBase64: key)
        #expect(decrypted == nil)
    }

    @Test("Decrypt with truncated blob returns nil")
    func decryptTruncated() {
        let key = ChannelCrypto.generateKey()
        let payload = SyncPayload(
            senderName: "test",
            senderType: "human",
            content: "hello",
            replyToId: nil
        )
        let blob = ChannelCrypto.encrypt(payload, keyBase64: key)!
        let truncated = String(blob.prefix(blob.count / 2))
        let decrypted = ChannelCrypto.decrypt(blob: truncated, keyBase64: key)
        #expect(decrypted == nil)
    }

    @Test("Encrypt with invalid key returns nil")
    func encryptInvalidKey() {
        let payload = SyncPayload(
            senderName: "test",
            senderType: "human",
            content: "hello",
            replyToId: nil
        )
        let result = ChannelCrypto.encrypt(payload, keyBase64: "not-a-key")
        #expect(result == nil)
    }

    @Test("Encrypt with short key (16 bytes) returns nil")
    func encryptShortKey() {
        let payload = SyncPayload(
            senderName: "test",
            senderType: "human",
            content: "hello",
            replyToId: nil
        )
        let shortKey = Data(repeating: 0, count: 16).base64EncodedString()
        let result = ChannelCrypto.encrypt(payload, keyBase64: shortKey)
        #expect(result == nil)
    }

    @Test("Decrypt with invalid key returns nil")
    func decryptInvalidKey() {
        let result = ChannelCrypto.decrypt(blob: "someblob", keyBase64: "not-a-key")
        #expect(result == nil)
    }
}
