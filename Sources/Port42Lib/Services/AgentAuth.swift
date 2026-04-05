import Foundation
import Security

// MARK: - Token Detection

/// Token type detected from content, not storage slot
public enum CredentialType: String, Codable, Equatable {
    case oauthToken    // sk-ant-oat01-...
    case apiKey        // sk-ant-api03-...
    case unknown
}

/// Pure function: prefix → type
public enum TokenDetector {
    /// Detect credential type from token prefix
    public static func detect(_ token: String) -> CredentialType {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("sk-ant-oat") { return .oauthToken }
        if trimmed.hasPrefix("sk-ant-api") { return .apiKey }
        // Future: OpenAI prefixes etc.
        return .unknown
    }

    /// Human-readable label for a credential type
    public static func humanLabel(_ type: CredentialType) -> String {
        switch type {
        case .oauthToken: return "OAuth session token"
        case .apiKey: return "API key"
        case .unknown: return "unrecognized token format"
        }
    }
}

// MARK: - Auth Credential

/// Resolved credential ready for use
public struct AuthCredential: Equatable {
    public let token: String
    public let type: CredentialType
    public let source: CredentialSource

    public enum CredentialSource: String, Codable, Equatable {
        case claudeCodeKeychain  // auto-detected from Claude Code
        case manual              // user pasted
    }

    public init(token: String, type: CredentialType, source: CredentialSource) {
        self.token = token
        self.type = type
        self.source = source
    }

    /// Whether this credential should use OAuth Bearer headers.
    /// Source is authoritative: anything from Claude Code Keychain is always OAuth.
    /// For manual tokens, we use the detected type.
    public var useOAuthHeaders: Bool {
        switch source {
        case .claudeCodeKeychain: return true
        case .manual: return type == .oauthToken
        }
    }
}

// MARK: - Auth Preference

/// User's preference per provider (persisted in UserDefaults)
public enum AuthPreference: String, Codable {
    case autoDetect    // try Claude Code Keychain
    case manualEntry   // user pasted a token
}

// MARK: - Auth Status

/// Published auth status for UI
public enum AuthStatus: Equatable {
    case unknown
    case checking
    case connected(type: CredentialType, expiresIn: String?)
    case noCredential
    case error(String)
}

// MARK: - Keychain Entry

/// A discovered Claude Code credential in the Keychain.
public struct ClaudeKeychainEntry: Identifiable, Equatable {
    public var id: String { serviceName }
    public let serviceName: String
    public let created: Date
    public let label: String
    public let expiresAt: Date?

    public var suffix: String? {
        let prefix = "Claude Code-credentials"
        guard serviceName.count > prefix.count else { return nil }
        let rest = String(serviceName.dropFirst(prefix.count))
        return rest.hasPrefix("-") ? String(rest.dropFirst()) : rest
    }
}

// MARK: - Errors

public enum AgentAuthError: Error, LocalizedError {
    case tokenNotFound
    case keychainError(OSStatus)
    case invalidTokenData

    public var errorDescription: String? {
        switch self {
        case .tokenNotFound:
            return "Token expired or not found. Run /login in Claude Code to refresh."
        case .invalidTokenData:
            return "Invalid token data in Keychain. Re-authenticate with /login in Claude Code."
        case .keychainError(let status):
            return "Keychain error (\(status)). Try re-authenticating with /login in Claude Code."
        }
    }
}

// MARK: - Provider-Keyed Store

/// Cached OAuth tokens persisted to Port42's own Keychain slot.
/// Written after every successful silent refresh so restarts don't re-consume
/// the same (potentially rotating) refresh token from Claude Code's Keychain.
public struct CachedOAuth: Codable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
}

/// Manages Port42's own stored credentials in Keychain, keyed by provider.
public final class Port42AuthStore {
    public static let shared = Port42AuthStore()

    private let service = "Port42-credentials"

    /// Save the user's auth preference for a provider
    public func savePreference(provider: String = "anthropic", pref: AuthPreference) {
        UserDefaults.standard.set(pref.rawValue, forKey: "port42AuthPref-\(provider)")
    }

    /// Load the auth preference for a provider
    public func loadPreference(provider: String = "anthropic") -> AuthPreference {
        // Check new key first
        if let raw = UserDefaults.standard.string(forKey: "port42AuthPref-\(provider)"),
           let pref = AuthPreference(rawValue: raw) {
            return pref
        }
        return .autoDetect
    }

    /// Save a credential to Keychain for a provider (e.g. "manual-anthropic")
    public func saveCredential(_ value: String, provider: String = "anthropic") {
        let account = "manual-\(provider)"
        let data = value.data(using: .utf8)!
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

    /// Load a credential from Keychain for a provider
    public func loadCredential(provider: String = "anthropic") -> String? {
        return loadKeychainValue(account: "manual-\(provider)")
    }

    /// Delete a credential from Keychain for a provider
    public func deleteCredential(provider: String = "anthropic") {
        deleteKeychainValue(account: "manual-\(provider)")
    }

    /// Persist refreshed OAuth tokens to Port42's own Keychain slot.
    public func saveOAuthCache(_ cache: CachedOAuth, provider: String = "anthropic") {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(cache),
              String(data: data, encoding: .utf8) != nil else { return }
        let account = "oauth-cache-\(provider)"
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
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Load previously refreshed OAuth tokens from Port42's own Keychain slot.
    public func loadOAuthCache(provider: String = "anthropic") -> CachedOAuth? {
        guard let str = loadKeychainValue(account: "oauth-cache-\(provider)"),
              let data = str.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(CachedOAuth.self, from: data)
    }

    /// Clear cached OAuth tokens (called on sign-out / reset).
    public func clearOAuthCache(provider: String = "anthropic") {
        deleteKeychainValue(account: "oauth-cache-\(provider)")
    }

    /// Clear all stored auth for a reset
    public func clearAll() {
        deleteKeychainValue(account: "manual-anthropic")
        deleteKeychainValue(account: "oauth-cache-anthropic")
        // Legacy cleanup
        deleteKeychainValue(account: "manualToken")
        deleteKeychainValue(account: "apiKey")
        UserDefaults.standard.removeObject(forKey: "port42AuthPref-anthropic")
        UserDefaults.standard.removeObject(forKey: "port42AuthMode")
    }

    // MARK: - Named Secrets (for rest.call and provider companions)

    /// Secret type determines how the credential is injected into HTTP requests.
    public enum SecretType: String, Codable {
        case bearerToken   // Authorization: Bearer <value>
        case apiKey        // x-api-key: <value>  (Anthropic, etc.)
        case basicAuth     // Authorization: Basic <base64(value)>  — value is "user:pass"
        case header        // Custom header — stored as "Header-Name: value"
        case llm           // LLM provider key — stored only, not injected into rest.call headers
    }

    /// A named secret stored in Keychain.
    public struct Secret: Identifiable, Equatable {
        public var id: String { name }
        public let name: String
        public let type: SecretType

        public init(name: String, type: SecretType) {
            self.name = name
            self.type = type
        }
    }

    private static let secretPrefix = "secret-"
    private static let secretMetaPrefix = "secret-meta-"

    /// Save a named secret to Keychain.
    public func saveSecret(name: String, type: SecretType, value: String) {
        // Store the credential value
        let account = Self.secretPrefix + name
        let data = value.data(using: .utf8)!
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
            NSLog("[Port42] Failed to save secret '%@': %d", name, status)
        }

        // Store metadata (type) in UserDefaults — not sensitive
        UserDefaults.standard.set(type.rawValue, forKey: "port42Secret-\(name)-type")

        // Track the set of secret names
        var names = secretNames()
        if !names.contains(name) {
            names.append(name)
            UserDefaults.standard.set(names, forKey: "port42SecretNames")
        }
        NSLog("[Port42] Secret saved: %@ (%@)", name, type.rawValue)
    }

    /// Load a named secret's value from Keychain. Returns nil if not found.
    public func loadSecretValue(name: String) -> String? {
        return loadKeychainValue(account: Self.secretPrefix + name)
    }

    /// Load a named secret's metadata. Returns nil if not found.
    public func loadSecret(name: String) -> Secret? {
        guard let rawType = UserDefaults.standard.string(forKey: "port42Secret-\(name)-type"),
              let type = SecretType(rawValue: rawType) else { return nil }
        return Secret(name: name, type: type)
    }

    /// Delete a named secret from Keychain and metadata.
    public func deleteSecret(name: String) {
        deleteKeychainValue(account: Self.secretPrefix + name)
        UserDefaults.standard.removeObject(forKey: "port42Secret-\(name)-type")
        var names = secretNames()
        names.removeAll { $0 == name }
        UserDefaults.standard.set(names, forKey: "port42SecretNames")
        NSLog("[Port42] Secret deleted: %@", name)
    }

    /// List all named secrets (metadata only, no values).
    public func listSecrets() -> [Secret] {
        return secretNames().compactMap { loadSecret(name: $0) }
    }

    /// Get all secret names.
    public func secretNames() -> [String] {
        return UserDefaults.standard.stringArray(forKey: "port42SecretNames") ?? []
    }

    /// Resolve a named secret into an HTTP Authorization header value.
    /// Returns (headerName, headerValue) or nil if the secret doesn't exist.
    public func resolveSecretHeader(name: String) -> (String, String)? {
        guard let secret = loadSecret(name: name),
              let value = loadSecretValue(name: name) else { return nil }
        switch secret.type {
        case .bearerToken:
            return ("Authorization", "Bearer \(value)")
        case .apiKey:
            return ("x-api-key", value)
        case .basicAuth:
            let encoded = Data(value.utf8).base64EncodedString()
            return ("Authorization", "Basic \(encoded)")
        case .header:
            // Format: "Header-Name: value"
            if let colonIdx = value.firstIndex(of: ":") {
                let headerName = String(value[value.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let headerValue = String(value[value.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                return (headerName, headerValue)
            }
            return ("Authorization", value)
        case .llm:
            return nil  // LLM keys are not injected into rest.call headers
        }
    }

    // MARK: - Migration

    /// Migrate from old auth format to new provider-keyed format.
    /// Safe to call multiple times (idempotent).
    public func migrateIfNeeded() {
        let migrated = UserDefaults.standard.bool(forKey: "authMigratedV2")
        guard !migrated else { return }

        let oldMode = UserDefaults.standard.string(forKey: "port42AuthMode")
        if oldMode == "manualToken" {
            // Copy old "manualToken" → "manual-anthropic"
            if let token = loadKeychainValue(account: "manualToken") {
                saveCredential(token, provider: "anthropic")
                savePreference(provider: "anthropic", pref: .manualEntry)
            }
        } else if oldMode == "apiKey" {
            // Copy old "apiKey" → "manual-anthropic"
            if let key = loadKeychainValue(account: "apiKey") {
                saveCredential(key, provider: "anthropic")
                savePreference(provider: "anthropic", pref: .manualEntry)
            }
        }

        // Delete old accounts
        deleteKeychainValue(account: "manualToken")
        deleteKeychainValue(account: "apiKey")
        UserDefaults.standard.removeObject(forKey: "port42AuthMode")

        UserDefaults.standard.set(true, forKey: "authMigratedV2")
        NSLog("[Port42:auth] Migration complete (oldMode=%@)", oldMode ?? "nil")
    }

    // MARK: - Private

    private func loadKeychainValue(account: String) -> String? {
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

    private func deleteKeychainValue(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Resolver

public final class AgentAuthResolver {
    public static let shared = AgentAuthResolver()

    private let keychainService: String
    private let keychainAccount: String?
    private var cachedToken: String?
    private var cachedExpiresAt: Date?
    private var cachedRefreshToken: String?
    private var keychainDenied: Bool = false
    private var hasReadKeychain: Bool = false

    private static let selectedServiceKey = "port42SelectedKeychainService"

    public init(
        keychainService: String = "Claude Code-credentials",
        keychainAccount: String? = nil
    ) {
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.activeService = UserDefaults.standard.string(forKey: AgentAuthResolver.selectedServiceKey)
    }

    public convenience init(claudeConfigDir: String) {
        self.init(keychainService: "test-\(claudeConfigDir)")
        self._testConfigDir = claudeConfigDir
    }

    private var _testConfigDir: String?

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

    private var activeService: String?
    private var resolvedService: String?

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

    public func clearCache() {
        NSLog("[Port42:auth] clearCache()")
        cachedToken = nil
        cachedExpiresAt = nil
        cachedRefreshToken = nil
        hasReadKeychain = false
        keychainDenied = false
    }

    /// Force a silent refresh on 401 — server rejected our token regardless of local expiry.
    /// Returns true if refresh succeeded (new token cached), false if no refresh token available or refresh failed.
    @discardableResult
    public func forceRefreshIfPossible() -> Bool {
        // Gather refresh token from memory or Port42 OAuth cache before clearing
        let rt = cachedRefreshToken ?? Port42AuthStore.shared.loadOAuthCache()?.refreshToken
        guard let rt else {
            NSLog("[Port42:auth] forceRefresh: no refresh token available")
            clearCache()
            return false
        }
        NSLog("[Port42:auth] forceRefresh: attempting silent refresh on 401")
        if let refreshed = try? refreshAccessToken(using: rt) {
            cachedToken = refreshed.accessToken
            cachedExpiresAt = refreshed.expiresAt
            let newRt = refreshed.refreshToken ?? rt
            cachedRefreshToken = newRt
            hasReadKeychain = false
            keychainDenied = false
            Port42AuthStore.shared.saveOAuthCache(CachedOAuth(
                accessToken: refreshed.accessToken,
                refreshToken: newRt,
                expiresAt: refreshed.expiresAt
            ))
            NSLog("[Port42:auth] forceRefresh: succeeded")
            return true
        }
        NSLog("[Port42:auth] forceRefresh: failed, clearing cache")
        clearCache()
        return false
    }

    public func resetAuth() {
        NSLog("[Port42:auth] resetAuth()")
        cachedToken = nil
        cachedExpiresAt = nil
        cachedRefreshToken = nil
        keychainDenied = false
        hasReadKeychain = false
        lastKeychainReadTime = nil
        activeService = nil
        resolvedService = nil
        UserDefaults.standard.removeObject(forKey: AgentAuthResolver.selectedServiceKey)
        Port42AuthStore.shared.clearOAuthCache()
    }

    /// List all Claude Code credential entries in the Keychain (attributes only, no prompts).
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

        return items.compactMap { item -> ClaudeKeychainEntry? in
            guard let svc = item[kSecAttrService as String] as? String,
                  svc.hasPrefix(prefix) else { return nil }
            let created = item[kSecAttrCreationDate as String] as? Date ?? .distantPast
            let modified = item[kSecAttrModificationDate as String] as? Date
            let account = item[kSecAttrAccount as String] as? String

            var label: String
            let acctName = account.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
            if svc.count > prefix.count {
                let suffix = String(svc.dropFirst(prefix.count + 1)).prefix(8)
                label = acctName.map { "\($0) (\(suffix))" } ?? "Account \(suffix)"
            } else {
                label = acctName ?? "Default"
            }

            // Approximate expiry: modification date + 1 hour (OAuth tokens last ~1h from refresh)
            let approxExpiry = modified.map { $0.addingTimeInterval(3600) }

            return ClaudeKeychainEntry(
                serviceName: svc, created: created, label: label, expiresAt: approxExpiry
            )
        }
        .sorted { ($0.expiresAt ?? $0.created) > ($1.expiresAt ?? $1.created) }
    }

    /// Use a specific Keychain entry for token resolution.
    public func selectEntry(_ entry: ClaudeKeychainEntry) {
        NSLog("[Port42:auth] selectEntry: %@", entry.serviceName)
        cachedToken = nil
        cachedExpiresAt = nil
        keychainDenied = false
        hasReadKeychain = false
        lastKeychainReadTime = nil
        activeService = entry.serviceName
        UserDefaults.standard.set(entry.serviceName, forKey: AgentAuthResolver.selectedServiceKey)
        _ = try? readClaudeCodeToken()
        NSLog("[Port42:auth] selectEntry done: service=%@, cachedExpiry=%@, tokenPrefix=%@",
              entry.serviceName,
              cachedExpiryDescription ?? "nil",
              cachedToken.map { String($0.prefix(20)) } ?? "nil")
    }

    /// Resolve credentials for a provider. Returns an AuthCredential ready to use.
    public func resolve(provider: String = "anthropic") throws -> AuthCredential {
        let store = Port42AuthStore.shared
        let pref = store.loadPreference(provider: provider)

        switch pref {
        case .manualEntry:
            guard let token = store.loadCredential(provider: provider) else {
                throw AgentAuthError.tokenNotFound
            }
            let type = TokenDetector.detect(token)
            return AuthCredential(token: token, type: type, source: .manual)

        case .autoDetect:
            let token = try readClaudeCodeToken()
            let type = TokenDetector.detect(token)
            return AuthCredential(token: token, type: type, source: .claudeCodeKeychain)
        }
    }

    /// Check auth status without throwing. Used for boot check and UI display.
    public func checkStatus(provider: String = "anthropic") -> AuthStatus {
        let store = Port42AuthStore.shared
        let pref = store.loadPreference(provider: provider)

        switch pref {
        case .manualEntry:
            guard let token = store.loadCredential(provider: provider) else {
                return .noCredential
            }
            let type = TokenDetector.detect(token)
            return .connected(type: type, expiresIn: nil)

        case .autoDetect:
            if let _ = try? readClaudeCodeToken() {
                let type: CredentialType = cachedToken.map { TokenDetector.detect($0) } ?? .oauthToken
                return .connected(type: type, expiresIn: cachedExpiryDescription)
            }
            return .noCredential
        }
    }

    // MARK: - Private

    private var lastKeychainReadTime: Date?
    private static let minKeychainReadInterval: TimeInterval = 30

    private func readClaudeCodeToken() throws -> String {
        // Return in-memory cached token if available and not near expiry
        if let cached = cachedToken {
            if let exp = cachedExpiresAt, exp < Date().addingTimeInterval(60) {
                if let lastRead = lastKeychainReadTime,
                   Date().timeIntervalSince(lastRead) < Self.minKeychainReadInterval {
                    return cached
                }
                cachedToken = nil
                cachedExpiresAt = nil
                hasReadKeychain = false
            } else {
                return cached
            }
        }

        if keychainDenied {
            throw AgentAuthError.tokenNotFound
        }

        if hasReadKeychain {
            if let lastRead = lastKeychainReadTime,
               Date().timeIntervalSince(lastRead) < Self.minKeychainReadInterval {
                throw AgentAuthError.tokenNotFound
            }
        }

        if let dir = _testConfigDir {
            let token = try readFromTestFile(dir: dir)
            cachedToken = token
            return token
        }

        // Check Port42's own OAuth cache before reading Claude Code's Keychain.
        // After a silent refresh the new tokens are persisted here so restarts
        // don't re-consume the same (possibly rotating) refresh token.
        if let cached = Port42AuthStore.shared.loadOAuthCache() {
            let remaining = cached.expiresAt.map { $0.timeIntervalSince(Date()) } ?? Double.infinity
            if remaining > 60 {
                NSLog("[Port42:auth] Using Port42 OAuth cache, expires in %.0fs", remaining)
                cachedToken = cached.accessToken
                cachedExpiresAt = cached.expiresAt
                cachedRefreshToken = cached.refreshToken
                return cached.accessToken
            }
            // Expired — seed cachedRefreshToken so the refresh below can use it
            if cachedRefreshToken == nil, let rt = cached.refreshToken {
                cachedRefreshToken = rt
                NSLog("[Port42:auth] Port42 OAuth cache expired; seeding refresh token")
            }
        }

        let data = try readKeychainData()
        hasReadKeychain = true
        lastKeychainReadTime = Date()
        guard let data else {
            keychainDenied = true
            throw AgentAuthError.tokenNotFound
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let oauthObj = json["claudeAiOauth"] as? [String: Any],
               let accessToken = oauthObj["accessToken"] as? String {
                let refreshToken = oauthObj["refreshToken"] as? String
                if let expiresMs = oauthObj["expiresAt"] as? Double {
                    let expiresAt = Date(timeIntervalSince1970: expiresMs / 1000.0)
                    let remaining = expiresAt.timeIntervalSince(Date())
                    if remaining < 0 {
                        // Access token expired — attempt silent refresh
                        if let rt = refreshToken ?? cachedRefreshToken {
                            NSLog("[Port42:auth] Access token expired, attempting silent refresh")
                            if let refreshed = try? refreshAccessToken(using: rt) {
                                cachedToken = refreshed.accessToken
                                cachedExpiresAt = refreshed.expiresAt
                                let newRt = refreshed.refreshToken ?? cachedRefreshToken
                                cachedRefreshToken = newRt
                                // Persist so next restart uses the new tokens
                                Port42AuthStore.shared.saveOAuthCache(CachedOAuth(
                                    accessToken: refreshed.accessToken,
                                    refreshToken: newRt,
                                    expiresAt: refreshed.expiresAt
                                ))
                                NSLog("[Port42:auth] Silent refresh succeeded, persisted to cache")
                                return refreshed.accessToken
                            }
                        }
                        throw AgentAuthError.tokenNotFound
                    }
                    cachedExpiresAt = expiresAt
                }
                cachedRefreshToken = refreshToken
                cachedToken = accessToken
                return accessToken
            }
            if let token = json["oauth_token"] as? String ?? json["token"] as? String {
                cachedToken = token
                return token
            }
        }

        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            keychainDenied = true
            throw AgentAuthError.invalidTokenData
        }
        cachedToken = token
        return token
    }

    private func readKeychainData() throws -> Data? {
        let service = activeService ?? keychainService

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

        if activeService != nil {
            return nil
        }

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

        let matches = items.compactMap { item -> (String, Date)? in
            guard let svc = item[kSecAttrService as String] as? String,
                  svc.hasPrefix(prefix) else { return nil }
            let created = item[kSecAttrCreationDate as String] as? Date ?? .distantPast
            return (svc, created)
        }

        guard let best = matches.max(by: { $0.1 < $1.1 }) else {
            return nil
        }

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
        return data
    }

    // MARK: - Token Refresh

    private static let tokenRefreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private struct RefreshResult {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    /// Exchange a refresh token for a new access token.
    /// Blocks the calling thread (uses a semaphore) — call only from a background context.
    private func refreshAccessToken(using refreshToken: String) throws -> RefreshResult {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: Self.oauthClientId),
        ]
        guard let bodyData = components.percentEncodedQuery?.data(using: .utf8) else {
            throw AgentAuthError.invalidTokenData
        }

        var request = URLRequest(url: Self.tokenRefreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 15

        var refreshResult: Result<RefreshResult, Error>?
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error = error {
                refreshResult = .failure(error)
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                refreshResult = .failure(AgentAuthError.invalidTokenData)
                return
            }
            var expiresAt: Date?
            if let expiresIn = json["expires_in"] as? Double {
                expiresAt = Date().addingTimeInterval(expiresIn)
            }
            let newRefreshToken = json["refresh_token"] as? String
            refreshResult = .success(RefreshResult(
                accessToken: accessToken,
                refreshToken: newRefreshToken,
                expiresAt: expiresAt
            ))
        }.resume()

        semaphore.wait()

        switch refreshResult! {
        case .success(let r): return r
        case .failure(let e): throw e
        }
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
