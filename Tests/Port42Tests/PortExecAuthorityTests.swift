import Testing
import Foundation
@testable import Port42Lib

/// **port.exec is judged like a code write** (APP-05).
///
/// `port.exec` runs the caller's JS inside the target port, and that JS calls the bridge as the
/// port's principal with the port's grants. A zero-grant caller could therefore borrow `.terminal`
/// from any port that held it. The refusal happens before the webview is reached, so these tests
/// assert on the gate alone: a refused call answers `permission_denied`, and a permitted one answers
/// anything else (it runs, or stops later at the webview, which a headless world may not have).
@Suite("port.exec needs the port's code authority (APP-05)")
@MainActor
struct PortExecAuthorityTests {

    func exec(_ w: ParityWorld, as p: Principal, _ id: String) async -> String? {
        do {
            let m = try #require(w.registry["port.exec"])
            _ = try await m.run(p, BridgeArgs(["id": id, "js": "1"]))
            return nil
        } catch let e as BridgeError {
            return e.code
        } catch {
            return "\(error)"
        }
    }

    /// A port the world's companion made, running with `grants` through that companion.
    func privilegedPort(_ w: ParityWorld, grants: Set<PortPermission>) throws -> String {
        w.state.saveGrants(grants, grantee: w.companion.id, on: .machine, zone: w.space.id)
        let created = w.state.createPort(
            type: "web", title: "Tool", html: "<div>tool</div>", command: nil, cwd: nil,
            systemPrompt: nil, spaceId: w.space.id, createdBy: w.companion.id,
            createdByName: w.companion.displayName, presentation: "tiled")
        return try #require(created["id"] as? String)
    }

    func expectPermitted(_ code: String?, _ who: String) {
        #expect(code != BridgeErrorCode.permissionDenied.wire, "\(who) was refused: \(code ?? "ok")")
    }

    func mallory(_ w: ParityWorld, grants: Set<PortPermission> = []) -> Principal {
        if !grants.isEmpty { w.state.saveGrants(grants, grantee: "mallory", on: .machine, zone: w.space.id) }
        return Principal.companion(id: "mallory", displayName: "mallory", spaceId: w.space.id)
    }

    @Test("a zero-grant caller cannot run code in a port that holds .terminal")
    func zeroGrantRefused() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.terminal])
        #expect(await exec(w, as: mallory(w), id) == BridgeErrorCode.permissionDenied.wire)
    }

    @Test("the port's author still runs code in it")
    func authorAllowed() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.terminal])
        expectPermitted(await exec(w, as: w.principal, id), "the author")
    }

    @Test("the person still runs code in any port")
    func humanAllowed() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.terminal])
        let me = Principal.human(id: "u1", displayName: "Alice", spaceId: w.space.id)
        expectPermitted(await exec(w, as: me, id), "the person")
    }

    @Test("a caller already holding every grant gains nothing, so it may run code")
    func supersetAllowed() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.terminal])
        expectPermitted(await exec(w, as: mallory(w, grants: [.terminal]), id), "a superset holder")
    }

    @Test("a port holding nothing stays open to anyone who can see it")
    func unprivilegedPortOpen() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [])
        expectPermitted(await exec(w, as: mallory(w), id), "a caller at an unprivileged port")
    }

    // MARK: - The space rule (APP-07, GM 2026-09-28)

    /// A registered companion, acting in `spaceId`.
    func companion(_ w: ParityWorld, _ name: String, in spaceId: String) throws -> Principal {
        let a = AgentConfig.createCommand(ownerId: w.state.currentUser!.id, displayName: name,
                                          command: "claude", systemPrompt: nil, trigger: .mentionOnly)
        try w.state.db.saveAgent(a)
        w.state.companions.append(a)
        return Principal.companion(id: a.id, displayName: a.displayName, spaceId: spaceId)
    }

    @Test("a companion in the port's own space may run code in it, as it may edit it")
    func sameSpaceCompanionAllowed() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.terminal])
        let teammate = try companion(w, "teammate", in: w.space.id)
        expectPermitted(await exec(w, as: teammate, id), "a companion in the port's space")
    }

    @Test("a companion in another space may not run code in a port that holds a grant")
    func otherSpaceCompanionRefused() async throws {
        let w = try makeParityWorld()
        let id = try privilegedPort(w, grants: [.terminal])
        let outsider = try companion(w, "elsewhere", in: "another-space")
        #expect(await exec(w, as: outsider, id) == BridgeErrorCode.permissionDenied.wire)
    }
}
