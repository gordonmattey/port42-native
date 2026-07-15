import Testing
import Foundation
@testable import Port42Lib

/// Rest/Wake — the working set (docs/plan-working-set.md §A) Tier A gate.
///
/// Every space is either WORKING (galaxy front, ⌘1–9, peeks live) or AT REST (off the front,
/// no index, fully silent — unread still accumulates). Same headless harness as
/// `ShellStateTests`: `DatabaseService(inMemory: true)` → `AppState` → `ShellState`.
@Suite("Rest/Wake working set")
struct RestWakeTests {

    @MainActor
    private func makeState() throws -> (ShellState, AppState, DatabaseService) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return (ShellState(appState: state), state, db)
    }

    /// Persist a space and mirror it into AppState (bypasses createSpace's side effects).
    @MainActor
    private func seed(_ names: [String], in state: AppState, db: DatabaseService) throws -> [Space] {
        let spaces = names.map { Space.create(name: $0) }
        for s in spaces { try db.saveSpace(s) }
        state.spaces = try db.getRegularSpaces()
        state.currentSpace = state.spaces.first
        return state.spaces
    }

    // MARK: v40 round-trip + the working/resting split

    @Test("restedAt round-trips through the v40 column; fresh spaces default to working")
    @MainActor
    func restedAtPersists() throws {
        let db = try DatabaseService(inMemory: true)
        var space = Space.create(name: "main")
        #expect(space.restedAt == nil)          // fresh = working
        #expect(!space.isResting)

        let when = Date(timeIntervalSince1970: 1_750_000_000)
        space.restedAt = when
        try db.saveSpace(space)
        let back = try db.getAllSpaces().first { $0.id == space.id }
        #expect(back?.restedAt == when)         // rest persisted
        #expect(back?.isResting == true)

        space.restedAt = nil
        try db.saveSpace(space)
        let woken = try db.getAllSpaces().first { $0.id == space.id }
        #expect(woken?.restedAt == nil)         // wake persisted
    }

    @Test("workingSpaces excludes rested; restingSpaces holds them, most recently rested first")
    @MainActor
    func workingRestingSplit() throws {
        let (_, state, db) = try makeState()
        var spaces = try seed(["a", "b", "c"], in: state, db: db)

        spaces[1].restedAt = Date(timeIntervalSince1970: 100)   // b rested long ago
        spaces[2].restedAt = Date(timeIntervalSince1970: 200)   // c rested more recently
        for s in spaces[1...] { try db.saveSpace(s) }
        state.spaces = try db.getRegularSpaces()

        #expect(state.workingSpaces.map(\.name) == ["a"])
        #expect(state.restingSpaces.map(\.name) == ["c", "b"])  // recency of resting
    }

    // MARK: guards (pure)

    @Test("canRest allows any working space — even the last one — and refuses a double-rest")
    @MainActor
    func canRestGuards() throws {
        var a = Space.create(name: "a")
        let b = Space.create(name: "b")
        #expect(AppState.canRest([a, b], id: a.id))            // working → may rest

        a.restedAt = Date()
        #expect(!AppState.canRest([a, b], id: a.id))           // already resting → refuse
        #expect(AppState.canRest([a, b], id: b.id))            // the LAST working space may rest too
        #expect(!AppState.canRest([a, b], id: "nope"))         // unknown id → refuse
    }

    @Test("restLandingId lands only when resting the current space, on the first other working space")
    @MainActor
    func restLanding() throws {
        let a = Space.create(name: "a")
        let b = Space.create(name: "b")
        let c = Space.create(name: "c")
        // Resting the current space → the first OTHER working space (A's minimal fallback).
        #expect(AppState.restLandingId([a, b, c], resting: a.id, currentId: a.id) == b.id)
        #expect(AppState.restLandingId([a, b, c], resting: b.id, currentId: b.id) == a.id)
        // Resting a non-current space → stay put.
        #expect(AppState.restLandingId([a, b, c], resting: b.id, currentId: a.id) == nil)
        // Resting the current space when it's the ONLY working one → nowhere to land: stay in it.
        #expect(AppState.restLandingId([a], resting: a.id, currentId: a.id) == nil)
    }

    @Test("restSpace on the current space lands in the fallback; resting the last one keeps you in it")
    @MainActor
    func restSpaceIntegration() throws {
        let (_, state, db) = try makeState()
        let spaces = try seed(["a", "b"], in: state, db: db)
        state.currentSpace = spaces[0]

        state.restSpace(spaces[0])                              // rest the CURRENT space
        #expect(state.currentSpace?.id == spaces[1].id)         // landed in the fallback
        #expect(state.workingSpaces.map(\.id) == [spaces[1].id])

        state.restSpace(state.spaces.first { $0.id == spaces[1].id }!)   // rest the LAST working space
        #expect(state.workingSpaces.isEmpty)                    // all-rested is a legal state
        #expect(state.currentSpace?.id == spaces[1].id)         // …and you simply stay in it
    }

    @Test("wakeSpace returns a rested space to the working set; wakeAndEnter also selects it")
    @MainActor
    func wakeAndEnter() throws {
        let (_, state, db) = try makeState()
        let spaces = try seed(["a", "b"], in: state, db: db)
        state.currentSpace = spaces[0]

        state.restSpace(state.spaces.first { $0.id == spaces[1].id }!)
        #expect(state.restingSpaces.count == 1)

        // The ⌘K / shelf path: selecting a rested space wakes + enters.
        state.wakeAndEnterSpace(state.spaces.first { $0.id == spaces[1].id }!)
        #expect(state.restingSpaces.isEmpty)
        #expect(state.workingSpaces.count == 2)
        #expect(state.currentSpace?.id == spaces[1].id)
    }

    // MARK: silence (fully silent — no chat peeks, no port-birth peeks; unread accumulates)

    @Test("a chat-unread increase in a rested space raises no peek; a working space still peeks")
    @MainActor
    func chatSilence() throws {
        let (shell, state, db) = try makeState()
        var spaces = try seed(["home", "rested", "working"], in: state, db: db)
        state.currentSpace = spaces[0]
        spaces[1].restedAt = Date()
        try db.saveSpace(spaces[1])
        state.spaces = try db.getRegularSpaces()

        shell.refreshNotifications(from: [:])                   // seed the baseline
        shell.refreshNotifications(from: [spaces[1].id: 3, spaces[2].id: 3])

        #expect(!shell.peekingPorts.contains { $0.isChat && $0.spaceId == spaces[1].id })  // silent
        #expect(shell.peekingPorts.contains { $0.isChat && $0.spaceId == spaces[2].id })   // control
    }

    @Test("a port born in a rested space raises no peek; in a working space it peeks")
    @MainActor
    func portBirthSilence() throws {
        let (shell, state, db) = try makeState()
        var spaces = try seed(["home", "rested", "working"], in: state, db: db)
        state.currentSpace = spaces[0]
        spaces[1].restedAt = Date()
        try db.saveSpace(spaces[1])
        state.spaces = try db.getRegularSpaces()

        shell.handlePortCreated(id: "p-rested", spaceId: spaces[1].id, title: "silent")
        shell.handlePortCreated(id: "p-working", spaceId: spaces[2].id, title: "loud")

        #expect(!shell.peekingPorts.contains { $0.id == "p-rested" })
        #expect(shell.peekingPorts.contains { $0.id == "p-working" })
    }

    @Test("resting a space clears its already-raised peeks immediately (shell.restSpace)")
    @MainActor
    func restClearsLivePeeks() throws {
        let (shell, state, db) = try makeState()
        let spaces = try seed(["home", "noisy"], in: state, db: db)
        state.currentSpace = spaces[0]

        shell.refreshNotifications(from: [:])
        shell.refreshNotifications(from: [spaces[1].id: 2])     // chat peek up
        shell.handlePortCreated(id: "p1", spaceId: spaces[1].id, title: "port")   // port peek up
        #expect(shell.peekingPorts.count == 2)

        shell.restSpace(spaces[1])
        #expect(shell.peekingPorts.isEmpty)                      // silenced NOW, not on next tick
        #expect(state.spaces.first { $0.id == spaces[1].id }?.isResting == true)
    }

    @Test("shell.restSpace on an already-rested space is refused and changes nothing")
    @MainActor
    func refusedRestChangesNothing() throws {
        let (shell, state, db) = try makeState()
        var spaces = try seed(["home", "away"], in: state, db: db)
        state.currentSpace = spaces[0]
        spaces[1].restedAt = Date(timeIntervalSince1970: 100)
        try db.saveSpace(spaces[1])
        state.spaces = try db.getRegularSpaces()

        shell.restSpace(spaces[1])                               // double-rest → refuse
        let after = state.spaces.first { $0.id == spaces[1].id }
        #expect(after?.restedAt == Date(timeIntervalSince1970: 100))   // timestamp untouched
    }

    @Test("boot lands on the desktop normally, in the galaxy when all spaces rest or none exist")
    @MainActor
    func initialZoomAllRested() throws {
        #expect(ShellState.initialZoom(hasCurrentSpace: true, allRested: false) == .space)
        #expect(ShellState.initialZoom(hasCurrentSpace: true, allRested: true) == .galaxy)   // shelf, not a rested inside
        #expect(ShellState.initialZoom(hasCurrentSpace: false, allRested: true) == .galaxy)  // fresh setup
    }

    // MARK: indexes (⌘1–9 over the working set, in working-set order)

    @Test("⌘1…N indexes the working set: a rested space is skipped over")
    @MainActor
    func jumpIndexesWorkingSet() throws {
        let (shell, state, db) = try makeState()
        var spaces = try seed(["a", "b", "c"], in: state, db: db)
        state.currentSpace = spaces[0]
        spaces[1].restedAt = Date()                              // rest the MIDDLE space
        try db.saveSpace(spaces[1])
        state.spaces = try db.getRegularSpaces()

        shell.jumpToSpace(index: 1)                              // ⌘2 → second WORKING space = c
        #expect(state.currentSpace?.id == spaces[2].id)

        shell.jumpToSpace(index: 2)                              // out of working range → no-op
        #expect(state.currentSpace?.id == spaces[2].id)
    }
}
