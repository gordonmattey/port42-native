import Testing
import Foundation
import CoreGraphics
@testable import Port42Lib

/// Backlog 1.1, Step 1 (`docs/plan-port-presentation-state.md`): the pure presentation mapping —
/// the port-facing state derived from the same desktop-membership + peek-index decision `contextItems`
/// makes, with the richer visibility gates layered on top. Headless like `PortUnitTests` (placement):
/// no window, no AppState. The emit funnel + JS surface are Steps 2-3.
@Suite("Port Presentation — mapping (Step 1)")
struct PortPresentationTests {

    private let area = CGSize(width: 1000, height: 800)   // focusRect → 780×640 (see PortUnitTests)
    private let size = CGSize(width: 460, height: 400)

    /// The pure core with sensible defaults — an on-desktop, non-peeking tile at `.space`.
    private func p(id: String = "p1",
                   isBackground: Bool = false,
                   mode: String = "tiled",
                   zoom: ShellState.Zoom = .space,
                   onDesktop: Bool = true,
                   isPeeking: Bool = false) -> PortPresentation {
        ShellState.presentation(id: id, isBackground: isBackground, mode: mode, size: size,
                                zoom: zoom, onDesktop: onDesktop, isPeeking: isPeeking, area: area)
    }

    // MARK: - The six states

    @Test("background: off the desktop, view unmounts → not visible, 0×0")
    func background() {
        let r = p(isBackground: true)
        #expect(r.state == .background)
        #expect(!r.visible)
        #expect(r.w == 0 && r.h == 0)
    }

    @Test("parked: a rail chip → not visible, 0×0")
    func parked() {
        let r = p(mode: "parked")
        #expect(r.state == .parked)
        #expect(!r.visible)
        #expect(r.w == 0 && r.h == 0)
    }

    @Test("inline: hosted in a chat card → visible at content size (v1 conservative)")
    func inline() {
        let r = p(mode: "inline")
        #expect(r.state == .inline)
        #expect(r.visible)
        #expect(r.w == 460 && r.h == 400)
    }

    @Test("off-desktop tile (another space) → tiled, not visible, 0×0")
    func offDesktop() {
        let r = p(onDesktop: false)
        #expect(r.state == .tiled)
        #expect(!r.visible)
        #expect(r.w == 0 && r.h == 0)
    }

    @Test("peek on the current desktop at .space → visible at peek size (210×140)")
    func peekVisible() {
        let r = p(isPeeking: true)
        #expect(r.state == .peek)
        #expect(r.visible)
        #expect(r.w == 210 && r.h == 140)
    }

    @Test("plain tile on the current desktop at .space → visible at its own size")
    func tileVisible() {
        let r = p()
        #expect(r.state == .tiled)
        #expect(r.visible)
        #expect(r.w == 460 && r.h == 400)
    }

    @Test("focused (this port) → visible at the focus card size (0.78×0.8 of area)")
    func focused() {
        let r = p(zoom: .focus("p1"))
        #expect(r.state == .focused)
        #expect(r.visible)
        #expect(r.w == 780 && r.h == 640)
    }

    // MARK: - Precedence

    @Test("background wins over parked (both set) — the mode gates run in order")
    func backgroundOverParked() {
        #expect(p(isBackground: true, mode: "parked").state == .background)
    }

    @Test("background wins over inline")
    func backgroundOverInline() {
        let r = p(isBackground: true, mode: "inline")
        #expect(r.state == .background)
        #expect(!r.visible)
    }

    @Test("focus wins over peek — a focused port that is also peeking is focused, not peek")
    func focusOverPeek() {
        let r = p(zoom: .focus("p1"), isPeeking: true)
        #expect(r.state == .focused)
        #expect(r.visible)
        #expect(r.w == 780 && r.h == 640)
    }

    // MARK: - Zoom occlusion (the "strictly richer than placement.visible" part)

    @Test("galaxy: the desktop is not shown → a tile is not visible (mode still tiled)")
    func galaxyTileHidden() {
        let r = p(zoom: .galaxy)
        #expect(r.state == .tiled)
        #expect(!r.visible)
        #expect(r.w == 0 && r.h == 0)
    }

    @Test("galaxy: a peek is not visible either (mode still peek)")
    func galaxyPeekHidden() {
        let r = p(zoom: .galaxy, isPeeking: true)
        #expect(r.state == .peek)
        #expect(!r.visible)
    }

    @Test("another port's focus: this tile is behind the backdrop → not visible")
    func otherFocusTileHidden() {
        let r = p(zoom: .focus("someone-else"))
        #expect(r.state == .tiled)
        #expect(!r.visible)
    }

    @Test("another port's focus: a peek is behind the backdrop too → not visible")
    func otherFocusPeekHidden() {
        let r = p(zoom: .focus("someone-else"), isPeeking: true)
        #expect(r.state == .peek)
        #expect(!r.visible)
    }

    // MARK: - Invariants

    @Test("w,h are 0,0 whenever not visible (structural, whatever size is passed)")
    func zeroSizeWhenHidden() {
        for r in [p(isBackground: true), p(mode: "parked"), p(onDesktop: false),
                  p(zoom: .galaxy), p(zoom: .focus("other"))] {
            #expect(!r.visible)
            #expect(r.w == 0 && r.h == 0)
        }
    }

    @Test("the pure mapping never attaches a reason (that is a diff-time annotation)")
    func noReasonFromMapping() {
        #expect(p().reason == nil)
        #expect(p(zoom: .focus("p1")).reason == nil)
        #expect(p(mode: "parked").reason == nil)
    }

    @Test("jsonObject carries state/visible/w/h and omits a nil reason")
    func jsonShape() {
        let o = p(zoom: .focus("p1")).jsonObject
        #expect(o["state"] as? String == "focused")
        #expect(o["visible"] as? Bool == true)
        #expect(o["w"] as? Int == 780)
        #expect(o["h"] as? Int == 640)
        #expect(o["reason"] == nil)
        #expect(p().with(reason: "space-switch").jsonObject["reason"] as? String == "space-switch")
    }

    /// Fixed inventory: every `State` must be producible by the mapping. `switch` over `allCases`
    /// so adding a new placement mode fails to compile here until its mapping is defined and covered.
    @Test("every presentation state is reachable from the pure mapping (fixed inventory)")
    func fixedInventory() {
        for state in PortPresentation.State.allCases {
            let produced: PortPresentation
            switch state {
            case .background: produced = p(isBackground: true)
            case .parked:     produced = p(mode: "parked")
            case .inline:     produced = p(mode: "inline")
            case .tiled:      produced = p()
            case .peek:       produced = p(isPeeking: true)
            case .focused:    produced = p(zoom: .focus("p1"))
            }
            #expect(produced.state == state)
        }
    }

    // MARK: - The panel + contextItem convenience (consumes the shared membership decision)

    @MainActor
    @Test("presentation(for:item:) forwards item==nil → off-desktop, item.peek != nil → peek")
    func conveniencesForwarding() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let bridge = PortBridge(appState: state, spaceId: "s1", messageId: "p1")
        let panel = PortPanel(id: "p1", udid: "p1", html: "<div/>", bridge: bridge,
                              spaceId: "s1", createdBy: nil, messageId: "p1", size: size)

        // No context item ⇒ not staged on this desktop.
        let off = ShellState.presentation(for: panel, zoom: .space, item: nil, area: area)
        #expect(off.state == .tiled && !off.visible)

        // A plain-tile context item ⇒ visible tile at .space.
        let tileItem = ShellState.PortContextItem(id: "p1", panel: panel, peek: nil, peekIndex: nil)
        let tile = ShellState.presentation(for: panel, zoom: .space, item: tileItem, area: area)
        #expect(tile.state == .tiled && tile.visible && tile.w == 460)

        // A peek context item ⇒ peek.
        let peek = ShellState.PeekPort(id: "p1", spaceId: "s1", spaceName: "s1", isChat: false, title: "t")
        let peekItem = ShellState.PortContextItem(id: "p1", panel: panel, peek: peek, peekIndex: 0)
        let peeking = ShellState.presentation(for: panel, zoom: .space, item: peekItem, area: area)
        #expect(peeking.state == .peek && peeking.visible && peeking.w == 210)
    }
}

/// Step 2: the JS surface. The `port42.presentation()` getter resolves through the shell's computed
/// value (invariant #5: getter == pure fn), and the registry dispatch returns that same snapshot.
@Suite("Port Presentation — getter & dispatch (Step 2)")
struct PortPresentationGetterTests {

    @MainActor
    private func world() throws -> (ShellState, AppState, String) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let shell = ShellState(appState: state)            // wires state.shell = shell
        let space = Space.create(name: "s")
        state.spaces = [space]; state.currentSpace = space
        shell.lastDesktopArea = CGSize(width: 1000, height: 800)
        let bridge = PortBridge(appState: state, spaceId: space.id, messageId: "p1")
        let panel = PortPanel(id: "p1", udid: "p1", html: "<div/>", bridge: bridge,
                              spaceId: space.id, createdBy: nil, messageId: "p1",
                              size: CGSize(width: 460, height: 400))
        state.portWindows.panels.append(panel)
        return (shell, state, space.id)
    }

    @Test("presentation(forPortId:) equals the pure mapping over the live shell state")
    @MainActor
    func getterMatchesPureFn() throws {
        let (shell, state, _) = try world()
        let panel = try #require(state.portWindows.panels.first)
        let item = shell.contextItems.first { $0.id == "p1" }
        let expected = ShellState.presentation(for: panel, zoom: shell.zoom,
                                               item: item, area: shell.lastDesktopArea)
        #expect(shell.presentation(forPortId: "p1") == expected)
        // A staged tile on the current desktop at .space → visible at its own size.
        #expect(shell.presentation(forPortId: "p1")?.state == .tiled)
        #expect(shell.presentation(forPortId: "p1")?.visible == true)
        #expect(shell.presentation(forPortId: "p1")?.w == 460)
    }

    @Test("presentation(forPortId:) is nil for an unknown port id")
    @MainActor
    func getterUnknownNil() throws {
        let (shell, _, _) = try world()
        #expect(shell.presentation(forPortId: "nope") == nil)
    }

    @Test("focus tracks through the getter: focus the port → focused at the card size")
    @MainActor
    func getterFollowsFocus() throws {
        let (shell, _, _) = try world()
        shell.zoom = .focus("p1")
        let snap = try #require(shell.presentation(forPortId: "p1"))
        #expect(snap.state == .focused)
        #expect(snap.visible)
        #expect(snap.w == 780 && snap.h == 640)          // 0.78×0.8 of 1000×800
    }

    @Test("the registry method returns the shell's snapshot for the calling port")
    @MainActor
    func dispatchReturnsSnapshot() async throws {
        let (shell, state, sid) = try world()
        let expected = try #require(shell.presentation(forPortId: "p1"))
        let p = Principal(id: "p1", displayName: "selftest", spaceId: sid, kind: .port, portId: "p1")
        let v = try await state.runBridgeMethod("presentation", principal: p, args: BridgeArgs([:]))
        #expect(v == .fromJSONObject(expected.jsonObject))
    }

    @Test("the registry method falls back to a visible tile for an unknown port")
    @MainActor
    func dispatchUnknownFallback() async throws {
        let (_, state, sid) = try world()
        let p = Principal(id: "ghost", displayName: "selftest", spaceId: sid, kind: .port, portId: "ghost")
        let v = try await state.runBridgeMethod("presentation", principal: p, args: BridgeArgs([:]))
        let fallback = PortPresentation(state: .tiled, visible: true, size: ShellState.defaultTileSize)
        #expect(v == .fromJSONObject(fallback.jsonObject))
    }
}
