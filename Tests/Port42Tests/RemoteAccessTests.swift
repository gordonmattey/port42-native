import Testing
import Foundation
@testable import Port42Lib

/// Nautilus Phase 4, step 4.1: a caller on another machine reaches only the ports it holds rights on,
/// within those rights, and nothing of the machine. Headless: a remote principal is built directly,
/// with no wire, so the gate is proven before any transport exists.
@Suite("Remote access (Phase 4, 4.1)")
@MainActor
struct RemoteAccessTests {

    struct World {
        let state: AppState
        let p: String      // a port the guest is granted
        let q: String      // a port it is not
        let pTitle: String
    }

    func makeWorld() throws -> World {
        let state = AppState(db: try DatabaseService(inMemory: true))
        _ = state.portWindows.registerTiledPort(id: "remote-p", html: "<html><body>p</body></html>",
                                                spaceId: nil, createdBy: nil, title: "shared chart", position: nil)
        _ = state.portWindows.registerTiledPort(id: "remote-q", html: "<html><body>q</body></html>",
                                                spaceId: nil, createdBy: nil, title: "private notes", position: nil)
        let p = try #require(state.portWindows.panels.first { $0.id == "remote-p" }?.udid)
        let q = try #require(state.portWindows.panels.first { $0.id == "remote-q" }?.udid)
        return World(state: state, p: p, q: q, pTitle: "shared chart")
    }

    let guest = Principal.remote(peer: "peer-guest-key", displayName: "Ada")

    func call(_ w: World, _ method: String, _ args: [String: Any],
              as who: Principal? = nil, pregrant: Set<PortPermission> = []) async throws -> BridgeValue {
        try await w.state.runBridgeMethod(method, principal: who ?? guest, args: BridgeArgs(args),
                                          pregrant: pregrant)
    }

    /// The call is refused with `not_granted`, and nothing else.
    func refused(_ w: World, _ method: String, _ args: [String: Any],
                 pregrant: Set<PortPermission> = [], _ why: Comment) async {
        do {
            _ = try await call(w, method, args, pregrant: pregrant)
            Issue.record(why)
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.notGranted.wire, "\(method): \(e.code) \(e.message)")
        } catch {
            Issue.record("\(method) threw \(error), not a BridgeError")
        }
    }

    func token(_ w: World, _ key: String) -> String { w.state.portInput.token(for: key) }

    // MARK: - The table

    @Test("every registry method is classified, and the table names no method that does not exist")
    func everyMethodClassified() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let methods = Set(state.bridgeRegistry.keys).union(state.bridgeStreamRegistry.keys)
        let classified = Set(RemoteAccess.table.keys)
        #expect(methods.subtracting(classified).isEmpty, """
            Unclassified: \(methods.subtracting(classified).sorted()). A new method must be put in \
            RemoteAccess.table, as reachable from another machine or not, before it ships.
            """)
        #expect(classified.subtracting(methods).isEmpty,
                "The table names methods that do not exist: \(classified.subtracting(methods).sorted())")
    }

    @Test("a remotely reachable method names an argument it really takes, and none needs a permission")
    func reachableMethodsAreSound() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        for (name, reach) in RemoteAccess.table {
            let one = state.bridgeRegistry[name]
            let stream = state.bridgeStreamRegistry[name]
            let permission = one?.permission ?? stream?.permission
            let declared = one?.declaredArgs ?? stream?.declaredArgs ?? []
            switch reach {
            case .never:
                continue
            case .listing:
                #expect(permission == nil, "\(name) is reachable remotely and would raise a card")
            case .port(let param, _):
                #expect(permission == nil, "\(name) is reachable remotely and would raise a card")
                #expect(declared.contains(param), "\(name) is gated on '\(param)', which it does not take")
            }
        }
        #expect(RemoteAccess.reach("port.exec") == .never, "port.exec borrows the target port's grants")
        #expect(RemoteAccess.reach("no.such.method") == .never, "absent must mean never")
    }

    // MARK: - Rights on one port

    @Test("with `see` a guest reads and lists its port, and is refused writes, exec, and every other port")
    func seeRight() async throws {
        let w = try makeWorld()
        w.state.grantRemoteRights([.see], to: guest.id, onPort: w.p)

        let html = try await call(w, "port.getHtml", ["id": w.p])
        #expect(html.toJSONObject() as? String != nil || (html.toJSONObject() as? [String: Any]) != nil)

        await refused(w, "port.getHtml", ["id": w.q], "read a port it holds no right on")
        await refused(w, "port.rename", ["id": w.p, "title": "x", PortActivity.expectParam: token(w, w.p)],
                      "edited with only `see`")
        await refused(w, "chat.post", ["port": w.p, "text": "hi"], "posted with only `see`")
        await refused(w, "port.exec", ["id": w.p, "js": "1"], "ran JS in the host's page")
    }

    @Test("a guest lists only its granted ports, and nothing about where they sit here")
    func listingIsFiltered() async throws {
        let w = try makeWorld()
        w.state.grantRemoteRights([.see], to: guest.id, onPort: w.p)
        let rows = try #require(try await call(w, "ports.list", [:]).toJSONObject() as? [[String: Any]])
        #expect(rows.map { $0["id"] as? String } == [w.p], "listed \(rows.map { $0["id"] ?? "?" })")
        let row = try #require(rows.first)
        for hidden in ["spaceId", "createdBy", "createdByName", "cwd", "x", "y"] {
            #expect(row[hidden] == nil, "a remote listing revealed \(hidden)")
        }
        #expect(row["token"] != nil, "a guest needs the token to write with CAS")

        // A local caller is unchanged: it still sees both.
        let local = Principal.peer(id: "local-client", displayName: "cli")
        let all = try #require(try await call(w, "ports.list", [:], as: local).toJSONObject() as? [[String: Any]])
        #expect(Set(all.compactMap { $0["id"] as? String }).isSuperset(of: [w.p, w.q]))
    }

    @Test("`use` allows chat on the port; `edit` is needed to change it")
    func useAndEdit() async throws {
        let w = try makeWorld()
        w.state.grantRemoteRights([.see, .use], to: guest.id, onPort: w.p)
        _ = try await call(w, "chat.post", ["port": w.p, "text": "hello from elsewhere"])
        await refused(w, "port.rename", ["id": w.p, "title": "mine now", PortActivity.expectParam: token(w, w.p)],
                      "renamed without `edit`")

        w.state.grantRemoteRights([.see, .use, .edit], to: guest.id, onPort: w.p)
        _ = try await call(w, "port.rename", ["id": w.p, "title": "renamed", PortActivity.expectParam: token(w, w.p)])
        #expect(w.state.portWindows.panels.first { $0.udid == w.p }?.title == "renamed")
    }

    @Test("a guest names its port by exact id: a matching title reaches nothing")
    func exactIdOnly() async throws {
        let w = try makeWorld()
        w.state.grantRemoteRights([.see], to: guest.id, onPort: w.p)
        await refused(w, "port.getHtml", ["id": w.pTitle], "a title resolved for a remote caller")
    }

    @Test("a refusal does not tell a guest whether another port exists")
    func noExistenceLeak() async throws {
        let w = try makeWorld()
        w.state.grantRemoteRights([.see], to: guest.id, onPort: w.p)
        var messages: [String] = []
        for id in [w.q, "no-such-port"] {
            do { _ = try await call(w, "port.getHtml", ["id": id]) } catch let e as BridgeError {
                #expect(e.code == BridgeErrorCode.notGranted.wire)
                messages.append(e.message)
            }
        }
        #expect(messages.count == 2 && messages[0] == messages[1],
                "an existing and a missing port were refused differently")
    }

    // MARK: - Nothing of the machine

    @Test("a guest reaches nothing of the machine, and never raises a card")
    func machineRefused() async throws {
        let w = try makeWorld()
        w.state.grantRemoteRights([.see, .use, .edit, .wakeAgents], to: guest.id, onPort: w.p)
        // Pregranted, so a broken gate fails fast instead of waiting on a card nobody answers.
        await refused(w, "clipboard.read", [:], pregrant: [.clipboard], "read the host's clipboard")
        await refused(w, "port.create", ["options": ["type": "web", "html": "<p>x</p>"]],
                      "created a port on the host")
        await refused(w, "space.list", [:], "listed the host's spaces")
        await refused(w, "whoami", [:], "asked who is on the host")
        #expect(w.state.permissions.current == nil, "a remote caller raised a permission card")
    }

    @Test("the streaming door is gated too: a guest cannot subscribe to a port it was not given")
    func subscribeGated() async throws {
        let w = try makeWorld()
        w.state.grantRemoteRights([.see], to: guest.id, onPort: w.p)
        // port.subscribe never returns on its own, so a broken gate would hang: race it.
        let attempt = Task { @MainActor in
            try await w.state.runBridgeStream("port.subscribe", principal: guest,
                                              args: BridgeArgs(["id": w.q]), yield: { _ in })
        }
        let deadline = Task { try await Task.sleep(nanoseconds: 2_000_000_000); attempt.cancel() }
        do {
            _ = try await attempt.value
            Issue.record("subscribed to a port it holds no right on")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.notGranted.wire, "\(e.code)")
        } catch {
            Issue.record("subscribe to an ungranted port was not refused (it ran until cancelled)")
        }
        deadline.cancel()
    }

    // MARK: - Waking agents

    @Test("a guest's chat post wakes this machine's companion only with `wake agents`")
    func wakeAgents() async throws {
        let w = try makeParityWorld()
        var a = AgentConfig.createCommand(ownerId: "u", displayName: "alpha", command: "claude",
                                          systemPrompt: nil, trigger: .mentionOnly)
        a.openInTerminal = true
        w.state.companions = [a]
        let panelId = try #require(w.state.spawnNativeTerminalPort(
            command: "true", cwd: NSTemporaryDirectory(), spaceId: w.space.id, title: "alpha",
            companionName: "alpha", companionId: a.id, systemPrompt: nil, postCard: false))
        let key = try #require(w.state.portWindows.panels.first { $0.id == panelId }?.udid)
        let guest = Principal.remote(peer: "peer-ada", displayName: "Ada")
        w.state.pendingTerminalInjections = [:]

        w.state.grantRemoteRights([.see, .use], to: guest.id, onPort: key)
        _ = try await w.state.runBridgeMethod("chat.post", principal: guest,
                                              args: BridgeArgs(["port": key, "text": "alpha, go"]))
        #expect(w.state.chatReplyTargets["alpha"] == nil, "a guest without `wake agents` woke a companion")

        w.state.grantRemoteRights([.see, .use, .wakeAgents], to: guest.id, onPort: key)
        _ = try await w.state.runBridgeMethod("chat.post", principal: guest,
                                              args: BridgeArgs(["port": key, "text": "alpha, go"]))
        #expect(w.state.chatReplyTargets["alpha"] == key, "`wake agents` did not wake the companion")
        withExtendedLifetime(w.state) {}
    }

    // MARK: - Per-caller secret grants

    @Test("a port must be granted a named secret; a card names it, and the answer is remembered")
    func secretGrant() async throws {
        let w = try makeWorld()
        let port = Principal.port(id: "some-port-author", displayName: "a port", spaceId: nil, portId: w.p)
        let args: [String: Any] = ["url": "https://example.invalid/x", "options": ["secret": "stripe"]]

        // No grant: the card names the secret. Deny it.
        let denied = Task { @MainActor in
            try await w.state.runBridgeMethod("rest.call", principal: port, args: BridgeArgs(args),
                                              pregrant: [.rest])
        }
        for _ in 0..<200 where w.state.permissions.current == nil { await Task.yield() }
        let card = try #require(w.state.permissions.current, "no card was raised for the secret")
        #expect(card.detail?.contains("stripe") == true, "the card does not name the secret")
        w.state.permissions.resolveCurrent(granted: false)
        do {
            _ = try await denied.value
            Issue.record("the secret was used after the person denied it")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.permissionDenied.wire, "\(e.code)")
        }

        // Granted: the secret gate passes, and the call fails only because no such secret is stored.
        try w.state.db.saveGrants([.rest], grantee: port.id, object: AppState.secretObject("stripe"), zone: "")
        do {
            _ = try await w.state.runBridgeMethod("rest.call", principal: port, args: BridgeArgs(args),
                                                  pregrant: [.rest])
            Issue.record("expected not_found for an unstored secret")
        } catch let e as BridgeError {
            #expect(e.code == BridgeErrorCode.notFound.wire, "granted, yet refused: \(e.code) \(e.message)")
        }
        #expect(w.state.permissions.current == nil, "asked again after the grant was given")
    }
}
