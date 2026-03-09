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
        let user = AppUser.createLocal(displayName: "Gordon")
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
        var user = AppUser.createLocal(displayName: "Gordon")
        user.appleUserID = "001234.abcdef1234567890.1234"
        try db.saveUser(user)

        let fetched = try db.getLocalUser()
        #expect(fetched?.appleUserID == "001234.abcdef1234567890.1234")
    }

    @Test("AppUser without appleUserID loads as nil")
    func appleUserIDNilByDefault() throws {
        let db = try makeDB()
        let user = AppUser.createLocal(displayName: "Gordon")
        try db.saveUser(user)

        let fetched = try db.getLocalUser()
        #expect(fetched?.appleUserID == nil)
    }

    // MARK: - Channels

    @Test("Create and list channels")
    func createAndListChannels() throws {
        let db = try makeDB()
        let c1 = Channel.create(name: "general")
        let c2 = Channel.create(name: "builders")
        try db.saveChannel(c1)
        try db.saveChannel(c2)

        let channels = try db.getAllChannels()
        #expect(channels.count == 2)
        #expect(channels[0].name == "general")
        #expect(channels[1].name == "builders")
    }

    @Test("Delete channel")
    func deleteChannel() throws {
        let db = try makeDB()
        let channel = Channel.create(name: "temp")
        try db.saveChannel(channel)
        #expect(try db.getAllChannels().count == 1)

        try db.deleteChannel(id: channel.id)
        #expect(try db.getAllChannels().count == 0)
    }

    @Test("Delete channel cascades messages")
    func deleteCascadesMessages() throws {
        let db = try makeDB()
        let channel = Channel.create(name: "temp")
        try db.saveChannel(channel)

        let msg = Message.create(
            channelId: channel.id, senderId: "u1",
            senderName: "Test", content: "hello"
        )
        try db.saveMessage(msg)
        #expect(try db.getMessages(channelId: channel.id).count == 1)

        try db.deleteChannel(id: channel.id)
        #expect(try db.getMessages(channelId: channel.id).count == 0)
    }

    // MARK: - Messages

    @Test("Save and retrieve messages")
    func saveAndGetMessages() throws {
        let db = try makeDB()
        let channel = Channel.create(name: "test")
        try db.saveChannel(channel)

        let m1 = Message.create(
            channelId: channel.id, senderId: "u1",
            senderName: "Alice", content: "first"
        )
        let m2 = Message.create(
            channelId: channel.id, senderId: "u2",
            senderName: "Bob", content: "second"
        )
        try db.saveMessage(m1)
        try db.saveMessage(m2)

        let messages = try db.getMessages(channelId: channel.id)
        #expect(messages.count == 2)
        #expect(messages[0].content == "first")
        #expect(messages[1].content == "second")
    }

    @Test("Messages are ordered by timestamp")
    func messageOrdering() throws {
        let db = try makeDB()
        let channel = Channel.create(name: "test")
        try db.saveChannel(channel)

        let earlier = Message(
            id: UUID().uuidString, channelId: channel.id,
            senderId: "u1", senderName: "A", senderType: "human",
            content: "earlier", timestamp: Date(timeIntervalSince1970: 1000),
            replyToId: nil, syncStatus: "local", createdAt: Date()
        )
        let later = Message(
            id: UUID().uuidString, channelId: channel.id,
            senderId: "u1", senderName: "A", senderType: "human",
            content: "later", timestamp: Date(timeIntervalSince1970: 2000),
            replyToId: nil, syncStatus: "local", createdAt: Date()
        )
        // Insert out of order
        try db.saveMessage(later)
        try db.saveMessage(earlier)

        let messages = try db.getMessages(channelId: channel.id)
        #expect(messages[0].content == "earlier")
        #expect(messages[1].content == "later")
    }

    @Test("Messages scoped to channel")
    func messagesPerChannel() throws {
        let db = try makeDB()
        let c1 = Channel.create(name: "one")
        let c2 = Channel.create(name: "two")
        try db.saveChannel(c1)
        try db.saveChannel(c2)

        try db.saveMessage(Message.create(
            channelId: c1.id, senderId: "u", senderName: "X", content: "in one"
        ))
        try db.saveMessage(Message.create(
            channelId: c2.id, senderId: "u", senderName: "X", content: "in two"
        ))

        #expect(try db.getMessages(channelId: c1.id).count == 1)
        #expect(try db.getMessages(channelId: c2.id).count == 1)
        #expect(try db.getMessages(channelId: c1.id).first?.content == "in one")
    }

    @Test("Empty channel returns no messages")
    func emptyChannel() throws {
        let db = try makeDB()
        let channel = Channel.create(name: "empty")
        try db.saveChannel(channel)

        let messages = try db.getMessages(channelId: channel.id)
        #expect(messages.isEmpty)
    }
}
