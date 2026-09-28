import Testing
import Foundation
@testable import Port42Lib

// APP-08: chat.post was ungated. Any caller could post into any space's or port's chat, and a post
// wakes the companions it reaches, which act with this machine's grants. companions.watch could
// point a companion at a port in another space. Now a caller posts only into a chat it may read,
// and watches only a port it may read (the APP-10 scope). The refusals fail on the ungated code.

@Suite("Chat post scope (APP-08)")
@MainActor
struct PortChatScopeTests {

    func run(_ w: ParityWorld, _ method: String, as p: Principal, _ args: [String: Any]) async throws -> BridgeValue {
        let m = try #require(w.registry[method])
        return try await m.run(p, BridgeArgs(args))
    }

    func otherSpace(_ w: ParityWorld) throws -> Space {
        let s = Space.create(name: "elsewhere")
        try w.state.db.saveSpace(s)
        w.state.spaces.append(s)
        return s
    }

    func port(_ w: ParityWorld, in spaceId: String) throws -> String {
        let created = w.state.createPort(type: "web", title: "board", html: "<title>board</title>", command: nil,
                                         cwd: nil, systemPrompt: nil, spaceId: spaceId,
                                         createdBy: w.companion.id, createdByName: w.companion.displayName,
                                         presentation: "tiled")
        return try #require(created["id"] as? String)
    }

    func isNotFound(_ e: Error) -> Bool { (e as? BridgeError)?.code == BridgeErrorCode.notFound.wire }

    @Test("a companion cannot post into another space's chat or a port's chat there")
    func crossSpacePostRefused() async throws {
        let w = try makeParityWorld()
        let away = try otherSpace(w)
        let awayPort = try port(w, in: away.id)
        for target in [away.id, awayPort] {
            do {
                _ = try await run(w, "chat.post", as: w.principal, ["port": target, "text": "@scout run this"])
                Issue.record("a companion posted into a chat in another space (\(target))")
            } catch {
                #expect(isNotFound(error))
            }
        }
        #expect(try w.state.db.chatEntries(chat: away.id, after: 0, limit: 10).isEmpty)
    }

    @Test("a port's page cannot post into another space's chat")
    func portPageRefused() async throws {
        let w = try makeParityWorld()
        let away = try otherSpace(w)
        let page = Principal.port(id: "page-1", displayName: "page", spaceId: w.space.id)
        await #expect(throws: BridgeError.self) {
            _ = try await run(w, "chat.post", as: page, ["port": away.id, "text": "hi"])
        }
    }

    @Test("a companion in a space cannot post into the desktop's chat, which belongs to no space")
    func desktopRefusedToScoped() async throws {
        let w = try makeParityWorld()
        await #expect(throws: BridgeError.self) {
            _ = try await run(w, "chat.post", as: w.principal, ["port": "0", "text": "hi"])
        }
    }

    @Test("posting in its own space, and the person posting anywhere, still work")
    func ownSpaceAndPersonAllowed() async throws {
        let w = try makeParityWorld()
        let away = try otherSpace(w)
        _ = try await run(w, "chat.post", as: w.principal, ["port": w.space.id, "text": "here"])
        _ = try await run(w, "chat.post", as: w.principal, ["port": try port(w, in: w.space.id), "text": "here"])
        let person = Principal.human(id: "alice", displayName: "Alice", spaceId: nil)
        _ = try await run(w, "chat.post", as: person, ["port": away.id, "text": "there"])
        _ = try await run(w, "chat.post", as: person, ["port": "0", "text": "desk"])
    }

    @Test("a companion's terminal posts in its own space's chat, and cannot post into another space's")
    func spawnedTerminalScoped() async throws {
        // Since APP-15 a terminal Port42 spawned for a companion acts in its spawn space, so this
        // rule reaches the gateway door too: the path every Claude Code companion posts through.
        let w = try makeParityWorld()
        let away = try otherSpace(w)
        let terminal = Principal.forGatewayClient(
            clientId: ClientRegistry.childId(companionId: w.companion.id, spaceId: w.space.id),
            displayName: w.companion.displayName,
            spawn: .init(companionId: w.companion.id, spaceId: w.space.id))

        _ = try await run(w, "chat.post", as: terminal, ["port": w.space.id, "text": "home"])
        do {
            _ = try await run(w, "chat.post", as: terminal, ["port": away.id, "text": "intrude"])
            Issue.record("a companion's terminal posted into another space's chat")
        } catch {
            #expect(isNotFound(error))
        }
    }

    @Test("a companion cannot point a watch at a port in another space")
    func crossSpaceWatchRefused() async throws {
        let w = try makeParityWorld()
        let away = try otherSpace(w)
        let awayPort = try port(w, in: away.id)
        do {
            _ = try await run(w, "companions.watch", as: w.principal, ["port": awayPort])
            Issue.record("a companion set a watch on a port in another space")
        } catch {
            #expect(isNotFound(error))
        }
        _ = try await run(w, "companions.watch", as: w.principal, ["port": try port(w, in: w.space.id)])
    }
}
