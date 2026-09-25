import Testing
import Foundation
import GRDB
@testable import Port42Lib

/// Nautilus Phase 1 housekeeping (GM, 2026-09-25): duplicate version history (F6), orphaned ports
/// (F8), and the signing keys (v48).
@Suite("Port housekeeping")
struct PortHousekeepingTests {

    @Test("v49 keeps every distinct version and drops only exact repeats of the version before")
    func dedupeKeepsDistinct() throws {
        let db = try DatabaseService(inMemory: true)
        // Insert after the migrations have run, then run the migration's own statement.
        try db.dbQueue.write { d in
            let rows: [(String, Int, String)] = [("P", 1, "a"), ("P", 2, "a"), ("P", 3, "b"), ("P", 4, "b"),
                                                 ("P", 5, "a"), ("Q", 1, "a"), ("Q", 2, "a")]
            for (port, v, html) in rows {
                try d.execute(sql: "INSERT INTO port_versions (portUdid, version, html, createdAt) VALUES (?, ?, ?, ?)",
                              arguments: [port, v, html, Date()])
            }
            try d.execute(sql: DatabaseService.dedupePortVersionsSQL)
        }
        let kept = try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: "SELECT portUdid, version, html FROM port_versions ORDER BY portUdid, version")
                .map { "\($0["portUdid"] as String)\($0["version"] as Int)\($0["html"] as String)" }
        }
        // P: a,a,b,b,a -> a(1) b(3) a(5); Q: a,a -> a(1). A return to an earlier html is kept.
        #expect(kept == ["P1a", "P3b", "P5a", "Q1a"])
    }

    @Test("a port whose space no longer exists is reaped; a port in a live space and a spaceless one stay")
    func orphansReaped() throws {
        let db = try DatabaseService(inMemory: true)
        let live = Space.create(name: "live")
        try db.saveSpace(live)
        try db.dbQueue.write { d in
            for (id, space) in [("in-live", live.id as String?), ("orphan", "gone-space"), ("spaceless", nil)] {
                try d.execute(sql: "INSERT INTO port_panels (id, html, spaceId, title, width, height, createdAt) VALUES (?, '', ?, ?, 400, 300, ?)",
                              arguments: [id, space, id, Date()])
            }
        }
        #expect(try db.reapOrphanPortPanels() == 1)
        let left = try db.dbQueue.read { d in try String.fetchAll(d, sql: "SELECT id FROM port_panels ORDER BY id") }
        #expect(left == ["in-live", "spaceless"])
    }

    @Test("users carry no signing keys")
    func noSigningKeys() throws {
        let db = try DatabaseService(inMemory: true)
        let cols = try db.dbQueue.read { d in try d.columns(in: "users").map(\.name) }
        #expect(!cols.contains("publicKey"))
        #expect(!cols.contains("privateKey"))
    }
}
