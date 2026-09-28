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
    /// Wait for the card. ~0 ms alone; under the full suite's load the main actor can take many
    /// seconds, and a 5 s ceiling then answered nothing and left the test waiting on an unanswered
    /// card until its minute ran out (it failed the release gate twice, 2026-09-27). 40 s, then a
    /// clear failure rather than a hang: false means no card, and the caller must not await the ask.
    private func awaitCard(_ appState: AppState) async throws -> Bool {
        for _ in 0..<1600 {
            if appState.permissions.current != nil { return true }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        Issue.record("no permission card appeared within 40 s")
        return false
    }

    @Test("a caller that already holds .terminal is NOT re-asked")
    @MainActor
    func existingGrantIsHonored() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { true }   // a mounted shell (APP-16)
        let p = Principal.peer(id: "claude-code-\(UUID().uuidString)", displayName: "Claude Code")
        appState.saveGrants([.terminal], grantee: p.id, on: .machine, zone: nil)

        // No prompt is pending and none is created: `ensurePermission` returns true from the store.
        // If this ever hangs, the gate stopped consulting existing grants and started asking every
        // time, which is the failure that would make `teleport` unusable.
        #expect(try await appState.ensurePermission(.terminal, for: p) == true)
        #expect(appState.permissions.current == nil, "an already-granted capability must raise no card")
    }

    /// **The time limit is load-bearing, and calibration is why.** Breaking the gate so it asks
    /// without remembering made an earlier version of this test HANG rather than fail: the second
    /// `ensurePermission` raised a fresh card that no one answered, and the suite sat for 30 minutes.
    /// A gate that wedges instead of reporting is not a gate. The assertion now reads the STORE —
    /// which is the actual property, "the answer was remembered" — and the limit converts any
    /// remaining await-forever into a failure.
    // No time limit: it counted from the test's start, and a loaded machine held the main actor
    // for 90 s before this test ran a line (2026-09-27). Nothing below can wait forever, since
    // `awaitCard` returns false instead of letting the ask be awaited unanswered.
    @Test("granting through the gate PERSISTS, so the second call is silent")
    @MainActor
    func gatePersistsTheGrant() async throws {
        let appState = AppState(db: try DatabaseService(inMemory: true))
        appState.permissions.canPrompt = { true }   // a mounted shell (APP-16)
        let p = Principal.peer(id: "cli-\(UUID().uuidString)", displayName: "port42 CLI")
        #expect(appState.grants(grantee: p.id, on: .machine, zone: nil).isEmpty)

        // Answer the card as the human would, then assert the answer was remembered.
        // A main-actor Task, not `async let`: an `async let` child starts on the global pool and
        // only then hops here, and under the full suite other tests hold every pool thread, so the
        // child never ran and no card appeared in 40 s (release gate, 2026-09-27). A main-actor
        // Task is queued on the main executor directly, the same one `awaitCard` runs on.
        let asked = Task { @MainActor in (try? await appState.ensurePermission(.browser, for: p)) ?? false }
        guard try await awaitCard(appState) else { return }
        appState.permissions.resolveCurrent(granted: true)
        #expect(await asked.value == true)

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
        appState.permissions.canPrompt = { true }   // a mounted shell (APP-16)
        let p = Principal.peer(id: "cli-\(UUID().uuidString)", displayName: "port42 CLI")

        // Same fix as above, and this one mattered MORE: no time limit here, so under contention it
        // did not fail, it hung forever.
        let asked = Task { @MainActor in (try? await appState.ensurePermission(.terminal, for: p)) ?? false }
        guard try await awaitCard(appState) else { return }
        appState.permissions.resolveCurrent(granted: false)
        #expect(await asked.value == false)

        #expect(appState.grants(grantee: p.id, on: .machine, zone: nil).isEmpty,
                "a deny must leave no grant behind")
    }
}
