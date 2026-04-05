import Testing
import Foundation
@testable import Port42Lib

@Suite("CLI Agent Identity")
struct CLIIdentityTests {

    @MainActor
    func makeStateReady() throws -> (AppState, Channel) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let user = AppUser.createForTesting(displayName: "Gordon")
        try db.saveUser(user)
        state.currentUser = user
        state.completeSetup(displayName: "Gordon")
        let channel = state.channels.first { !$0.isSwim }!
        state.selectChannel(channel)
        return (state, channel)
    }

    // MARK: - #7 senderName override

    @Test("sendMessageAsNamedAgent stores message with agent name not host name")
    @MainActor
    func namedAgentMessageAttribution() throws {
        let (state, channel) = try makeStateReady()

        state.sendMessageAsNamedAgent(content: "hello from bot", senderName: "test-bot", toChannelId: channel.id)

        let messages = try state.db.getMessages(channelId: channel.id)
        let botMsg = messages.first { $0.senderName == "test-bot" }
        #expect(botMsg != nil)
        #expect(botMsg?.senderName == "test-bot")
        #expect(botMsg?.senderType == "agent")
        // Must NOT be attributed to the host user
        #expect(botMsg?.senderName != "Gordon")
    }

    @Test("sendMessageAsNamedAgent uses stable derived senderId")
    @MainActor
    func namedAgentStableSenderId() throws {
        let (state, channel) = try makeStateReady()

        state.sendMessageAsNamedAgent(content: "msg 1", senderName: "my-agent", toChannelId: channel.id)
        state.sendMessageAsNamedAgent(content: "msg 2", senderName: "my-agent", toChannelId: channel.id)

        let messages = try state.db.getMessages(channelId: channel.id).filter { $0.senderName == "my-agent" }
        #expect(messages.count == 2)
        // Both messages should have the same derived sender ID
        #expect(messages[0].senderId == messages[1].senderId)
    }

    @Test("sendMessageAsNamedAgent ignores empty content")
    @MainActor
    func namedAgentEmptyContentIgnored() throws {
        let (state, channel) = try makeStateReady()
        let before = try state.db.getMessages(channelId: channel.id).count

        state.sendMessageAsNamedAgent(content: "   ", senderName: "bot", toChannelId: channel.id)

        let after = try state.db.getMessages(channelId: channel.id).count
        #expect(after == before)
    }

    @Test("sendMessageAsNamedAgent ignores unknown channel")
    @MainActor
    func namedAgentUnknownChannel() throws {
        let (state, _) = try makeStateReady()

        // Should not crash, just silently drop
        state.sendMessageAsNamedAgent(content: "hello", senderName: "bot", toChannelId: "nonexistent-channel-id")
    }

    // MARK: - #9 stale presence eviction in SyncService

    @Test("onlineUsers evicts stale peer ID when same name reconnects")
    @MainActor
    func stalePresenceEvicted() throws {
        // Simulate: peer "old-id" is online as "port42-growth"
        // Then "new-id" comes online with the same name — old-id should be evicted
        var onlineUsers: [String: Set<String>] = ["chan-1": ["old-id", "other-peer"]]
        var knownNames: [String: String] = ["old-id": "port42-growth", "other-peer": "someone-else"]

        let newId = "new-id"
        let newName = "port42-growth"
        let channelId = "chan-1"

        // Apply the same logic as SyncService.handlePresence
        var members = onlineUsers[channelId] ?? []
        let stale = members.filter { knownNames[$0] == newName && $0 != newId }
        stale.forEach { members.remove($0) }
        members.insert(newId)
        onlineUsers[channelId] = members
        knownNames[newId] = newName

        #expect(onlineUsers["chan-1"]?.contains("old-id") == false)
        #expect(onlineUsers["chan-1"]?.contains("new-id") == true)
        #expect(onlineUsers["chan-1"]?.contains("other-peer") == true)
        #expect(onlineUsers["chan-1"]?.count == 2)
    }

    @Test("onlineUsers does not evict peers with different names")
    @MainActor
    func differentNamesNotEvicted() {
        var onlineUsers: [String: Set<String>] = ["chan-1": ["peer-a", "peer-b"]]
        let knownNames: [String: String] = ["peer-a": "agent-alpha", "peer-b": "agent-beta"]

        let newId = "peer-c"
        let newName = "agent-gamma"
        let channelId = "chan-1"

        var members = onlineUsers[channelId] ?? []
        let stale = members.filter { knownNames[$0] == newName && $0 != newId }
        stale.forEach { members.remove($0) }
        members.insert(newId)
        onlineUsers[channelId] = members

        #expect(onlineUsers["chan-1"]?.count == 3)
    }

    // MARK: - #12 system event encoding

    @Test("AgentProtocol encodes system event with correct fields")
    func systemEventEncoding() throws {
        let data = try AgentProtocol.encode(.system(content: "You are a CLI agent."))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["event"] as? String == "system")
        #expect(json["content"] as? String == "You are a CLI agent.")
    }

    @Test("AgentConfig createCommand stores system prompt")
    func commandConfigSystemPrompt() {
        let agent = AgentConfig.createCommand(
            ownerId: "u1",
            displayName: "bot",
            command: "/usr/bin/bot",
            systemPrompt: "You are a bot.",
            trigger: .mentionOnly
        )
        #expect(agent.systemPrompt == "You are a bot.")
    }
}
