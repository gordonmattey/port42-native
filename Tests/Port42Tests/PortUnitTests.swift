import Testing
import CoreGraphics
@testable import Port42Lib

/// Tier A for the Port Units refactor, Phase 0 (plan-port-units-render-refactor.md §9):
/// the pure `placement()` — state, not geometry, drives where a port's one persistent
/// view sits. Headless; the mount/window half is Tier B (`PortRenderProbe` + the
/// "Port Units — cycle" harness).
@Suite("Port Units — placement (Phase 0)")
struct PortUnitTests {

    private let area = CGSize(width: 1000, height: 800)
    private let size = CGSize(width: 460, height: 400)

    private func place(id: String = "p1",
                       position: CGPoint? = CGPoint(x: 100, y: 120),
                       z: Int = 3,
                       zoom: ShellState.Zoom = .space,
                       onDesktop: Bool = true,
                       fallbackIndex: Int = 0) -> PortPlacement {
        ShellPlacement.placement(id: id, position: position, size: size, z: z,
                                 zoom: zoom, onDesktop: onDesktop,
                                 fallbackIndex: fallbackIndex, area: area)
    }

    @Test("focusRect is 0.78×0.8 of the area, centered")
    func focusRectCentered() {
        let r = ShellPlacement.focusRect(in: area)
        #expect(r.width == 780)
        #expect(r.height == 640)
        #expect(r.midX == 500)
        #expect(r.midY == 400)
    }

    @Test("tiled placement uses the committed position/size (== resolvedTileFrame)")
    func tiledUsesCommittedFrame() {
        let p = place()
        #expect(p.rect == CGRect(x: 100, y: 120, width: 460, height: 400))
        #expect(p.rect == ShellPlacement.resolvedTileFrame(position: CGPoint(x: 100, y: 120),
                                                           size: size, fallbackIndex: 0))
        #expect(p.chrome == .tile)
        #expect(p.corner == ShellPlacement.tileCorner)
        #expect(p.z == 3)
        #expect(p.visible)
    }

    @Test("tiled placement falls back to the cascade when never positioned")
    func tiledFallbackCascade() {
        let p0 = place(position: nil, fallbackIndex: 0)
        let p5 = place(position: nil, fallbackIndex: 5)
        #expect(p0.rect.origin == CGPoint(x: 330, y: 200))
        #expect(p5.rect.origin == CGPoint(x: 330 + 90, y: 200 + 2 * 80))   // 5%4=1, 5%3=2
        #expect(p0.rect.size == size)
    }

    @Test("legacy z 0 paints at zIndex 1 (never under the desktop floor)")
    func legacyZeroZClamps() {
        #expect(place(z: 0).z == 1)
    }

    @Test("focused placement = focusRect + focus z/chrome/corner")
    func focusedPlacement() {
        let p = place(zoom: .focus("p1"))
        #expect(p.rect == ShellPlacement.focusRect(in: area))
        #expect(p.z == ShellPlacement.focusZ)
        #expect(p.chrome == .focus)
        #expect(p.corner == ShellPlacement.focusCorner)
        #expect(p.visible)
    }

    @Test("another port's focus leaves this tile placed as a tile (stays staged)")
    func otherPortsFocusLeavesTileAlone() {
        let p = place(zoom: .focus("someone-else"))
        #expect(p.chrome == .tile)
        #expect(p.rect == CGRect(x: 100, y: 120, width: 460, height: 400))
        #expect(p.visible)
    }

    @Test("off-desktop → invisible, never a different mount")
    func offDesktopInvisible() {
        let p = place(onDesktop: false)
        #expect(!p.visible)
    }

    @Test("zoom round trip returns the identical tile rect (state drives geometry)")
    func zoomRoundTrip() {
        let before = place(zoom: .space)
        let during = place(zoom: .focus("p1"))
        let after = place(zoom: .space)
        #expect(before == after)
        #expect(during.rect != before.rect)
    }

    @Test("focus z sits above the rails and the backdrop; backdrop above the rails")
    func zLayering() {
        #expect(ShellPlacement.focusZ > ShellPlacement.backdropZ)
        #expect(ShellPlacement.backdropZ > ShellPlacement.peekZ)
        #expect(ShellPlacement.peekZ > 10_000)       // park rail
    }
}

/// Tier A for Phase 1 — peeks as units (§9): rail slots, the unified context list, and the
/// simplified preview/settle lifecycle (`pendingPreviewPeek` is deleted — its absence is a
/// compile-time fact; these tests cover the behavior that replaced it).
@Suite("Port Units — peeks (Phase 1)")
struct PortUnitPeekTests {

    private let area = CGSize(width: 1000, height: 800)

    @MainActor
    private func makeState() throws -> (ShellState, AppState) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return (ShellState(appState: state), state)
    }

    @Test("railSlot stacks 210-wide peeks from the top-left")
    func railSlots() {
        let s0 = ShellPlacement.railSlot(0, in: area)
        let s1 = ShellPlacement.railSlot(1, in: area)
        #expect(s0 == CGRect(x: 12, y: 60, width: 210, height: 140))
        #expect(s1.minY == s0.maxY + 12)
        #expect(s1.minX == 12 && s1.width == 210)
    }

    @Test("placement: a peeking port sits in its rail slot at peek z with peek chrome")
    func peekPlacement() {
        let p = ShellPlacement.placement(id: "x", position: CGPoint(x: 700, y: 300),
                                         size: CGSize(width: 460, height: 400), z: 5,
                                         zoom: .space, onDesktop: true, peekIndex: 1,
                                         fallbackIndex: 0, area: area)
        #expect(p.rect == ShellPlacement.railSlot(1, in: area))
        #expect(p.chrome == .peek)
        #expect(p.z == ShellPlacement.peekZ + 1)
        #expect(p.corner == ShellPlacement.peekCorner)
    }

    @Test("placement: focus beats peeking — a previewed peek resizes to the focus rect")
    func focusBeatsPeek() {
        let p = ShellPlacement.placement(id: "x", position: nil,
                                         size: ShellPlacement.peekSize, z: 0,
                                         zoom: .focus("x"), onDesktop: true, peekIndex: 0,
                                         fallbackIndex: 0, area: area)
        #expect(p.rect == ShellPlacement.focusRect(in: area))
        #expect(p.chrome == .focus)
        #expect(p.z == ShellPlacement.focusZ)
    }

    @Test("contextItems: peeks first (rail order), then tiles; peek state wins the dedupe")
    @MainActor
    func contextItemsDedupe() throws {
        let (_, state) = try makeState()
        _ = state.portWindows.registerTiledPort(id: "a", html: "<title>a</title>", spaceId: "s1",
                                                createdBy: nil, title: "a", position: nil)
        _ = state.portWindows.registerTiledPort(id: "b", html: "<title>b</title>", spaceId: "s1",
                                                createdBy: nil, title: "b", position: nil)
        let panels = state.portWindows.panels
        // "b" is BOTH tiled here and peeking (the same-space case) → one item, peek state.
        let peeks = [ShellState.PeekPort(id: "b", spaceId: "s1", spaceName: "s1", isChat: false, title: "b"),
                     ShellState.PeekPort(id: "chatX", spaceId: "chatX", spaceName: "other", isChat: true, title: "other")]
        let items = ShellState.contextItems(tiled: panels, peeks: peeks, allPanels: panels)
        #expect(items.map { $0.id } == ["b", "chatX", "a"])
        #expect(items[0].peek != nil && items[0].panel?.id == "b")   // peek wins, panel attached
        #expect(items[0].peekIndex == 0)
        #expect(items[1].panel == nil && items[1].peek?.isChat == true)   // chat peek, no panel
        #expect(items[2].peek == nil)                                     // plain tile
    }

    @Test("contextItems: a port peek whose panel vanished is dropped (no dead unit)")
    func contextItemsDropsDeadPeek() {
        let peeks = [ShellState.PeekPort(id: "ghost", spaceId: "s2", spaceName: "s2", isChat: false, title: "g")]
        let items = ShellState.contextItems(tiled: [], peeks: peeks, allPanels: [])
        #expect(items.isEmpty)
    }

    @Test("previewPeek leaves the peek staged (seen) and focuses it — no removal, no stash")
    @MainActor
    func previewKeepsPeekStaged() throws {
        let (shell, state) = try makeState()
        let space = Space.create(name: "main"); let other = Space.create(name: "b")
        state.spaces = [space, other]; state.currentSpace = space
        _ = state.portWindows.registerTiledPort(id: "pk", html: "<title>pk</title>", spaceId: other.id,
                                                createdBy: "someone", title: "pk", position: nil)
        shell.handlePortCreated(id: "pk", spaceId: other.id, title: "pk")
        #expect(shell.peekingPorts.count == 1)

        shell.previewPeek(shell.peekingPorts[0])
        #expect(shell.zoom == .focus("pk"))
        #expect(shell.peekingPorts.count == 1)               // still staged — resized in place
        #expect(shell.peekingPorts[0].seen)
        #expect(shell.isDesktopUnit("pk"))                   // focus stays in-desktop (no overlay)
    }

    @Test("settleAfterPreview arms the countdown for seen peeks only")
    @MainActor
    func settleArmsCountdown() throws {
        let (shell, state) = try makeState()
        let space = Space.create(name: "main"); let other = Space.create(name: "b")
        state.spaces = [space, other]; state.currentSpace = space
        _ = state.portWindows.registerTiledPort(id: "s1", html: "<title>s1</title>", spaceId: other.id,
                                                createdBy: "someone", title: "s1", position: nil)
        _ = state.portWindows.registerTiledPort(id: "s2", html: "<title>s2</title>", spaceId: other.id,
                                                createdBy: "someone", title: "s2", position: nil)
        shell.handlePortCreated(id: "s1", spaceId: other.id, title: "s1")
        shell.handlePortCreated(id: "s2", spaceId: other.id, title: "s2")

        shell.previewPeek(shell.peekingPorts[0])             // s1 seen
        shell.settleAfterPreview()
        #expect(shell.peekRemaining["s1"] != nil)            // counting down
        #expect(shell.peekRemaining["s2"] == nil)            // never previewed — no countdown
    }

    @Test("same-space birth peeks (self-suppression fixed); the user's own spawn does not")
    @MainActor
    func sameSpacePeeks() throws {
        let (shell, state) = try makeState()
        let space = Space.create(name: "main")
        state.spaces = [space]; state.currentSpace = space

        shell.handlePortCreated(id: "remote1", spaceId: space.id, title: "from a companion")
        #expect(shell.peekingPorts.map(\.id) == ["remote1"])   // same space, still surfaces

        shell.noteUserSpawn("mine1")
        shell.handlePortCreated(id: "mine1", spaceId: space.id, title: "dock spawn")
        #expect(!shell.peekingPorts.contains { $0.id == "mine1" })   // you made it — no peek

        shell.handlePortCreated(id: "remote1", spaceId: space.id, title: "dup")
        #expect(shell.peekingPorts.count == 1)                 // deduped by id
    }

    @Test("keepPeek adopts: entry cleared, port surfaced; arrange only when asked")
    @MainActor
    func keepAdopts() throws {
        let (shell, state) = try makeState()
        let space = Space.create(name: "main"); let other = Space.create(name: "b")
        state.spaces = [space, other]; state.currentSpace = space
        _ = state.portWindows.registerTiledPort(id: "kp", html: "<title>kp</title>", spaceId: other.id,
                                                createdBy: "someone", title: "kp", position: nil)
        shell.handlePortCreated(id: "kp", spaceId: other.id, title: "kp")
        let bump = shell.arrangeBump

        shell.keepPeek(shell.peekingPorts[0], arrange: false)   // drag-to-keep: hand-placed
        #expect(shell.peekingPorts.isEmpty)
        #expect(state.portWindows.panels.first { $0.id == "kp" }?.adoptedSpaceIds == [space.id])
        #expect(shell.arrangeBump == bump)                      // no re-grid on a hand drop
        #expect(shell.isDesktopUnit("kp"))                      // now a tile of this desktop
    }
}

/// Tier A for Phase 2 — collapse/cleanup (§9): focus can ONLY target desktop units (the
/// focus overlay + `ShellFocusContent` are deleted — a compile-time fact), the shell has no
/// "floating" presentation (undock lands a tile; legacy rows normalize at restore), and
/// `move` re-homes a port by rewriting its persisted `spaceId`.
@Suite("Port Units — collapse (Phase 2)")
struct PortUnitCollapseTests {

    @MainActor
    private func makeState() throws -> (ShellState, AppState) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return (ShellState(appState: state), state)
    }

    @Test("zoomIn skips a non-unit selection and falls back to a desktop unit")
    @MainActor
    func zoomInSkipsNonUnits() throws {
        let (shell, state) = try makeState()
        let space = Space.create(name: "main")
        state.spaces = [space]; state.currentSpace = space
        _ = state.portWindows.registerTiledPort(id: "t1", html: "<title>t1</title>", spaceId: space.id,
                                                createdBy: nil, title: "t1", position: nil)
        _ = state.portWindows.registerTiledPort(id: "p1", html: "<title>p1</title>", spaceId: space.id,
                                                createdBy: nil, title: "p1", position: nil)
        state.portWindows.park(id: "p1")                        // p1 leaves the desktop

        shell.selectedTileId = "p1"                             // stale selection on a parked port
        shell.zoomIn()
        #expect(shell.zoom == .focus("t1"))                     // fell back to a real unit
    }

    @Test("zoomIn with no units stays at the space rung (never a dead focus)")
    @MainActor
    func zoomInNoUnitsStays() throws {
        let (shell, state) = try makeState()
        let space = Space.create(name: "main")
        state.spaces = [space]; state.currentSpace = space
        _ = state.portWindows.registerTiledPort(id: "p1", html: "<title>p1</title>", spaceId: space.id,
                                                createdBy: nil, title: "p1", position: nil)
        state.portWindows.park(id: "p1")                        // the only port is parked

        shell.zoomIn()
        #expect(shell.zoom == .space)
    }

    @Test("exitFocusIfGone: focus snaps to space when the focused unit leaves the desktop")
    @MainActor
    func exitFocusWhenUnitGone() throws {
        let (shell, state) = try makeState()
        let space = Space.create(name: "main")
        state.spaces = [space]; state.currentSpace = space
        _ = state.portWindows.registerTiledPort(id: "f1", html: "<title>f1</title>", spaceId: space.id,
                                                createdBy: nil, title: "f1", position: nil)
        shell.zoom = .focus("f1")

        shell.exitFocusIfGone()
        #expect(shell.zoom == .focus("f1"))                     // still a unit — untouched

        state.portWindows.close("f1")                           // closed out from under the focus
        shell.exitFocusIfGone()
        #expect(shell.zoom == .space)
    }

    @Test("shell undock lands a tile — there is no floating presentation in the shell")
    @MainActor
    func shellUndockTiles() throws {
        let (_, state) = try makeState()
        _ = state.portWindows.registerInlinePort(id: "i1", html: "<title>i1</title>", spaceId: "s1",
                                                 createdBy: nil, title: "i1", anchorMessageId: nil)

        state.portWindows.undockInline(id: "i1", in: CGSize(width: 800, height: 600))
        let p = try #require(state.portWindows.panels.first { $0.id == "i1" })
        #expect(p.presentation == "tiled")
        #expect(p.size.width >= 200 && p.size.height >= 150)    // outgrew its 100×100 inline seed
    }

    @Test("move re-homes a port: it renders in the new space, not the old")
    @MainActor
    func moveRehomes() throws {
        let (shell, state) = try makeState()
        let a = Space.create(name: "a"); let b = Space.create(name: "b")
        state.spaces = [a, b]; state.currentSpace = a
        _ = state.portWindows.registerTiledPort(id: "m1", html: "<title>m1</title>", spaceId: a.id,
                                                createdBy: nil, title: "m1", position: nil)
        #expect(shell.isDesktopUnit("m1"))

        shell.movePort(id: "m1", toSpace: b.id)
        #expect(!shell.isDesktopUnit("m1"))                     // gone from A's desktop
        #expect(state.portWindows.panels.first { $0.id == "m1" }?.spaceId == b.id)
        #expect(state.portWindows.panels.first { $0.id == "m1" }?.bridge.spaceId == b.id)

        state.currentSpace = b
        #expect(shell.isDesktopUnit("m1"))                      // native in B
    }

    @Test("move exits a stale focus and clears peek/adoption residue")
    @MainActor
    func moveClearsResidue() throws {
        let (shell, state) = try makeState()
        let a = Space.create(name: "a"); let b = Space.create(name: "b")
        state.spaces = [a, b]; state.currentSpace = a
        _ = state.portWindows.registerTiledPort(id: "m2", html: "<title>m2</title>", spaceId: b.id,
                                                createdBy: "someone", title: "m2", position: nil)
        shell.handlePortCreated(id: "m2", spaceId: b.id, title: "m2")   // peeks into A
        shell.previewPeek(shell.peekingPorts[0])                        // focused
        #expect(shell.zoom == .focus("m2"))

        shell.movePort(id: "m2", toSpace: b.id)                 // re-home while focused
        #expect(shell.zoom == .space)                           // focus exited (unit left A)
        #expect(shell.peekingPorts.isEmpty)
        #expect(state.portWindows.panels.first { $0.id == "m2" }?.adoptedSpaceIds.isEmpty == true)
    }

    @Test("move survives a restart (spaceId is the persisted column)")
    @MainActor
    func movePersists() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let shell = ShellState(appState: state)
        let a = Space.create(name: "a"); let b = Space.create(name: "b")
        state.spaces = [a, b]; state.currentSpace = a
        _ = state.portWindows.registerTiledPort(id: "m3", html: "<title>m3</title>", spaceId: a.id,
                                                createdBy: nil, title: "m3", position: nil)
        shell.movePort(id: "m3", toSpace: b.id)

        let restored = try db.fetchPortPanels()
        #expect(restored.first { $0.id == "m3" }?.spaceId == b.id)
    }

    @Test("browser page rect = unit content minus the address bar")
    func browserContentRect() {
        let unit = ShellPlacement.focusRect(in: CGSize(width: 1000, height: 800))
        #expect(ShellPlacement.browserBarH == 34)
        #expect(unit.height - ShellPlacement.browserBarH > 0)
    }
}

/// Tier A for Phase 3 — adoption persistence (§9): adoption is a fact about the PORT
/// (`PortPanel.adoptedSpaceIds`, v38 column), not the session — a kept peek survives
/// `clearOpenDMs` (space switch) and a restart; ✕-detach un-persists; `move` strips only
/// the new home from adopters; `panels(in:)` is the facade query (native ∪ adopted).
@Suite("Port Units — adoption persistence (Phase 3)")
struct PortUnitAdoptionTests {

    @MainActor
    private func makeState(db: DatabaseService? = nil) throws -> (ShellState, AppState, DatabaseService) {
        let database = try db ?? DatabaseService(inMemory: true)
        let state = AppState(db: database)
        return (ShellState(appState: state), state, database)
    }

    /// A port native to `home`, peeked into and KEPT on the current desktop.
    @MainActor
    private func adoptPort(_ id: String, home: Space, shell: ShellState, state: AppState) {
        _ = state.portWindows.registerTiledPort(id: id, html: "<title>\(id)</title>", spaceId: home.id,
                                                createdBy: "someone", title: id, position: nil)
        shell.handlePortCreated(id: id, spaceId: home.id, title: id)
        shell.keepPeek(shell.peekingPorts.first { $0.id == id }!)
    }

    @Test("keepPeek adoption survives clearOpenDMs (the space-switch wipe)")
    @MainActor
    func adoptionSurvivesSwitch() throws {
        let (shell, state, _) = try makeState()
        let a = Space.create(name: "a"); let b = Space.create(name: "b")
        state.spaces = [a, b]; state.currentSpace = a
        adoptPort("ad1", home: b, shell: shell, state: state)
        #expect(shell.isDesktopUnit("ad1"))

        shell.clearOpenDMs()                                    // what a space switch runs
        #expect(shell.isDesktopUnit("ad1"))                     // still on A's desktop
        #expect(shell.peekingPorts.isEmpty)                     // peeks stayed transient
    }

    @Test("adoption survives a restart (restoreFromDB round-trip)")
    @MainActor
    func adoptionSurvivesRestart() throws {
        let (shell, state, db) = try makeState()
        let a = Space.create(name: "a"); let b = Space.create(name: "b")
        state.spaces = [a, b]; state.currentSpace = a
        adoptPort("ad2", home: b, shell: shell, state: state)

        let state2 = AppState(db: db)                           // "relaunch" over the same DB
        state2.portWindows.restoreFromDB(appState: state2)
        let restored = try #require(state2.portWindows.panels.first { $0.id == "ad2" })
        #expect(restored.adoptedSpaceIds == [a.id])
        #expect(restored.spaceId == b.id)                       // home unchanged

        let shell2 = ShellState(appState: state2)
        state2.spaces = [a, b]; state2.currentSpace = a
        #expect(shell2.isDesktopUnit("ad2"))                    // back on A's desktop
    }

    @Test("✕-detach unadopts and persists (the port lives on at home)")
    @MainActor
    func detachUnpersists() throws {
        let (shell, state, db) = try makeState()
        let a = Space.create(name: "a"); let b = Space.create(name: "b")
        state.spaces = [a, b]; state.currentSpace = a
        adoptPort("ad3", home: b, shell: shell, state: state)
        let panel = try #require(state.portWindows.panels.first { $0.id == "ad3" })

        shell.dismissTile(panel)                                // adopted → detach, not close
        let after = try #require(state.portWindows.panels.first { $0.id == "ad3" })
        #expect(after.adoptedSpaceIds.isEmpty)
        #expect(!shell.isDesktopUnit("ad3"))                    // off A's desktop
        let rows = try db.fetchPortPanels()
        #expect(rows.first { $0.id == "ad3" }?.adoptedSpaceIds == nil)   // un-persisted
    }

    @Test("move strips only the NEW home from adopters (native beats adopted)")
    @MainActor
    func moveStripsNewHomeOnly() throws {
        let (_, state, _) = try makeState()
        let a = Space.create(name: "a"); let b = Space.create(name: "b"); let c = Space.create(name: "c")
        state.spaces = [a, b, c]; state.currentSpace = a
        _ = state.portWindows.registerTiledPort(id: "mv", html: "<title>mv</title>", spaceId: a.id,
                                                createdBy: nil, title: "mv", position: nil)
        state.portWindows.adopt(id: "mv", into: b.id)
        state.portWindows.adopt(id: "mv", into: c.id)

        state.portWindows.move(id: "mv", toSpace: b.id)         // B becomes home
        let p = try #require(state.portWindows.panels.first { $0.id == "mv" })
        #expect(p.spaceId == b.id)
        #expect(p.adoptedSpaceIds == [c.id])                    // C's adoption preserved
    }

    @Test("adopt is idempotent and never adopts a port into its own home")
    @MainActor
    func adoptGuards() throws {
        let (_, state, _) = try makeState()
        _ = state.portWindows.registerTiledPort(id: "g1", html: "<title>g1</title>", spaceId: "home",
                                                createdBy: nil, title: "g1", position: nil)
        state.portWindows.adopt(id: "g1", into: "home")         // own home — refused
        state.portWindows.adopt(id: "g1", into: "s2")
        state.portWindows.adopt(id: "g1", into: "s2")           // dup — refused
        #expect(state.portWindows.panels.first { $0.id == "g1" }?.adoptedSpaceIds == ["s2"])
    }

    @Test("panels(in:) = native plus adopted; close drops the port everywhere")
    @MainActor
    func panelsInQuery() throws {
        let (_, state, _) = try makeState()
        _ = state.portWindows.registerTiledPort(id: "q1", html: "<title>q1</title>", spaceId: "sA",
                                                createdBy: nil, title: "q1", position: nil)
        _ = state.portWindows.registerTiledPort(id: "q2", html: "<title>q2</title>", spaceId: "sB",
                                                createdBy: nil, title: "q2", position: nil)
        state.portWindows.adopt(id: "q2", into: "sA")

        #expect(state.portWindows.panels(in: "sA").map(\.id).sorted() == ["q1", "q2"])
        #expect(state.portWindows.panels(in: "sB").map(\.id) == ["q2"])
        state.portWindows.close("q2")
        #expect(state.portWindows.panels(in: "sA").map(\.id) == ["q1"])
        #expect(state.portWindows.panels(in: "sB").isEmpty)
    }

    @Test("a parked port restores parked (presentation round-trips)")
    @MainActor
    func parkedRestoresParked() throws {
        let (_, state, db) = try makeState()
        _ = state.portWindows.registerTiledPort(id: "pk1", html: "<title>pk1</title>", spaceId: "sA",
                                                createdBy: nil, title: "pk1", position: nil)
        state.portWindows.park(id: "pk1")

        let state2 = AppState(db: db)
        state2.portWindows.restoreFromDB(appState: state2)
        #expect(state2.portWindows.panels.first { $0.id == "pk1" }?.presentation == "parked")
    }
}
