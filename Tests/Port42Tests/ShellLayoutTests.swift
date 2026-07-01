import Testing
import Foundation
import CoreGraphics
import SwiftUI
@testable import Port42Lib

/// SHELL — S3 test gate (headless): the layout authority (`arrange`), per-space accent bound for
/// life (decision #5), and desktop-layout persistence (`presentation` + `z` + `position` survive a
/// restart — the bug this phase fixes). Pure functions + `DatabaseService(inMemory: true)`, no
/// window/webview. The interaction layer (drag/park/pop-out/exposé) is verified manually + by
/// `ReParentStabilityTests`.
@Suite("Shell layout, accent & persistence")
struct ShellLayoutTests {

    @MainActor
    private func makeState() throws -> (ShellState, AppState) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return (ShellState(appState: state), state)
    }

    // MARK: - arrange (the layout authority)

    @Test("arrange grids by ceil(√n), centered, clears the Chrome, no overlaps, deterministic")
    func arrangeGrid() throws {
        let tiles = (0..<5).map {
            ShellState.ArrangeTile(id: "p\($0)", size: CGSize(width: 360, height: 260), z: $0)
        }
        let area = CGSize(width: 1440, height: 900)
        let pos = ShellState.arrange(tiles, in: area)

        #expect(pos.count == 5)
        // Every tile clears the top Chrome (startY ≥ 70).
        for p in pos.values { #expect(p.y >= 70) }
        // Deterministic: same set → identical grid.
        #expect(ShellState.arrange(tiles, in: area) == pos)
        // No two tiles share an origin (grid cells are distinct).
        let origins = Array(pos.values)
        for i in 0..<origins.count {
            for j in (i + 1)..<origins.count {
                #expect(!(origins[i].x == origins[j].x && origins[i].y == origins[j].y))
            }
        }
    }

    @Test("arrange walks tiles in z order (lowest z lands first, top-left)")
    func arrangeZOrder() throws {
        let a = ShellState.ArrangeTile(id: "a", size: CGSize(width: 300, height: 200), z: 5)
        let b = ShellState.ArrangeTile(id: "b", size: CGSize(width: 300, height: 200), z: 1)
        let pos = ShellState.arrange([a, b], in: CGSize(width: 1000, height: 800))
        // n=2 → cols=2 → the lower-z tile (b) takes the first (left) cell.
        #expect(pos["b"]!.x <= pos["a"]!.x)
    }

    @Test("arrange of an empty desktop is empty (no crash)")
    func arrangeEmpty() throws {
        #expect(ShellState.arrange([], in: CGSize(width: 800, height: 600)).isEmpty)
    }

    // MARK: - z-order counter

    @Test("nextZ is monotonic and seeds above any restored z")
    @MainActor
    func zCounterMonotonic() throws {
        let (shell, _) = try makeState()
        #expect(shell.nextZ() == 1)
        #expect(shell.nextZ() == 2)
        // A restart restores ports with higher z — the counter must catch up so new focus wins.
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let bridge = PortBridge(appState: state, spaceId: "s1", messageId: "m")
        var high = PortPanel(id: "h", udid: "h", html: "<div/>", bridge: bridge,
                             spaceId: "s1", createdBy: nil, messageId: "m",
                             size: CGSize(width: 300, height: 200))
        high.z = 40
        shell.seedZCounter(from: [high])
        #expect(shell.nextZ() == 41)
    }

    // MARK: - accent bound for life (decision #5)

    @Test("accent is bound to the space, not its list position — no reshuffle on delete")
    @MainActor
    func accentStableAcrossDelete() throws {
        let (shell, state) = try makeState()
        var s0 = Space.create(name: "a"); s0.accent = "#00D4AA"
        var s1 = Space.create(name: "b"); s1.accent = "#FF6BB2"
        var s2 = Space.create(name: "c"); s2.accent = "#FFBD33"
        state.spaces = [s0, s1, s2]

        let before = shell.accent(for: s2)          // gold, from its stored hex
        state.spaces = [s0, s2]                      // delete the middle space (s1)
        #expect(shell.accent(for: s2) == before)     // s2 stays gold — position-based would flip it
    }

    @Test("accent with no stored hex is id-stable, independent of list position")
    @MainActor
    func accentFallbackIdStable() throws {
        let (shell, state) = try makeState()
        let s0 = Space.create(name: "a")             // no stored accent
        let s1 = Space.create(name: "b")
        state.spaces = [s0, s1]
        let before = shell.accent(for: s1)
        state.spaces = [s1]                           // s1 moves from position 1 → 0
        #expect(shell.accent(for: s1) == before)      // id-hash fallback ignores position
    }

    @Test("createSpace assigns and persists an accent for life")
    @MainActor
    func createSpaceAssignsAccent() throws {
        let (_, state) = try makeState()
        state.createSpace(name: "First")
        let created = try #require(state.spaces.first { $0.name == "first" })
        #expect(created.accent != nil)
        #expect(Color(shellHex: created.accent!) != nil)   // a real hex
    }

    // MARK: - desktop-layout persistence (the restart bug)

    @Test("a tiled port persists its presentation + position and restores after a restart")
    @MainActor
    func tiledPortSurvivesRestart() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let mgr = state.portWindows
        mgr.registerTiledPort(id: "t1", html: "<title>t</title><div/>", spaceId: "s1",
                              createdBy: nil, title: "t1", position: CGPoint(x: 120, y: 340))
        #expect(mgr.panels.first { $0.id == "t1" }?.presentation == "tiled")

        // Simulate a restart: tear down the live panels, restore from the same DB.
        mgr.panels.removeAll()
        mgr.webViews.removeAll()
        mgr.restoreFromDB(appState: state)

        let p = try #require(mgr.panels.first { $0.id == "t1" })
        #expect(p.presentation == "tiled")                       // was lost pre-v37 (came back floating)
        #expect(p.position == CGPoint(x: 120, y: 340))
    }

    @Test("PersistedPortPanel round-trips presentation + z + position")
    @MainActor
    func persistedPanelRoundTrips() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let bridge = PortBridge(appState: state, spaceId: "s1", messageId: "m")
        var panel = PortPanel(id: "z1", udid: "z1", html: "<div/>", bridge: bridge,
                              spaceId: "s1", createdBy: nil, messageId: "m",
                              size: CGSize(width: 300, height: 200))
        panel.presentation = "parked"
        panel.z = 7
        panel.position = CGPoint(x: 10, y: 20)

        try db.savePortPanel(PersistedPortPanel(from: panel))
        let fetched = try #require(try db.fetchPortPanels().first { $0.id == "z1" })
        #expect(fetched.presentation == "parked")
        #expect(fetched.z == 7)
        #expect(fetched.posX == 10 && fetched.posY == 20)
    }
}
