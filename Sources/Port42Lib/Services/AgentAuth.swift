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

// MARK: - Keychain Entry

/// A discovered Claude Code credential in the Keychain.
public struct ClaudeKeychainEntry: Identifiable, Equatable {
    public var id: String { serviceName }
    public let serviceName: String
    public let created: Date
    public let label: String        // human-readable: subscription type or suffix
    public let expiresAt: Date?

    /// Suffix after "Claude Code-credentials", if any.
    public var suffix: String? {
        let prefix = "Claude Code-credentials"
        guard serviceName.count > prefix.count else { return nil }
        let rest = String(serviceName.dropFirst(prefix.count))
        return rest.hasPrefix("-") ? String(rest.dropFirst()) : rest
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
    private var keychainDenied: Bool = false
    /// True after we successfully read from Keychain once. Prevents re-reads
    /// (and repeated permission prompts) until the user explicitly calls resetAuth().
    private var hasReadKeychain: Bool = false

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

    /// Human-readable description of cached token expiry, if available.
    public var cachedExpiryDescription: String? {
        guard let exp = cachedExpiresAt else { return nil }
        let remaining = exp.timeIntervalSince(Date())
        if remaining <= 0 { return "expired" }
        let hours = Int(remaining / 3600)
        let minutes = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// The service name currently in use (may be overridden by user picking a specific entry).
    private var activeService: String?

    /// The service name that was actually resolved from Keychain (may differ from activeService
    /// when auto-detect found via prefix match).
    private var resolvedService: String?

    /// Human-readable label of the active Keychain entry.
    public var activeAccountLabel: String? {
        guard let svc = resolvedService ?? activeService else { return nil }
        let prefix = keychainService
        if svc == prefix {
            return "Default"
        }
        if svc.count > prefix.count {
            let suffix = String(svc.dropFirst(prefix.count + 1))
            return "Account \(suffix.prefix(8))"
        }
        return "Default"
    }

    /// Clear the cached token so next resolve() re-reads from Keychain.
    /// Call this on 401 errors to pick up refreshed tokens.
    /// Does NOT reset keychainDenied to avoid repeated Keychain prompts on bad tokens.
    public func clearCache() {
        cachedToken = nil
        cachedExpiresAt = nil
    }

    /// Full reset including keychainDenied. Use only when the user explicitly
    /// changes auth settings or selects a new Keychain entry.
    public func resetAuth() {
        cachedToken = nil
        cachedExpiresAt = nil
        keychainDenied = false
        hasReadKeychain = false
        activeService = nil
        resolvedService = nil
    }

    /// List all Claude Code credential entries in the Keychain.
    /// Only queries attributes (no data) so this triggers zero Keychain permission prompts.
    /// Data is fetched later when the user selects an entry or on single-entry auto-select.
    public func listKeychainEntries() -> [ClaudeKeychainEntry] {
        let prefix = keychainService

        let attrQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var attrResult: AnyObject?
        let status = SecItemCopyMatching(attrQuery as CFDictionary, &attrResult)
        guard status == errSecSuccess,
              let items = attrResult as? [[String: Any]] else {
            return []
        }

        let entries = items.compactMap { item -> ClaudeKeychainEntry? in
            guard let svc = item[kSecAttrService as String] as? String,
                  svc.hasPrefix(prefix) else { return nil }
            let created = item[kSecAttrCreationDate as String] as? Date ?? .distantPast
            let account = item[kSecAttrAccount as String] as? String

            // Build label from suffix or account name (no data fetch needed)
            var label: String
            if svc.count > prefix.count {
                let suffix = String(svc.dropFirst(prefix.count + 1))
                label = "Account \(suffix.prefix(8))"
            } else {
                label = "Default"
            }
            // Use account name if available and meaningful
            if let acct = account, !acct.isEmpty, acct != "default" {
                label = acct
            }

            return ClaudeKeychainEntry(
                serviceName: svc,
                created: created,
                label: label,
                expiresAt: nil  // unknown until data is fetched on selection
            )
        }
        .sorted { $0.created > $1.created }

        return entries
    }

    /// Use a specific Keychain entry (by service name) for token resolution.
    /// This triggers a single Keychain data fetch (one permission prompt).
    public func selectEntry(_ entry: ClaudeKeychainEntry) {
        cachedToken = nil
        cachedExpiresAt = nil
        keychainDenied = false
        hasReadKeychain = false
        activeService = entry.serviceName
        // Pre-warm the cache with a single read so no further prompts are needed
        _ = try? readClaudeCodeToken()
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
                hasReadKeychain = false  // allow re-read for expired tokens
                NSLog("[Port42] OAuth token expired or expiring soon, re-reading from Keychain")
            } else {
                return cached
            }
        }

        // If we already failed to read from Keychain this session, don't prompt again
        if keychainDenied {
            throw AgentAuthError.tokenNotFound
        }

        // If we already read from Keychain successfully this session but the token
        // was cleared (e.g. 401 retry), don't re-read. The Keychain data hasn't
        // changed and re-reading would trigger another permission prompt.
        if hasReadKeychain {
            NSLog("[Port42] Keychain already read this session, skipping re-read to avoid prompt")
            throw AgentAuthError.tokenNotFound
        }

        // Test path: read from JSON file
        if let dir = _testConfigDir {
            let token = try readFromTestFile(dir: dir)
            cachedToken = token
            return token
        }

        // Production path: read from macOS Keychain
        let data = try readKeychainData()
        hasReadKeychain = true
        guard let data else {
            keychainDenied = true
            NSLog("[Port42] Claude Code Keychain entry not found, caching denial for session")
            throw AgentAuthError.tokenNotFound
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
            keychainDenied = true
            NSLog("[Port42] Keychain entry found but no valid token, caching denial for session")
            throw AgentAuthError.invalidTokenData
        }
        cachedToken = token
        return token
    }

    /// Read credential data from Keychain, trying exact service match first then prefix search.
    /// If the user selected a specific entry via `selectEntry(_:)`, that service name is used directly.
    private func readKeychainData() throws -> Data? {
        let service = activeService ?? keychainService

        // Fast path: exact service name match
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account = keychainAccount {
            query[kSecAttrAccount as String] = account
        }

        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data {
            resolvedService = service
            return data
        }

        // If user explicitly selected an entry and it wasn't found, don't broaden
        if activeService != nil {
            return nil
        }

        // Slow path: Claude Code may store under suffixed names like
        // "Claude Code-credentials-d53625db". Query attributes (no data) to find
        // matching service names, then fetch the newest one's data individually.
        guard status == errSecItemNotFound else {
            throw AgentAuthError.keychainError(status)
        }

        let prefix = keychainService
        let attrQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var attrResult: AnyObject?
        status = SecItemCopyMatching(attrQuery as CFDictionary, &attrResult)

        guard status == errSecSuccess,
              let items = attrResult as? [[String: Any]] else {
            return nil
        }

        // Find matching service names with creation dates, pick newest
        let matches = items.compactMap { item -> (String, Date)? in
            guard let svc = item[kSecAttrService as String] as? String,
                  svc.hasPrefix(prefix) else { return nil }
            let created = item[kSecAttrCreationDate as String] as? Date ?? .distantPast
            return (svc, created)
        }

        guard let best = matches.max(by: { $0.1 < $1.1 }) else {
            return nil
        }

        // Fetch data for the newest matching entry
        let dataQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: best.0,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var dataResult: AnyObject?
        let dataStatus = SecItemCopyMatching(dataQuery as CFDictionary, &dataResult)
        guard dataStatus == errSecSuccess, let data = dataResult as? Data else {
            return nil
        }

        resolvedService = best.0
        NSLog("[Port42] Found Claude Code credential via prefix match: %@", best.0)
        return data
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
