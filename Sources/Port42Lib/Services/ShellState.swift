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

    #if DEBUG
    /// The live shell instance, for DEBUG harnesses only (the render-probe cycle drives
    /// `zoom` on the real shell). Weak — the harness must never keep a dead shell alive.
    public private(set) static weak var debugCurrent: ShellState?
    /// DEBUG accessor for harnesses that need the panels/registry behind this shell.
    public var debugAppState: AppState? { appState }
    #endif

    public init(appState: AppState) {
        self.appState = appState
        #if DEBUG
        Self.debugCurrent = self
        #endif
        // Notifications (§8b): a non-current space gaining unread activity (a companion reply / chat)
        // raises a peeking chat notification…
        notifSink = appState.$unreadCounts
            .receive(on: RunLoop.main)
            .sink { [weak self] counts in self?.refreshNotifications(from: counts) }
        // …and a TILED port's birth raises a peeking port notification — the live port,
        // clickable to surface here (§8b). Phase 1: same-space births peek too (the
        // self-suppression fix); only the user's own shell-UI spawns are exempt.
        portSink = appState.portWindows.portCreated
            .receive(on: RunLoop.main)
            .sink { [weak self] p in self?.handlePortCreated(id: p.id, spaceId: p.spaceId, title: p.title) }
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
        public var seen: Bool = false   // true after you've previewed it → its 10s countdown is armed
    }
    @Published public var peekingPorts: [PeekPort] = []

    /// Is this port adopted onto the CURRENT desktop? Phase 3: adoption lives on the panel
    /// (`adoptedSpaceIds`, persisted) — not a session set — so it survives switch + restart.
    private func isAdoptedHere(_ id: String) -> Bool {
        guard let sid = appState.currentSpace?.id else { return false }
        return appState.portWindows.panels.first { $0.id == id }?.adoptedSpaceIds.contains(sid) ?? false
    }

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

    /// Port ids the USER just spawned from the shell UI (dock/⌘K) — their birth shouldn't
    /// peek at the person who made them. One-shot; consumed by `handlePortCreated`.
    private var userSpawnedPortIds: Set<String> = []
    public func noteUserSpawn(_ id: String) { userSpawnedPortIds.insert(id) }

    /// A tiled port's birth → it peeks here, deduped by port id (Phase 1: same-space births
    /// included — a peek is a live surface with an attention beat, not just an unread badge.
    /// A same-space port renders in PEEK state until its entry clears, then settles into the
    /// grid — it can't evaporate from its own home space). Internal so tests drive it directly.
    func handlePortCreated(id: String, spaceId: String?, title: String) {
        guard let sid = spaceId else { return }
        if userSpawnedPortIds.remove(id) != nil { return }              // you made it; it's right there
        guard !peekingPorts.contains(where: { $0.id == id }), !isAdoptedHere(id) else { return }
        peekingPorts.append(PeekPort(id: id, spaceId: sid, spaceName: spaceLabel(sid), isChat: false, title: title))
    }

    /// The peek currently under the cursor — makes it the ⌘↓/pinch zoom-in target (peeks aren't
    /// desktop tiles, so hovering one otherwise leaves the gesture pointed at an in-space tile).
    @Published public var hoveredPeekId: String?

    /// Seconds left before a *seen* peek evaporates, by peek id (drives the countdown ring).
    @Published public var peekRemaining: [String: Double] = [:]
    private var peekTimer: Timer?
    private let peekLifetime: Double = 10

    /// Click / hover-gesture on a peek → PREVIEW it (zoom in). Non-committal: keeping is a drag.
    public func previewPeek(_ peek: PeekPort) {
        if peek.isChat {
            // Chat renders via SwiftUI ChatView (no re-parented NSView); surfacing IS keeping for chat.
            peekingPorts.removeAll { $0.id == peek.id }
            peekRemaining[peek.id] = nil
            surfaceSpaceChat(spaceId: peek.spaceId, spaceName: peek.spaceName)
            appState.lastReadDates[peek.spaceId] = Date()
            if let panel = appState.portWindows.panels.first(where: { $0.isChatPort && $0.spaceId == peek.spaceId }) {
                withAnimation(.spring(response: 0.4)) { zoom = .focus(panel.id) }
            }
            return
        }
        // Port peek (Phase 1): the unit stays mounted exactly where it is — mark it seen and
        // zoom; placement() resizes it railSlot → focusRect IN PLACE. No removal, no stash,
        // no reparent — the stash dance (`pendingPreviewPeek`) is gone with the rail VStack.
        if let i = peekingPorts.firstIndex(where: { $0.id == peek.id }) { peekingPorts[i].seen = true }
        peekRemaining[peek.id] = nil                     // countdown pauses during the preview
        withAnimation(.spring(response: 0.4)) { zoom = .focus(peek.id) }
    }

    /// Zoom returned to the desktop → every *seen*, still-peeking port starts its countdown
    /// (evaporate-by-default for a foreign port; a same-space port settles into the grid when
    /// its entry clears). Pure bookkeeping — no peek add/remove, no view moves (Phase 1).
    public func settleAfterPreview() {
        for p in peekingPorts where p.seen && !p.isChat && peekRemaining[p.id] == nil {
            startPeekCountdown(p.id)
        }
    }

    /// Keep a peek: it becomes a real tile of this desktop (cancels its countdown).
    /// `arrange: false` = the caller placed it by hand (drag-to-keep) — don't re-grid.
    public func keepPeek(_ peek: PeekPort, arrange: Bool = true) {
        peekingPorts.removeAll { $0.id == peek.id }
        peekRemaining[peek.id] = nil
        if let sid = appState.currentSpace?.id {                     // adoption is persisted (Phase 3)
            appState.portWindows.adopt(id: peek.id, into: sid)
        }
        bringToFront(peek.id)
        if arrange { arrangeBump += 1 }
    }

    private func startPeekCountdown(_ id: String) {
        peekRemaining[id] = peekLifetime
        guard peekTimer == nil else { return }
        peekTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPeekCountdowns() }
        }
    }

    private func tickPeekCountdowns() {
        for (id, rem) in peekRemaining {
            if id == hoveredPeekId { continue }                         // hover pauses the countdown
            let next = rem - 0.1
            if next <= 0 {
                peekRemaining[id] = nil
                peekingPorts.removeAll { $0.id == id }                  // evaporate (still lives in its home space)
            } else {
                peekRemaining[id] = next
            }
        }
        if peekRemaining.isEmpty { peekTimer?.invalidate(); peekTimer = nil }
    }

    /// ✕ a peek → dismiss it from your desktop; it lives on in its home space.
    public func dismissPeek(_ peek: PeekPort) {
        peekingPorts.removeAll { $0.id == peek.id }
        peekRemaining[peek.id] = nil
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

    /// THE desktop-tile predicate — the one source for "which panels are staged as tiles on
    /// this desktop": the current space's tiled panels, plus surfaced DM chats, plus adopted
    /// foreign ports. The desktop renders this set, `applyArrange` grids it, and ShellView's
    /// focus branch checks membership — one filter, so they can never drift apart (Phase 0).
    public var desktopTilePanels: [PortPanel] {
        guard let sid = appState.currentSpace?.id else { return [] }
        let allowed = Set([sid] + openDMSpaceIds)
        return appState.portWindows.panels.filter { p in
            p.presentation == "tiled" && (allowed.contains(p.spaceId ?? "") || p.adoptedSpaceIds.contains(sid))
        }
    }

    /// One renderable unit on the desktop (Phase 1): a tiled panel, a peeking port, or a
    /// chat peek — ONE ForEach row per port id, so peek → tile → focus are geometry states
    /// of the same mounted view (I3/I4: identity never changes across adopt).
    public struct PortContextItem: Identifiable {
        public let id: String            // panel id (ports) · spaceId (chat peeks)
        public let panel: PortPanel?     // nil = a chat peek with no local panel (renders ChatView)
        public let peek: PeekPort?       // non-nil while the unit is in peek state
        public let peekIndex: Int?       // rail slot while peeking
    }

    /// The desktop's render list: peeks first (rail order), then tiles — deduped by id with
    /// PEEK STATE WINNING (a same-space port that's both tiled and peeking renders once, in
    /// the rail, and settles into the grid when its peek entry clears). Pure → headless.
    nonisolated public static func contextItems(tiled: [PortPanel], peeks: [PeekPort],
                                                allPanels: [PortPanel]) -> [PortContextItem] {
        var items: [PortContextItem] = []
        var seen = Set<String>()
        for (i, p) in peeks.enumerated() {
            let panel = allPanels.first { $0.id == p.id }
            if panel == nil && !p.isChat { continue }     // a port peek whose panel vanished
            items.append(PortContextItem(id: p.id, panel: panel, peek: p, peekIndex: i))
            seen.insert(p.id)
        }
        for t in tiled where !seen.contains(t.id) {
            items.append(PortContextItem(id: t.id, panel: t, peek: nil, peekIndex: nil))
        }
        return items
    }

    /// The live render list for the current desktop.
    public var contextItems: [PortContextItem] {
        Self.contextItems(tiled: desktopTilePanels, peeks: peekingPorts,
                          allPanels: appState.portWindows.panels)
    }

    /// Is this id a unit on the current desktop (tile OR peek)? Focus on a desktop unit is a
    /// resize-in-place of that unit; nothing else can be focused after Phase 1.
    public func isDesktopUnit(_ id: String) -> Bool {
        contextItems.contains { $0.id == id }
    }

    /// Focus is only valid while its target is a desktop unit (Phase 2 — there is no focus
    /// overlay to catch anything else). Called when the unit set changes: if the focused unit
    /// left the desktop (closed via API, evaporated, detached, moved away), fall back to the
    /// space rung instead of a dead focus state (hit-testing off, no backdrop, no exit).
    public func exitFocusIfGone() {
        if case .focus(let id) = zoom, !isDesktopUnit(id) {
            withAnimation(.spring(response: 0.4)) { zoom = .space }
        }
    }

    /// Re-home a port to another space (the facade's `move`, plan §3) and clear this desktop's
    /// peek/adoption residue for it — a moved port is native to its new space, not surfaced.
    public func movePort(id: String, toSpace sid: String) {
        appState.portWindows.move(id: id, toSpace: sid)   // strips the new home from adopters
        peekingPorts.removeAll { $0.id == id }
        peekRemaining[id] = nil
        exitFocusIfGone()
        arrangeBump += 1
    }

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
            // A hovered peek is the zoom target: the gesture adopts it (peeks aren't desktop tiles,
            // so they never set selectedTileId — without this ⌘↓/pinch would zoom an in-space tile).
            if let pid = hoveredPeekId, let peek = peekingPorts.first(where: { $0.id == pid }) {
                previewPeek(peek); return
            }
            // Focus the highlighted desktop UNIT; else the first unit. Only a desktop unit is
            // focusable (Phase 2 — the focus overlay is gone): a parked/inline port has no
            // mounted view to resize, so it can never be a focus target.
            if let tid = [selectedTileId, selectedPort].compactMap({ $0 }).first(where: isDesktopUnit)
                        ?? contextItems.first?.id {
                zoom = .focus(tid)
            }
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
        // (Adopted ports are NOT cleared — Phase 3: adoption lives on the panel, persisted,
        // so a kept port is still on this desktop when you come back. Peeks stay transient.)
        peekingPorts.removeAll()             // peeks belong to the desktop you were on
        peekRemaining.removeAll()
        peekTimer?.invalidate(); peekTimer = nil
    }

    /// Dismiss a tile via its ✕. A surfaced foreign chat/port is DETACHED (removed from this desktop,
    /// but lives on in its home space); a native tile of THIS space is actually closed.
    public func dismissTile(_ panel: PortPanel) {
        if let sid = panel.spaceId, openDMSpaceIds.contains(sid) {   // surfaced foreign chat / DM → detach
            closeDM(spaceId: sid)
            return
        }
        if let cur = appState.currentSpace?.id, panel.adoptedSpaceIds.contains(cur) {
            appState.portWindows.unadopt(id: panel.id, from: cur)   // adopted foreign port → detach (persisted)
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
        guard appState.currentSpace != nil else { return }
        // Arrange the SAME set the desktop renders — `desktopTilePanels`, the shared predicate
        // (Phase 0). Previously this filter omitted adopted foreign ports, so a kept peek
        // never got gridded and stacked at its home-space position.
        let panels = desktopTilePanels
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
