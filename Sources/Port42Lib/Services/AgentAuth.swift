import Foundation
import Security

// MARK: - Auth Config

public enum AgentAuthConfig: Equatable {
    case claudeCodeOAuth
    case claudeManualToken(String)
    case apiKey(String)
}

// MARK: - Stored Auth Mode

/// Which auth mode the user selected (persisted in UserDefaults)
public enum StoredAuthMode: String {
    case autoDetect = "autoDetect"
    case manualToken = "manualToken"
    case apiKey = "apiKey"
}

/// Manages Port42's own stored credentials in Keychain
public final class Port42AuthStore {
    public static let shared = Port42AuthStore()

    private let service = "Port42-credentials"

    /// Save the user's chosen auth mode
    public func saveMode(_ mode: StoredAuthMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "port42AuthMode")
    }

    /// Load the stored auth mode
    public func loadMode() -> StoredAuthMode {
        guard let raw = UserDefaults.standard.string(forKey: "port42AuthMode"),
              let mode = StoredAuthMode(rawValue: raw) else {
            return .autoDetect
        }
        return mode
    }

    /// Save a credential to Keychain (manual token or API key)
    public func saveCredential(_ value: String, account: String) {
        let data = value.data(using: .utf8)!
        // Delete existing first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[Port42] Failed to save credential for %@: %d", account, status)
        }
    }

    /// Load a credential from Keychain
    public func loadCredential(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    /// Delete a credential from Keychain
    public func deleteCredential(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Resolve the stored auth config (returns nil if not configured or auto-detect)
    public func resolveStoredConfig() -> AgentAuthConfig? {
        switch loadMode() {
        case .autoDetect:
            return nil // let AgentAuthResolver.autoDetect() handle it
        case .manualToken:
            if let token = loadCredential(account: "manualToken") {
                return .claudeManualToken(token)
            }
            return nil
        case .apiKey:
            if let key = loadCredential(account: "apiKey") {
                return .apiKey(key)
            }
            return nil
        }
    }
}

// MARK: - Resolved Auth

public struct ResolvedAuth {
    public let token: String
    public let source: AuthSource

    public enum AuthSource: Equatable {
        case claudeCodeOAuth
        case apiKey
    }

    public init(token: String, source: AuthSource) {
        self.token = token
        self.source = source
    }
}

// MARK: - Errors

public enum AgentAuthError: Error {
    case tokenNotFound
    case keychainError(OSStatus)
    case invalidTokenData
}

// MARK: - Resolver

public final class AgentAuthResolver {
    /// Shared instance so all LLMEngine instances reuse the same cached token (one Keychain prompt).
    public static let shared = AgentAuthResolver()

    private let keychainService: String
    private let keychainAccount: String?
    private var cachedToken: String?
    private var cachedExpiresAt: Date?

    /// Default init reads from the real Claude Code keychain entry.
    /// Pass custom service/account for testing.
    public init(
        keychainService: String = "Claude Code-credentials",
        keychainAccount: String? = nil
    ) {
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    /// For test compatibility: init with a mock directory (reads JSON file instead of Keychain)
    public convenience init(claudeConfigDir: String) {
        // Use the dir path as a sentinel service name so tests can inject mock tokens
        self.init(keychainService: "test-\(claudeConfigDir)")
        self._testConfigDir = claudeConfigDir
    }

    private var _testConfigDir: String?

    /// Clear the cached token so next resolve() re-reads from Keychain.
    /// Call this on 401 errors to pick up refreshed tokens.
    public func clearCache() {
        cachedToken = nil
        cachedExpiresAt = nil
    }

    public func resolve(config: AgentAuthConfig) throws -> ResolvedAuth {
        switch config {
        case .claudeCodeOAuth:
            let token = try readClaudeCodeToken()
            return ResolvedAuth(token: token, source: .claudeCodeOAuth)

        case .claudeManualToken(let token):
            return ResolvedAuth(token: token, source: .claudeCodeOAuth)

        case .apiKey(let key):
            return ResolvedAuth(token: key, source: .apiKey)
        }
    }

    /// Auto-detect available auth. Returns the best available config, or nil.
    /// Checks Port42's stored auth first, then falls back to Claude Code Keychain.
    public func autoDetect() -> AgentAuthConfig? {
        // Check if user has explicitly configured auth in Port42
        if let stored = Port42AuthStore.shared.resolveStoredConfig() {
            return stored
        }

        if let dir = _testConfigDir {
            let credPath = (dir as NSString).appendingPathComponent("credentials.json")
            return FileManager.default.fileExists(atPath: credPath) ? .claudeCodeOAuth : nil
        }

        // If we already have a cached token, we know OAuth is available
        if cachedToken != nil {
            return .claudeCodeOAuth
        }

        // Try to read and cache the token in one shot (single Keychain prompt)
        if let _ = try? readClaudeCodeToken() {
            return .claudeCodeOAuth
        }

        // Fallback: check environment for any API_KEY variable
        if let envKey = ProcessInfo.processInfo.environment.first(where: {
            $0.key.uppercased().contains("API_KEY") && !$0.value.isEmpty
        }) {
            return .apiKey(envKey.value)
        }

        return nil
    }

    // MARK: - Private

    private func readClaudeCodeToken() throws -> String {
        // Return cached token if available and not expired
        if let cached = cachedToken {
            if let exp = cachedExpiresAt, exp < Date().addingTimeInterval(60) {
                // Token expires within 60s, force re-read from Keychain
                cachedToken = nil
                cachedExpiresAt = nil
                NSLog("[Port42] OAuth token expired or expiring soon, re-reading from Keychain")
            } else {
                return cached
            }
        }

        // Test path: read from JSON file
        if let dir = _testConfigDir {
            let token = try readFromTestFile(dir: dir)
            cachedToken = token
            return token
        }

        // Production path: read from macOS Keychain
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account = keychainAccount {
            query[kSecAttrAccount as String] = account
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                throw AgentAuthError.tokenNotFound
            }
            throw AgentAuthError.keychainError(status)
        }

        // Claude Code stores credentials as JSON: {"claudeAiOauth":{"accessToken":"sk-ant-oat01-...",...}}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Primary path: nested under claudeAiOauth
            if let oauthObj = json["claudeAiOauth"] as? [String: Any],
               let accessToken = oauthObj["accessToken"] as? String {
                cachedToken = accessToken
                // Cache expiry so we can proactively refresh
                if let expiresMs = oauthObj["expiresAt"] as? Double {
                    cachedExpiresAt = Date(timeIntervalSince1970: expiresMs / 1000.0)
                    let remaining = cachedExpiresAt!.timeIntervalSince(Date())
                    NSLog("[Port42] OAuth token read from Keychain, expires in %.0f minutes (%.1f hours)", remaining / 60, remaining / 3600)
                } else {
                    NSLog("[Port42] OAuth token read from Keychain, no expiry set")
                }
                return accessToken
            }
            // Fallback: flat structure
            if let token = json["oauth_token"] as? String ?? json["token"] as? String {
                cachedToken = token
                return token
            }
        }

        // Fallback: maybe the raw data is the token string
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw AgentAuthError.invalidTokenData
        }
        cachedToken = token
        return token
    }

    private func readFromTestFile(dir: String) throws -> String {
        let credPath = (dir as NSString).appendingPathComponent("credentials.json")
        guard FileManager.default.fileExists(atPath: credPath) else {
            throw AgentAuthError.tokenNotFound
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: credPath))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["oauth_token"] as? String, !token.isEmpty else {
            throw AgentAuthError.invalidTokenData
        }
        return token
    }
}
