import Testing
import Foundation
@testable import Port42Lib

/// A version row records a CHANGE to a port, not a save of its panel record.
///
/// `persistPanel` snapshots a version on every panel write, and `setZ` calls `persistPanel` on every
/// click, hover-to-front and focus — so every layout event used to insert a full copy of the port's
/// HTML. Measured on a 6-panel dev instance before the guard: 1108 rows, 1.7MB, and every port had
/// exactly ONE distinct html. The version picker showed the user 102 identical entries.
///
/// The guard lives in `savePortVersion` rather than at its callers, so a caller added later cannot
/// reintroduce the noise without deleting this test.
@Suite("Port versions record changes, not clicks")
struct PortVersionNoiseTests {

    @Test("an identical html snapshot does not create a version")
    func identicalHtmlIsNotAVersion() throws {
        let db = try DatabaseService(inMemory: true)
        let html = "<h1>one</h1>"

        try db.savePortVersion(portUdid: "p1", html: html, createdBy: nil)
        for _ in 0..<20 { try db.savePortVersion(portUdid: "p1", html: html, createdBy: nil) }

        #expect(try db.fetchPortVersions(portUdid: "p1").count == 1)
    }

    @Test("a real edit still versions, and the history keeps its order")
    func realEditsStillVersion() throws {
        let db = try DatabaseService(inMemory: true)

        try db.savePortVersion(portUdid: "p1", html: "<h1>one</h1>", createdBy: nil)
        try db.savePortVersion(portUdid: "p1", html: "<h1>one</h1>", createdBy: nil)     // a click
        try db.savePortVersion(portUdid: "p1", html: "<h1>two</h1>", createdBy: nil)     // an edit
        try db.savePortVersion(portUdid: "p1", html: "<h1>two</h1>", createdBy: nil)     // a drag
        try db.savePortVersion(portUdid: "p1", html: "<h1>three</h1>", createdBy: nil)   // an edit

        let versions = try db.fetchPortVersions(portUdid: "p1")
        #expect(versions.map(\.html) == ["<h1>one</h1>", "<h1>two</h1>", "<h1>three</h1>"])
        #expect(versions.map(\.version) == [1, 2, 3])
    }

    @Test("reverting to earlier content versions again — the guard compares the LATEST, not the set")
    func revertIsAChange() throws {
        let db = try DatabaseService(inMemory: true)
        try db.savePortVersion(portUdid: "p1", html: "<h1>a</h1>", createdBy: nil)
        try db.savePortVersion(portUdid: "p1", html: "<h1>b</h1>", createdBy: nil)
        try db.savePortVersion(portUdid: "p1", html: "<h1>a</h1>", createdBy: nil)   // reverted → a change

        #expect(try db.fetchPortVersions(portUdid: "p1").count == 3)
    }

    @Test("the guard is per port — two ports with the same html both get a first version")
    func guardIsPerPort() throws {
        let db = try DatabaseService(inMemory: true)
        try db.savePortVersion(portUdid: "p1", html: "<h1>same</h1>", createdBy: nil)
        try db.savePortVersion(portUdid: "p2", html: "<h1>same</h1>", createdBy: nil)

        #expect(try db.fetchPortVersions(portUdid: "p1").count == 1)
        #expect(try db.fetchPortVersions(portUdid: "p2").count == 1)
    }
}
