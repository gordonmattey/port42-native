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

    /// **THIS IS THE ONLY IMPLEMENTATION OF THE TOKEN FORMAT** (GM, 2026-07-29).
    ///
    /// It briefly had a twin in `gateway/credentials.go`, pinned to it by a shared test vector. GM's
    /// call was that a gate is not a fix: two implementations of one format can still drift, and the
    /// failure mode is the worst available — every token silently rejected while both sides stay
    /// individually correct and individually green. So the duplicate was deleted, not guarded. The
    /// gateway forwards a credential as an opaque string; the app mints AND verifies.
    ///
    /// The vector is kept because it pins the format against an INDEPENDENT computation (HMAC-SHA256
    /// over the id, base64url, unpadded) rather than against this code's opinion of itself — so it
    /// still catches an accidental change here, which is now the only place one could happen.
    /// `TestNoTokenFormatLivesInTheGateway` is what keeps the twin from returning.
    @Test("the token format is stable against an independently computed vector")
    func tokenFormatIsStable() {
        #expect(ClientRegistry.mac(id: "claude-code", secret: secret)
                    == "5U2Q9QduHVJNxsiJy6go6uItuDpLFuVdtf8pD4zRFHA")
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

    // MARK: - Who is calling (5a) — the CREDENTIAL decides, not sender_id

    @Test("a verified credential names the enrolled client, not the caller's chosen sender_id")
    @MainActor
    func credentialWinsOverSenderId() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let reg = appState.clientRegistry
        let token = try #require(reg.register(id: "claude-code", name: "Claude Code", kind: .manual))

        // The caller also claims to be someone else entirely — exactly how `"Claude Code"`,
        // `"Gemini CLI"` and claude1…claude101 came to hold standing grants in production.
        let who = try appState.resolveGatewayCaller(credential: token, senderId: "i-am-whoever-i-say")
        #expect(who.id == "claude-code", "sender_id must not be able to name a caller")
        #expect(who.name == "Claude Code", "the name is fixed at mint time, not asserted per call")
    }

    /// **THE FLIP (5b).** An unnamed caller used to get the pooled `local-http` principal. It is now
    /// refused, and every refusal names where to fix it (FR10) — because a session already running
    /// holds the old instruction block in its context and will never re-read it, so the error is the
    /// only thing that can teach.
    @Test("a call with NO credential is refused, and the refusal says where to fix it")
    @MainActor
    func unnamedCallerIsRefused() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        do {
            _ = try appState.resolveGatewayCaller(credential: nil, senderId: "local-http")
            Issue.record("an unnamed caller was accepted")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.authRequired.rawValue)
            #expect(e.message.contains("Settings → Access"), "the refusal must carry the fix (FR10)")
        }
    }

    @Test("a credential from ANOTHER instance is refused, and says so")
    @MainActor
    func foreignInstanceCredentialIsRefused() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        // Instances are separated by their secrets (NFR4), so this verifies perfectly somewhere else.
        // That is invisible from the caller's side, which is why the message names the cause.
        let foreign = ClientRegistry.token(id: "port42-cli", secret: "another-instances-secret")
        do {
            _ = try appState.resolveGatewayCaller(credential: foreign, senderId: "x")
            Issue.record("a foreign instance's credential was accepted")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.authRequired.rawValue)
            // Was `contains("different port42")`, pinned to a phrasing rather than to the fact. The
            // message now names WHICH instance refused (D1), which is the part that makes this
            // diagnosable, so the assertion moved to that.
            #expect(e.message.contains("Port42 instance"))
            #expect(e.message.lowercased().contains("mints its own"))
        }
    }

    // MARK: - Hygiene (E)

    @Test("E1 · a token file naming no client is reaped; a live client's is not")
    @MainActor
    func orphanTokenFilesAreReaped() throws {
        let db = try DatabaseService(inMemory: true)
        let reg = ClientRegistry(db: db, instance: "Port42Test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: reg.tokenDirectory().deletingLastPathComponent()) }

        _ = reg.register(id: "live-tool", name: "Live", kind: .manual)
        // An orphan, made the way the real ones were: a file whose row does not exist.
        let orphan = reg.tokenDirectory().appendingPathComponent("claude-code")
        try "p42_claude-code_whatever".write(to: orphan, atomically: true, encoding: .utf8)

        let removed = reg.reapOrphanTokenFiles()

        #expect(removed == ["claude-code"])
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: reg.tokenPath(id: "live-tool").path),
                "a live client's credential was destroyed")
    }

    @Test("E1 · a REVOKED client's row is respected, and a row with no file is left alone")
    @MainActor
    func reapDoesNotTouchRowsWithoutFiles() throws {
        let db = try DatabaseService(inMemory: true)
        let reg = ClientRegistry(db: db, instance: "Port42Test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: reg.tokenDirectory().deletingLastPathComponent()) }

        // D9: a user deleting their token file is a SUPPORTED act. The row survives so re-enrolling
        // lands on it and keeps its grants. Dev3 holds exactly this case (`test`), and treating it
        // as garbage would discard consent the user gave.
        _ = reg.register(id: "hand-made", name: "Hand Made", kind: .manual)
        try FileManager.default.removeItem(at: reg.tokenPath(id: "hand-made"))

        #expect(reg.reapOrphanTokenFiles().isEmpty, "the reap must never act on a missing FILE")
        #expect(try db.allClients().contains { $0.id == "hand-made" },
                "the row must survive, or re-enrolling would lose its grants")
    }

    @Test("E3 · grants held by an identity that cannot exist again are gone")
    @MainActor
    func unreachableGrantsAreReaped() throws {
        // `local-http` was deleted as an identity in 5b, so these can never fire. Measured on
        // 2026-07-31: three in production, two in Dev3. The migration runs on open, so a fresh
        // database can only demonstrate that a WRITE of one does not survive a reopen — what is
        // asserted here is that the delete is scoped, and a live grantee's grant is untouched.
        let db = try DatabaseService(inMemory: true)
        try db.saveGrants([.terminal], grantee: "local-http", object: "0", zone: "")
        try db.saveGrants([.terminal], grantee: "port42-cli", object: "0", zone: "")

        try db.reapUnreachableGrants()

        #expect(try db.grants(grantee: "local-http", object: "0", zone: "").isEmpty)
        #expect(try db.grants(grantee: "port42-cli", object: "0", zone: "") == [.terminal],
                "a live grantee's consent was destroyed")
    }

    // MARK: - The refusal (D)
    //
    // Measured 2026-07-31 on a machine running five instances at once: a session reached for prod's
    // token file while calling Dev4, and the refusal it got could not tell it so. "Add a client in
    // Settings → Access" is correct for a human and unusable by a process, and it never said which
    // Settings, on which instance.

    @Test("D1 · every refusal names the instance and port that refused")
    @MainActor
    func everyRefusalNamesWhoRefused() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        // **NOT compared against `refusingInstanceLabel()`.** The first version of this test did
        // exactly that, and when the label was replaced with the bare word "Port42" the test still
        // passed — both sides moved together, so it could never fail. It asserts the FACTS a caller
        // needs instead: which instance, and which port. Fifth time in this thread that calibration
        // caught the test rather than the code.
        let instance = ClientRegistry.currentInstance
        let port = String(GatewayProcess.shared.port)

        var messages: [String] = []
        func capture(_ credential: String?) {
            do { _ = try appState.resolveGatewayCaller(credential: credential, senderId: "x") }
            catch let e as BridgeError { messages.append(e.message) }
            catch { Issue.record("unexpected error type") }
        }
        capture(nil)                                                          // no credential
        capture(ClientRegistry.token(id: "x", secret: "another-instance"))    // foreign instance
        capture(ClientRegistry.token(id: "ghost",                             // verifies, no row
                                     secret: appState.clientRegistry.rootSecret()))

        #expect(messages.count == 3, "all three refusal paths must produce a message")
        for m in messages {
            #expect(m.contains(instance), "refusal does not name the instance: \(m)")
            #expect(m.contains(port), "refusal does not name the port it reached: \(m)")
        }
        // And no message may ever echo the credential itself (NFR2).
        for m in messages { #expect(!m.contains("p42_")) }
    }

    @Test("D3 · a caller Port42 started is told how to fix it WITHOUT a human")
    @MainActor
    func refusalIsExecutableByAProcess() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        do {
            _ = try appState.resolveGatewayCaller(credential: nil, senderId: "x")
            Issue.record("accepted")
        } catch let e as BridgeError {
            // The remedy a process can actually execute, rather than only the one needing a GUI.
            #expect(e.message.contains("PORT42_TOKEN_FILE"))
            #expect(e.message.contains("Settings → Access"), "the human route must survive too")
            #expect(e.message.lowercased().contains("another tool's token"),
                    "the borrow is what actually happened, so the refusal names it")
        }
    }

    @Test("D4 · an ORPHAN token reads differently from a revoked client")
    @MainActor
    func orphanAndRevokedAreDistinguishable() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))

        // Orphan: verifies against this instance, names a client that has no row. Exactly the state
        // ~/.port42/port42/tokens/claude-code was in when a session found it.
        let orphan = ClientRegistry.token(id: "claude-code", secret: appState.clientRegistry.rootSecret())
        var orphanMessage = ""
        do { _ = try appState.resolveGatewayCaller(credential: orphan, senderId: "x") }
        catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.authRevoked.rawValue)
            orphanMessage = e.message
        }

        // Revoked: a real client the user withdrew.
        let token = try #require(appState.clientRegistry.register(
            id: "old-tool", name: "Old Tool", kind: .manual))
        appState.revokeClient(id: "old-tool")
        var revokedMessage = ""
        do { _ = try appState.resolveGatewayCaller(credential: token, senderId: "x") }
        catch let e as BridgeError { revokedMessage = e.message }

        // Same code, different repair: stop using a stale file, versus ask the human who withdrew it.
        #expect(orphanMessage != revokedMessage)
        #expect(orphanMessage.lowercased().contains("leftover"))
        #expect(revokedMessage.lowercased().contains("ask them"))
    }

    @Test("a REVOKED client is refused with auth_revoked, not auth_required")
    @MainActor
    func revokedClientIsRefusedDistinctly() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let token = try #require(appState.clientRegistry.register(
            id: "old-tool", name: "Old Tool", kind: .manual))
        appState.revokeClient(id: "old-tool")
        do {
            _ = try appState.resolveGatewayCaller(credential: token, senderId: "x")
            Issue.record("a revoked client was accepted")
        } catch let e as BridgeError {
            // Kept apart from auth_required on purpose: the credential is REAL, so re-sending it will
            // never help. Same rule that keeps no_surface apart from not_found — the repair differs.
            #expect(e.code == BridgeErrorCode.authRevoked.rawValue)
            #expect(e.message.contains("Old Tool"), "name the client, since the user chose that name")
        }
    }

    @Test("revocation is the APP's decision, not the credential's — D6's split")
    @MainActor
    func revocationIsCheckedAgainstTheRow() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let reg = appState.clientRegistry
        let token = try #require(reg.register(id: "old-tool", name: "Old Tool", kind: .manual))
        #expect(try appState.resolveGatewayCaller(credential: token, senderId: "x").id == "old-tool")

        appState.revokeClient(id: "old-tool")

        // THE POINT: the token still verifies CRYPTOGRAPHICALLY. Revocation works because the app
        // checks the row, not because the credential became invalid — which is exactly why it takes
        // effect on the next call with no gateway restart and no client table on the transport.
        #expect(ClientRegistry.verify(token: token, secret: reg.rootSecret()) == "old-tool")
        #expect(throws: BridgeError.self) {
            _ = try appState.resolveGatewayCaller(credential: token, senderId: "x")
        }
    }

    @Test("a forged credential does not name anybody")
    @MainActor
    func forgedCredentialIsIgnored() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.clientRegistry.register(id: "claude-code", name: "Claude Code", kind: .manual)
        // Right shape, wrong MAC. Refused, and `senderId` gets no say — that string is caller-chosen
        // and was never an identity.
        #expect(throws: BridgeError.self) {
            _ = try appState.resolveGatewayCaller(credential: "p42_claude-code_deadbeef", senderId: "x")
        }
    }

    @Test("a credential for a client that was never enrolled names nobody")
    @MainActor
    func unknownClientIsIgnored() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        // Correctly signed by this instance's secret, but no row exists — a token file left behind
        // after the row was deleted, for instance.
        let orphan = ClientRegistry.token(id: "ghost", secret: appState.clientRegistry.rootSecret())
        #expect(throws: BridgeError.self) {
            _ = try appState.resolveGatewayCaller(credential: orphan, senderId: "x")
        }
    }

    // MARK: - Add by hand (CR4) — the route for a caller nobody installs

    @Test("a hand-added client is enrolled, named as typed, and its token is readable at the path")
    @MainActor
    func addByHandEnrols() throws {
        let db = try DatabaseService(inMemory: true)
        let instance = "Port42Test-\(UUID().uuidString)"
        let reg = ClientRegistry(db: db, instance: instance)
        defer { try? FileManager.default.removeItem(at: reg.tokenDirectory().deletingLastPathComponent()) }

        // What Settings does: slug the typed name for the id, keep the typed name for the card.
        let typed = "My Backup Script"
        let id = ClientRegistry.slug(typed)
        let token = try #require(reg.register(id: id, name: typed, kind: .manual))

        let client = try #require(reg.client(id: "my-backup-script"))
        #expect(client.name == typed, "the card must show what the user typed, not the slug")
        #expect(client.kind == .manual)

        // The user is shown a PATH, so the file has to actually be there with the token in it.
        let path = reg.tokenPath(id: id)
        #expect(try String(contentsOf: path, encoding: .utf8) == token)
    }

    @Test("a hand-added client can then name a call")
    @MainActor
    func handAddedClientIsNamedOnCalls() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let token = try #require(appState.clientRegistry.register(
            id: ClientRegistry.slug("scripts"), name: "scripts", kind: .manual))
        // The whole point: a script with no installer and no human at call time can still be named.
        let who = try appState.resolveGatewayCaller(credential: token, senderId: "local-http")
        #expect(who.id == "scripts")
        #expect(who.name == "scripts")
    }

    @Test("two names that slug the same way are ONE client, not two")
    @MainActor
    func slugCollisionsReuseTheRow() throws {
        let db = try DatabaseService(inMemory: true)
        let instance = "Port42Test-\(UUID().uuidString)"
        let reg = ClientRegistry(db: db, instance: instance)
        defer { try? FileManager.default.removeItem(at: reg.tokenDirectory().deletingLastPathComponent()) }

        // "My Script" and "my-script" are the same id. Re-adding re-issues onto the same row rather
        // than silently creating a second client the user cannot tell apart in the list.
        reg.register(id: ClientRegistry.slug("My Script"), name: "My Script", kind: .manual)
        reg.register(id: ClientRegistry.slug("my-script"), name: "my-script", kind: .manual)
        #expect(reg.clients().filter { $0.id == "my-script" }.count == 1)
        #expect(reg.client(id: "my-script")?.name == "my-script", "the later name wins")
    }

    // MARK: - Install-time enrolment (GM, 2026-07-29)
    //
    // The CLI is not a child, so step 6's spawn-time enrolment never reaches it, and CR3's stated
    // remedy — pairing — was dropped. Installing is the named act instead: the user is present and is
    // deliberately putting the tool on their machine, the same consent that lets a child enrol
    // silently. Without this there is no way for the CLI to hold a token, and 5b would lock the door
    // with nobody able to knock.

    @Test("installing the CLI enrols it, and re-installing keeps the same row and token")
    @MainActor
    func installEnrolsTheCLI() throws {
        let db = try DatabaseService(inMemory: true)
        let instance = "Port42Test-\(UUID().uuidString)"
        let reg = ClientRegistry(db: db, instance: instance)
        defer { try? FileManager.default.removeItem(at: reg.tokenDirectory().deletingLastPathComponent()) }

        let first = reg.register(id: CLIInstallService.clientID,
                                 name: CLIInstallService.clientName, kind: .installed)
        let client = try #require(reg.client(id: "port42-cli"))
        #expect(client.kind == .installed, "the user did not name this one; Port42 knows what it is")
        #expect(client.name == "port42 CLI")

        // Install runs on EVERY boot and re-points after the app moves, so enrolment must be
        // idempotent — a new token each time would invalidate the CLI's stored file on every launch.
        let second = reg.register(id: CLIInstallService.clientID,
                                  name: CLIInstallService.clientName, kind: .installed)
        #expect(first == second)
        #expect(reg.clients().filter { $0.id == "port42-cli" }.count == 1)
    }

    @Test("the CLI's id is FIXED, because the CLI must compute its own token path")
    func cliIdIsFixed() {
        // The CLI reads a known path with no way to ask what its id is — the same reason a client id
        // is a slug rather than a UUID. A derived or random id here would be unreadable to it.
        #expect(CLIInstallService.clientID == "port42-cli")
        #expect(ClientRegistry.isValidSlug(CLIInstallService.clientID))
        #expect(ClientRegistry.slug(CLIInstallService.clientID) == CLIInstallService.clientID,
                "the id must survive slugging unchanged, or the row and the file would disagree")
    }

    @Test("an enrolled CLI is named on a call; an unenrolled one is refused")
    @MainActor
    func cliCallIsNamed() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let token = try #require(appState.clientRegistry.register(
            id: CLIInstallService.clientID, name: CLIInstallService.clientName, kind: .installed))

        #expect(try appState.resolveGatewayCaller(credential: token, senderId: "local-http").id == "port42-cli")
        // And an UNENROLLED one is refused (5b). There is no anonymous lane left.
        #expect(throws: BridgeError.self) {
            _ = try appState.resolveGatewayCaller(credential: nil, senderId: "local-http")
        }
    }

    // MARK: - Children (step 6) — where the pooled bucket actually dies

    @Test("a spawned child is told its ID and its token PATH, never its token")
    func childEnvCarriesNoSecret() throws {
        // `ps -E` publishes a subprocess environment to every process running as the user — the same
        // measurement that moved the gateway's own secrets to stdin. A token in the environment would
        // be readable machine-wide, so the child gets an id (not a secret) plus a path to a 0600 file.
        let session = TerminalSessionBootstrap.make(
            sessionId: "panel-1", spaceId: "SPACE-1", spaceName: "port42-app",
            companionId: "echo", claudePath: "/bin/echo")

        let clientId = try #require(session.env["PORT42_CLIENT_ID"])
        #expect(clientId == ClientRegistry.childId(companionId: "echo", spaceId: "SPACE-1"),
                "the env and the registry must agree on who this child is")
        #expect(session.env["PORT42_TOKEN_FILE"]?.hasSuffix(clientId) == true)

        // Nothing in the environment may look like a credential.
        for (k, v) in session.env {
            #expect(!v.hasPrefix("p42_"), "\(k) carries a token into the process table")
        }
    }

    @Test("B2 · a terminal with no companion is STILL enrolled, under its own id")
    func adHocTerminalIsStillEnrolled() throws {
        // **THIS TEST USED TO ASSERT THE OPPOSITE**, that an ad-hoc terminal gets no identity
        // (§10a5). That rule was right about SHARING and wrong about nothing: being spawned by
        // Port42 is the named act, and leaving the terminal anonymous is what sent a session
        // looking for the CLI's token on 2026-07-31. Reversed deliberately (GM), not relaxed —
        // the anti-pooling property below is what the old rule was actually protecting.
        let session = TerminalSessionBootstrap.make(
            sessionId: "panel-2", spaceId: "SPACE-1", spaceName: "port42-app",
            companionId: nil, claudePath: "/bin/echo")
        let id = try #require(session.env["PORT42_CLIENT_ID"])
        #expect(session.env["PORT42_TOKEN_FILE"]?.hasSuffix(id) == true)

        // And it pools with nobody: not with a companion, not with another terminal.
        let companion = ClientRegistry.spawnedTerminalId(companionId: "echo", sessionId: "panel-2",
                                                         spaceId: "SPACE-1")
        let otherTerminal = ClientRegistry.spawnedTerminalId(companionId: nil, sessionId: "panel-3",
                                                             spaceId: "SPACE-1")
        let otherSpace = ClientRegistry.spawnedTerminalId(companionId: nil, sessionId: "panel-2",
                                                          spaceId: "SPACE-2")
        #expect(id != companion)
        #expect(id != otherTerminal)
        #expect(id != otherSpace)
    }

    @Test("B4 · a companion PROMPT without an id still gets an identity — the exact defect")
    func companionPromptWithoutIdIsStillEnrolled() throws {
        // The shape that broke: identity was gated on `companionId` while companion-ness arrived
        // via `companionPrompt`, so a spawn could set the second and omit the first. Measured on
        // 2026-07-31 in a live session: PORT42_COMPANION_PROMPT set, PORT42_CLIENT_ID absent.
        let session = TerminalSessionBootstrap.make(
            sessionId: "panel-9", spaceId: "SPACE-1", spaceName: "port42-app",
            companionId: nil, companionPrompt: "You are Maker, a space companion in Port42",
            claudePath: "/bin/echo")
        #expect(session.env["PORT42_COMPANION_PROMPT"] != nil)
        #expect(session.env["PORT42_CLIENT_ID"] != nil,
                "a session with a companion prompt and no identity is the defect this fixes")
        #expect(session.env["PORT42_TOKEN_FILE"] != nil)
    }

    @Test("B5 · a respawn lands on the same id, so grants survive it")
    func respawnKeepsTheSameIdentity() throws {
        func idFor(_ companion: String?) throws -> String {
            let s = TerminalSessionBootstrap.make(
                sessionId: "panel-7", spaceId: "SPACE-1", spaceName: "port42-app",
                companionId: companion, claudePath: "/bin/echo")
            return try #require(s.env["PORT42_CLIENT_ID"])
        }
        #expect(try idFor("echo") == idFor("echo"))
        #expect(try idFor(nil) == idFor(nil))   // ad-hoc keys on the port id, also stable
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

    // MARK: - Test isolation (A)
    //
    // The suite used to write into the DAILY DRIVER's credential store. `AppState.clientRegistry`
    // is built with no explicit instance, so it resolved to `"Port42"`, which lowercases to
    // `port42`, which is prod. A test that built an `AppState` and registered anything minted with
    // prod's real Keychain root secret and left a real token file in a real user's home. Measured
    // 2026-07-31: `claude-code` and `scripts` appeared in `~/.port42/port42/tokens/` at 07:30:31,
    // the second a full suite run happened, with no matching rows in prod's database.
    //
    // A throwaway instance NAME is not the guard, because the defect came from a caller that passed
    // no name at all. The whole path is rooted elsewhere instead.

    @Test("A1 · no test can write into a real ~/.port42 directory, whatever instance it names")
    func testsNeverTouchTheRealTokenStore() {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".port42").standardizedFileURL.path

        // The dangerous one FIRST: the instance a registry gets when nobody passes one, which is
        // exactly what `AppState` does.
        for instance in [ClientRegistry.currentInstance, "Port42", "port42", "Port42Dev3"] {
            let dir = ClientRegistry.tokenDirectory(instance: instance).standardizedFileURL.path
            #expect(!dir.hasPrefix(home),
                    "instance '\(instance)' resolves into the user's real credential store: \(dir)")
        }
    }

    @Test("A1b · the DEFECT ITSELF: a registry built with no instance, registering, writes nowhere real")
    @MainActor
    func defaultRegistryDoesNotWriteIntoTheUsersHome() throws {
        // A1 and A2 pin path RESOLUTION, which is not what broke. What broke was this exact
        // sequence, and it is what `AppState.clientRegistry` does: construct with no instance, then
        // register. Reproduced rather than approximated, so a second way to write a token file
        // would still be caught here.
        let reg = ClientRegistry(db: try DatabaseService(inMemory: true))   // no instance, as AppState
        let token = reg.register(id: "claude-code", name: "Claude Code", kind: .installed)
        #expect(token != nil)

        let written = reg.tokenPath(id: "claude-code").standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".port42").standardizedFileURL.path
        #expect(!written.hasPrefix(home), "a test just wrote a credential into the user's home: \(written)")
        #expect(FileManager.default.fileExists(atPath: written), "it must still write SOMEWHERE, or this proves nothing")
    }

    @Test("A2 · a test process mints from memory, never from the Keychain")
    @MainActor
    func testsNeverMintWithTheRealRootSecret() throws {
        #expect(ClientRegistry.isTestProcess,
                "the isolation guard is not active, so every other assertion here is vacuous")

        // Two registries on the same instance share a secret, so a token still round-trips within a
        // run; a different instance gets a different one, so NFR4's separation is still exercised.
        let a = ClientRegistry(db: try DatabaseService(inMemory: true), instance: "Port42")
        let b = ClientRegistry(db: try DatabaseService(inMemory: true), instance: "Port42")
        let c = ClientRegistry(db: try DatabaseService(inMemory: true), instance: "Port42Other")
        #expect(a.rootSecret() == b.rootSecret())
        #expect(a.rootSecret() != c.rootSecret())

        // And it is not the daily driver's. A token minted here must not verify against whatever
        // prod holds, which is the property the orphan files violated.
        if let real = Port42AuthStore.shared.gatewayRootSecret(instance: "Port42") {
            // Compared into a Bool FIRST, because `#expect` prints both operands on failure and
            // this one would print the user's root secret into the test log. NFR2 is "never
            // logged, never in an error body", and a failing assertion is both. Found by
            // calibrating this gate, which is the only run where the message is ever produced.
            let mintsWithTheRealSecret = (a.rootSecret() == real)
            #expect(mintsWithTheRealSecret == false,
                    "a test is minting with the daily driver's root secret")
        }
    }
}
