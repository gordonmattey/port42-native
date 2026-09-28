import Testing
import Foundation
@testable import Port42Lib

/// **A caller changes only ports and spaces it acts in** (APP-11).
///
/// With no grant at all, a port's JS or a companion could close, reopen and permanently delete any
/// port, delete a whole space, and redirect where every companion in a space spawns. A refused write
/// also answered `token_required` with the port's current token, confirming it existed.
@Suite("Port write scope (APP-11)", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct PortWriteScopeTests {

    func makePort(_ w: ParityWorld, title: String, spaceId: String) throws -> String {
        let created = w.state.createPort(
            type: "web", title: title, html: "<title>\(title)</title>", command: nil,
            cwd: nil, systemPrompt: nil, spaceId: spaceId, createdBy: w.companion.id,
            createdByName: w.companion.displayName, presentation: "tiled")
        return try #require(created["id"] as? String)
    }

    func code(_ w: ParityWorld, _ method: String, _ args: [String: Any],
              as caller: Principal? = nil) async -> String? {
        do { _ = try await w.state.runBridgeMethod(method, principal: caller ?? w.principal, args: BridgeArgs(args)); return nil }
        catch let e as BridgeError { return e.code }
        catch { return "unexpected" }
    }

    func otherSpace(_ w: ParityWorld) throws -> Space {
        try #require(w.state.createSpace(name: "elsewhere", select: false))
    }

    @Test("port.manage on another space's port is not_found, before any token check")
    func manageOtherSpaceRefused() async throws {
        let w = try makeParityWorld()
        let here = try makePort(w, title: "here", spaceId: w.space.id)
        let away = try makePort(w, title: "away", spaceId: try otherSpace(w).id)

        #expect(await code(w, "port.manage", ["id": here, "action": "close"]) == BridgeErrorCode.tokenRequired.wire,
                "in scope, the write seam is reached and asks for its token")
        #expect(await code(w, "port.manage", ["id": away, "action": "close"]) == BridgeErrorCode.notFound.wire)
        #expect(w.state.portWindows.findPort(by: away) != nil)
    }

    @Test("port.manage by TITLE cannot reach another space's port either")
    func manageByTitleRefused() async throws {
        let w = try makeParityWorld()
        let away = try makePort(w, title: "away-titled", spaceId: try otherSpace(w).id)
        let method = try #require(w.registry["port.manage"])
        do {
            _ = try await method.run(w.principal, BridgeArgs(["id": "away-titled", "action": "close"]))
            Issue.record("a title reached another space's port")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.notFound.wire)
        }
        #expect(w.state.portWindows.findPort(by: away) != nil)
    }

    @Test("port.delete and port.reopen refuse another space's closed port")
    func deleteAndReopenScoped() async throws {
        let w = try makeParityWorld()
        let away = try makePort(w, title: "away", spaceId: try otherSpace(w).id)
        let panelId = try #require(w.state.portWindows.findPort(by: away)?.id)
        w.state.portWindows.close(panelId)

        #expect(await code(w, "port.delete", ["id": away]) == BridgeErrorCode.notFound.wire)
        #expect(await code(w, "port.reopen", ["id": away]) == BridgeErrorCode.notFound.wire)
        #expect(w.state.portWindows.closedPortId(away) != nil, "the closed port must still exist")
    }

    @Test("space.delete: another space is not_found; its own space asks the person every time")
    func spaceDeleteNeedsThePerson() async throws {
        let w = try makeParityWorld()
        let other = try otherSpace(w)
        #expect(await code(w, "space.delete", ["space_id": other.id]) == BridgeErrorCode.notFound.wire)
        #expect(w.state.spaces.contains { $0.id == other.id })

        // Its own space: a card, and a no leaves the space.
        let target = w.space.id
        let principal = w.principal
        final class Done { var value = false }
        let done = Done()
        let refused = Task { @MainActor in
            let c = await self.code(w, "space.delete", ["space_id": target], as: principal)
            done.value = true
            return c
        }
        // A card, or the call finishing without one (the unfixed code deletes at once). Never a hang.
        while w.state.permissions.current == nil && !done.value { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(w.state.permissions.current?.permission == .deleteSpace, "the person must be asked")
        #expect(w.state.permissions.current?.detail?.contains(w.space.name) == true)
        if w.state.permissions.current != nil { w.state.permissions.resolveCurrent(granted: false) }
        #expect(await refused.value == BridgeErrorCode.permissionDenied.wire)
        #expect(w.state.spaces.contains { $0.id == target })
    }

    @Test("setWorkingDirectory needs .filesystem and a space the caller acts in")
    func workingDirectoryGated() async throws {
        let w = try makeParityWorld()
        let other = try otherSpace(w)
        #expect(w.state.bridgeRegistry["space.setWorkingDirectory"]?.permission == .filesystem)
        #expect(w.state.setSpaceWorkingDirectory("/tmp", spaceId: other.id))
        let method = try #require(w.registry["space.setWorkingDirectory"])
        do {
            _ = try await method.run(w.principal, BridgeArgs(["space_id": other.id, "path": "/"]))
            Issue.record("a caller in another space redirected this one")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.notFound.wire)
        }
        #expect(w.state.spaces.first { $0.id == other.id }?.workingDirectory == "/tmp")
    }
}
