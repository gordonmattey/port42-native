import Testing
import Foundation
@testable import Port42Lib

@Suite("DatabaseService")
struct DatabaseTests {

    func makeDB() throws -> DatabaseService {
        try DatabaseService(inMemory: true)
    }

    // MARK: - Users

    @Test("Save and retrieve local user")
    func saveAndGetUser() throws {
        let db = try makeDB()
        let user = AppUser.createForTesting(displayName: "Gordon")
        try db.saveUser(user)

        let fetched = try db.getLocalUser()
        #expect(fetched != nil)
        #expect(fetched?.displayName == "Gordon")
        #expect(fetched?.isLocal == true)
        #expect(fetched?.id == user.id)
    }

    @Test("No local user initially")
    func noUserInitially() throws {
        let db = try makeDB()
        let user = try db.getLocalUser()
        #expect(user == nil)
    }



    // MARK: - Spaces

    @Test("Create and list spaces")
    func createAndListSpaces() throws {
        let db = try makeDB()
        let c1 = Space.create(name: "general")
        let c2 = Space.create(name: "builders")
        try db.saveSpace(c1)
        try db.saveSpace(c2)

        let spaces = try db.getAllSpaces()
        #expect(spaces.count == 2)
        #expect(spaces[0].name == "general")
        #expect(spaces[1].name == "builders")
    }

    @Test("Delete space")
    func deleteSpace() throws {
        let db = try makeDB()
        let space = Space.create(name: "temp")
        try db.saveSpace(space)
        #expect(try db.getAllSpaces().count == 1)

        try db.deleteSpace(id: space.id)
        #expect(try db.getAllSpaces().count == 0)
    }

    // MARK: - Messages

}
