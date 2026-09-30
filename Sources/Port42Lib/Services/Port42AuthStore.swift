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
        case header        // <field>: <value>, a header the API names (xi-api-key, api-key, ...)
        case query         // ?<field>=<value>, a query parameter the API names (key, api_key, ...)
    }

    /// A named secret stored in Keychain.
    public struct Secret: Identifiable, Equatable {
        public var id: String { name }
        public let name: String
        public let type: SecretType
        /// The header or query parameter a `.header` or `.query` secret goes in (#225). nil for the
        /// other types, and for a header secret saved before #225, whose value carries its name.
        public let field: String?

        public init(name: String, type: SecretType, field: String? = nil) {
            self.name = name
            self.type = type
            self.field = field
        }

        /// Where it goes, as the person reads it: "Bearer", "header xi-api-key", "query key".
        public var placementLabel: String {
            switch type {
            case .bearerToken: return "Bearer"
            case .apiKey: return "header x-api-key"
            case .basicAuth: return "Basic"
            case .header: return field.map { "header \($0)" } ?? "header"
            case .query: return field.map { "query \($0)" } ?? "query"
            }
        }
    }

    /// Where a secret's value goes on a request.
    public enum SecretPlacement: Equatable {
        case header(name: String, value: String)
        case query(name: String, value: String)

        /// Where it goes, without the value: for an error that says what was sent.
        public var described: String {
            switch self {
            case .header(let name, let value):
                return name.lowercased() == "authorization"
                    ? "the Authorization header (\(value.split(separator: " ").first.map(String.init) ?? "raw value"))"
                    : "the \(name) header"
            case .query(let name, _): return "the \(name) query parameter"
            }
        }
    }

    /// Where a secret of `type` goes, given its header or parameter name and its value (#225).
    ///
    /// Any API can want its key somewhere of its own: ElevenLabs in `xi-api-key`, Azure in `api-key`,
    /// Google in a `key` query parameter. A header or query secret therefore names its place. A header
    /// secret saved before #225 kept its name in the value ("xi-api-key: sk_..."); a value without one
    /// went out as `Authorization: <value>`, which is how a bare ElevenLabs key failed.
    public static func placement(type: SecretType, field: String?, value: String) -> SecretPlacement? {
        let named = field?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch type {
        case .bearerToken: return .header(name: "Authorization", value: "Bearer \(value)")
        case .apiKey: return .header(name: "x-api-key", value: value)
        case .basicAuth: return .header(name: "Authorization", value: "Basic \(Data(value.utf8).base64EncodedString())")
        case .query:
            guard let named else { return nil }
            return .query(name: named, value: value)
        case .header:
            if let named { return .header(name: named, value: value) }
            if let colon = value.firstIndex(of: ":") {
                let name = value[..<colon].trimmingCharacters(in: .whitespaces)
                let rest = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return .header(name: name, value: rest) }
            }
            return .header(name: "Authorization", value: value)
        }
    }

    private static let secretPrefix = "secret-"

    /// Save a named secret to Keychain. `field` is the header or query parameter a `.header` or
    /// `.query` secret goes in.
    public func saveSecret(name: String, type: SecretType, value: String, field: String? = nil) {
        // Store the credential value
        let account = Self.secretPrefix + name
        let data = value.data(using: .utf8)!
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        KeychainGate.delete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        let status = KeychainGate.add(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            p42log("[Port42] Failed to save secret '%@': %d", name, status)
        }

        // Store metadata (type) in UserDefaults — not sensitive
        UserDefaults.standard.set(type.rawValue, forKey: "port42Secret-\(name)-type")
        if let field = field?.trimmingCharacters(in: .whitespacesAndNewlines), !field.isEmpty {
            UserDefaults.standard.set(field, forKey: "port42Secret-\(name)-field")
        } else {
            UserDefaults.standard.removeObject(forKey: "port42Secret-\(name)-field")
        }

        // Track the set of secret names
        var names = secretNames()
        if !names.contains(name) {
            names.append(name)
            UserDefaults.standard.set(names, forKey: "port42SecretNames")
        }
        p42log("[Port42] Secret saved: %@ (%@)", name, type.rawValue)
    }

    /// Load a named secret's value from Keychain. Returns nil if not found.
    public func loadSecretValue(name: String) -> String? {
        return loadKeychainValue(account: Self.secretPrefix + name)
    }

    /// Load a named secret's metadata. Returns nil if not found.
    public func loadSecret(name: String) -> Secret? {
        guard let rawType = UserDefaults.standard.string(forKey: "port42Secret-\(name)-type"),
              let type = SecretType(rawValue: rawType) else { return nil }
        return Secret(name: name, type: type, field: UserDefaults.standard.string(forKey: "port42Secret-\(name)-field"))
    }

    /// Delete a named secret from Keychain and metadata.
    public func deleteSecret(name: String) {
        deleteKeychainValue(account: Self.secretPrefix + name)
        UserDefaults.standard.removeObject(forKey: "port42Secret-\(name)-type")
        UserDefaults.standard.removeObject(forKey: "port42Secret-\(name)-field")
        var names = secretNames()
        names.removeAll { $0 == name }
        UserDefaults.standard.set(names, forKey: "port42SecretNames")
        p42log("[Port42] Secret deleted: %@", name)
    }

    /// List all named secrets (metadata only, no values).
    public func listSecrets() -> [Secret] {
        return secretNames().compactMap { loadSecret(name: $0) }
    }

    /// Get all secret names.
    public func secretNames() -> [String] {
        return UserDefaults.standard.stringArray(forKey: "port42SecretNames") ?? []
    }

    /// Put a secret on a request: set its header, or add its query parameter (replacing one of the same
    /// name the caller put in the URL).
    public static func apply(_ placement: SecretPlacement, to request: inout URLRequest) {
        switch placement {
        case .header(let name, let value):
            request.setValue(value, forHTTPHeaderField: name)
        case .query(let name, let value):
            guard let url = request.url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            var items = (comps.queryItems ?? []).filter { $0.name != name }
            items.append(URLQueryItem(name: name, value: value))
            comps.queryItems = items
            if let placed = comps.url { request.url = placed }
        }
    }

    /// What to tell the caller when the API refused the request a secret went on (401 or 403): where
    /// the key was sent, and where to change it. A new user whose key went out in the wrong header saw
    /// only the API's own "unauthorized", with nothing saying what Port42 had sent (#225). Never the value.
    public static func refusedHint(status: Int, secret: String, placed: SecretPlacement) -> String? {
        guard status == 401 || status == 403 else { return nil }
        return "The API refused secret '\(secret)', which Port42 sent in \(placed.described). If this API "
             + "expects its key somewhere else (a header of its own such as xi-api-key or api-key, or a query "
             + "parameter), add the secret again in Settings → Secrets with that header or parameter. "
             + "If the place is right, the key itself may be wrong or expired."
    }

    /// Where a named secret goes on a request, with its value; nil if there is no such secret, or a
    /// query secret with no parameter name.
    public func resolveSecret(name: String) -> SecretPlacement? {
        guard let secret = loadSecret(name: name), let value = loadSecretValue(name: name) else { return nil }
        return Self.placement(type: secret.type, field: secret.field, value: value)
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

    /// The gateway root secret, telling "none yet" from "could not read it".
    public func readGatewayRootSecret(instance: String) -> KeychainRead {
        readKeychainValue(account: rootSecretAccount(instance))
    }

    public func saveGatewayRootSecret(_ value: String, instance: String) {
        saveKeychainValue(value, account: rootSecretAccount(instance))
    }

    private func peerSeedAccount(_ instance: String) -> String { "peer-key-\(instance)" }

    /// An unused invite's link (and code), kept so the person can copy it again (4.6b). The invites
    /// table holds only the nonce's hash; the link lives here, and goes when the invite does.
    public func inviteLink(id: String) -> String? { loadKeychainValue(account: "invite-link-\(id)") }
    public func saveInviteLink(_ value: String, id: String) { saveKeychainValue(value, account: "invite-link-\(id)") }
    public func deleteInviteLink(id: String) { deleteKeychainValue(account: "invite-link-\(id)") }

    /// The instance's Ed25519 seed, base64 (nautilus Phase 4, 4.2). Per instance, never per person.
    public func peerSeed(instance: String) -> String? {
        loadKeychainValue(account: peerSeedAccount(instance))
    }

    /// The instance's seed, telling "none yet" from "could not read it".
    public func readPeerSeed(instance: String) -> KeychainRead {
        readKeychainValue(account: peerSeedAccount(instance))
    }

    public func savePeerSeed(_ value: String, instance: String) {
        saveKeychainValue(value, account: peerSeedAccount(instance))
    }

    // MARK: - Private

    private func saveKeychainValue(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        KeychainGate.delete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
        let status = KeychainGate.add([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ] as CFDictionary, nil)
        if status != errSecSuccess {
            // NEVER log the value (NFR2) — only that it failed, and with what code.
            p42log("[Port42] Failed to save keychain value for %@: %d", account, status)
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
        let status = KeychainGate.copyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    /// A read that says why nothing came back. Only `.missing` means there is nothing to keep: every
    /// other failure (another build's signature, a prompt nobody could answer, a locked keychain) must
    /// not be taken as "make a new one", which silently replaced an instance's identity (Dev2,
    /// 2026-09-27) and orphaned every grant and invite keyed on it.
    private func readKeychainValue(account: String) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = KeychainGate.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return .unreadable(status) }
        return .found(str)
    }

    private func deleteKeychainValue(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        KeychainGate.delete(query as CFDictionary)
    }
}

/// What a Keychain read found: the value, nothing (the item does not exist), or a failure to read an
/// item that may well exist.
public enum KeychainRead: Equatable {
    case found(String)
    case missing
    case unreadable(OSStatus)
}

/// The one rule for a secret that must outlive a launch: keep what is there, make one only when there
/// is none, and never replace one that could not be read.
public enum KeptSecret {
    public enum Outcome: Equatable { case kept(String), made(String), unreadable(OSStatus) }

    public static func resolve(_ read: KeychainRead, make: () -> String, save: (String) -> Void) -> Outcome {
        switch read {
        case .found(let v): return .kept(v)
        case .missing:
            let fresh = make()
            save(fresh)
            return .made(fresh)
        case .unreadable(let status): return .unreadable(status)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
