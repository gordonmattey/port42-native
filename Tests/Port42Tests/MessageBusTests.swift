import Testing
import Foundation
@testable import Port42Lib

@Suite("MessageBus")
struct MessageBusTests {

    func makeDB() throws -> DatabaseService {
        try DatabaseService(inMemory: true)
    }

    func makeSpace(in db: DatabaseService, name: String = "test") throws -> Space {
        let space = Space.create(name: name)
        try db.saveSpace(space)
        return space
    }

    // MARK: - Topic-filtered getMessages

    @Test("getMessages(spaceId:topic:) returns only matching topic")
    func testTopicFilter() throws {
        let db = try makeDB()
        let space = try makeSpace(in: db)

        let chatMsg = Message.create(spaceId: space.id, senderId: "u1", senderName: "Alice", content: "hello", topic: "chat")
        let busMsg  = Message.create(spaceId: space.id, senderId: "u1", senderName: "Alice", content: "signal", topic: "bus")
        try db.saveMessage(chatMsg)
        try db.saveMessage(busMsg)

        let chatOnly = try db.getMessages(spaceId: space.id, topic: "chat")
        let busOnly  = try db.getMessages(spaceId: space.id, topic: "bus")

        #expect(chatOnly.count == 1)
        #expect(chatOnly[0].content == "hello")
        #expect(busOnly.count == 1)
        #expect(busOnly[0].content == "signal")
    }

    @Test("getMessages(spaceId:topic:) returns empty for unknown topic")
    func testUnknownTopicReturnsEmpty() throws {
        let db = try makeDB()
        let space = try makeSpace(in: db)

        let msg = Message.create(spaceId: space.id, senderId: "u1", senderName: "Alice", content: "hello", topic: "chat")
        try db.saveMessage(msg)

        let result = try db.getMessages(spaceId: space.id, topic: "port:someport")
        #expect(result.isEmpty)
    }

    @Test("getMessages(spaceId:topic:) scopes to spaceId")
    func testTopicScopedToSpace() throws {
        let db = try makeDB()
        let space1 = try makeSpace(in: db, name: "space1")
        let space2 = try makeSpace(in: db, name: "space2")

        let msg1 = Message.create(spaceId: space1.id, senderId: "u1", senderName: "Alice", content: "s1", topic: "bus")
        let msg2 = Message.create(spaceId: space2.id, senderId: "u1", senderName: "Alice", content: "s2", topic: "bus")
        try db.saveMessage(msg1)
        try db.saveMessage(msg2)

        let result = try db.getMessages(spaceId: space1.id, topic: "bus")
        #expect(result.count == 1)
        #expect(result[0].content == "s1")
    }

    // MARK: - Default topic

    @Test("Message.create defaults topic to 'chat'")
    func testDefaultTopic() throws {
        let db = try makeDB()
        let space = try makeSpace(in: db)

        let msg = Message.create(spaceId: space.id, senderId: "u1", senderName: "Alice", content: "hi")
        try db.saveMessage(msg)

        let allMsgs = try db.getMessages(spaceId: space.id)
        #expect(allMsgs.count == 1)
        #expect(allMsgs[0].topic == "chat")

        let chatFiltered = try db.getMessages(spaceId: space.id, topic: "chat")
        #expect(chatFiltered.count == 1)
    }

    // MARK: - Chat query excludes bus messages

    @Test("chat query never returns bus messages even when bus messages exist")
    func testChatQueryExcludesBus() throws {
        let db = try makeDB()
        let space = try makeSpace(in: db)

        // Add messages on two different topics
        let busMsg  = Message.create(spaceId: space.id, senderId: "u1", senderName: "agent", content: "signal", topic: "bus")
        let chatMsg = Message.create(spaceId: space.id, senderId: "u2", senderName: "Alice", content: "hi", topic: "chat")
        let sysMsg  = Message.create(spaceId: space.id, senderId: "u1", senderName: "system", content: "joined", topic: "system")
        try db.saveMessage(busMsg)
        try db.saveMessage(chatMsg)
        try db.saveMessage(sysMsg)

        let chatResults = try db.getMessages(spaceId: space.id, topic: "chat")
        #expect(chatResults.count == 1)
        #expect(chatResults[0].content == "hi")
        #expect(chatResults.allSatisfy { $0.topic == "chat" })
    }
}
