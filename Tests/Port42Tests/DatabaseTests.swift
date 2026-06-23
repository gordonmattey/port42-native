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

    @Test("AppUser appleUserID persists across save/load")
    func appleUserIDPersists() throws {
        let db = try makeDB()
        var user = AppUser.createForTesting(displayName: "Gordon")
        user.appleUserID = "001234.abcdef1234567890.1234"
        try db.saveUser(user)

        let fetched = try db.getLocalUser()
        #expect(fetched?.appleUserID == "001234.abcdef1234567890.1234")
    }

    @Test("AppUser without appleUserID loads as nil")
    func appleUserIDNilByDefault() throws {
        let db = try makeDB()
        let user = AppUser.createForTesting(displayName: "Gordon")
        try db.saveUser(user)

        let fetched = try db.getLocalUser()
        #expect(fetched?.appleUserID == nil)
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

    @Test("Delete space cascades messages")
    func deleteCascadesMessages() throws {
        let db = try makeDB()
        let space = Space.create(name: "temp")
        try db.saveSpace(space)

        let msg = Message.create(
            spaceId: space.id, senderId: "u1",
            senderName: "Test", content: "hello"
        )
        try db.saveMessage(msg)
        #expect(try db.getMessages(spaceId: space.id).count == 1)

        try db.deleteSpace(id: space.id)
        #expect(try db.getMessages(spaceId: space.id).count == 0)
    }

    // MARK: - Messages

    @Test("Save and retrieve messages")
    func saveAndGetMessages() throws {
        let db = try makeDB()
        let space = Space.create(name: "test")
        try db.saveSpace(space)

        let m1 = Message.create(
            spaceId: space.id, senderId: "u1",
            senderName: "Alice", content: "first"
        )
        let m2 = Message.create(
            spaceId: space.id, senderId: "u2",
            senderName: "Bob", content: "second"
        )
        try db.saveMessage(m1)
        try db.saveMessage(m2)

        let messages = try db.getMessages(spaceId: space.id)
        #expect(messages.count == 2)
        #expect(messages[0].content == "first")
        #expect(messages[1].content == "second")
    }

    @Test("Messages are ordered by timestamp")
    func messageOrdering() throws {
        let db = try makeDB()
        let space = Space.create(name: "test")
        try db.saveSpace(space)

        let earlier = Message(
            id: UUID().uuidString, spaceId: space.id,
            senderId: "u1", senderName: "A", senderType: "human",
            content: "earlier", timestamp: Date(timeIntervalSince1970: 1000),
            replyToId: nil, syncStatus: "local", createdAt: Date()
        )
        let later = Message(
            id: UUID().uuidString, spaceId: space.id,
            senderId: "u1", senderName: "A", senderType: "human",
            content: "later", timestamp: Date(timeIntervalSince1970: 2000),
            replyToId: nil, syncStatus: "local", createdAt: Date()
        )
        // Insert out of order
        try db.saveMessage(later)
        try db.saveMessage(earlier)

        let messages = try db.getMessages(spaceId: space.id)
        #expect(messages[0].content == "earlier")
        #expect(messages[1].content == "later")
    }

    @Test("Messages scoped to space")
    func messagesPerSpace() throws {
        let db = try makeDB()
        let c1 = Space.create(name: "one")
        let c2 = Space.create(name: "two")
        try db.saveSpace(c1)
        try db.saveSpace(c2)

        try db.saveMessage(Message.create(
            spaceId: c1.id, senderId: "u", senderName: "X", content: "in one"
        ))
        try db.saveMessage(Message.create(
            spaceId: c2.id, senderId: "u", senderName: "X", content: "in two"
        ))

        #expect(try db.getMessages(spaceId: c1.id).count == 1)
        #expect(try db.getMessages(spaceId: c2.id).count == 1)
        #expect(try db.getMessages(spaceId: c1.id).first?.content == "in one")
    }

    @Test("Empty space returns no messages")
    func emptySpace() throws {
        let db = try makeDB()
        let space = Space.create(name: "empty")
        try db.saveSpace(space)

        let messages = try db.getMessages(spaceId: space.id)
        #expect(messages.isEmpty)
    }
}
