import Testing
import Foundation
@testable import Port42Lib

/// Slice-02 half two, step 4: **store and mint** (D1/D3/D5).
///
/// A caller becomes a NAMED thing. Today every local process collapses into one shared `local-http`
/// principal, which is why the permission card is anonymous and why a grant given to one tool is
/// inherited by every other.
///
/// **Nothing here enforces anything yet**, deliberately (§10 step 4). Tokens exist and clients are
/// registered; no call is refused for lacking one until step 5, by which point every caller has a
/// token and the refusal can teach the fix.
@Suite("Client registry (slice-02 half two, step 4)")
struct ClientRegistryTests {

    let secret = "dGVzdC1zZWNyZXQtbm90LWEtcmVhbC1vbmU="

    // MARK: - Token format (D3)

    @Test("a token is p42_<id>_<mac> and splits into exactly three parts")
    func tokenShape() {
        let t = ClientRegistry.token(id: "claude-code", secret: secret)
        #expect(t.hasPrefix("p42_claude-code_"))
        let parts = t.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        // base64url, unpadded — it rides in an Authorization header and a JSON envelope.
        let mac = String(parts[2])
        #expect(!mac.contains("+") && !mac.contains("/") && !mac.contains("="))
        #expect(!mac.isEmpty)
    }

    @Test("a token verifies back to the id it names")
    func verifyRoundTrip() {
        let t = ClientRegistry.token(id: "claude-code", secret: secret)
        #expect(ClientRegistry.verify(token: t, secret: secret) == "claude-code")
    }

    @Test("a token minted by ANOTHER instance's secret does not verify")
    func instanceSeparation() {
        // NFR4: instances are separated by their SECRETS, not by a path check. Prod, Dev and Dev3
        // hold different root secrets, so a token minted by one fails another's verification.
        let t = ClientRegistry.token(id: "claude-code", secret: secret)
        #expect(ClientRegistry.verify(token: t, secret: "a-different-instances-secret") == nil)
    }

    @Test("a forged or malformed token is refused, in every shape")
    func forgeriesRefused() {
        #expect(ClientRegistry.verify(token: "p42_claude-code_deadbeef", secret: secret) == nil)
        #expect(ClientRegistry.verify(token: "", secret: secret) == nil)
        #expect(ClientRegistry.verify(token: "claude-code", secret: secret) == nil)
        #expect(ClientRegistry.verify(token: "p42_claude-code", secret: secret) == nil)
        #expect(ClientRegistry.verify(token: "xxx_claude-code_mac", secret: secret) == nil)
        // An id outside [a-z0-9-] never round-trips, so a crafted one cannot smuggle a path
        // separator into the token FILE's name.
        let evil = ClientRegistry.token(id: "../../etc/passwd", secret: secret)
        #expect(ClientRegistry.verify(token: evil, secret: secret) == nil)
    }

    @Test("a token for one id cannot be replayed as another")
    func macBindsTheId() {
        let a = ClientRegistry.token(id: "claude-code", secret: secret)
        let macOfA = String(a.split(separator: "_", maxSplits: 2)[2])
        // Same MAC, different id — the MAC is over the id, so this must not verify.
        #expect(ClientRegistry.verify(token: "p42_gemini-cli_\(macOfA)", secret: secret) == nil)
    }

    @Test("the MAC comparison is CORRECT for near-misses")
    func comparisonRejectsNearMisses() {
        // Deliberately NOT called a constant-time test. This asserts correctness only: a
        // near-miss and a prefix must both fail. Plain `==` would satisfy every line here, which is
        // exactly why this cannot be the guarantee for NFR1 — see `verifyDoesNotUseEquality` below.
        let real = ClientRegistry.mac(id: "claude-code", secret: secret)
        var almost = Array(real)
        almost[almost.count - 1] = almost.last == "a" ? "b" : "a"
        #expect(!ClientRegistry.constantTimeEquals(real, String(almost)))
        #expect(!ClientRegistry.constantTimeEquals(real, String(real.dropLast())))
        #expect(ClientRegistry.constantTimeEquals(real, real))
    }

    @Test("NFR1 is enforced STRUCTURALLY: verification never compares a MAC with ==")
    func verifyDoesNotUseEquality() throws {
        // Timing is not unit-testable — a statistical timing assertion is flaky and proves little on
        // a loaded machine. So the property is made greppable instead, in the same shape as the
        // terminal write funnel: verification must route through `constantTimeEquals`, and the
        // comparison operator must not appear on the MAC path at all.
        //
        // This exists because the behavioral test above passes under a naive `==`. A test that a
        // wrong implementation also passes is not a gate, and NFR1 deserves a real one.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Services/ClientRegistry.swift")
        let src = try String(contentsOf: url, encoding: .utf8)

        let verifyStart = try #require(src.range(of: "public nonisolated static func verify("))
        let body = String(src[verifyStart.lowerBound...].prefix(700))
        #expect(body.contains("constantTimeEquals"),
                "verification must go through the constant-time comparison")

        let offending = body.split(separator: "\n").map(String.init).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("//"), !t.hasPrefix("///") else { return false }
            // `parts[0] == "p42"` is a fixed, public prefix and leaks nothing; a MAC comparison does.
            return t.contains("expected ==") || t.contains("== expected")
                || t.contains("presented ==") || t.contains("== presented")
        }
        let found = offending.joined(separator: "\n")
        #expect(offending.isEmpty, "a MAC is being compared with ==, which leaks it byte by byte:\n\(found)")
    }

    // MARK: - Slugs

    @Test("a caller-supplied name becomes a safe slug, and a path traversal cannot survive it")
    func slugging() {
        #expect(ClientRegistry.slug("Claude Code") == "claude-code")
        #expect(ClientRegistry.slug("Gemini CLI") == "gemini-cli")
        // The name is a CLAIM. It must not be able to escape the tokens directory.
        let s = ClientRegistry.slug("../../etc/passwd")
        #expect(!s.contains("/") && !s.contains(".."))
        #expect(ClientRegistry.isValidSlug(s))
        #expect(ClientRegistry.slug("") == "client")
        #expect(ClientRegistry.slug("!!!") == "client")
        #expect(ClientRegistry.isValidSlug(ClientRegistry.slug("MiXeD 123 Case!")))
    }

    @Test("a child's id is DERIVED, so grants survive a respawn")
    func childIdIsStable() {
        let a = ClientRegistry.childId(companionId: "echo", spaceId: "SPACE-1")
        let b = ClientRegistry.childId(companionId: "echo", spaceId: "SPACE-1")
        #expect(a == b, "a random child id would orphan its grants on every respawn")
        #expect(a != ClientRegistry.childId(companionId: "echo", spaceId: "SPACE-2"))
        #expect(a != ClientRegistry.childId(companionId: "forge", spaceId: "SPACE-1"))
        #expect(ClientRegistry.isValidSlug(a))
    }

    // MARK: - The registry

    @Test("registering a client stores it, and re-registering keeps the same row")
    @MainActor
    func registerAndReissue() throws {
        let db = try DatabaseService(inMemory: true)
        let reg = ClientRegistry(db: db, instance: "Port42TestInstance")

        let token = reg.register(id: "Claude Code", name: "Claude Code", kind: .paired)
        #expect(token != nil)
        let c = try #require(reg.client(id: "claude-code"))
        #expect(c.name == "Claude Code")
        #expect(c.kind == .paired)
        #expect(c.isActive)

        // Re-issue: same row, so grants attached to this id survive a client losing its file.
        let token2 = reg.register(id: "claude-code", name: "Claude Code", kind: .paired)
        #expect(token2 == token, "the same id and secret must mint the same token")
        #expect(reg.clients().filter { $0.id == "claude-code" }.count == 1)

        reg.revoke(id: "claude-code")
        #expect(reg.client(id: "claude-code")?.isActive == false)
    }

    @Test("re-registering a REVOKED client reactivates it, because that is a deliberate act")
    @MainActor
    func reregisterClearsRevocation() throws {
        let db = try DatabaseService(inMemory: true)
        let reg = ClientRegistry(db: db, instance: "Port42TestInstance")
        reg.register(id: "cron-job", name: "Cron", kind: .manual)
        reg.revoke(id: "cron-job")
        #expect(reg.client(id: "cron-job")?.isActive == false)

        reg.register(id: "cron-job", name: "Cron", kind: .manual)
        #expect(reg.client(id: "cron-job")?.isActive == true)
    }

    @Test("the token file lands at 0600 inside a 0700 directory, and revoking removes it")
    @MainActor
    func tokenFilePermissions() throws {
        let db = try DatabaseService(inMemory: true)
        // A throwaway instance name so this never touches a real ~/.port42/<instance>/tokens.
        let instance = "Port42Test-\(UUID().uuidString)"
        let reg = ClientRegistry(db: db, instance: instance)
        defer { try? FileManager.default.removeItem(at: reg.tokenDirectory().deletingLastPathComponent()) }

        let token = try #require(reg.register(id: "claude-code", name: "Claude Code", kind: .paired))
        let path = reg.tokenPath(id: "claude-code")

        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(try String(contentsOf: path, encoding: .utf8) == token)

        let fileMode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.int16Value == 0o600, "a token readable by group or other is a token anyone can use")
        let dirMode = try FileManager.default.attributesOfItem(
            atPath: reg.tokenDirectory().path)[.posixPermissions] as? NSNumber
        #expect(dirMode?.int16Value == 0o700)

        // BR5: revoking removes the file. The app owns it, so revocation is not advisory.
        reg.revoke(id: "claude-code")
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test("a fresh secret is 32 bytes of randomness, and two are never equal")
    func secretsAreRandom() {
        let a = ClientRegistry.randomSecret(), b = ClientRegistry.randomSecret()
        #expect(a != b)
        #expect(Data(base64Encoded: a)?.count == 32)
    }

    // MARK: - Children (step 6) — where the pooled bucket actually dies

    @Test("a spawned child is told its ID and its token PATH, never its token")
    func childEnvCarriesNoSecret() throws {
        // `ps -E` publishes a subprocess environment to every process running as the user — the same
        // measurement that moved the gateway's own secrets to stdin. A token in the environment would
        // be readable machine-wide, so the child gets an id (not a secret) plus a path to a 0600 file.
        let session = TerminalSessionBootstrap.make(
            sessionId: "panel-1", spaceId: "SPACE-1", spaceName: "port42-app",
            companionId: "echo", claudePath: "/bin/echo", oauthToken: "")

        let clientId = try #require(session.env["PORT42_CLIENT_ID"])
        #expect(clientId == ClientRegistry.childId(companionId: "echo", spaceId: "SPACE-1"),
                "the env and the registry must agree on who this child is")
        #expect(session.env["PORT42_TOKEN_FILE"]?.hasSuffix(clientId) == true)

        // Nothing in the environment may look like a credential.
        for (k, v) in session.env {
            #expect(!v.hasPrefix("p42_"), "\(k) carries a token into the process table")
        }
    }

    @Test("an ad-hoc terminal with no companion gets NO client identity")
    func adHocTerminalIsNotAChild() {
        // Nothing to derive an id from, and it must not silently share another child's — that
        // sharing is the pooling this step exists to end.
        let session = TerminalSessionBootstrap.make(
            sessionId: "panel-2", spaceId: "SPACE-1", spaceName: "port42-app",
            companionId: nil, claudePath: "/bin/echo", oauthToken: "")
        #expect(session.env["PORT42_CLIENT_ID"] == nil)
    }

    @Test("children do not pool: per companion AND per space")
    func childrenDoNotPool() {
        let a = ClientRegistry.childId(companionId: "echo", spaceId: "SPACE-1")
        let b = ClientRegistry.childId(companionId: "forge", spaceId: "SPACE-1")
        let c = ClientRegistry.childId(companionId: "echo", spaceId: "SPACE-2")
        #expect(Set([a, b, c]).count == 3,
                "children sharing an id would inherit each other's grants, which is today's defect")
    }

    /// **With REAL uuids, which is the whole point of this test existing.**
    ///
    /// The version above uses `"echo"` and `"SPACE-1"` and passed while production silently broke: a
    /// real child id is `child-<companionUUID>-<spaceUUID>`, 79 characters, and the old 64-character
    /// truncation cut the SPACE uuid in half. Two spaces sharing a 21-character prefix collapsed into
    /// ONE client — the pooling this step exists to end. Found by looking at the row Dev3 actually
    /// wrote, not by any test.
    @Test("real UUID-shaped ids stay distinct despite the length cap")
    func realUuidChildrenDoNotCollide() {
        let companion = "ac9b2306-cea3-4430-ab5e-778bd2e4a22f"
        // Two spaces agreeing for 21 characters, differing only after the old cut point.
        // Dev3's real space id, and a twin agreeing past where the old cut fell
        // (`…-4b60409c-e6c1-4ec0-85`), so the collision is the one that actually happened.
        let spaceA = "4b60409c-e6c1-4ec0-8571-223e6ee5bec5"
        let spaceB = "4b60409c-e6c1-4ec0-8571-999999999999"
        #expect(spaceA.prefix(24) == spaceB.prefix(24), "the fixture must actually share a prefix")

        let a = ClientRegistry.childId(companionId: companion, spaceId: spaceA)
        let b = ClientRegistry.childId(companionId: companion, spaceId: spaceB)
        #expect(a != b, "two spaces collapsed into one client, so their grants would merge")
        #expect(ClientRegistry.isValidSlug(a) && ClientRegistry.isValidSlug(b))
        #expect(a.count <= ClientRegistry.maxSlugLength)
        // And still derived: the same inputs give the same id, or a respawn loses its grants.
        #expect(a == ClientRegistry.childId(companionId: companion, spaceId: spaceA))
    }

    @Test("an over-long name is bounded but still unique")
    func longNamesStayUnique() {
        let a = ClientRegistry.slug(String(repeating: "a", count: 300) + "-one")
        let b = ClientRegistry.slug(String(repeating: "a", count: 300) + "-two")
        #expect(a != b, "truncation collapsed two different names into one client")
        #expect(a.count <= ClientRegistry.maxSlugLength)
        #expect(ClientRegistry.isValidSlug(a))
    }

    @Test("the path the child is handed is the path the registry writes")
    @MainActor
    func envPathMatchesWhereTheTokenLands() throws {
        // Two definitions of this path would mean the child looks where nothing was written — a
        // failure that only shows up once enforcement lands in step 5.
        let db = try DatabaseService(inMemory: true)
        let instance = "Port42Test-\(UUID().uuidString)"
        let reg = ClientRegistry(db: db, instance: instance)
        defer { try? FileManager.default.removeItem(at: reg.tokenDirectory().deletingLastPathComponent()) }

        let id = ClientRegistry.childId(companionId: "echo", spaceId: "SPACE-1")
        reg.register(id: id, name: "Echo", kind: .child)

        let advertised = ClientRegistry.tokenPath(id: id, instance: instance)
        #expect(advertised == reg.tokenPath(id: id))
        #expect(FileManager.default.fileExists(atPath: advertised.path),
                "the child was told a path the registry never wrote to")
    }
}
