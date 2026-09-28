import Testing
import Foundation
@testable import Port42Lib

/// **The CAS token is not an access control** (APP-21).
///
/// `ports.list` hands every visible port's token to the caller, and `stale_write` / `token_required`
/// carry the current one back, by design: the token says "you composed against current state", not
/// who you are. Authorization is the write-scope check and the permission gate, which run before any
/// token logic, so holding a port's real, current token must open nothing.
@Suite("The CAS token is not an access control (APP-21)")
@MainActor
struct PortTokenIsNotAuthTests {

    func makePort(_ w: ParityWorld, title: String, spaceId: String) throws -> String {
        let created = w.state.createPort(
            type: "web", title: title, html: "<title>\(title)</title>", command: nil,
            cwd: nil, systemPrompt: nil, spaceId: spaceId, createdBy: w.companion.id,
            createdByName: w.companion.displayName, presentation: "tiled")
        return try #require(created["id"] as? String)
    }

    func code(_ w: ParityWorld, _ method: String, _ args: [String: Any]) async -> String? {
        do { _ = try await w.state.runBridgeMethod(method, principal: w.principal, args: BridgeArgs(args)); return nil }
        catch let e as BridgeError { return e.code }
        catch { return "unexpected" }
    }

    @Test("a VALID token does not open another space's port")
    func tokenIsNotAuthorization() async throws {
        let w = try makeParityWorld()
        let elsewhere = try #require(w.state.createSpace(name: "elsewhere", select: false))
        let away = try makePort(w, title: "away", spaceId: elsewhere.id)
        // The token an outsider could have learned (ports.list, a leaked refusal): the real, current one.
        let key = try #require(w.state.resolvePortRef(away)?.key)
        let token = w.state.portInput.token(for: key)

        #expect(await code(w, "port.manage", ["id": away, "action": "close", PortActivity.expectParam: token])
                == BridgeErrorCode.notFound.wire, "a valid token opened a port outside the caller's scope")
        #expect(w.state.portWindows.findPort(by: away) != nil, "the other space's port must still be open")
    }

    @Test("the same token in the right hands still passes CAS, so CAS itself is untouched")
    func tokenStillWorksInScope() async throws {
        let w = try makeParityWorld()
        let here = try makePort(w, title: "here", spaceId: w.space.id)
        let key = try #require(w.state.resolvePortRef(here)?.key)
        #expect(await code(w, "port.manage", ["id": here, "action": "focus",
                                             PortActivity.expectParam: w.state.portInput.token(for: key)]) == nil)
    }
}
