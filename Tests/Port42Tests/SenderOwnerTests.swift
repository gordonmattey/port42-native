import Testing
import Foundation
@testable import Port42Lib

@Suite("F-506/F-509 Sender Owner")
struct SenderOwnerTests {

    // MARK: - Message Model

    @Test("Human message has nil senderOwner by default")
    func humanMessageNilOwner() {
        let msg = Message.create(
            channelId: "ch1", senderId: "user1",
            senderName: "Gordon", content: "hello"
        )
        #expect(msg.senderOwner == nil)
    }

    @Test("Agent message preserves senderOwner on init")
    func agentMessageOwner() {
        let msg = Message(
            id: "m1", channelId: "ch1", senderId: "agent1",
            senderName: "Echo", senderType: "agent",
            content: "hi", timestamp: Date(),
            replyToId: nil, syncStatus: "local",
            createdAt: Date(), senderOwner: "Gordon"
        )
        #expect(msg.senderOwner == "Gordon")
    }

    // MARK: - ChatEntry Display Name

    @Test("ChatEntry displayName without owner shows bare name")
    func displayNameNoOwner() {
        let entry = ChatEntry(
            id: "1", senderName: "Echo", content: "hi",
            isAgent: true
        )
        #expect(entry.displayName == "Echo")
    }

    @Test("ChatEntry displayName with owner shows Name@Owner")
    func displayNameWithOwner() {
        let entry = ChatEntry(
            id: "1", senderName: "Echo", content: "hi",
            isAgent: true, senderOwner: "Gordon"
        )
        #expect(entry.displayName == "Echo@Gordon")
    }

    @Test("ChatEntry human has no senderOwner")
    func humanChatEntry() {
        let entry = ChatEntry(
            id: "1", senderName: "Alice", content: "hello"
        )
        #expect(entry.displayName == "Alice")
        #expect(entry.senderOwner == nil)
    }

    // MARK: - Agent Color Hashing

    @Test("Agent color is deterministic for same name")
    func agentColorDeterministic() {
        let c1 = Port42Theme.agentColor(for: "Echo")
        let c2 = Port42Theme.agentColor(for: "Echo")
        #expect(c1 == c2)
    }

    @Test("Agent color differs when owner is added")
    func agentColorDiffersWithOwner() {
        let noOwner = Port42Theme.agentColor(for: "Echo")
        let withOwner = Port42Theme.agentColor(for: "Echo", owner: "Gordon")
        #expect(noOwner != withOwner, "Echo and Echo·Gordon should hash to different colors")
    }

    @Test("Agent color differs between different owners")
    func agentColorDifferentOwners() {
        let gordon = Port42Theme.agentColor(for: "Echo", owner: "Gordon")
        let alice = Port42Theme.agentColor(for: "Echo", owner: "Alice")
        #expect(gordon != alice, "Echo·Gordon and Echo·Alice should hash to different colors")
    }

    @Test("Agent color nil owner matches no-owner call")
    func agentColorNilOwner() {
        let withNil = Port42Theme.agentColor(for: "Echo", owner: nil)
        let noParam = Port42Theme.agentColor(for: "Echo")
        #expect(withNil == noParam)
    }

    // MARK: - SyncPayload Encoding

    @Test("SyncPayload encodes and decodes senderOwner")
    func syncPayloadRoundTrip() throws {
        let payload = SyncPayload(
            senderName: "Echo", senderType: "agent",
            content: "hello", replyToId: nil,
            senderOwner: "Gordon"
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SyncPayload.self, from: data)
        #expect(decoded.senderOwner == "Gordon")
        #expect(decoded.senderName == "Echo")
    }

    @Test("SyncPayload without senderOwner decodes as nil")
    func syncPayloadNoOwner() throws {
        let payload = SyncPayload(
            senderName: "Alice", senderType: "human",
            content: "hey", replyToId: nil
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SyncPayload.self, from: data)
        #expect(decoded.senderOwner == nil)
    }

    @Test("SyncPayload backward compatible with old clients")
    func syncPayloadBackwardCompat() throws {
        // Old client payload without senderOwner field
        let json = """
        {"senderName":"Echo","senderType":"agent","content":"hello","replyToId":null}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SyncPayload.self, from: data)
        #expect(decoded.senderOwner == nil)
        #expect(decoded.senderName == "Echo")
    }

    // MARK: - SyncEnvelope Round-Trip

    @Test("SyncEnvelope preserves senderOwner through encoding")
    func syncEnvelopeRoundTrip() throws {
        let payload = SyncPayload(
            senderName: "Echo", senderType: "agent",
            content: "test", replyToId: nil,
            encrypted: false, senderOwner: "Gordon"
        )
        let envelope = SyncEnvelope(
            type: "message", channelId: "ch1",
            senderId: "user1", messageId: "m1",
            payload: payload,
            timestamp: 1710000000000
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(SyncEnvelope.self, from: data)
        #expect(decoded.payload?.senderOwner == "Gordon")
        #expect(decoded.type == "message")
        #expect(decoded.channelId == "ch1")
    }

    // MARK: - Database Persistence

    @Test("senderOwner persisted and retrieved from DB")
    func senderOwnerInDB() throws {
        let db = try DatabaseService(inMemory: true)

        let user = AppUser.createLocal(displayName: "Gordon")
        try db.saveUser(user)

        let channel = Channel.create(name: "general")
        try db.saveChannel(channel)

        let msg = Message(
            id: "m1", channelId: channel.id, senderId: "agent1",
            senderName: "Echo", senderType: "agent",
            content: "hello", timestamp: Date(),
            replyToId: nil, syncStatus: "local",
            createdAt: Date(), senderOwner: "Gordon"
        )
        try db.saveMessage(msg)

        let messages = try db.getMessages(channelId: channel.id)
        #expect(messages.count == 1)
        #expect(messages[0].senderOwner == "Gordon")
    }

    @Test("Nil senderOwner persisted correctly in DB")
    func nilSenderOwnerInDB() throws {
        let db = try DatabaseService(inMemory: true)

        let user = AppUser.createLocal(displayName: "Alice")
        try db.saveUser(user)

        let channel = Channel.create(name: "general")
        try db.saveChannel(channel)

        let msg = Message.create(
            channelId: channel.id, senderId: user.id,
            senderName: "Alice", content: "hey"
        )
        try db.saveMessage(msg)

        let messages = try db.getMessages(channelId: channel.id)
        #expect(messages.count == 1)
        #expect(messages[0].senderOwner == nil)
    }
}
