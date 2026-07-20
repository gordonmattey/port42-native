import Testing
import Foundation
@testable import Port42Lib

// Step 1 of the command-companion cwd fix (docs/plan-companion-cwd.md): a Space carries a
// user-picked working directory. This suite gates the MODEL + MIGRATION only — a Space
// round-trips `workingDirectory` through the DB, and an unset value reads back nil (the
// append-only migration adds a nullable column, so pre-migration rows lose nothing). The
// home-fallback RESOLUTION lives in step 2 (`resolveTerminalCwd`), tested there.

@Suite("SpaceWorkingDir — the per-space working directory field")
struct SpaceWorkingDirTests {

    private func reload(_ db: DatabaseService, id: String) throws -> Space? {
        try db.getAllSpaces().first { $0.id == id }
    }

    @Test("A set working directory round-trips through the DB")
    func roundTripsWorkingDirectory() throws {
        let db = try DatabaseService(inMemory: true)
        var space = Space.create(name: "dev")
        space.workingDirectory = "/Users/gordon/code/project"
        try db.saveSpace(space)

        let loaded = try reload(db, id: space.id)
        #expect(loaded?.workingDirectory == "/Users/gordon/code/project")
    }

    @Test("An unset working directory reads back nil (migration adds a nullable column)")
    func unsetIsNil() throws {
        let db = try DatabaseService(inMemory: true)
        let space = Space.create(name: "dev")   // no workingDirectory set
        try db.saveSpace(space)

        let loaded = try reload(db, id: space.id)
        #expect(loaded?.workingDirectory == nil)
    }

    @Test("Normalization trims, and treats empty/blank as unset (nil) so a cleared picker clears the field")
    func normalizeWorkingDirectory() {
        #expect(Space.normalizeWorkingDirectory("/Users/gordon/code") == "/Users/gordon/code")
        #expect(Space.normalizeWorkingDirectory("  /Users/gordon/code  ") == "/Users/gordon/code")
        #expect(Space.normalizeWorkingDirectory("") == nil)
        #expect(Space.normalizeWorkingDirectory("   ") == nil)
        #expect(Space.normalizeWorkingDirectory(nil) == nil)
    }
}
