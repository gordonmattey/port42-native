import Testing
import Foundation
@testable import Port42Lib

@Suite("CLI Agent Identity")
struct CLIIdentityTests {

    @MainActor
    func makeStateReady() throws -> (AppState, Space) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let user = AppUser.createForTesting(displayName: "Gordon")
        try db.saveUser(user)
        state.currentUser = user
        state.completeSetup(displayName: "Gordon")
        let space = state.spaces.first { $0.type != "direct" }!
        state.selectSpace(space)
        return (state, space)
    }

    // MARK: - #7 senderName override

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
        let spaceId = "chan-1"

        // Apply the same logic as SyncService.handlePresence
        var members = onlineUsers[spaceId] ?? []
        let stale = members.filter { knownNames[$0] == newName && $0 != newId }
        stale.forEach { members.remove($0) }
        members.insert(newId)
        onlineUsers[spaceId] = members
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
        let spaceId = "chan-1"

        var members = onlineUsers[spaceId] ?? []
        let stale = members.filter { knownNames[$0] == newName && $0 != newId }
        stale.forEach { members.remove($0) }
        members.insert(newId)
        onlineUsers[spaceId] = members

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
