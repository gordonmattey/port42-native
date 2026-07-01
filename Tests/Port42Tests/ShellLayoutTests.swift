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

    // MARK: - key yield (§3.1)

    @Test("shouldYieldKey: editor/terminal own the keyboard; Esc reaches a focused terminal")
    func keyYieldMatrix() throws {
        let esc: UInt16 = 53, up: UInt16 = 126, one: UInt16 = 18
        // A focused text field / web view / terminal → yield every key (typing incl. ⌘-combos).
        #expect(ShellState.shouldYieldKey(isEditor: true, keyCode: up, focusedPortIsTerminal: false))
        #expect(ShellState.shouldYieldKey(isEditor: true, keyCode: one, focusedPortIsTerminal: false))
        // Nothing focused for editing → shell drives the ladder (don't yield ⌘↑ / ⌘1).
        #expect(!ShellState.shouldYieldKey(isEditor: false, keyCode: up, focusedPortIsTerminal: false))
        #expect(!ShellState.shouldYieldKey(isEditor: false, keyCode: one, focusedPortIsTerminal: false))
        // Esc: yields to a focused terminal (vim/TUI), otherwise peels the zoom rung.
        #expect(ShellState.shouldYieldKey(isEditor: false, keyCode: esc, focusedPortIsTerminal: true))
        #expect(!ShellState.shouldYieldKey(isEditor: false, keyCode: esc, focusedPortIsTerminal: false))
        // Esc also yields to a plain editing field.
        #expect(ShellState.shouldYieldKey(isEditor: true, keyCode: esc, focusedPortIsTerminal: false))
    }

    @Test("focusedPortIsTerminal reads the focused panel's portType")
    @MainActor
    func focusedPortIsTerminalReflectsPanel() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let shell = ShellState(appState: state)
        state.portWindows.registerTiledPort(id: "web1", html: "<div/>", spaceId: "s1",
                                            createdBy: nil, title: nil, position: nil)
        shell.zoom = .focus("web1")
        #expect(shell.focusedPortIsTerminal == false)      // a web tile
        shell.zoom = .space
        #expect(shell.focusedPortIsTerminal == false)      // nothing focused
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

    // MARK: - movable tiles (S3 Chunk 2 — bringToFront, applyArrange, drag/resize commit)

    @Test("bringToFront stamps ascending z (frontmost) + selects; chat stays the z=0 anchor")
    @MainActor
    func bringToFrontZOrder() throws {
        let (shell, state) = try makeState()
        let mgr = state.portWindows
        mgr.registerTiledPort(id: "a", html: "<div/>", spaceId: "s1", createdBy: nil, title: "a", position: nil)
        mgr.registerTiledPort(id: "b", html: "<div/>", spaceId: "s1", createdBy: nil, title: "b", position: nil)

        shell.bringToFront("a")
        let za = try #require(mgr.panels.first { $0.id == "a" }?.z)
        #expect(shell.selectedTileId == "a")

        shell.bringToFront("b")
        let zb = try #require(mgr.panels.first { $0.id == "b" }?.z)
        #expect(zb > za)                          // b is now frontmost
        #expect(shell.selectedTileId == "b")

        // Chat is the back anchor: selecting it highlights but stamps no panel z.
        shell.bringToFront(ShellState.chatTileId)
        #expect(shell.selectedTileId == ShellState.chatTileId)
        #expect(mgr.panels.first { $0.id == "b" }?.z == zb)   // unchanged
    }

    @Test("applyArrange positions every tile (chat + ports), clears the Chrome, and a spawn re-grids")
    @MainActor
    func applyArrangePositionsAndRegrid() throws {
        let (shell, state) = try makeState()
        state.currentSpace = Space(id: "s1", name: "s", type: "team", createdAt: Date())
        let mgr = state.portWindows
        mgr.registerTiledPort(id: "a", html: "<div/>", spaceId: "s1", createdBy: nil, title: "a", position: nil)
        mgr.registerTiledPort(id: "b", html: "<div/>", spaceId: "s1", createdBy: nil, title: "b", position: nil)

        let area = CGSize(width: 1440, height: 900)
        shell.applyArrange(area: area)

        #expect(shell.chatFrame(space: "s1") != nil)                       // chat got a slot
        let pa = try #require(mgr.panels.first { $0.id == "a" }?.position)  // ports got positions
        let pb = try #require(mgr.panels.first { $0.id == "b" }?.position)
        #expect(pa.y >= 70 && pb.y >= 70)                                  // clears the Chrome
        #expect(pa != pb)

        // Hand-move a tile, then a spawn re-grids over it (arrange is the authority, §4).
        mgr.updateTileFrame(id: "a", position: CGPoint(x: 5, y: 5), size: nil)
        #expect(mgr.panels.first { $0.id == "a" }?.position == CGPoint(x: 5, y: 5))
        mgr.registerTiledPort(id: "c", html: "<div/>", spaceId: "s1", createdBy: nil, title: "c", position: nil)
        shell.applyArrange(area: area)
        let pa2 = try #require(mgr.panels.first { $0.id == "a" }?.position)
        #expect(pa2 != CGPoint(x: 5, y: 5))                               // re-gridded over the hand position
    }

    @Test("parkZone: right strip is park, its bottom portion is close, the rest is nil")
    func parkZoneDetection() throws {
        let area = CGSize(width: 1440, height: 900)
        let w = ShellState.parkWidth(area.width)
        #expect(w == max(64, 1440 * 0.05))
        #expect(ShellState.parkZone(at: CGPoint(x: 700, y: 400), in: area) == nil)                    // middle
        #expect(ShellState.parkZone(at: CGPoint(x: area.width - 5, y: 200), in: area) == .park)        // strip, high
        #expect(ShellState.parkZone(at: CGPoint(x: area.width - 5, y: area.height - 10), in: area) == .close)  // strip, low
        #expect(ShellState.parkZone(at: CGPoint(x: area.width - w - 5, y: area.height - 10), in: area) == nil) // just left of strip
    }

    @Test("ensureChatPlaced gives the chat a slot without disturbing persisted port positions")
    @MainActor
    func ensureChatPlacedLeavesPortsAlone() throws {
        let (shell, state) = try makeState()
        state.currentSpace = Space(id: "s1", name: "s", type: "team", createdAt: Date())
        let mgr = state.portWindows
        mgr.registerTiledPort(id: "a", html: "<div/>", spaceId: "s1", createdBy: nil, title: "a",
                              position: CGPoint(x: 777, y: 555))
        #expect(shell.chatFrame(space: "s1") == nil)

        let area = CGSize(width: 1440, height: 900)
        shell.ensureChatPlaced(area: area)
        #expect(shell.chatFrame(space: "s1") != nil)                                    // chat got a slot
        #expect(mgr.panels.first { $0.id == "a" }?.position == CGPoint(x: 777, y: 555)) // port untouched (restart-safe)

        // Idempotent: a second entry doesn't shove the chat around.
        let placed = shell.chatFrame(space: "s1")
        shell.ensureChatPlaced(area: area)
        #expect(shell.chatFrame(space: "s1") == placed)
    }

    @Test("ShellTile.resized pins the opposite corner for every corner and clamps to the min size")
    func cornerResizeMath() throws {
        let f = CGRect(x: 100, y: 100, width: 400, height: 300)
        // SE grows down-right; top-left (100,100) pinned.
        let se = ShellTile.resized(f, corner: .se, by: CGSize(width: 50, height: 40))
        #expect(se.minX == 100 && se.minY == 100 && se.width == 450 && se.height == 340)
        // NW moves the origin; bottom-right (500,400) pinned.
        let nw = ShellTile.resized(f, corner: .nw, by: CGSize(width: 30, height: 20))
        #expect(nw.maxX == 500 && nw.maxY == 400 && nw.minX == 130 && nw.minY == 120)
        // NE: bottom-left (100,400) pinned (top edge moves up).
        let ne = ShellTile.resized(f, corner: .ne, by: CGSize(width: 20, height: -50))
        #expect(ne.minX == 100 && ne.maxY == 400 && ne.width == 420 && ne.minY == 50)
        // SW: top-right (500,100) pinned (left edge moves left).
        let sw = ShellTile.resized(f, corner: .sw, by: CGSize(width: -60, height: 30))
        #expect(sw.maxX == 500 && sw.minY == 100 && sw.minX == 40 && sw.height == 330)
        // Dragging a corner far past the opposite one clamps to min — it does NOT flip.
        let tiny = ShellTile.resized(f, corner: .se, by: CGSize(width: -1000, height: -1000))
        #expect(tiny.minX == 100 && tiny.minY == 100)
        #expect(tiny.width == ShellState.minTileSize.width && tiny.height == ShellState.minTileSize.height)
    }

    @Test("drag + edge-resize commit (updateTileFrame) persists position & size across a restart")
    @MainActor
    func tileGeometryCommitSurvivesRestart() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let mgr = state.portWindows
        mgr.registerTiledPort(id: "t", html: "<div/>", spaceId: "s1", createdBy: nil, title: "t",
                              position: CGPoint(x: 10, y: 10))
        // Simulate a drag-move + edge-resize ending on the desktop.
        mgr.updateTileFrame(id: "t", position: CGPoint(x: 420, y: 260),
                            size: CGSize(width: 500, height: 360))

        mgr.panels.removeAll(); mgr.webViews.removeAll()
        mgr.restoreFromDB(appState: state)

        let p = try #require(mgr.panels.first { $0.id == "t" })
        #expect(p.position == CGPoint(x: 420, y: 260))
        #expect(p.size == CGSize(width: 500, height: 360))
        #expect(p.presentation == "tiled")
    }
}
