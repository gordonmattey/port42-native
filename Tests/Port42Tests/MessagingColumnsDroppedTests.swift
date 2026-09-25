import Testing
import Foundation
import GRDB
@testable import Port42Lib

/// Migration v47 (nautilus Phase 1 step 4): the messaging hub's columns are gone from the schema, and
/// the rows they sat in survive.
@Suite("Messaging columns dropped")
struct MessagingColumnsDroppedTests {
    @Test("spaces has no encryptionKey or syncEnabled, users has no appleUserID")
    func columnsGone() throws {
        let db = try DatabaseService(inMemory: true)
        let (spaceCols, userCols) = try db.dbQueue.read { d in
            (try d.columns(in: "spaces").map(\.name), try d.columns(in: "users").map(\.name))
        }
        #expect(!spaceCols.contains("encryptionKey"))
        #expect(!spaceCols.contains("syncEnabled"))
        #expect(!userCols.contains("appleUserID"))
        #expect(spaceCols.contains("workingDirectory"), "the columns that stay are still there")
    }

    @Test("a space and a user still save and load")
    func rowsRoundTrip() throws {
        let db = try DatabaseService(inMemory: true)
        let space = Space.create(name: "after-v47")
        try db.saveSpace(space)
        #expect(try db.getAllSpaces().contains { $0.id == space.id })
        let user = AppUser.createForTesting(displayName: "v47")
        try db.saveUser(user)
        #expect(try db.getLocalUser()?.displayName == "v47")
    }
}
