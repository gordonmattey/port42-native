import Testing
import Foundation
@testable import Port42Lib

/// **A caller reads the chats of the space it acts in** (APP-09).
///
/// `chat.read` took any chat by id: the desktop's, any space's, any port's. So a port's JS or a
/// companion in one space read every conversation on the machine. It now follows the APP-10 rule,
/// and a chat outside the caller's scope is `not_found`, the same as one that does not exist.
@Suite("Chat read scope (APP-09)")
@MainActor
struct ChatReadScopeTests {

    func makePort(_ w: ParityWorld, spaceId: String) throws -> String {
        let created = w.state.createPort(
            type: "web", title: "p-\(spaceId)", html: "<title>p</title>", command: nil, cwd: nil,
            systemPrompt: nil, spaceId: spaceId, createdBy: w.companion.id,
            createdByName: w.companion.displayName, presentation: "tiled")
        return try #require(created["id"] as? String)
    }

    func read(_ w: ParityWorld, _ chat: String, as p: Principal) async -> String? {
        do { _ = try await w.state.runBridgeMethod("chat.read", principal: p, args: BridgeArgs(["port": chat])); return nil }
        catch let e as BridgeError { return e.code }
        catch { return "unexpected" }
    }

    func human(_ w: ParityWorld) -> Principal {
        Principal.human(id: "person", displayName: "person", spaceId: nil)
    }

    @Test("a companion reads its own space's chat and its ports' chats")
    func ownSpaceReadable() async throws {
        let w = try makeParityWorld()
        let here = try makePort(w, spaceId: w.space.id)
        _ = try w.state.postToChat(key: w.space.id, text: "hi", from: human(w))
        #expect(await read(w, w.space.id, as: w.principal) == nil)
        #expect(await read(w, here, as: w.principal) == nil)
    }

    @Test("another space's chat, its ports' chats and the desktop's chat are not_found")
    func otherChatsRefused() async throws {
        let w = try makeParityWorld()
        let other = try #require(w.state.createSpace(name: "elsewhere", select: false))
        let away = try makePort(w, spaceId: other.id)
        _ = try w.state.postToChat(key: other.id, text: "private", from: human(w))

        #expect(await read(w, other.id, as: w.principal) == BridgeErrorCode.notFound.wire)
        #expect(await read(w, away, as: w.principal) == BridgeErrorCode.notFound.wire)
        #expect(await read(w, PortChat.desktopKey, as: w.principal) == BridgeErrorCode.notFound.wire)
    }

    @Test("the person still reads every chat")
    func humanUnscoped() async throws {
        let w = try makeParityWorld()
        let other = try #require(w.state.createSpace(name: "elsewhere", select: false))
        #expect(await read(w, other.id, as: human(w)) == nil)
        #expect(await read(w, PortChat.desktopKey, as: human(w)) == nil)
    }
}
