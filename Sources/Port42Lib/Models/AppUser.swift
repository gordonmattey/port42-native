import Foundation
import GRDB
import CryptoKit
import Security

public struct AppUser: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "users"

    private static let keychainService = "com.port42.identity"

    public var id: String
    public var displayName: String
    public var avatarData: Data?
    public var isLocal: Bool
    public var publicKey: String?
    public var privateKey: Data?
    public var appleUserID: String?
    public var createdAt: Date

    public init(id: String, displayName: String, avatarData: Data?, isLocal: Bool,
                publicKey: String? = nil, privateKey: Data? = nil,
                appleUserID: String? = nil, createdAt: Date) {
        self.id = id
        self.displayName = displayName
        self.avatarData = avatarData
        self.isLocal = isLocal
        self.publicKey = publicKey
        self.privateKey = privateKey
        self.appleUserID = appleUserID
        self.createdAt = createdAt
    }

    public static func createLocal(displayName: String) -> AppUser {
        let key = P256.Signing.PrivateKey()
        let pubKeyHex = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let userId = UUID().uuidString

        // Store private key in Keychain
        storeKeyInKeychain(key.rawRepresentation, account: userId)

        return AppUser(
            id: userId,
            displayName: displayName,
            avatarData: nil,
            isLocal: true,
            publicKey: pubKeyHex,
            privateKey: nil, // Private key lives in Keychain, not DB
            createdAt: Date()
        )
    }

    // MARK: - Keychain

    @discardableResult
    private static func storeKeyInKeychain(_ keyData: Data, account: String) -> Bool {
        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[Port42] Failed to store key in Keychain: \(status)")
            return false
        }
        NSLog("[Port42] Identity key stored in Keychain")
        return true
    }

    /// Check if this user's private key is stored in Keychain
    public static func keychainHasKey(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func loadPrivateKey() -> P256.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? P256.Signing.PrivateKey(rawRepresentation: data)
    }
}
