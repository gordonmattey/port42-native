import Testing
import Foundation
@testable import Port42Lib

/// SHELL — S2 test gate: the zoom ladder (galaxy ↔ space ↔ focus).
///
/// `ShellState` is the shell-only UI `ObservableObject` (zoom level, selection, galaxy hover, pinch
/// latch). The zoom ladder is *pure state* (no window, no webview), so it's fully unit-testable
/// headlessly — same harness as `RegisteredInlinePortTests` (`DatabaseService(inMemory: true)` →
/// `AppState`). Ports are registered as inline panels (which work headlessly) just to give focus a
/// target.
@Suite("Shell zoom ladder")
struct ShellStateTests {

    @MainActor
    private func makeState() throws -> (ShellState, AppState) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return (ShellState(appState: state), state)
    }

    /// Register a non-background port on `space` so `selectedPort`/focus has something to target.
    @MainActor
    private func addPort(_ id: String, to space: Space, in state: AppState) {
        // A TILED port — a desktop unit. Phase 2: only units are focusable (zoomIn skips
        // anything that isn't on the desktop), so the ladder's focus rung needs a real tile.
        _ = state.portWindows.registerTiledPort(id: id, html: "<title>\(id)</title><div/>",
                                                spaceId: space.id, createdBy: nil, title: nil,
                                                position: nil)
    }

    @Test("⌘↑/pinch-out steps focus → space → galaxy, one rung per gesture")
    @MainActor
    func zoomsOutOneRungPerStep() throws {
        let (shell, state) = try makeState()
        let space = Space.create(name: "main")
        state.spaces = [space]; state.currentSpace = space
        addPort("p1", to: space, in: state)

        shell.zoom = .focus("p1")
        shell.zoomOut(); #expect(shell.zoom == .space)
        shell.zoomOut(); #expect(shell.zoom == .galaxy)

        // Pinch latch: ONE rung per gesture, no multi-rung jumps in a single continuous squeeze.
        shell.zoom = .focus("p1")
        shell.pinch(delta: -0.2, began: true)    // below threshold → no move yet
        #expect(shell.zoom == .focus("p1"))
        shell.pinch(delta: -0.2, began: false)   // accum -0.4 < -0.32 → fires once → space
        #expect(shell.zoom == .space)
        shell.pinch(delta: -0.9, began: false)   // already fired this gesture → latched, no move
        #expect(shell.zoom == .space)
        shell.pinch(delta: -0.9, began: true)    // new gesture → fires → galaxy
        #expect(shell.zoom == .galaxy)
    }

    @Test("⌘↓/pinch-in steps galaxy → space → focus(selected); hover-dive enters the hovered space")
    @MainActor
    func zoomsInOneRungPerStep() throws {
        let (shell, state) = try makeState()
        let main = Space.create(name: "main")
        let api = Space.create(name: "api")
        state.spaces = [main, api]; state.currentSpace = main
        addPort("p1", to: main, in: state)

        shell.zoom = .galaxy
        shell.zoomIn(); #expect(shell.zoom == .space)          // no hover → just descend a rung
        shell.selectedPortId = "p1"
        shell.zoomIn(); #expect(shell.zoom == .focus("p1"))    // → focus the highlighted port

        // Hover-dive: from galaxy, hovering another space-world enters THAT space (lands on .space).
        shell.zoom = .galaxy; shell.galaxyHover = 1
        shell.zoomIn()
        #expect(state.currentSpace?.id == api.id)
        #expect(shell.zoom == .space)
    }

    @Test("zoom clamps at the ends (galaxy is the ceiling, focus is the floor)")
    @MainActor
    func clampsAtBounds() throws {
        let (shell, state) = try makeState()
        let space = Space.create(name: "main")
        state.spaces = [space]; state.currentSpace = space
        addPort("p1", to: space, in: state)

        shell.zoom = .galaxy
        shell.zoomOut(); #expect(shell.zoom == .galaxy)        // ceiling — stays galaxy

        shell.zoom = .focus("p1")
        shell.zoomIn(); #expect(shell.zoom == .focus("p1"))    // floor — stays focus
    }

    @Test("⌘1…N jumps directly to the Nth space and lands on its desktop rung")
    @MainActor
    func numberKeyJumpsSpace() throws {
        let (shell, state) = try makeState()
        let s0 = Space.create(name: "main")
        let s1 = Space.create(name: "api")
        let s2 = Space.create(name: "ui")
        state.spaces = [s0, s1, s2]; state.currentSpace = s0

        shell.zoom = .galaxy
        shell.jumpToSpace(index: 2)
        #expect(state.currentSpace?.id == s2.id)
        #expect(shell.zoom == .space)

        // Out-of-range is a no-op (no crash, no change).
        shell.jumpToSpace(index: 9)
        #expect(state.currentSpace?.id == s2.id)
        #expect(shell.zoom == .space)
    }

    // MARK: - Dock restore + launch z-order (Bug 1)

    @MainActor
    private func z(_ id: String, _ state: AppState) -> Int {
        state.portWindows.panels.first { $0.id == id }?.z ?? -1
    }

    @Test("a same-space birth is stamped frontmost + selected (not left at z=0 under everything)")
    @MainActor
    func birthLandsFrontmost() throws {
        let (shell, state) = try makeState()
        let space = Space.create(name: "main")
        state.spaces = [space]; state.currentSpace = space
        addPort("p1", to: space, in: state)
        addPort("p2", to: space, in: state)
        // handlePortCreated is the portCreated sink (live it is .receive(on: RunLoop.main)); a
        // same-space birth stamps frontmost + selects rather than returning at the default z=0.
        shell.handlePortCreated(id: "p1", spaceId: space.id, title: "p1")
        shell.handlePortCreated(id: "p2", spaceId: space.id, title: "p2")
        #expect(z("p2", state) > z("p1", state))     // the later birth is on top
        #expect(shell.selectedTileId == "p2")
    }

    @Test("restoring a parked port stamps it frontmost over what was focused since")
    @MainActor
    func restoreLandsFrontmost() throws {
        let (shell, state) = try makeState()
        let space = Space.create(name: "main")
        state.spaces = [space]; state.currentSpace = space
        addPort("p1", to: space, in: state)
        addPort("p2", to: space, in: state)
        shell.bringToFront("p1")                      // p1 focused
        state.portWindows.park(id: "p1")             // then parked (keeps its now-stale z)
        shell.bringToFront("p2")                      // p2 focused since → higher z than p1
        // The chip-restore path: unpark + re-stamp frontmost.
        state.portWindows.unpark(id: "p1")
        shell.bringToFront("p1")
        #expect(z("p1", state) > z("p2", state))     // restored port is frontmost, not under p2
        #expect(shell.selectedTileId == "p1")
    }

    @Test("nextZ re-seeds so a birth lands above a panel stamped by the manager's max+1 authority")
    @MainActor
    func zAuthorityDoesNotDrift() throws {
        let (shell, state) = try makeState()
        let space = Space.create(name: "main")
        state.spaces = [space]; state.currentSpace = space
        addPort("p1", to: space, in: state)
        addPort("p2", to: space, in: state)
        // The OTHER z authority (PortWindowManager.bringToFront = max+1, used by terminal focus)
        // stamps p1 high WITHOUT bumping the shell counter — the drift that put new ports behind.
        state.portWindows.bringToFront("p1")
        // A same-space birth must still land ABOVE p1 (nextZ re-seeds against the live max).
        shell.handlePortCreated(id: "p2", spaceId: space.id, title: "p2")
        #expect(z("p2", state) > z("p1", state))
    }
}
