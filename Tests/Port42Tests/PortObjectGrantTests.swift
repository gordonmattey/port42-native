import Testing
import Foundation
@testable import Port42Lib

/// Slice-02 milestone A, step 1: **port 0 exists, and the grant key gains its object slot**
/// (docs/membrane/slice-02-cross-instance.md §4, §10 step 1, CR5).
///
/// **What makes these tests necessary rather than decorative.** No production path can put anything
/// but port 0 in the object slot today, because every `PortPermission` case is a machine capability.
/// So a migration that only ever writes `0` is indistinguishable from a key rename unless the tests
/// exercise a NON-ZERO object on purpose. They do: a tile key and a peer-qualified object, neither
/// of which production can currently produce, both of which the wire half will.
@Suite("Port 0 and the grant object (slice-02 A.1)")
struct PortObjectGrantTests {

    /// A scratch defaults domain, so nothing here can touch the real store. The migration walks
    /// `dictionaryRepresentation()`, which on `.standard` would include the user's 144 live grants.
    func scratchDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "port42.tests.grants.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: - The object

    @Test("port 0 is the machine, and it is local")
    func portZero() {
        #expect(PortObject.machine.portKey == "0")
        #expect(PortObject.machine.isLocal)
        #expect(PortObject.machine.keySegment == "0")
    }

    @Test("an object is peer-qualifiable in the address grammar, with a slash and never a dot")
    func peerQualified() {
        #expect(PortObject.remoteMachine(peerID: "12D3KooWabc").keySegment == "12D3KooWabc/0")
        #expect(PortObject.remotePort(peerID: "12D3KooWabc", portKey: "tile-7").keySegment
                    == "12D3KooWabc/tile-7")
        #expect(!PortObject.remoteMachine(peerID: "12D3KooWabc").isLocal)
        // The separator matters: a key is split on dots, so an object segment must not contain one.
        #expect(!PortObject.remoteMachine(peerID: "12D3KooWabc").keySegment.contains("."))
    }

    @Test("port 0 here and port 0 on a peer are DIFFERENT objects")
    func machineIsNotRemoteMachine() {
        #expect(PortObject.machine != PortObject.remoteMachine(peerID: "peerA"))
        #expect(PortObject.remoteMachine(peerID: "peerA") != PortObject.remoteMachine(peerID: "peerB"))
        #expect(PortObject.port("0") == PortObject.machine)   // same object, spelled two ways
    }

    // MARK: - The key

    @Test("a key names all three parts: grantee, object, zone")
    func keyShape() {
        #expect(PortGrantKey.key(grantee: "echo", object: .machine, zone: "space-1")
                    == "portGrant.echo.0.space-1")
        #expect(PortGrantKey.key(grantee: "echo", object: .remoteMachine(peerID: "peerA"), zone: nil)
                    == "portGrant.echo.peerA/0.global")
    }

    @Test("a zoneless caller keys under global, and an empty zone is the same as none")
    func zonelessKeysGlobal() {
        let none = PortGrantKey.key(grantee: "claude-code", object: .machine, zone: nil)
        let empty = PortGrantKey.key(grantee: "claude-code", object: .machine, zone: "")
        #expect(none == "portGrant.claude-code.0.global")
        #expect(none == empty)
    }

    // MARK: - The slot actually separates objects (the part production cannot show)

    @Test("a grant on port 0 is NOT visible on another port, and vice versa")
    @MainActor
    func objectSeparatesGrants() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let g = "grantee-\(UUID().uuidString)"
        let zone = "zone-\(UUID().uuidString)"
        let tile = PortObject.port("tile-\(UUID().uuidString)")

        appState.saveGrants([.terminal], grantee: g, on: .machine, zone: zone)
        #expect(appState.grants(grantee: g, on: .machine, zone: zone).contains(.terminal))
        #expect(appState.grants(grantee: g, on: tile, zone: zone).isEmpty)

        appState.saveGrants([.clipboard], grantee: g, on: tile, zone: zone)
        #expect(appState.grants(grantee: g, on: tile, zone: zone) == [.clipboard])
        // Granting on the tile must not have widened port 0's grant.
        #expect(appState.grants(grantee: g, on: .machine, zone: zone) == [.terminal])

        appState.saveGrants([], grantee: g, on: .machine, zone: zone)
        appState.saveGrants([], grantee: g, on: tile, zone: zone)
    }

    @Test("a grant on a PEER's port 0 does not reach this machine's port 0")
    @MainActor
    func peerObjectSeparatesGrants() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let g = "grantee-\(UUID().uuidString)"
        let theirs = PortObject.remoteMachine(peerID: "peer-\(UUID().uuidString)")

        appState.saveGrants([.screen], grantee: g, on: theirs, zone: nil)
        #expect(appState.grants(grantee: g, on: theirs, zone: nil) == [.screen])
        #expect(appState.grants(grantee: g, on: .machine, zone: nil).isEmpty)

        appState.saveGrants([], grantee: g, on: theirs, zone: nil)
    }

    // MARK: - The reap
    //
    // The objectless store is deleted rather than migrated onto port 0 (GM, 2026-07-29). Of the 144
    // grants in production only 9 could ever fire again: a grant is read with the caller's LIVE
    // zone, and 135 named a space that no longer exists. Everything re-asks once.

    @Test("the reap deletes every grant key, in both spellings, and nothing else")
    func reapDeletesGrants() {
        let d = scratchDefaults()
        // Every real production key shape: a space uuid, the legacy swim- form, global, and a
        // grantee that named itself over the WS door and so contains a space.
        d.set("terminal,ai", forKey: "portPerms.echo.SPACE-1")
        d.set("terminal", forKey: "portPerms.forge.swim-6A3F1B43-F15B-4AD1")
        d.set("screen", forKey: "portPerms.Claude Code.global")
        d.set("automation", forKey: "portGrant.local-http.0.global")   // from the retired migration
        d.set(true, forKey: "portGrantObjectMigrated")                 // its retired flag
        // Not grants. Must survive: a reap that reaches past its own prefixes is a different bug.
        d.set("1", forKey: "remoteAllowTerminal")
        d.set("keep me", forKey: "portGrantsEnabled")   // prefix-adjacent, deliberately

        #expect(PortGrantKey.reapGrantStore(in: d) == 5)

        #expect(d.string(forKey: "portPerms.echo.SPACE-1") == nil)
        #expect(d.string(forKey: "portPerms.forge.swim-6A3F1B43-F15B-4AD1") == nil)
        #expect(d.string(forKey: "portPerms.Claude Code.global") == nil)
        #expect(d.string(forKey: "portGrant.local-http.0.global") == nil)
        #expect(d.object(forKey: "portGrantObjectMigrated") == nil)
        #expect(d.string(forKey: "remoteAllowTerminal") == "1")
        #expect(d.string(forKey: "portGrantsEnabled") == "keep me")
    }

    @Test("the sweep is unconditional and idempotent, because grants no longer live here")
    func sweepIsUnconditional() {
        let d = scratchDefaults()
        d.set("terminal", forKey: "portPerms.echo.SPACE-1")
        d.set(true, forKey: "portGrantStoreReapedV1")   // the retired once-only flag

        #expect(PortGrantKey.reapGrantStore(in: d) == 2)   // the key AND the dead flag
        #expect(d.object(forKey: "portGrantStoreReapedV1") == nil)

        // Running again is a no-op rather than a hazard. While grants lived in defaults the flag was
        // load-bearing — a sweep per launch would have eaten real consent. With the table
        // authoritative there is nothing here left to protect.
        #expect(PortGrantKey.reapGrantStore(in: d) == 0)
        #expect(PortGrantKey.reapGrantStore(in: d) == 0)
    }

    @Test("a grant lives in the TABLE, so the defaults sweep cannot touch it")
    @MainActor
    func sweepCannotTouchARealGrant() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let g = "grantee-\(UUID().uuidString)"
        appState.saveGrants([.terminal], grantee: g, on: .machine, zone: nil)

        PortGrantKey.reapGrantStore(in: .standard)

        #expect(appState.grants(grantee: g, on: .machine, zone: nil) == [.terminal],
                "the defaults sweep reached a grant in the table")
        appState.revokeAllGrants(grantee: g)
    }

    @Test("the reap leaves an empty store, so nothing is inherited from before it")
    @MainActor
    func reapLeavesNothingReadable() throws {
        let d = scratchDefaults()
        d.set("terminal,screen,filesystem", forKey: "portPerms.Claude Code.global")
        PortGrantKey.reapGrantStore(in: d)

        // Read back through the key the app actually uses.
        let key = PortGrantKey.key(grantee: "Claude Code", object: .machine, zone: nil)
        #expect(d.string(forKey: key) == nil)
    }

    // MARK: - The table (A.2)
    //
    // The store moved out of UserDefaults so the permission manager can enumerate, group and revoke
    // ONE capability. The object/zone separation tests above are the real regression check on the
    // swap — they pass against either store, which is the point. These cover what only a table can
    // do, plus the two things the swap could break silently.

    @Test("re-granting an existing capability does not reset its history")
    @MainActor
    func regrantKeepsHistory() throws {
        let db = try DatabaseService(inMemory: true)
        let g = "grantee-\(UUID().uuidString)"
        try db.saveGrants([.terminal], grantee: g, object: "0", zone: "")
        try db.touchGrants(grantee: g, object: "0", zone: "")   // it has now been USED

        // Grant a second capability. The first must survive untouched, or "unused for 90 days"
        // means nothing the moment anything re-saves the set — and re-saving is what every grant
        // prompt does.
        //
        // Asserted on `lastUsedAt` rather than `grantedAt` deliberately: two `Date()` values written
        // microseconds apart land in the same stored millisecond, so a `grantedAt` comparison passes
        // whether the row was preserved or replaced. It was calibrated by breaking it and did not
        // fail. `lastUsedAt` is nil-or-not, so a replaced row is unambiguous.
        try db.saveGrants([.terminal, .clipboard], grantee: g, object: "0", zone: "")

        let terminal = try #require(try db.allGrants().first {
            $0.grantee == g && $0.permission == .terminal })
        #expect(terminal.lastUsedAt != nil, "re-granting replaced the row and erased its use history")
        let clipboard = try #require(try db.allGrants().first {
            $0.grantee == g && $0.permission == .clipboard })
        #expect(clipboard.lastUsedAt == nil, "a newly granted capability cannot already have been used")
        #expect(try db.grants(grantee: g, object: "0", zone: "") == [.terminal, .clipboard])
    }

    @Test("using a grant records it, which is what makes reaping possible later")
    func touchRecordsUse() throws {
        let db = try DatabaseService(inMemory: true)
        let g = "grantee-\(UUID().uuidString)"
        try db.saveGrants([.terminal], grantee: g, object: "0", zone: "")
        #expect(try db.allGrants().first { $0.grantee == g }?.lastUsedAt == nil)

        try db.touchGrants(grantee: g, object: "0", zone: "")
        #expect(try db.allGrants().first { $0.grantee == g }?.lastUsedAt != nil)
    }

    @Test("saving a smaller set revokes what is missing")
    func saveDropsMissing() throws {
        let db = try DatabaseService(inMemory: true)
        let g = "grantee-\(UUID().uuidString)"
        try db.saveGrants([.terminal, .clipboard, .screen], grantee: g, object: "0", zone: "")
        try db.saveGrants([.terminal], grantee: g, object: "0", zone: "")
        #expect(try db.grants(grantee: g, object: "0", zone: "") == [.terminal])
    }

    @Test("one capability can be revoked without touching the others")
    func revokeOne() throws {
        let db = try DatabaseService(inMemory: true)
        let g = "grantee-\(UUID().uuidString)"
        try db.saveGrants([.terminal, .clipboard], grantee: g, object: "0", zone: "")
        try db.revokeGrant(grantee: g, object: "0", zone: "", permission: .clipboard)
        #expect(try db.grants(grantee: g, object: "0", zone: "") == [.terminal])
    }

    @Test("revoking a grantee clears it everywhere, and leaves other grantees alone")
    func revokeGrantee() throws {
        let db = try DatabaseService(inMemory: true)
        let a = "a-\(UUID().uuidString)", b = "b-\(UUID().uuidString)"
        try db.saveGrants([.terminal], grantee: a, object: "0", zone: "zone-1")
        try db.saveGrants([.screen], grantee: a, object: "0", zone: "zone-2")
        try db.saveGrants([.terminal], grantee: b, object: "0", zone: "zone-1")

        try db.revokeAllGrants(grantee: a)
        #expect(try db.grants(grantee: a, object: "0", zone: "zone-1").isEmpty)
        #expect(try db.grants(grantee: a, object: "0", zone: "zone-2").isEmpty)
        #expect(try db.grants(grantee: b, object: "0", zone: "zone-1") == [.terminal])
    }

    @Test("the store can finally be ENUMERATED, which is the whole reason for the table")
    func enumerateAll() throws {
        let db = try DatabaseService(inMemory: true)
        let g = "grantee-\(UUID().uuidString)"
        try db.saveGrants([.terminal, .clipboard], grantee: g, object: "0", zone: "zone-1")
        try db.saveGrants([.screen], grantee: g, object: "peerA/0", zone: "")

        let mine = try db.allGrants().filter { $0.grantee == g }
        #expect(mine.count == 3)                                   // one ROW per permission
        #expect(Set(mine.map(\.object)) == ["0", "peerA/0"])
        #expect(mine.allSatisfy { $0.lastUsedAt == nil })           // never exercised yet
    }

    @Test("a revoked capability stops answering yes THROUGH the cache")
    @MainActor
    func revokeBeatsTheCache() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let g = "grantee-\(UUID().uuidString)"

        appState.saveGrants([.terminal], grantee: g, on: .machine, zone: nil)
        #expect(appState.grants(grantee: g, on: .machine, zone: nil) == [.terminal])  // now cached

        appState.revokeGrant(grantee: g, object: "0", zone: "", permission: .terminal)
        #expect(appState.grants(grantee: g, on: .machine, zone: nil).isEmpty,
                "a withdrawn capability was still granted from cache — the one error this store must not make")
    }

    @Test("a write is visible to the next read through the cache")
    @MainActor
    func writeThenReadIsCoherent() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let g = "grantee-\(UUID().uuidString)"

        #expect(appState.grants(grantee: g, on: .machine, zone: nil).isEmpty)   // caches the miss
        appState.saveGrants([.screen], grantee: g, on: .machine, zone: nil)
        #expect(appState.grants(grantee: g, on: .machine, zone: nil) == [.screen],
                "the cached MISS survived a write")
    }

    // MARK: - The manager's display rule (A.2 / D13)
    //
    // The one thing the permission manager exists to do. 135 of the 144 grants in the old store were
    // qualified by a space that had been deleted, and nothing anywhere said so. Rendering a zone as
    // a raw uuid would hide that exactly as well as having no screen did.

    @Test("a zone whose space is gone is named as gone, not printed as a uuid")
    func deadZoneIsNamedAsDead() {
        let live = ["SPACE-1": "port42-app"]

        let ok = PortGrantDisplay.zoneLabel("SPACE-1", spaceNames: live)
        #expect(ok.text == "in #port42-app")
        #expect(!ok.isDead)

        let dead = PortGrantDisplay.zoneLabel("SPACE-DELETED", spaceNames: live)
        #expect(dead.isDead)
        #expect(!dead.text.contains("SPACE-DELETED"), "a uuid on screen hides exactly what this exists to show")

        let everywhere = PortGrantDisplay.zoneLabel("", spaceNames: live)
        #expect(everywhere.text == "everywhere")
        #expect(!everywhere.isDead)
    }

    @Test("port 0 reads as the app's own name, local and remote")
    func objectReadsAsPort42() {
        #expect(PortGrantDisplay.objectLabel("0") == "Port42")
        #expect(PortGrantDisplay.objectLabel("12D3KooWabc/0") == "Port42 on 12D3KooWabc")
        #expect(PortGrantDisplay.objectLabel("tile-7") == "a port")
        #expect(PortGrantDisplay.objectLabel("12D3KooWabc/tile-7") == "a port on 12D3KooWabc")
    }

    // MARK: - The gate
    //
    // The property step 1 exists to establish: a grant cannot be read or written without naming its
    // object. Greppable, in the same shape as the terminal write funnel — a hand-maintained list of
    // call sites is a to-do list that rots, so the guarantee is structural.

    func sourceFiles() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var out: [(String, String)] = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in e where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    @Test("only PortObject.swift builds a grant key, anywhere in the source tree")
    func oneKeyBuilder() throws {
        var offenders: [String] = []
        for (name, text) in try sourceFiles() where name != "PortObject.swift" {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                if t.contains("\"portGrant") || t.contains("\"portPerms") {
                    offenders.append("\(name): \(t)")
                }
            }
        }
        let found = offenders.joined(separator: "\n")
        #expect(offenders.isEmpty,
                "a grant key is built outside PortGrantKey, which is how the object slot gets skipped:\n\(found)")
    }
}
