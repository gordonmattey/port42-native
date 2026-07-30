import Foundation
import CryptoKit

// MARK: - ClientRegistry
//
// **THE ONLY PLACE A TOKEN IS MINTED, NAMED OR REVOKED** (slice-02 half two, D1/D3/D5/D7).
//
// Half one made every grant name its object and made consent visible. This is the other half of the
// same sentence: making the CALLER a named thing, so a grant can be about someone rather than about
// "anything that reaches the gateway". Today every local process collapses into one shared
// `local-http` principal, which is why the permission card is anonymous and why a grant given to one
// tool is inherited by every other.
//
// **There is no root token and no ambient token file** (D5). An unconsented enrollment is the same
// hole one level out: anything that can read a shared file becomes a legitimate principal with no
// human in the loop, and a caller that enrolled itself has no name anyone gave it. Every token is
// minted by an act that already carries consent — connecting a tool, spawning a child, or adding one
// by hand.
//
// **This step enforces NOTHING** (§10 step 4). Tokens exist, clients appear in the manager, and no
// call is refused for lacking one. The seam and the verifier land together in step 5, by which point
// every caller has a token and the refusal can teach the fix.

public struct Port42Client: Equatable, Identifiable {
    /// A slug, `[a-z0-9-]+`. It is also the token FILE's name, which is why it is not a UUID: the
    /// documented client flow is "read a known path, pair only if it is missing", and a UUID would
    /// make that path unknowable before the first pairing.
    public let id: String
    /// The label shown on permission cards. Fixed at mint time (FR3).
    public let name: String
    public let kind: Kind
    public let createdAt: Date
    public let lastSeenAt: Date?
    public let revokedAt: Date?

    public enum Kind: String, Equatable {
        /// A caller Port42 did not spawn, approved by the user through pairing.
        case paired
        /// A companion terminal or command agent the app spawned. No prompt: the user spawning it
        /// IS the consent, and the app is both parties.
        case child
        /// Added by hand in Settings, for the user's own scripts and for any caller with no human
        /// present (cron, a background job) — which cannot pair. Stated regression, CR4.
        case manual
    }

    public var isActive: Bool { revokedAt == nil }
}

@MainActor
public final class ClientRegistry {

    private let db: DatabaseService
    private let instance: String

    public init(db: DatabaseService, instance: String = ClientRegistry.currentInstance) {
        self.db = db
        self.instance = instance
    }

    /// Which Port42 this is: `Port42`, `Port42Dev`, `Port42Dev3`. The same value that already picks
    /// the data directory, so a dev instance cannot mint a token production would accept.
    public nonisolated static var currentInstance: String {
        ProcessInfo.processInfo.environment["PORT42_DATA_DIR"] ?? "Port42"
    }

    // MARK: - The root secret

    /// The instance's minting secret, created on first use. 32 random bytes.
    ///
    /// Generated lazily rather than at launch so a build that never mints one never writes to the
    /// Keychain at all.
    func rootSecret() -> String {
        if let existing = Port42AuthStore.shared.gatewayRootSecret(instance: instance) {
            return existing
        }
        let fresh = Self.randomSecret()
        Port42AuthStore.shared.saveGatewayRootSecret(fresh, instance: instance)
        return fresh
    }

    nonisolated static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Token format (D3)

    /// `p42_<id>_<mac>`, mac = base64url-unpadded(HMAC-SHA256(secret, id)).
    ///
    /// `id` is constrained to `[a-z0-9-]`, so splitting on `_` always yields exactly three parts.
    /// The verifier recomputes the MAC and compares in constant time; it consults no table and
    /// stores nothing, which is what lets the gateway hold no client state and survive its own
    /// restart (NFR5).
    public nonisolated static func token(id: String, secret: String) -> String {
        "p42_\(id)_\(mac(id: id, secret: secret))"
    }

    nonisolated static func mac(id: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(id.utf8), using: key)
        return Data(code).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Verify a token against a secret and return the client id it names, or nil.
    ///
    /// **Constant-time comparison** (NFR1): a byte-by-byte early return leaks how much of a forged
    /// MAC was correct, which is enough to forge one a byte at a time.
    public nonisolated static func verify(token: String, secret: String) -> String? {
        let parts = token.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "p42" else { return nil }
        let id = String(parts[1]), presented = String(parts[2])
        guard isValidSlug(id) else { return nil }
        let expected = mac(id: id, secret: secret)
        return constantTimeEquals(expected, presented) ? id : nil
    }

    nonisolated static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        // Length is not secret (the MAC is fixed-width), but the CONTENT comparison must not short
        // circuit, so every byte of the shorter run is still examined.
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<min(x.count, y.count) { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: - Slugs

    public nonisolated static func isValidSlug(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLowercase && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "-" }
    }

    /// Turn a caller-supplied name into a slug. The name is a CLAIM (D5) — it is shown to the user
    /// at approval — and this only makes it safe to use as a filename and a key.
    public nonisolated static func slug(_ raw: String) -> String {
        let mapped = raw.lowercased().map { ch -> Character in
            if ch.isASCII && (ch.isLetter || ch.isNumber) { return ch }
            return "-"
        }
        var out = ""
        var lastDash = false
        for ch in mapped {
            if ch == "-" {
                if lastDash || out.isEmpty { continue }
                lastDash = true
            } else {
                lastDash = false
            }
            out.append(ch)
        }
        while out.hasSuffix("-") { out.removeLast() }
        guard !out.isEmpty else { return "client" }

        // **TRUNCATION MUST NOT LOSE WHAT DISTINGUISHES TWO CLIENTS**, and live verification is what
        // caught this: a real child id is `child-<companionUUID>-<spaceUUID>`, 79 characters, and a
        // plain `prefix(64)` cut the SPACE uuid in half —
        // `child-ac9b2306-…-778bd2e4a22f-4b60409c-e6c1-4ec0-85`. Two spaces sharing a 21-character
        // prefix would then be ONE client and inherit each other's grants, which is exactly the
        // pooling step 6 exists to end.
        //
        // The unit test missed it because it used `"echo"` and `"SPACE-1"` — toy values that never
        // reach the cap. A slug over the limit now keeps a readable head and appends a short digest
        // of the WHOLE input, so the result stays bounded, stays a valid slug, and stays unique for
        // inputs that differ anywhere at all. That covers a long pairing name as well as a child id.
        guard out.count > maxSlugLength else { return out }
        let digest = SHA256.hash(data: Data(out.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
        let head = String(out.prefix(maxSlugLength - digest.count - 1))
        return "\(head)-\(digest)"
    }

    /// Bounded so a client id is always a comfortable filename. Long enough that a derived child id
    /// (`child-` + two uuids = 79) keeps both uuids readable ahead of the digest.
    nonisolated static let maxSlugLength = 96

    /// A child's id is DERIVED, not random, so a companion terminal keeps its grants across
    /// respawns (D1). Re-registering the same slug re-issues onto the same row.
    public nonisolated static func childId(companionId: String, spaceId: String?) -> String {
        slug("child-\(companionId)-\(spaceId ?? "global")")
    }

    // MARK: - Minting

    /// Register a client and return its token. Re-registering an existing slug RE-ISSUES onto the
    /// same row, so a user who deletes a token file gets a new credential and keeps their grants.
    ///
    /// Returns nil only if the database write fails.
    @discardableResult
    public func register(id rawId: String, name: String, kind: Port42Client.Kind) -> String? {
        let id = Self.slug(rawId)
        do {
            try db.upsertClient(id: id, name: name, kind: kind.rawValue)
            let token = Self.token(id: id, secret: rootSecret())
            try writeTokenFile(id: id, token: token)
            return token
        } catch {
            NSLog("[Port42] ClientRegistry: failed to register %@: %@", id, "\(error)")
            return nil
        }
    }

    public func clients() -> [Port42Client] {
        (try? db.allClients()) ?? []
    }

    public func client(id: String) -> Port42Client? {
        try? db.client(id: id)
    }

    /// Revoke: mark the row, and DELETE THE TOKEN FILE (BR5). Effective on the client's next call,
    /// with no gateway restart, because the gateway holds no client table — it only proves a token
    /// was minted here, and the app decides whether that client still exists (D6 steps 2 and 5).
    public func revoke(id: String) {
        try? db.revokeClient(id: id)
        removeTokenFile(id: id)
    }

    // MARK: - The token file (D5)

    /// `~/.port42/<instance>/tokens/<id>`, 0600 inside a 0700 directory. The app owns the file, so
    /// revoking removes it.
    /// STATIC, and nonisolated, because a spawning child needs to be told where its token lives from
    /// a non-`@MainActor` context (`TerminalSessionBootstrap.make`). One definition, so the path the
    /// child is handed and the path the registry writes cannot drift.
    public nonisolated static func tokenDirectory(instance: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".port42", isDirectory: true)
            .appendingPathComponent(instance.lowercased(), isDirectory: true)
            .appendingPathComponent("tokens", isDirectory: true)
    }

    public nonisolated static func tokenPath(id: String, instance: String) -> URL {
        tokenDirectory(instance: instance).appendingPathComponent(id, isDirectory: false)
    }

    public func tokenDirectory() -> URL { Self.tokenDirectory(instance: instance) }

    public func tokenPath(id: String) -> URL { Self.tokenPath(id: id, instance: instance) }

    func writeTokenFile(id: String, token: String) throws {
        let dir = tokenDirectory()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Set the mode on the directory even when it already existed with a looser one.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let path = tokenPath(id: id)
        try Data(token.utf8).write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    func removeTokenFile(id: String) {
        try? FileManager.default.removeItem(at: tokenPath(id: id))
    }
}
