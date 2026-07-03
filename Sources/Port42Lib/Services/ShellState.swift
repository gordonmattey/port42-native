import Foundation
import CoreGraphics
import SwiftUI
import Combine

/// SHELL — S2 spine. The shell-only UI state (zoom ladder, selection, pinch latch) layered over
/// `AppState`. It READS `AppState` (spaces, ports, current space); it never owns or duplicates
/// ports/spaces/companions. Pure state so the S2 gate (`ShellStateTests`) runs headlessly — no
/// window, no webview. Mirrors the prototype's `Shell` zoom logic (`prototypes/p42shell`), the
/// canonical interaction reference (`spec-shell-reimplementation.md` §3.2 / §4 "Zoom ladder").
@MainActor
public final class ShellState: ObservableObject {

    /// The zoom ladder rungs: galaxy (all spaces) ↔ space (this desktop) ↔ focus (one port immersive).
    public enum Zoom: Equatable {
        case galaxy
        case space
        case focus(String)   // focused port udid
    }

    @Published public var zoom: Zoom = .space
    /// The highlighted tile zoom-in targets (hover/click); nil ⇒ fall back to the first port.
    @Published public var selectedPortId: String?
    /// The highlighted desktop tile (chat or a tiled port) — hover/click; what ⌘↓ focuses.
    @Published public var selectedTileId: String?
    /// Bumped to re-trigger the desktop grid layout (the Chrome "arrange" + every spawn).
    @Published public var arrangeBump: Int = 0
    /// Exposé (Tab): a TEMPORARY arrange — every tile spreads to the fit grid for selection, without
    /// overwriting its real position. Picking a tile (or Tab/Esc) exits and tiles snap back.
    @Published public var exposeActive: Bool = false

    /// The item whose settings box is open (long-press a galaxy world / companion). nil = closed.
    /// A shared overlay hosts rename / accent / delete; `.companion` lands with S4.
    public enum SettingsTarget: Equatable { case space(String), companion(String) }
    @Published public var settingsTarget: SettingsTarget?

    /// Show the New Companion form as a shell overlay (not a macOS sheet). Set from the dock's ＋ menu.
    @Published public var showNewCompanion: Bool = false
    /// The global Settings panel (the app's SignOutSheet) surfaced as a shell overlay.
    @Published public var showSettings: Bool = false
    /// The Token Usage panel (UsageSheet) surfaced as a shell overlay.
    @Published public var showUsage: Bool = false
    /// Which space-world the mouse is over in galaxy (zoom-in dives into it).
    @Published public var galaxyHover: Int?
    /// Normalized cursor position (0…1) for the ambient background parallax (prototype's `mouse`).
    @Published public var mouse: CGPoint = CGPoint(x: 0.5, y: 0.5)

    private let appState: AppState
    private var notifSink: AnyCancellable?
    private var portSink: AnyCancellable?
    public init(appState: AppState) {
        self.appState = appState
        // Notifications (§8b): a non-current space gaining unread activity (a companion reply / chat)
        // raises a peeking chat notification…
        notifSink = appState.$unreadCounts
            .receive(on: RunLoop.main)
            .sink { [weak self] counts in self?.refreshNotifications(from: counts) }
        // …and a TILED port BORN in another space raises a peeking port notification — the live port
        // from elsewhere, clickable to surface here (the heart of §8b).
        portSink = appState.portWindows.portCreated
            .receive(on: RunLoop.main)
            .sink { [weak self] p in self?.raisePortNotification(id: p.id, spaceId: p.spaceId, title: p.title) }
    }

    // MARK: - Notifications (§8b) — a notification IS the live port, PEEKING as a small tile here.
    // Not a card: the actual port from another space attaches to your current desktop. Zoom into it →
    // it STICKS in your space (adopted); ✕ detaches it (it lives on in its home space).

    public struct PeekPort: Identifiable, Equatable {
        public let id: String        // portId for a port; spaceId for a space's chat
        public let spaceId: String
        public let spaceName: String
        public let isChat: Bool
        public let title: String
    }
    @Published public var peekingPorts: [PeekPort] = []
    /// Foreign ports ADOPTED onto this desktop (a peek you zoomed into sticks here), by port id.
    @Published public var surfacedPortIds: Set<String> = []

    private var lastUnread: [String: Int] = [:]
    private var notifSeeded = false

    private func spaceLabel(_ sid: String) -> String {
        appState.spaces.first(where: { $0.id == sid })?.name
            ?? appState.companions(forSpace: sid).first?.displayName ?? "space"
    }

    /// New chat activity in another space → that space's chat peeks here (deduped per space). Seeds the
    /// baseline silently so the unread backlog doesn't peek on launch; only an INCREASE peeks.
    private func refreshNotifications(from counts: [String: Int]) {
        defer { lastUnread = counts }
        guard notifSeeded else { notifSeeded = true; return }
        let currentId = appState.currentSpace?.id
        for (spaceId, count) in counts {
            if count == 0 || spaceId == currentId || openDMSpaceIds.contains(spaceId) {
                peekingPorts.removeAll { $0.isChat && $0.spaceId == spaceId }
                continue
            }
            let increased = count > (lastUnread[spaceId] ?? 0)
            guard increased, !peekingPorts.contains(where: { $0.isChat && $0.spaceId == spaceId }) else { continue }
            let name = spaceLabel(spaceId)
            peekingPorts.append(PeekPort(id: spaceId, spaceId: spaceId, spaceName: name, isChat: true, title: name))
        }
    }

    /// A tiled port born in another space → it peeks here (deduped by port id).
    private func raisePortNotification(id: String, spaceId: String?, title: String) {
        guard let sid = spaceId, sid != appState.currentSpace?.id else { return }
        guard !peekingPorts.contains(where: { $0.id == id }), !surfacedPortIds.contains(id) else { return }
        peekingPorts.append(PeekPort(id: id, spaceId: sid, spaceName: spaceLabel(sid), isChat: false, title: title))
    }

    /// Zoom into a peek → it STICKS in your current space (adopted) and you focus it. Zooming back out
    /// leaves you in your space with the port now a tile here.
    public func adoptPeek(_ peek: PeekPort) {
        peekingPorts.removeAll { $0.id == peek.id }
        if peek.isChat {
            surfaceSpaceChat(spaceId: peek.spaceId, spaceName: peek.spaceName)
            appState.lastReadDates[peek.spaceId] = Date()
            if let panel = appState.portWindows.panels.first(where: { $0.isChatPort && $0.spaceId == peek.spaceId }) {
                withAnimation(.spring(response: 0.4)) { zoom = .focus(panel.id) }
            }
        } else {
            surfacedPortIds.insert(peek.id)
            bringToFront(peek.id)
            arrangeBump += 1
            withAnimation(.spring(response: 0.4)) { zoom = .focus(peek.id) }
        }
    }

    /// ✕ a peek → dismiss it from your desktop; it lives on in its home space.
    public func dismissPeek(_ peek: PeekPort) {
        peekingPorts.removeAll { $0.id == peek.id }
    }

    /// Surface ANY space's chat as a tile on the current desktop (generalizes `openDM`).
    public func surfaceSpaceChat(spaceId: String, spaceName: String) {
        guard spaceId != appState.currentSpace?.id else { return }
        appState.activateSpaceMessages(spaceId: spaceId)
        if !openDMSpaceIds.contains(spaceId) { openDMSpaceIds.append(spaceId) }
        appState.portWindows.revealChat(spaceId: spaceId, spaceName: spaceName)
        if let panel = appState.portWindows.panels.first(where: { $0.isChatPort && $0.spaceId == spaceId }) {
            bringToFront(panel.id)
        }
        arrangeBump += 1
    }

    // MARK: Per-space accent theme (prototype's SpaceDef.accent)

    /// The per-space accent palette (mirrors the prototype's space colors), as hex. **Keep in sync
    /// with the v37 migration backfill in `DatabaseService`.** A space's color is assigned at
    /// creation (`createSpace`) and stored on `Space.accent` for life (spec decision #1) — the
    /// palette is only the source for *new* assignments and the legacy fallback.
    public static let paletteHex: [String] = [
        "#00D4AA",  // teal #00d4aa (prototype's base)
        "#FF6BB2",  // pink
        "#FFBD33",  // gold
        "#66C7FF",  // blue
        "#73E68C",  // light green
        "#9E47FA",  // purple
        "#4DD9CC",  // teal 2
    ]
    static let palette: [Color] = paletteHex.map { Color(shellHex: $0) ?? .teal }

    /// The color a *newly created* space at position `count` should get (before it's added). Stored
    /// permanently on the space, so it never shifts when other spaces come and go.
    public static func accentHex(forNewSpaceAt count: Int) -> String {
        paletteHex[count % paletteHex.count]
    }

    /// A per-space accent. Reads the space's **stored** hex (assigned for life at creation); for a
    /// space with no stored accent (predates v37 / remote) falls back to a **stable id-hash** — never
    /// list position, so colors never reshuffle when spaces are added or deleted.
    public func accent(for space: Space) -> Color {
        if let hex = space.accent, let c = Color(shellHex: hex) { return c }
        let h = space.id.utf8.reduce(0) { $0 &+ Int($1) }
        return Self.palette[h % Self.palette.count]
    }

    /// The current space's accent (falls back to the base accent).
    public var accent: Color {
        guard let s = appState.currentSpace else { return Self.palette[0] }
        return accent(for: s)
    }

    // MARK: Read-through helpers (never duplicate AppState)

    /// Non-background port udids on the current space, in panel order.
    public var currentSpacePortIds: [String] {
        guard let sid = appState.currentSpace?.id else { return [] }
        return appState.portWindows.panels
            .filter { $0.spaceId == sid && !$0.isBackground }
            .map { $0.udid }
    }

    /// What focus zooms into: the explicit selection (if still on this space) else the first port.
    public var selectedPort: String? {
        if let s = selectedPortId, currentSpacePortIds.contains(s) { return s }
        return currentSpacePortIds.first
    }

    // MARK: Zoom ladder (one rung per call; clamps at the ends)

    /// ⌘↑ / pinch-out — step UP toward the galaxy. Clamps at galaxy (the ceiling).
    public func zoomOut() {
        switch zoom {
        case .focus:  zoom = .space
        case .space:  zoom = .galaxy; galaxyHover = nil
        case .galaxy: break                       // ceiling — no wraparound
        }
    }

    /// ⌘↓ / pinch-in — step DOWN toward a single focused port. Clamps at focus (the floor).
    /// In galaxy, a hovered space-world dives straight into that space (hover-dive).
    public func zoomIn() {
        switch zoom {
        case .galaxy:
            if let h = galaxyHover, appState.spaces.indices.contains(h),
               appState.spaces[h].id != appState.currentSpace?.id {
                jumpToSpace(index: h)             // hover-dive: enter the hovered space
            } else {
                zoom = .space
            }
        case .space:
            // Focus the highlighted desktop tile (chat or a tiled port); else the first port.
            if let tid = selectedTileId ?? selectedPort { zoom = .focus(tid) }   // nothing ⇒ stay
        case .focus:
            break                                 // floor — no wraparound
        }
    }

    /// ⌘1…N — jump straight to the Nth space (0-based) and land on its desktop rung.
    public func jumpToSpace(index: Int) {
        guard appState.spaces.indices.contains(index) else { return }
        appState.selectSpace(appState.spaces[index])
        selectedPortId = nil
        galaxyHover = nil
        zoom = .space
    }

    // MARK: Pinch latch — ONE rung per gesture (prototype `Shell.pinch`)

    public var pinchAccum: CGFloat = 0
    public var pinchFired = false

    /// Trackpad magnify drives the same ladder: accumulate magnification, fire exactly one rung
    /// once past the threshold, then latch until the next gesture begins (`began`). Spread
    /// (delta > 0) zooms in; pinch (delta < 0) zooms out. Prevents a single squeeze rocketing
    /// through several rungs.
    public func pinch(delta: CGFloat, began: Bool) {
        if began { pinchAccum = 0; pinchFired = false }
        guard !pinchFired else { return }
        pinchAccum += delta
        let threshold: CGFloat = 0.32
        if pinchAccum > threshold { pinchFired = true; zoomIn() }
        else if pinchAccum < -threshold { pinchFired = true; zoomOut() }
    }

    // MARK: Key yield (§3.1) — pure decision, headless-tested

    /// Whether the shell should YIELD a key to a focused field/port instead of driving the zoom
    /// ladder. `isEditor` = a text editor / web view / terminal owns the keyboard (so any key it
    /// wants, including ⌘-combos while typing, passes through). **Esc** additionally yields whenever
    /// the focused port is a **terminal** — vim/less/any TUI needs its Esc (a non-terminal focused
    /// port still lets Esc peel back out of focus). Everything else drives the ladder.
    nonisolated public static func shouldYieldKey(isEditor: Bool, keyCode: UInt16,
                                                  focusedPortIsTerminal: Bool) -> Bool {
        if keyCode == 53 { return isEditor || focusedPortIsTerminal }   // 53 = Esc
        return isEditor
    }

    /// The port currently in focus is a terminal (its Esc must reach it, not the ladder).
    public var focusedPortIsTerminal: Bool {
        guard case .focus(let id) = zoom else { return false }
        return appState.portWindows.panels.first { $0.id == id }?.portType == "terminal"
    }

    // MARK: Z-order (prototype `Shell.zCounter` / `focus()`)

    /// Monotonic z-order source. Every focus bumps it and stamps the port, so the just-touched
    /// port is always frontmost. Persisted per-port via `PortPanel.z`.
    public private(set) var zCounter: Int = 0

    /// Next z value (frontmost). Call when a tile is focused/spawned, then stamp it on the panel.
    @discardableResult
    public func nextZ() -> Int { zCounter += 1; return zCounter }

    /// Keep the counter ahead of any restored `z` so freshly focused ports still land on top.
    public func seedZCounter(from panels: [PortPanel]) {
        zCounter = max(zCounter, panels.map(\.z).max() ?? 0)
    }

    // MARK: Tile geometry (S3 — movable tiles; positions live in state, not a render grid)

    /// A tile's default full size (titlebar + body) when a panel carries none yet.
    public static let defaultTileSize = CGSize(width: 460, height: 400)

    /// Minimum tile size (drag-resize floor).
    public static let minTileSize = CGSize(width: 220, height: 160)

    /// The right-edge rail's two drop zones: park (minimize to a chip) and close (delete the port).
    public enum ParkZone: Equatable { case park, close }

    /// Which rail zone the in-progress tile drag is currently over (drives the rail highlight); nil
    /// when the drag isn't over the rail.
    @Published public var draggingOverPark: ParkZone?
    /// True while a tile is being dragged/resized — suppresses hover-to-front so tiles you drag OVER
    /// don't pop in front of the one in your hand.
    @Published public var isDraggingTile: Bool = false

    /// The right rail's width (spec §4: `max(64, screenW·0.05)`).
    nonisolated public static func parkWidth(_ screenW: CGFloat) -> CGFloat { max(64, screenW * 0.05) }

    /// The close sub-zone's height — the bottom portion of the rail.
    nonisolated public static func closeZoneHeight(_ screenH: CGFloat) -> CGFloat { max(120, screenH * 0.2) }

    /// Classify a point (in desktop coordinates) against the right rail: the bottom portion of the
    /// strip is the **close** zone, the rest of the strip is **park**, everything left of the strip
    /// is nil. Pure → headless-testable.
    nonisolated public static func parkZone(at p: CGPoint, in area: CGSize) -> ParkZone? {
        guard p.x >= area.width - parkWidth(area.width) else { return nil }
        return p.y >= area.height - closeZoneHeight(area.height) ? .close : .park
    }

    /// Direct-message spaces surfaced as tiles on the CURRENT desktop (B — multi-space chat). Each id
    /// here means "render that space's chat port as a tile alongside the space chat"; `AppState` keeps
    /// their messages live via `activateSpaceMessages`.
    @Published public var openDMSpaceIds: [String] = []

    /// Open a companion's 1:1 DM (a 2-member `direct` space) as its OWN live tile next to the space
    /// chat — no space switch, nothing torn down. The space chat and every open DM coexist as separate
    /// windows, each streaming its own conversation.
    /// Clicking a companion in the dock/member list. A CLI companion (claude/gemini, `openInTerminal`)
    /// launches/reveals its terminal port; everyone else opens a DM chat. Both are just ports.
    public func activateCompanion(_ companion: AgentConfig) {
        if companion.openInTerminal {
            guard let sid = appState.currentSpace?.id else { return }
            appState.ensureTerminalLive(companion: companion, spaceId: sid)
        } else {
            openDM(companion)
        }
    }

    public func openDM(_ companion: AgentConfig) {
        guard let dm = appState.openDMSpace(with: companion) else { return }   // resolve/stream DM space
        surfaceSpaceChat(spaceId: dm.id, spaceName: dm.name)                   // surface + front + arrange
    }

    /// Close a surfaced DM tile: stop streaming its space and drop it from the desktop.
    public func closeDM(spaceId: String) {
        openDMSpaceIds.removeAll { $0 == spaceId }
        appState.deactivateSpaceMessages(spaceId: spaceId)
        arrangeBump += 1
    }

    /// Drop every surfaced DM (used when leaving a desktop — DMs belong to the working session on the
    /// space you opened them from, not the one you switch to).
    public func clearOpenDMs() {
        for sid in openDMSpaceIds { appState.deactivateSpaceMessages(spaceId: sid) }
        openDMSpaceIds.removeAll()
        surfacedPortIds.removeAll()          // adopted foreign ports are per-desktop
        peekingPorts.removeAll()             // peeks belong to the desktop you were on
    }

    /// Dismiss a tile via its ✕. A surfaced foreign chat/port is DETACHED (removed from this desktop,
    /// but lives on in its home space); a native tile of THIS space is actually closed.
    public func dismissTile(_ panel: PortPanel) {
        if let sid = panel.spaceId, openDMSpaceIds.contains(sid) {   // surfaced foreign chat / DM → detach
            closeDM(spaceId: sid)
            return
        }
        if surfacedPortIds.contains(panel.id) {                      // adopted foreign port → detach
            surfacedPortIds.remove(panel.id)
            arrangeBump += 1
            return
        }
        appState.portWindows.close(panel.id)                         // a real tile of this space → close it
    }

    /// Bring a tile to the front (focus/hover/drag-start): stamp it frontmost via `nextZ()` and
    /// select it. `setZ` no-ops if the id isn't a panel, so it's safe for any tile.
    public func bringToFront(_ tileId: String) {
        selectedTileId = tileId
        appState.portWindows.setZ(id: tileId, z: nextZ())
    }

    /// Re-grid the current space's tiled ports (the chat is one of them now) via the pure `arrange`
    /// and WRITE the resulting positions back — the layout authority (§4). Called on ⌘L and every
    /// user-initiated spawn/park; hand-drag positions survive a restart but a spawn re-grids them.
    public func applyArrange(area: CGSize) {
        guard let sid = appState.currentSpace?.id else { return }
        // Arrange the SAME set the desktop renders: the current space + any surfaced DM tiles. If this
        // filter drifts from `tiledPanels`, DM ports never get a position and stack invisibly under the
        // space chat at their default docked spot.
        let allowed = Set([sid] + openDMSpaceIds)
        let panels = appState.portWindows.panels.filter { allowed.contains($0.spaceId ?? "") && $0.presentation == "tiled" }
        let tiles = panels.map { ArrangeTile(id: $0.id, size: $0.size, z: max($0.z, 1)) }
        let origins = Self.arrange(tiles, in: area)
        // Animate the moves here (not via a distant `.animation(value:)`) so the tiles visibly spring
        // to their spots — a bouncy, slightly slow settle, like the prototype.
        withAnimation(.spring(response: 0.55, dampingFraction: 0.68)) {
            for p in panels where origins[p.id] != nil {
                appState.portWindows.updateTileFrame(id: p.id, position: origins[p.id]!, size: nil)   // reposition only — keep varied sizes
            }
        }
    }

    // MARK: Arrange (pure — prototype `arrange()`; the layout authority, §4)

    /// One tile's geometry input to `arrange` (id + current size + z). Pure so the grid is headless.
    public struct ArrangeTile: Equatable {
        public let id: String
        public let size: CGSize
        public let z: Int
        public init(id: String, size: CGSize, z: Int) { self.id = id; self.size = size; self.z = z }
    }

    /// Tidy tiles into a centered grid — the prototype's `arrange`, preserved. It ONLY repositions:
    /// each tile keeps its own (varied) size and is centered in a uniform cell sized to the LARGEST
    /// tile, so the desktop stays lively rather than homogenized into equal boxes (a strict grid is
    /// exposé's job). `cols = ceil(√n)`; the block is centered horizontally (may spill symmetrically
    /// when crowded) and pinned below the Chrome (`startY ≥ 70`). Walks tiles in `z` order (stable).
    /// Returns each tile's top-left origin; callers set `panel.position` (never `.size`). Pure → headless.
    nonisolated public static func arrange(_ tiles: [ArrangeTile], in area: CGSize) -> [String: CGPoint] {
        let items = tiles.sorted { $0.z < $1.z }
        guard !items.isEmpty else { return [:] }
        let n = items.count
        let cols = max(1, Int(ceil(sqrt(Double(n)))))
        let rows = max(1, Int(ceil(Double(n) / Double(cols))))
        // Cells fill the WORK AREA (inside Chrome/dock/rail), so the grid always fits. Each tile keeps
        // its OWN size, centered in its cell (variety preserved — not homogenized). When crowded, cells
        // get smaller than the tiles so they overlap a little (lively) rather than run off-screen; the
        // origin is clamped to the work area so nothing is ever pushed out of view.
        let top: CGFloat = 70, bottom: CGFloat = 100, side: CGFloat = 40
        let workX = side, workW = max(240, area.width - side * 2 - parkWidth(area.width))
        let workY = top, workH = max(200, area.height - top - bottom)
        let colW = workW / Double(cols), rowH = workH / Double(rows)
        var out: [String: CGPoint] = [:]
        for (i, item) in items.enumerated() {
            let cx = workX + (Double(i % cols) + 0.5) * colW         // cell center
            let cy = workY + (Double(i / cols) + 0.5) * rowH
            let ox = min(max(cx - item.size.width / 2, workX), workX + workW - item.size.width)
            let oy = min(max(cy - item.size.height / 2, workY), workY + workH - item.size.height)
            out[item.id] = CGPoint(x: ox, y: oy)                     // centered, clamped in-bounds
        }
        return out
    }
}

// MARK: - Hex color (shell accents)

extension Color {
    /// Parse "#RRGGBB" (or "RRGGBB") into a Color; nil on malformed input. Used for per-space accents.
    init?(shellHex: String) {
        var s = shellHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255.0,
            green: Double((v >> 8) & 0xFF) / 255.0,
            blue:  Double(v & 0xFF) / 255.0
        )
    }
}
