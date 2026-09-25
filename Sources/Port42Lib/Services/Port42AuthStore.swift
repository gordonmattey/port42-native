import Foundation
import Security

/// Port42's own Keychain slot: the named secrets `rest.call` injects as headers, and the gateway's
/// root secret that every client token is minted from.
///
/// It holds NO model-provider credential (D9, nautilus Phase 1 step 3). The in-app engine's API keys,
/// OAuth cache and preferences went with the engine, and so did the Claude OAuth token Port42 used to
/// inject into companion terminals: a CLI agent signs in to its own provider, in its own terminal.
public final class Port42AuthStore {
    public static let shared = Port42AuthStore()

    private let service = "Port42-credentials"

    /// Delete the credential copies the removed engine kept. Idempotent, run at launch. These are
    /// Port42's own copies; a CLI's own login is never touched.
    public func removeEngineCredentials() {
        for account in ["manual-anthropic", "oauth-cache-anthropic", "manual-gemini", "manual-compatible-url",
                        "manual-compatibleEndpoint", "manualToken", "apiKey", "secret-claude-oauth"] {
            deleteKeychainValue(account: account)
        }
        for key in ["port42AuthPref-anthropic", "port42AuthMode", "authMigratedV2", "port42Secret-claude-oauth-type"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        var names = secretNames(); names.removeAll { $0 == "claude-oauth" }
        UserDefaults.standard.set(names, forKey: "port42SecretNames")
    }

    // MARK: - Named Secrets (for rest.call)

    /// Secret type determines how the credential is injected into HTTP requests.
    public enum SecretType: String, Codable {
        case bearerToken   // Authorization: Bearer <value>
        case apiKey        // x-api-key: <value>  (Anthropic, etc.)
        case basicAuth     // Authorization: Basic <base64(value)>  — value is "user:pass"
        case header        // Custom header — stored as "Header-Name: value"
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
        }
    }

    // MARK: - Gateway root secret (slice-02 half two, D2)
    //
    // The ONE thing that can mint a client token. 32 random bytes, created on first use, and
    // INSTANCE-QUALIFIED: prod, Dev and Dev3 hold different secrets, so a token minted by one fails
    // another's verification. Instance separation therefore falls out of the secret rather than out
    // of a path check (NFR4).
    //
    // Spike A validated the Keychain for this: a new RELEASE, same identifier and certificate but a
    // different cdhash, reads it back silently. It also explains the dev-instance prompt exactly —
    // a dev build has a different bundle id AND certificate — which is the second reason to qualify
    // the account by instance.

    private func rootSecretAccount(_ instance: String) -> String { "gateway-root-\(instance)" }

    public func gatewayRootSecret(instance: String) -> String? {
        loadKeychainValue(account: rootSecretAccount(instance))
    }

    public func saveGatewayRootSecret(_ value: String, instance: String) {
        saveKeychainValue(value, account: rootSecretAccount(instance))
    }

    public func deleteGatewayRootSecret(instance: String) {
        deleteKeychainValue(account: rootSecretAccount(instance))
    }

    // MARK: - Private

    private func saveKeychainValue(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ] as CFDictionary, nil)
        if status != errSecSuccess {
            // NEVER log the value (NFR2) — only that it failed, and with what code.
            NSLog("[Port42] Failed to save keychain value for %@: %d", account, status)
        }
    }

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
