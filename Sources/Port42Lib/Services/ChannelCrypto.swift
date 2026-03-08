import Foundation
import CryptoKit

/// Per-channel AES-256-GCM encryption for E2E message privacy.
/// The gateway sees only encrypted blobs and routing metadata.
public enum ChannelCrypto {

    /// Generate a new 256-bit symmetric key, returned as base64.
    public static func generateKey() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    /// Encrypt a SyncPayload into a base64 blob (nonce + ciphertext + tag).
    /// Returns nil if the key is invalid.
    public static func encrypt(_ payload: SyncPayload, keyBase64: String) -> String? {
        guard let keyData = Data(base64Encoded: keyBase64),
              keyData.count == 32 else { return nil }

        let key = SymmetricKey(data: keyData)

        guard let plaintext = try? JSONEncoder().encode(payload) else { return nil }

        guard let sealedBox = try? AES.GCM.seal(plaintext, using: key) else { return nil }

        // combined = nonce (12) + ciphertext + tag (16)
        guard let combined = sealedBox.combined else { return nil }
        return combined.base64EncodedString()
    }

    /// Decrypt a base64 blob back into a SyncPayload.
    /// Returns nil if the key is wrong, data is corrupted, or format is invalid.
    public static func decrypt(blob: String, keyBase64: String) -> SyncPayload? {
        guard let keyData = Data(base64Encoded: keyBase64),
              keyData.count == 32 else { return nil }

        let key = SymmetricKey(data: keyData)

        guard let combined = Data(base64Encoded: blob) else { return nil }

        guard let sealedBox = try? AES.GCM.SealedBox(combined: combined) else { return nil }

        guard let plaintext = try? AES.GCM.open(sealedBox, using: key) else { return nil }

        return try? JSONDecoder().decode(SyncPayload.self, from: plaintext)
    }
}
