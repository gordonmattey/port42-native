import Foundation
import Security

// MARK: - Auth Config

public enum AgentAuthConfig: Equatable {
    case claudeCodeOAuth
    case apiKey(String)
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

        case .apiKey(let key):
            return ResolvedAuth(token: key, source: .apiKey)
        }
    }

    /// Auto-detect available auth. Returns the best available config, or nil.
    /// Eagerly reads and caches the token so only one Keychain prompt is needed.
    public func autoDetect() -> AgentAuthConfig? {
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
