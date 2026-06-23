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

    @Test("New user has nil appleUserID")
    func newUserNoAppleID() {
        let user = AppUser.createForTesting(displayName: "Gordon")
        #expect(user.appleUserID == nil)
    }

    @Test("AppUser stores appleUserID")
    func userWithAppleID() {
        var user = AppUser.createForTesting(displayName: "Gordon")
        user.appleUserID = "001234.abcdef1234567890.1234"
        #expect(user.appleUserID == "001234.abcdef1234567890.1234")
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

    @Test("Create message")
    func createMessage() {
        let msg = Message.create(
            spaceId: "chan-1",
            senderId: "user-1",
            senderName: "Gordon",
            content: "hello world"
        )
        #expect(msg.content == "hello world")
        #expect(msg.senderName == "Gordon")
        #expect(msg.senderType == "human")
        #expect(msg.syncStatus == "local")
        #expect(msg.isAgent == false)
        #expect(msg.isSystem == false)
    }

    @Test("Agent message flags")
    func agentMessage() {
        let msg = Message.create(
            spaceId: "chan-1",
            senderId: "agent-1",
            senderName: "@ai-engineer",
            content: "analyzing...",
            senderType: "agent"
        )
        #expect(msg.isAgent == true)
        #expect(msg.isSystem == false)
    }

    @Test("System message flags")
    func systemMessage() {
        let msg = Message.create(
            spaceId: "chan-1",
            senderId: "system",
            senderName: "Port42",
            content: "Welcome",
            senderType: "system"
        )
        #expect(msg.isSystem == true)
        #expect(msg.isAgent == false)
    }

    @Test("Message formatted time is not empty")
    func formattedTime() {
        let msg = Message.create(
            spaceId: "c", senderId: "u", senderName: "X", content: "test"
        )
        #expect(!msg.formattedTime.isEmpty)
    }

    @Test("Two messages get unique IDs")
    func uniqueMessageIds() {
        let a = Message.create(spaceId: "c", senderId: "u", senderName: "X", content: "one")
        let b = Message.create(spaceId: "c", senderId: "u", senderName: "X", content: "two")
        #expect(a.id != b.id)
    }
}
