import Testing
import Foundation
@testable import Port42Lib

@Suite("Models")
struct ModelTests {

    // MARK: - AppUser

    @Test("Create local user")
    func createLocalUser() {
        let user = AppUser.createForTesting(displayName: "Gordon")
        #expect(user.displayName == "Gordon")
        #expect(user.isLocal == true)
        #expect(user.avatarData == nil)
        #expect(!user.id.isEmpty)
    }



    @Test("Two users get unique IDs")
    func uniqueUserIds() {
        let a = AppUser.createForTesting(displayName: "Alice")
        let b = AppUser.createForTesting(displayName: "Bob")
        #expect(a.id != b.id)
    }

    // MARK: - Space

    @Test("Create space")
    func createSpace() {
        let space = Space.create(name: "builders")
        #expect(space.name == "builders")
        #expect(space.type == "team")
        #expect(!space.id.isEmpty)
    }

    @Test("Create space with custom type")
    func createDMSpace() {
        let space = Space.create(name: "alice", type: "dm")
        #expect(space.type == "dm")
    }

    // MARK: - Message

}
