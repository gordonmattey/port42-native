import Testing
import Foundation
@testable import Port42Lib

/// **The gate is on the FIRST command, not the second** (slice-02, GM 2026-07-29).
///
/// `terminal.exec` required `.terminal` and `browser.open` required `.browser`, but creating the PORT
/// required nothing — so either gate could be skipped by making a port instead of calling the verb.
/// `port42 teleport` was the live case: it created a terminal already running `claude`, in the user's
/// current space, with no prompt, and so could any local process that reached the gateway.
///
/// No new permission was needed. Creating a terminal IS using the terminal; creating a browser IS
/// browsing. The escalation is keyed on `type`, in the body, which is the pattern `screen.record`
/// already uses when it asks for `.microphone` only because `audio` said so.
@Suite("port.create is gated by what it starts")
struct PortCreateGateTests {

    /// The registry declaration is the permission table, so what a method needs is readable there —
    /// except when the need depends on an argument, which is this case. These tests therefore assert
    /// on the SOURCE for the declaration and on behavior for the gate.
    func createBody() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Services/BridgeMethods.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(src.range(of: "r[\"port.create\"] = BridgeMethod("))
        return String(src[start.lowerBound...].prefix(12000))
    }

    @Test("creating a TERMINAL requires .terminal, and a BROWSER requires .browser")
    func createEscalatesByType() throws {
        let body = try createBody()
        #expect(body.contains("case \"terminal\": return .terminal"),
                "creating a terminal starts a process and must go through the terminal gate")
        #expect(body.contains("case \"browser\": return .browser"))
        #expect(body.contains("ensurePermission"),
                "must use the gate that PERSISTS the answer, or every create re-asks")
    }

    @Test("the gate runs BEFORE the port is created, not after")
    func gatePrecedesCreation() throws {
        let body = try createBody()
        let gate = try #require(body.range(of: "ensurePermission"))
        let create = try #require(body.range(of: "appState.createPort("))
        #expect(gate.lowerBound < create.lowerBound,
                "a denied create must not have already spawned the process")
    }

    @Test("web and chat stay UNGATED, deliberately")
    func inertTypesAreNotGated() throws {
        // A web port renders inert HTML; `chat` only reveals the space's own chat port and is
        // idempotent. Neither starts anything, and gating them would make the first port a
        // companion creates in a conversation raise a prompt for nothing.
        let body = try createBody()
        #expect(!body.contains("case \"web\": return ."))
        #expect(!body.contains("case \"chat\": return ."))
    }

    // MARK: - Behavior: the gate remembers

    /// Wait for the card to actually be raised, rather than sleeping a fixed interval and hoping.
    ///
    /// A fixed `Task.sleep` is a RACE, not a synchronization: it assumes the child task has hopped
    /// to `@MainActor` and set `current` within the interval. Alone it does, in ~0.3s. In the full
    /// suite, many `@MainActor` tests run concurrently, the child had not run yet, `resolveCurrent`
    /// found `current == nil` and no-opped — and the `await` below then waited for a card nobody
    /// would ever answer. Passes in isolation, hangs in the suite, which is the worst shape a test
    /// can have because the failure looks like an unrelated flake.
    @MainActor
    private func awaitCard(_ appState: AppState) async throws {
        for _ in 0..<200 {                     // 5s ceiling, ~0ms in practice
            if appState.permissions.current != nil { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    @Test("a caller that already holds .terminal is NOT re-asked")
    @MainActor
    func existingGrantIsHonored() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let p = Principal.peer(id: "claude-code-\(UUID().uuidString)", displayName: "Claude Code")
        appState.saveGrants([.terminal], grantee: p.id, on: .machine, zone: nil)

        // No prompt is pending and none is created: `ensurePermission` returns true from the store.
        // If this ever hangs, the gate stopped consulting existing grants and started asking every
        // time, which is the failure that would make `teleport` unusable.
        #expect(await appState.ensurePermission(.terminal, for: p) == true)
        #expect(appState.permissions.current == nil, "an already-granted capability must raise no card")
    }

    /// **The time limit is load-bearing, and calibration is why.** Breaking the gate so it asks
    /// without remembering made an earlier version of this test HANG rather than fail: the second
    /// `ensurePermission` raised a fresh card that no one answered, and the suite sat for 30 minutes.
    /// A gate that wedges instead of reporting is not a gate. The assertion now reads the STORE —
    /// which is the actual property, "the answer was remembered" — and the limit converts any
    /// remaining await-forever into a failure.
    @Test("granting through the gate PERSISTS, so the second call is silent",
          .timeLimit(.minutes(1)))
    @MainActor
    func gatePersistsTheGrant() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let p = Principal.peer(id: "cli-\(UUID().uuidString)", displayName: "port42 CLI")
        #expect(appState.grants(grantee: p.id, on: .machine, zone: nil).isEmpty)

        // Answer the card as the human would, then assert the answer was remembered.
        async let asked = appState.ensurePermission(.browser, for: p)
        try await awaitCard(appState)
        appState.permissions.resolveCurrent(granted: true)
        #expect(await asked == true)

        // The store, not a second call: a second call that re-prompts BLOCKS, so asserting on it
        // would hide the regression behind a hang.
        #expect(appState.grants(grantee: p.id, on: .machine, zone: nil).contains(.browser),
                "the gate asked but did not remember — every create would re-prompt")
        #expect(appState.permissions.current == nil, "no card should still be pending")
    }

    @Test("a denial is not persisted, so the caller can be asked again")
    @MainActor
    func denialIsNotRemembered() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        let p = Principal.peer(id: "cli-\(UUID().uuidString)", displayName: "port42 CLI")

        // Same fix as above, and this one mattered MORE: no time limit here, so under contention it
        // did not fail, it hung forever.
        async let asked = appState.ensurePermission(.terminal, for: p)
        try await awaitCard(appState)
        appState.permissions.resolveCurrent(granted: false)
        #expect(await asked == false)

        #expect(appState.grants(grantee: p.id, on: .machine, zone: nil).isEmpty,
                "a deny must leave no grant behind")
    }
}
