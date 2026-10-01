import Testing
import Foundation
@testable import Port42Lib

/// **Every ungated bridge method names what guards it** (APP-01).
///
/// The audit counted 57 of 89 methods declaring `permission: nil`. A nil permission is right for a
/// verb whose risk is WHICH object it touches rather than which machine capability it uses, but only
/// if a target check stands in for the permission. This pins every ungated method to the check that
/// covers it, or to the open ticket that will, so a new ungated verb fails here until someone decides
/// what guards it, and a ticket that lands must update its row.
@Suite("Ungated verbs name their guard (APP-01)")
@MainActor
struct BridgeTargetScopeTests {

    static let covered: [String: String] = [
        // Terminal targets need .terminal (APP-03, APP-04); code needs the port's authority (APP-05, APP-07).
        "port.push": "terminal target (APP-03); write scope (APP-11)",
        "port.subscribe": "terminal target (APP-04); read scope OPEN: APP-10",
        "port.exec": "code authority (APP-05)",
        // Browser use: read scope, and a card per companion and site before it sees or acts (#177).
        "port.look": "read scope; site grant per companion (#177)",
        "port.act": "read scope and write token; site grant per companion (#177)",
        "port.update": "code authority (APP-07)", "port.patch": "code authority (APP-07)",
        "port.restore": "code authority (APP-07)",
        "port.create": "gated on its type: terminal and browser ask for the capability",
        // A port acting on itself only.
        "port.close": "own port", "port.setTitle": "own port", "port.setCapabilities": "own port",
        "port.info": "own port", "port.publish": "own port's topic", "presentation": "own port",
        // Sharing and spaces (APP-01, NAU-03).
        "invite.create": "share card for any caller but the person (NAU-03)",
        "invite.accept": "share card for any caller but the person (NAU-03)",
        "invite.list": "the port's authority or the invite's maker (APP-01)",
        "invite.revoke": "the port's authority or the invite's maker (APP-01)",
        "space.delete": "read scope, and a card every time for anyone but the person (APP-11)",
        "companions.remove": "write scope: only a space the caller acts in (APP-11 rule, #131)",
        "companions.update": "a companion edits itself freely; editing another asks the person every time (API parity, Phase A)",
        "companions.delete": "the person, or a card every time naming the companion, never kept (API parity, Phase A)",
        "space.create": "creates only", "space.list": "space names",
        "space.switchTo": "moves the person's view only",
        "space.update": "read scope: only a space the caller acts in; reversible (API parity, Phase C)",
        "space.rest": "read scope: only a space the caller acts in; reversible (API parity, Phase C)",
        "space.wake": "read scope: only a space the caller acts in; reversible (API parity, Phase C)",
        "space.reorder": "read scope: only a space the caller acts in; reversible (API parity, Phase C)",
        // Open, each with the ticket that closes it.
        "ports.list": "OPEN: APP-10", "port.getHtml": "OPEN: APP-10", "port.getDom": "OPEN: APP-10",
        "port.history": "OPEN: APP-10", "port.console": "OPEN: APP-10", "port.position": "OPEN: APP-10",
        "space.current": "OPEN: APP-10",
        "port.rename": "write scope (APP-11)", "port.move": "write scope (APP-11)",
        "port.manage": "write scope (APP-11)",
        "port.fork": "read scope on the source, and on the space it lands in (API parity, Phase D)",
        "port.reopen": "OPEN: NAU-05", "port.delete": "OPEN: NAU-05",
        "chat.read": "OPEN: APP-09", "presence.list": "OPEN: APP-09 (a chat's presence, by key)", "chat.post": "OPEN: APP-08",
        "companions.watch": "OPEN: APP-08", "companions.unwatch": "OPEN: APP-08",
        "companions.watches": "OPEN: APP-08",
        "imagine.budget": "OPEN: any space's budget, reported with APP-01",
        // Not about any target object.
        "help": "static reference", "whoami": "the caller's own identity",
        "user.get": "the person's display name",
        "companions.list": "companion roster", "companions.get": "companion roster",
        "screen.displays": "display geometry", "screen.record.status": "status only",
        "audio.speak": "output only", "audio.play": "output only", "audio.stop": "stop only",
        "camera.stopStream": "stop only", "screen.stopStream": "stop only",
        "screen.record.stop": "stop only",
        // Files: picking is the consent (APP-19). The native panel is shown only to the person, who
        // chooses exactly the files or cancels; while locked the pick is refused as `locked` (APP-16).
        "fs.pick": "the native panel is the consent, shown only to the person; refused while locked (APP-19, APP-16)",
        // Storage: the caller's own space and bucket; global and shared are a public board (APP-20).
        "state.get": "canRead on the named port, else the caller's own",
        "state.set": "maySetState: the port, its author, the person or a companion in its space",
        "storage.get": "caller-scoped bucket", "storage.set": "caller-scoped bucket",
        "storage.delete": "caller-scoped bucket", "storage.list": "caller-scoped bucket",
    ]

    @Test("every permission: nil method is classified, and nothing classified is stale")
    func everyUngatedMethodIsClassified() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let oneShot = appState.bridgeRegistry.filter { $0.value.permission == nil }.keys
        let streams = buildBridgeStreamRegistry(appState).filter { $0.value.permission == nil }.keys
        let ungated = Set(oneShot).union(streams)
        let unclassified = ungated.subtracting(Self.covered.keys).sorted()
        let stale = Set(Self.covered.keys).subtracting(ungated).sorted()
        #expect(unclassified.isEmpty, "ungated with no stated guard: \(unclassified)")
        #expect(stale.isEmpty, "classified but no longer ungated, update the table: \(stale)")
    }

    // MARK: - The verbs this ticket closed

    func code(_ body: () async throws -> BridgeValue) async -> String? {
        do { _ = try await body(); return nil }
        catch let e as BridgeError { return e.code }
        catch { return "\(error)" }
    }

    func call(_ w: ParityWorld, _ method: String, as p: Principal,
              _ args: [String: Any]) async throws -> BridgeValue {
        try await #require(w.registry[method]).run(p, BridgeArgs(args))
    }

    /// An invite on a port the world's companion made, made by that companion. Inserted as a row:
    /// minting a link needs the gateway's peer id, which a headless world does not have.
    func invite(_ w: ParityWorld) throws -> String {
        let created = w.state.createPort(
            type: "web", title: "Shared", html: "<div>x</div>", command: nil, cwd: nil,
            systemPrompt: nil, spaceId: w.space.id, createdBy: w.companion.id,
            createdByName: w.companion.displayName, presentation: "tiled")
        let port = try #require(created["id"] as? String)
        let key = w.state.resolvePortRef(port)?.key ?? port
        let id = "inv-\(UUID().uuidString)"
        try w.state.db.insertInvite(id: id, portKey: key, rights: [.see], nonceHash: "n",
                                    codeHash: nil, createdBy: w.principal.id,
                                    expiresAt: Date().addingTimeInterval(3600))
        return id
    }

    func mallory(_ w: ParityWorld) -> Principal {
        Principal.companion(id: "mallory", displayName: "mallory", spaceId: w.space.id)
    }

    @Test("another caller neither sees nor withdraws someone else's invite")
    func invitesAreScoped() async throws {
        let w = try makeParityWorld()
        let id = try invite(w)

        let seen = try await call(w, "invite.list", as: mallory(w), [:])
        #expect(seen == .array([]), "another caller listed an invite it did not make")
        #expect(await code { try await call(w, "invite.revoke", as: mallory(w), ["id": id]) }
                == BridgeErrorCode.notFound.rawValue)
        let open = try #require(try w.state.db.allInvites().first { $0.id == id })
        #expect(open.revokedAt == nil, "another caller withdrew the share")
    }

    @Test("the invite's maker and the person still list and withdraw it")
    func makerAndPersonStillManage() async throws {
        let w = try makeParityWorld()
        let id = try invite(w)
        if case .array(let rows) = try await call(w, "invite.list", as: w.principal, [:]) {
            #expect(rows.count == 1)
        } else { Issue.record("expected an array") }
        let me = Principal.human(id: "u1", displayName: "Alice", spaceId: w.space.id)
        if case .array(let rows) = try await call(w, "invite.list", as: me, [:]) {
            #expect(rows.count == 1)
        } else { Issue.record("expected an array") }
        #expect(await code { try await call(w, "invite.revoke", as: w.principal, ["id": id]) } == nil)
    }

}
