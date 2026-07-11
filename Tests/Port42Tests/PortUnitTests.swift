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
        #expect(shell.surfacedPortIds.contains("kp"))
        #expect(shell.arrangeBump == bump)                      // no re-grid on a hand drop
        #expect(shell.isDesktopUnit("kp"))                      // now a tile of this desktop
    }
}
