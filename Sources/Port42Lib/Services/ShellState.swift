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

    @Published public var zoom: Zoom = .space {
        didSet { if zoom != oldValue { returnPoppedIfLeft() } }
    }
    /// The highlighted tile zoom-in targets (hover/click); nil ⇒ fall back to the first port.
    @Published public var selectedPortId: String?
    /// The highlighted desktop tile (chat or a tiled port) — hover/click; what ⌘↓ focuses.
    @Published public var selectedTileId: String?
    /// Exposé (Tab): a TEMPORARY arrange — every tile spreads to the fit grid for selection, without
    /// overwriting its real position. Picking a tile (or Tab/Esc) exits and tiles snap back.
    @Published public var exposeActive: Bool = false

    /// The item whose settings box is open (long-press a galaxy world / companion). nil = closed.
    /// A shared overlay hosts rename / accent / delete; `.companion` lands with S4.
    public enum SettingsTarget: Equatable { case space(String), companion(String) }
    @Published public var settingsTarget: SettingsTarget?

    /// Show the New Companion form as a shell overlay (not a macOS sheet). Set from the dock's ＋ menu.
    @Published public var showNewCompanion: Bool = false
    /// The quick imagine box (⌘I): one line starts an imagine team (docs/plan-imagine.md).
    @Published public var showImagine: Bool = false
    /// What an imagine link filled the box with, taken by the box when it opens.
    @Published public var imagineLink: ImagineLinkRequest?
    /// True while hold-to-talk is capturing. The SHELL owns this and draws it: a port must not be
    /// able to suppress an indicator it does not draw, which is the security requirement behind
    /// putting voice in the shell rather than in a port.
    @Published public var voiceCapturing: Bool = false
    /// Where the speech model is. A hold with no model must say so rather than do nothing.
    @Published public var voiceModel: VoiceModelState = .absent
    /// What the last hold produced, or why it produced nothing. Shown next to the indicator; Phase 3
    /// is what puts the text into the focused surface.
    @Published public var voiceNotice: String?
    /// What a HOLD is saying: the live mic, the words so far, and what went wrong with that hold. It belongs
    /// wherever the words are going, which is the tile being dictated into when there is one.
    private var voiceHoldIndicator: (label: String, live: Bool)? {
        if voiceCapturing { return (voicePartial ?? "listening", true) }
        if let notice = voiceNotice { return (notice, false) }
        return nil
    }

    /// What the MODEL is doing. Not part of any hold, so it belongs to the space: a download pinned to the tile
    /// of the last hold is in the wrong place, and disappears when that tile does (GM, 2026-09-27).
    private var voiceModelIndicator: (label: String, live: Bool)? {
        switch voiceModel {
        case .downloading, .loading: return (voiceModel.label, false)
        case .ready, .absent, .failed: return nil
        }
    }

    /// The indicator for one tile: only the hold that is going there.
    public func voiceIndicator(forPort id: String) -> (label: String, live: Bool)? {
        guard voiceAnchorPortId == id else { return nil }
        return voiceHoldIndicator
    }

    /// The indicator for the space: a hold that is not going to any tile, otherwise whatever the model is doing.
    /// So a download shows on the space even while a hold is streaming into a tile.
    public var voiceIndicatorForSpace: (label: String, live: Bool)? {
        if voiceAnchorPortId == nil, let hold = voiceHoldIndicator { return hold }
        return voiceModelIndicator
    }

    /// What the system has not granted yet, if a hold could not run because of it.
    @Published public var voicePermissionNeeded: VoicePermission?
    /// The words so far, while the hold is still open. Feedback only: the text is inserted on release.
    @Published public var voicePartial: String?
    /// The port being dictated into, so the indicator sits on that tile instead of over the desktop.
    /// Nil means the words are going somewhere the shell itself owns, such as the chat input.
    @Published public var voiceAnchorPortId: String?
    /// Bring running sessions in (⌘K, docs/plan-session-import.md).
    @Published public var showImportSessions: Bool = false
    /// The port the Share box is open for (4.6b), by port key; nil when it is closed.
    @Published public var shareTarget: String? = nil
    /// The Share box is handing the port over rather than sharing it (a move to another machine).
    @Published public var shareMove: Bool = false
    /// An invite link waiting for the person to accept it (4.6b): clicked, or pasted into ⌘K.
    @Published public var pendingInvite: String? = nil
    /// The Quick Switcher (⌘K), migrated from the classic app — fuzzy jump across spaces/companions.
    @Published public var showQuickSwitcher: Bool = false

    /// The global Settings panel (the app's SignOutSheet) surfaced as a shell overlay.
    @Published public var showSettings: Bool = false
    /// Which space-world the mouse is over in galaxy (zoom-in dives into it).
    @Published public var galaxyHover: Int?
    /// Normalized cursor position (0…1) for the ambient background parallax (prototype's `mouse`).
    @Published public var mouse: CGPoint = CGPoint(x: 0.5, y: 0.5)

    // MARK: - Background-as-port (the chrome-is-ports wedge)

    /// The LIVE port set as the space background — re-parented full-bleed as Layer 0, NOT reloaded.
    /// Background is a PRESENTATION of the port (like tiled/parked/focus), so moving to or from it is
    /// a position change, never a lifecycle change: the hoisted webview never remounts, so a running
    /// shader / JS state survives. Layer 0 hosts this port's live surface via `hostView(for:)`.
    @Published public var backgroundPortId: String?

    /// Fallback ONLY: the background port was CLOSED, so there is no live surface to re-parent —
    /// Layer 0 mounts a fresh copy from this stored HTML. A live background always uses `backgroundPortId`.
    @Published public var backgroundPortHtml: String?
    private static let bgKey = "shell.backgroundPortId"

    /// True while anything is the background (a live port or the closed-port HTML fallback).
    public var hasBackgroundPort: Bool { backgroundPortId != nil || backgroundPortHtml != nil }

    /// Set (or clear, with nil) the background port. A live port MOVES to the background presentation
    /// (re-parent, no reload); a closed port falls back to a fresh HTML mount. The id is remembered so
    /// it restores next launch.
    @MainActor
    public func setBackgroundPort(id: String?) {
        guard let id else {
            // Clear to the ambient dreamscape. A live background port flips back to a tile.
            if let cur = backgroundPortId,
               let panel = appState.portWindows.panels.first(where: { $0.id == cur || $0.udid == cur }) {
                appState.portWindows.setPresentation(id: panel.id, to: "tiled")
            }
            backgroundPortId = nil
            backgroundPortHtml = nil
            UserDefaults.standard.removeObject(forKey: Self.bgKey)
            return
        }
        // Live port → move it to the background presentation (drops from the grid, re-parents at
        // Layer 0). The webview keeps running; nothing is cloned or reloaded.
        if let panel = appState.portWindows.panels.first(where: { $0.id == id || $0.udid == id }) {
            appState.portWindows.setPresentation(id: panel.id, to: "background")
            backgroundPortId = panel.id
            backgroundPortHtml = nil
            UserDefaults.standard.set(id, forKey: Self.bgKey)
            return
        }
        // Closed port → nothing live to preserve; mount a fresh copy from its stored HTML.
        if let html = resolveBackgroundHtml(id: id) {
            backgroundPortId = nil
            backgroundPortHtml = html
            UserDefaults.standard.set(id, forKey: Self.bgKey)
        }
    }

    /// Resolve a port's current HTML: live panel first, then the version store (so a closed port can
    /// still be a background).
    @MainActor
    private func resolveBackgroundHtml(id: String) -> String? {
        if let panel = appState.portWindows.panels.first(where: { $0.id == id || $0.udid == id }) {
            return panel.html
        }
        return (try? appState.db.fetchPortHtml(udid: id)) ?? nil
    }

    /// Restore a background port set in a previous session. A live port (persisted with the background
    /// presentation) is re-parented; a closed one falls back to stored HTML.
    @MainActor
    public func restoreBackgroundPort() {
        guard let id = UserDefaults.standard.string(forKey: Self.bgKey), !id.isEmpty else { return }
        if let panel = appState.portWindows.panels.first(where: { $0.id == id || $0.udid == id }) {
            appState.portWindows.setPresentation(id: panel.id, to: "background")   // keep it out of the grid
            backgroundPortId = panel.id
        } else {
            backgroundPortHtml = resolveBackgroundHtml(id: id)
        }
    }

    /// Clear the background AND pop the port back onto the desktop as a tile — the reverse of "set as
    /// background". A live background flips straight back to a frontmost tile (no reload); a closed-port
    /// fallback is recreated from its stored HTML.
    @MainActor
    public func clearBackgroundToTile() {
        if let cur = backgroundPortId {
            let pid = appState.portWindows.panels.first(where: { $0.id == cur || $0.udid == cur })?.id
            setBackgroundPort(id: nil)                           // flips it to "tiled" + clears the background
            if let pid { bringToFront(pid) }   // frontmost; the count change places it if unplaced
            return
        }
        let html = backgroundPortHtml
        setBackgroundPort(id: nil)                               // ambient dreamscape returns
        guard let html, let sid = appState.currentSpace?.id else { return }
        _ = appState.createPort(type: "web", title: "port", html: html, command: nil, cwd: nil,
                                systemPrompt: nil, spaceId: sid, createdBy: nil, createdByName: nil)
    }

    private let appState: AppState
    private var portSink: AnyCancellable?
    private var presentationSink: AnyCancellable?

    #if DEBUG
    /// The live shell instance, for DEBUG harnesses only (the render-probe cycle drives
    /// `zoom` on the real shell). Weak — the harness must never keep a dead shell alive.
    public private(set) static weak var debugCurrent: ShellState?
    /// DEBUG accessor for harnesses that need the panels/registry behind this shell.
    public var debugAppState: AppState? { appState }
    #endif

    /// Whether any of the shell's window can be seen: false when it is hidden, minimized or fully
    /// covered (`NSWindow.occlusionState`). The ambient background pauses on it (Phase 2 step 4).
    @Published public private(set) var windowVisible = true
    private var visibilityObservers: [NSObjectProtocol] = []

    /// Whether the ambient background animates. It runs whenever any of it can be seen, including
    /// behind a focused port, which dims it but does not hide it (GM, 2026-09-25). A wallpaper port
    /// replaces it entirely, so it is not drawn at all then.
    nonisolated public static func ambientPaused(windowVisible: Bool, wallpaperShown: Bool) -> Bool {
        !windowVisible || wallpaperShown
    }

    /// Re-read the shell window's visibility. The shell window is the app's one key-able window.
    func refreshWindowVisibility() {
        guard let app = NSApp,
              let window = app.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey }) else { return }
        let visible = !app.isHidden && !window.isMiniaturized && window.occlusionState.contains(.visible)
        if visible != windowVisible { windowVisible = visible }
    }

    public init(appState: AppState) {
        self.appState = appState
        appState.shell = self          // back-ref so the bridge can reach shell-level state
        #if DEBUG
        Self.debugCurrent = self
        #endif
        // Notifications (§8b): a TILED port's birth in ANOTHER space raises a peeking port notification — the
        // live port, clickable to surface here (§8b). A port born in the CURRENT space is just a
        // tile on this desktop (gated in handlePortCreated), never a peek.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            visibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindowVisibility() }
            })
        }
        portSink = appState.portWindows.portCreated
            .receive(on: RunLoop.main)
            .sink { [weak self] p in self?.handlePortCreated(id: p.id, spaceId: p.spaceId, title: p.title) }

        // Presentation (backlog 1.1, Step 3): every input that can change a port's presentation feeds ONE
        // debounced funnel. Merged + debounced so a burst (arrange, cycle, the space-switch cascade)
        // coalesces into one settled emit per port. This is the sole trigger — no per-call-site sync.
        let inputs: [AnyPublisher<Void, Never>] = [
            $zoom.map { _ in () }.eraseToAnyPublisher(),                       // focus / galaxy / space
            $peekingPorts.map { _ in () }.eraseToAnyPublisher(),              // peek in / out
            appState.portWindows.$panels.map { _ in () }.eraseToAnyPublisher(), // park/bg/adopt/move/new/close/size
            appState.$currentSpace.map { _ in () }.eraseToAnyPublisher()      // desktop switch
        ]
        presentationSink = Publishers.MergeMany(inputs)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.syncPresentation() }
    }

    // MARK: - Notifications (§8b) — a notification IS the live port, PEEKING as a small tile here.
    // Not a card: the actual port from another space attaches to your current desktop. Zoom into it →
    // it STICKS in your space (adopted); ✕ detaches it (it lives on in its home space).

    public struct PeekPort: Identifiable, Equatable {
        public let id: String        // the port's id
        public let spaceId: String
        public let spaceName: String
        public let title: String
        public var seen: Bool = false   // true after you've previewed it
    }
    @Published public var peekingPorts: [PeekPort] = []

    /// Is this port adopted onto the CURRENT desktop? Phase 3: adoption lives on the panel
    /// (`adoptedSpaceIds`, persisted) — not a session set — so it survives switch + restart.
    private func isAdoptedHere(_ id: String) -> Bool {
        guard let sid = appState.currentSpace?.id else { return false }
        return appState.portWindows.panels.first { $0.id == id }?.adoptedSpaceIds.contains(sid) ?? false
    }


    private func spaceLabel(_ sid: String) -> String {
        appState.spaces.first(where: { $0.id == sid })?.name
            ?? appState.companions(forSpace: sid).first?.displayName ?? "space"
    }

    /// Is this space at rest? A rested space is FULLY SILENT — no chat peeks, no port-birth
    /// peeks; unread still accumulates (visible only inside the galaxy shelf). A DM (`direct`)
    /// space is never in `appState.spaces`, so it can never read as rested here — correct,
    /// since only galaxy worlds carry the rest affordance.
    private func isRested(_ spaceId: String) -> Bool {
        appState.spaces.first { $0.id == spaceId }?.isResting ?? false
    }

    /// A tiled port's birth raises a peek here ONLY if it landed in another space — a glance at
    /// activity elsewhere, deduped by port id. A port born in the space you're currently viewing
    /// is just yours: it settles straight into the grid as a tile (desktopTilePanels →
    /// contextItems), never a peek. Gating on the current space covers every creation path (dock,
    /// CLI companion, gateway, JS) with no per-path bookkeeping. Internal so tests drive it directly.
    func handlePortCreated(id: String, spaceId: String?, title: String) {
        guard let sid = spaceId, !isRested(sid) else { return }        // a rested space is fully silent
        // Your space → a tile, not a peek. A fresh panel is born at z=0 (the bottom of the paint
        // order), so stamp it frontmost + select it here — the ONE choke point every creator funnels
        // through (portCreated) — so a launched terminal/browser/AI-made port lands on top, not under.
        guard sid != appState.currentSpace?.id else { bringToFront(id); return }
        guard !peekingPorts.contains(where: { $0.id == id }), !isAdoptedHere(id) else { return }
        peekingPorts.append(PeekPort(id: id, spaceId: sid, spaceName: spaceLabel(sid), title: title))
        startPeekCountdown(id, Self.unseenPeekLifetime)
    }

    /// A companion is WAITING ON YOU — it asked for a tool permission, or went idle at its prompt.
    /// This is backlog 1.4, the waiting-for-input signal: with several sessions running you cannot
    /// watch them all, so the one that needs you comes to you.
    ///
    /// **No classifier, deliberately.** The backlog sized this on separating "needs attention" from
    /// "done, nothing wanted" by inspecting turn output. That work is unnecessary: the CLI already
    /// draws the distinction itself and only raises this when it is blocked. `turnComplete` fires on
    /// EVERY turn and would peek constantly.
    ///
    /// Same rules as `handlePortCreated`, and for the same reasons: a rested space stays silent, a
    /// port in the space you are already looking at is visible without a peek, and one already
    /// peeking or adopted here is not raised twice. Repeats are the norm here rather than the
    /// exception — an unanswered permission prompt re-notifies — so the dedup is load-bearing.
    func handleNeedsAttention(id: String, spaceId: String?, title: String, reason: String = "") {
        guard let sid = spaceId, !isRested(sid) else { return }
        guard sid != appState.currentSpace?.id else { return }
        guard !peekingPorts.contains(where: { $0.id == id }), !isAdoptedHere(id) else { return }
        peekingPorts.append(PeekPort(id: id, spaceId: sid, spaceName: spaceLabel(sid),
                                     title: Self.attentionTitle(companion: title, reason: reason)))
        startPeekCountdown(id, Self.unseenPeekLifetime)
    }

    /// What the peek SAYS. The CLI's own message is the useful half — "needs your permission to use
    /// Bash" tells you whether to get up; the companion's name alone only tells you someone did.
    ///
    /// The name still leads, because with several sessions waiting the first question is WHICH one.
    /// Claude's messages are already prefixed with "Claude " ("Claude needs your permission…"), which
    /// reads wrong under a companion's own name, so that prefix is dropped.
    static func attentionTitle(companion: String, reason: String) -> String {
        // A turn's reply is the usual reason and can be paragraphs, so take the FIRST LINE and cap
        // it. A peek is a glance, not a transcript — the port is one click away for the rest.
        let firstLine = reason.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        var body = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return companion }
        // Notification messages are phrased "Claude is waiting…", which reads as the wrong agent
        // under a companion's own name.
        for prefix in ["Claude Code ", "Claude "] where body.hasPrefix(prefix) {
            body = String(body.dropFirst(prefix.count))
            break
        }
        if body.count > 60 {
            body = body.prefix(60).trimmingCharacters(in: .whitespaces) + "…"
        }
        return "\(companion) — \(body)"
    }

    /// Rest a space (the settings card's action): delegates the state change to `AppState` and
    /// silences it IMMEDIATELY — any peek already raised from that space (chat or port) clears
    /// here, since peeks are shell state that a counts tick wouldn't re-evaluate on its own.
    public func restSpace(_ space: Space) {
        appState.restSpace(space)
        guard appState.spaces.first(where: { $0.id == space.id })?.isResting == true else { return }
        for p in peekingPorts where p.spaceId == space.id { peekRemaining[p.id] = nil }
        peekingPorts.removeAll { $0.spaceId == space.id }
    }

    /// The peek currently under the cursor — makes it the ⌘↓/pinch zoom-in target (peeks aren't
    /// desktop tiles, so hovering one otherwise leaves the gesture pointed at an in-space tile).
    @Published public var hoveredPeekId: String?

    /// Seconds left before a peek evaporates, by peek id, and what it started from (drive the ring).
    /// A peek stays a minute. Looking at it (zoomed in) pauses the countdown, and zooming back out
    /// returns it to the strip with the time it had left (GM, 2026-09-29).
    @Published public var peekRemaining: [String: Double] = [:]
    @Published public var peekTotal: [String: Double] = [:]
    private var peekTimer: Timer?
    nonisolated public static let unseenPeekLifetime: Double = 60

    /// Click / hover-gesture on a peek → PREVIEW it (zoom in). Non-committal: keeping is a drag.
    public func previewPeek(_ peek: PeekPort) {
        // Port peek (Phase 1): the unit stays mounted exactly where it is — mark it seen and
        // zoom; placement() resizes it railSlot → focusRect IN PLACE. No removal, no stash,
        // no reparent — the stash dance (`pendingPreviewPeek`) is gone with the rail VStack.
        if let i = peekingPorts.firstIndex(where: { $0.id == peek.id }) { peekingPorts[i].seen = true }
        // The countdown pauses while you look (the tick skips a focused peek) and carries on after.
        withAnimation(.spring(response: 0.4)) { zoom = .focus(peek.id) }
    }

    /// Zoom returned to the desktop → a peek you looked at goes back to the strip and its countdown runs
    /// on from where it paused (GM, 2026-09-29). Nothing to do here: the tick resumes it by itself.
    public func settleAfterPreview() {}

    /// Keep a peek: it becomes a real tile of this desktop (cancels its countdown).
    /// `arrange: false` = the caller placed it by hand (drag-to-keep) — don't re-grid.
    public func keepPeek(_ peek: PeekPort, arrange: Bool = true) {
        peekingPorts.removeAll { $0.id == peek.id }
        peekRemaining[peek.id] = nil
        peekTotal[peek.id] = nil
        if let sid = appState.currentSpace?.id {                     // adoption is persisted (Phase 3)
            appState.portWindows.adopt(id: peek.id, into: sid)
        }
        bringToFront(peek.id)
        if arrange { placeUnpositioned(area: lastDesktopArea) }   // an adopted peek arrives unplaced
    }

    private func startPeekCountdown(_ id: String, _ seconds: Double) {
        peekRemaining[id] = seconds
        peekTotal[id] = seconds
        guard peekTimer == nil else { return }
        peekTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPeekCountdowns() }
        }
    }

    private func tickPeekCountdowns() {
        for (id, rem) in peekRemaining {
            if id == hoveredPeekId { continue }                         // hover pauses the countdown
            if zoom == .focus(id) { continue }                          // so does looking at it
            let next = rem - 0.1
            if next <= 0 {
                peekRemaining[id] = nil
                peekTotal[id] = nil
                peekingPorts.removeAll { $0.id == id }                  // evaporate (still lives in its home space)
            } else {
                peekRemaining[id] = next
            }
        }
        if peekRemaining.isEmpty { peekTimer?.invalidate(); peekTimer = nil }
    }

    /// Dismiss a peek from your desktop; it lives on in its home space (nothing is closed).
    public func dismissPeek(_ peek: PeekPort) {
        peekingPorts.removeAll { $0.id == peek.id }
        peekRemaining[peek.id] = nil
        peekTotal[peek.id] = nil
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

    /// The current desktop render area, set by `ShellDesktop`'s GeometryReader on layout. Stored so
    /// the presentation getter/sync (backlog 1.1) can size a focused port's card headlessly. A sane
    /// default until first layout — a focused port implies the desktop has laid out, so this is a floor,
    /// not a live-critical value.
    public var lastDesktopArea: CGSize = CGSize(width: 1440, height: 900)

    // MARK: Presence — who is driving each port (L2.e)

    public struct DriverBadge: Equatable {
        public let driver: String       // the ActorRef wire form
        public let name: String         // what a human reads
        public let until: Date
    }

    /// port udid → who is driving it. Fed by SUBSCRIBING to each visible port's own Notify topic,
    /// not by reading `DriverRegistry`: the registry is a plain value (not `@Published`) and would
    /// never drive a view, and going through the bus is the protocol-correct path anyway — the
    /// header is just another subscriber, exactly like an agent or a remote instance would be.
    @Published public private(set) var portDrivers: [String: DriverBadge] = [:]
    private var driverSubs: [String: Int] = [:]

    /// Keep one driver subscription per visible port. Called when the desktop's unit set changes.
    public func syncDriverSubscriptions() {
        let live = Set(contextItems.compactMap { $0.panel?.udid })
        for id in live where driverSubs[id] == nil {
            let topic = PortNotify.topic(forPortKey: id)
            driverSubs[id] = appState.notifyBus.subscribe(topic: topic) { [weak self] envelope in
                self?.applyDriverEnvelope(envelope, port: id)
            }
        }
        for (id, sub) in driverSubs where !live.contains(id) {
            appState.notifyBus.unsubscribe(id: sub, topic: PortNotify.topic(forPortKey: id))
            driverSubs[id] = nil
            portDrivers[id] = nil
        }
    }

    /// Parse one `{topic, kind, payload}` envelope; only `driver` is ours. Everything else on the
    /// topic (push, console, terminal output) flows past untouched.
    /// Test seam: the desktop only subscribes to ports it is rendering, and there is no desktop
    /// headless. The PARSING is the part worth pinning, so tests feed an envelope straight in.
    func applyDriverEnvelopeForTesting(_ json: String, port: String) {
        applyDriverEnvelope(json, port: port)
    }

    private func applyDriverEnvelope(_ json: String, port: String) {
        guard let data = json.data(using: .utf8),
              let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              env["kind"] as? String == "driver",
              let p = env["payload"] as? [String: Any],
              let driver = p["driver"] as? String,
              let name = p["driverName"] as? String,
              let until = p["until"] as? Double else { return }
        portDrivers[port] = DriverBadge(driver: driver, name: name,
                                        until: Date(timeIntervalSince1970: until))
    }

    /// The badge to SHOW for a port: someone else is driving it, right now.
    ///
    /// Deliberately silent when the driver is you. In the common single-driver case the chrome says
    /// nothing, and it speaks exactly when there is contention — which is the only moment the
    /// information is actionable.
    public func otherDriver(of udid: String?, now: Date = Date()) -> DriverBadge? {
        guard let udid, let badge = portDrivers[udid], now < badge.until else { return nil }
        guard badge.driver != appState.humanPrincipal.map({ ActorRef(principal: $0.id).description })
        else { return nil }
        return badge
    }

    // MARK: First-run breakout (the aquarium video on the first zoom-out; GM brought it back 2026-09-27)

    /// Non-nil while the first-run breakout plays: the rect the video STARTS at, the frame of the port
    /// the person was focused on. It grows from there to full screen, plays out, and fades to leave
    /// them in the space. Set by `ShellView` on the first `.focus → .space` of a first run.
    @Published public var breakoutFrom: CGRect? = nil

    /// Begin the breakout from the focused unit's frame. No-op if one is already running.
    public func startBreakout(area: CGSize) {
        guard breakoutFrom == nil else { return }
        breakoutFrom = ShellPlacement.focusRect(in: area)
    }

    public func endBreakout() { breakoutFrom = nil }

    /// THE desktop-tile predicate — the one source for "which panels are staged as tiles on
    /// this desktop": the current space's tiled panels, plus adopted
    /// foreign ports. The desktop renders this set, placement places into it, and ShellView's
    /// focus branch checks membership — one filter, so they can never drift apart (Phase 0).
    public var desktopTilePanels: [PortPanel] {
        guard let sid = appState.currentSpace?.id else { return [] }
        return appState.portWindows.panels.filter { p in
            p.presentation == "tiled" && !p.isBackground
                && (p.spaceId == sid || p.adoptedSpaceIds.contains(sid) || p.pinnedEverywhere)
        }
    }

    /// Paint order for the desktop's tiles (GM, 2026-09-27): pinned tiles above unpinned ones, each
    /// group by its own z. A rank, not z plus a large offset, so a tile never climbs over the shell's
    /// own layers (the rail, the drag overlays) however many times ports have been raised.
    nonisolated public static func stackRank(_ panels: [PortPanel]) -> [String: Int] {
        let ordered = panels.sorted { a, b in
            a.isAlwaysOnTop != b.isAlwaysOnTop ? !a.isAlwaysOnTop : a.z < b.z
        }
        var rank: [String: Int] = [:]
        for (i, p) in ordered.enumerated() { rank[p.id] = i + 1 }
        return rank
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
            if panel == nil { continue }                  // a port peek whose panel vanished
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

    /// Presentation snapshot for a port resolved by its own id (udid/messageId), or nil if unknown
    /// (backlog 1.1). The source behind `port42.presentation()` (Step 2) and, in Step 3, the per-port
    /// input to `syncPresentation`. Keyed like `owningPortBridge` (backlog 0.5). Lives here, not in the
    /// `PortPresentation` extension, because it reads the file-private `appState`.
    public func presentation(forPortId key: String) -> PortPresentation? {
        guard let panel = appState.portWindows.panels.first(where: { $0.udid == key || $0.messageId == key })
        else { return nil }
        let item = contextItems.first { $0.id == panel.id }
        return Self.presentation(for: panel, zoom: zoom, item: item, area: lastDesktopArea)
    }

    /// The last presentation pushed to each port, keyed by `panel.id` — the diff baseline for
    /// `syncPresentation` (Step 3). Reason-nil (the mapping never sets reason) so the diff compares only
    /// state/visible/w/h. `private(set)` so tests can read it; nothing outside writes it.
    private(set) var lastPresentation: [String: PortPresentation] = [:]

    /// Build the current presentation for every port that owns a live web bridge (Step 3). Terminal
    /// (Ghostty) and SwiftUI chat ports carry no rAF and no JS listener, so they are excluded — as they
    /// are from the desktop's web-unit predicate. Reads live shell/app state; mutates nothing observed.
    func presentationSnapshot() -> [String: PortPresentation] {
        let itemById = Dictionary(contextItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: PortPresentation] = [:]
        for panel in appState.portWindows.panels where panel.portType == "web" {
            out[panel.id] = Self.presentation(for: panel, zoom: zoom,
                                              item: itemById[panel.id], area: lastDesktopArea)
        }
        return out
    }

    /// Whether this port's surface is actually on screen right now (backlog 1.1, Step 4): the
    /// presentation `visible` axis. The ONE computation shared by the AI-suspend gate (0.3, re-keyed)
    /// and the heartbeat skip — not visible = not spending, not woken.
    func isVisible(_ panel: PortPanel) -> Bool {
        let item = contextItems.first { $0.id == panel.id }
        return Self.presentation(for: panel, zoom: zoom, item: item, area: lastDesktopArea).visible
    }

    /// THE one emit funnel (Step 3): snapshot → pure diff → push the changed ports → store the snapshot.
    /// Read-only over observed state and it stores only the non-`@Published` `lastPresentation`, so it can
    /// never feed back into its own trigger (invariant #3). Driven solely by the debounced pipeline in
    /// `init`; never call it per-transition (that is the fragility the teardown work removed).
    func syncPresentation() {
        let next = presentationSnapshot()
        for delta in Self.presentationDeltas(prev: lastPresentation, next: next) {
            appState.portWindows.panels.first(where: { $0.id == delta.id })?
                .bridge.pushEvent(.presentation, data: delta.presentation.bridgeValue)
        }
        lastPresentation = next
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
        placeUnpositioned(area: lastDesktopArea)
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

    /// The space pill and ⌘G: straight to the galaxy from any rung, and back to the space from it
    /// (GM, 2026-09-27: from a focused port the pill only stepped up to the space).
    public func toggleGalaxy() {
        if zoom == .galaxy { zoom = .space } else { zoom = .galaxy; galaxyHover = nil }
    }

    /// ⌘↓ / pinch-in — step DOWN toward a single focused port. Clamps at focus (the floor).
    /// In galaxy, a hovered space-world dives straight into that space (hover-dive).
    public func zoomIn() {
        switch zoom {
        case .galaxy:
            // Hover indexes the WORKING SET (the galaxy front renders workingSpaces only).
            if let h = galaxyHover, appState.workingSpaces.indices.contains(h),
               appState.workingSpaces[h].id != appState.currentSpace?.id {
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
            // A hovered Running card in the open rail pops that port up, as its magnifier does (GM).
            if railOpen, let rid = hoveredRunningId,
               appState.portWindows.hiddenPanels.contains(where: { $0.id == rid }) {
                popRunning(rid); return
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

    /// Where the shell lands on boot/unlock: the current space's desktop — or the GALAXY when
    /// there's nothing working to land on: no space yet (fresh setup), or EVERY space rests
    /// (an all-rested boot shows the empty front + shelf, not the inside of a rested space).
    ///
    /// FIRST RUN overrides all of that: onboarding lands FOCUSED on the space's chat tile (the
    /// first swim is the shell's focus view). With no chat udid yet, hold at the desktop rung —
    /// never the galaxy, which would strand a fresh user outside their only space. The shell
    /// re-applies this reactively once `ensureChatPort` lands the panel. Pure → headless.
    nonisolated public static func initialZoom(hasCurrentSpace: Bool, allRested: Bool,
                                               onboarding: Bool = false,
                                               chatUdid: String? = nil) -> Zoom {
        if onboarding { return chatUdid.map { Zoom.focus($0) } ?? .space }
        return (hasCurrentSpace && !allRested) ? .space : .galaxy
    }

    /// ⌘1…N — jump straight to the Nth WORKING space (0-based, working-set order) and land on
    /// its desktop rung. Rested spaces have no index — ⌘K (which wakes) is their way back.
    public func jumpToSpace(index: Int) {
        let working = appState.workingSpaces
        guard working.indices.contains(index) else { return }
        appState.selectSpace(working[index])
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

    // MARK: Shell-global chords (plan-working-set §B) — the yield BYPASS

    /// The few chords that drive the shell even while a terminal/webview/text field owns the
    /// keyboard. Kept deliberately tiny — every other key keeps today's yield behavior, so
    /// ports never lose a keystroke they currently receive. ⌘⌥Tab joins with the space
    /// switcher (C). ⌘↑/⌘↓ stay yielded (GM call: click/pinch cover the ladder while typing).
    public enum ShellChord: Equatable {
        case cycleForward       // ⌘`  — next desktop unit (MRU)
        case cycleBackward      // ⇧⌘` — previous
        case jumpSpace(Int)     // ⌘1…9 — Nth working space (0-based)
        case quickSwitcher      // ⌘K — the switcher must open from anywhere
        case imagine            // ⌘I — the quick imagine box, from anywhere
        case galaxy             // ⌘G — the galaxy, and back to the space (GM, 2026-09-27)
        case zoomOut            // ⌘↑ — one rung up, even with a port holding the keyboard (GM, 2026-09-29)
    }

    /// Classify a keystroke as a shell-global chord (nil = not one; normal yield applies).
    /// `characters` = `charactersIgnoringModifiers`, lowercased by the caller. The backtick
    /// matches by character ("`"/"~" — layout-proof) with the ANSI keyCode 50 as fallback.
    /// Pure → headless-tested.
    nonisolated public static func shellGlobalChord(keyCode: UInt16, characters: String?,
                                                    command: Bool, shift: Bool,
                                                    option: Bool, control: Bool) -> ShellChord? {
        guard command, !option, !control else { return nil }
        let ch = characters ?? ""
        if keyCode == 50 || ch == "`" || ch == "~" {
            return shift ? .cycleBackward : .cycleForward
        }
        guard !shift else { return nil }
        // ⌘↑ climbs the ladder from anywhere: yielded to a port that held the keyboard, it never got from
        // the space to the galaxy. ⌘↓ still yields, since zooming in needs a target the pointer chose.
        if keyCode == 126 { return .zoomOut }
        if ch == "k" { return .quickSwitcher }
        if ch == "i" { return .imagine }
        if ch == "g" { return .galaxy }
        if let n = Int(ch), (1...9).contains(n) { return .jumpSpace(n - 1) }
        return nil
    }

    // MARK: ⌘` port cycling (plan-working-set §B)

    /// MRU order of the current desktop's units: tiles only (chat included; no peeks, no
    /// parked, no backgrounded), frontmost first — the z-stamp IS the recency signal.
    public var cycleOrder: [String] {
        desktopTilePanels.sorted { $0.z > $1.z }.map(\.id)
    }

    /// One cycling BURST: chords < `cycleBurstWindow` apart walk an order snapshotted at the
    /// first tap (naive MRU re-sorts on every raise — A and B would swap ranks 1↔2 forever
    /// and a third tap could never reach C). The burst commits ONE MRU update when it ends.
    private struct CycleBurst { var order: [String]; var index: Int; var lastAt: Date }
    private var cycleBurst: CycleBurst?
    private var cycleCommitTimer: Timer?
    public static let cycleBurstWindow: TimeInterval = 1.0

    /// Render-only top boost for the burst's current landing (like exposé's) — visible on top
    /// WITHOUT a z stamp, so intermediates never pollute the MRU order.
    @Published public var cycleBoostId: String?
    /// A brief accent flash on the landing tile so the hop is visible; state clears it.
    @Published public var cycleFlashId: String?

    /// Pure wrap-around step through a snapshot of `count` units. Forward walks DOWN the MRU
    /// list (toward older); backward wraps up. Headless-tested.
    nonisolated public static func cycleNext(count: Int, index: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        return ((index + (forward ? 1 : -1)) % count + count) % count
    }

    /// ⌘` / ⇧⌘` — one cycling step. `now` injected for headless burst-timing tests.
    public func cycleStep(forward: Bool, now: Date = Date()) {
        guard zoom != .galaxy else { return }                       // cycling is a desktop gesture
        if let b = cycleBurst, now.timeIntervalSince(b.lastAt) <= Self.cycleBurstWindow {
            advanceCycle(forward: forward, now: now)
        } else {
            commitCycleBurst()                                      // a stale burst commits first
            let order = cycleOrder
            guard order.count > 1 else { return }
            // Start from the unit you're ON (focused, else selected, else frontmost) so the
            // first tap bounces to the SECOND hot port, like macOS ⌘`.
            let startId: String? = { if case .focus(let f) = zoom { return f } else { return selectedTileId } }()
            let start = startId.flatMap { order.firstIndex(of: $0) } ?? 0
            cycleBurst = CycleBurst(order: order, index: start, lastAt: now)
            advanceCycle(forward: forward, now: now)
        }
    }

    private func advanceCycle(forward: Bool, now: Date) {
        guard var b = cycleBurst else { return }
        let live = Set(desktopTilePanels.map(\.id))
        var idx = b.index
        for _ in 0..<b.order.count {                                // skip ids that died mid-burst
            idx = Self.cycleNext(count: b.order.count, index: idx, forward: forward)
            if live.contains(b.order[idx]) { break }
        }
        guard live.contains(b.order[idx]) else { commitCycleBurst(); return }   // nothing left alive
        b.index = idx; b.lastAt = now
        cycleBurst = b
        landCycle(on: b.order[idx])
        scheduleCycleCommit()
    }

    /// Land a step: select + boost + flash; at the focus rung swap the focused unit IN PLACE
    /// (a geometry state — the next unit's own view resizes; no zoom-out bounce). The keyboard
    /// follows the landing at BOTH rungs — cycling is an intentional "go to that port", unlike
    /// hover-raise (which deliberately never steals the keyboard). The .focus swap's keyboard
    /// handoff also runs via ShellView's zoom onChange; the direct call covers the .space rung.
    private func landCycle(on id: String) {
        selectedTileId = id
        cycleBoostId = id
        cycleFlashId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if self?.cycleFlashId == id { self?.cycleFlashId = nil }
        }
        if case .focus = zoom {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { zoom = .focus(id) }
        }
        appState.portWindows.focusKeyboard(on: id)
    }

    private func scheduleCycleCommit() {
        cycleCommitTimer?.invalidate()
        cycleCommitTimer = Timer.scheduledTimer(withTimeInterval: Self.cycleBurstWindow,
                                                repeats: false) { [weak self] _ in
            Task { @MainActor in self?.commitCycleBurst() }
        }
    }

    /// End of burst: the ONE MRU update — only the final landing gets a z stamp.
    public func commitCycleBurst() {
        cycleCommitTimer?.invalidate(); cycleCommitTimer = nil
        cycleBoostId = nil
        guard let b = cycleBurst else { return }
        cycleBurst = nil
        let id = b.order[b.index]
        if desktopTilePanels.contains(where: { $0.id == id }) { bringToFront(id) }
    }

    // MARK: Key yield (§3.1) — pure decision, headless-tested

    /// Whether the shell should YIELD a key to a focused field/port instead of driving the zoom
    /// ladder. `isEditor` = a text editor / web view / terminal owns the keyboard (so any key it
    /// wants, including ⌘-combos while typing, passes through). **Esc** additionally yields whenever
    /// the focused port is a **terminal** — vim/less/any TUI needs its Esc (a non-terminal focused
    /// port still lets Esc peel back out of focus). Everything else drives the ladder.
    /// `commandBoxOpen`: ⌘K, imagine or the session list is up. Esc then closes it, even with its own
    /// field holding the keyboard (GM, 2026-09-27: Esc did nothing in them; the field editor took it as
    /// "cancel" before the box's own handler).
    nonisolated public static func shouldYieldKey(isEditor: Bool, keyCode: UInt16,
                                                  focusedPortIsTerminal: Bool, commandBoxOpen: Bool = false) -> Bool {
        if keyCode == 53 { return !commandBoxOpen && (isEditor || focusedPortIsTerminal) }   // 53 = Esc
        return isEditor
    }

    /// A command box is up: ⌘K, imagine, the session list, sharing a port or accepting an invite.
    public var commandBoxOpen: Bool {
        showQuickSwitcher || showImagine || showImportSessions || shareTarget != nil || pendingInvite != nil
    }

    // MARK: - Where the person is (#130)

    /// The window's title: where the person is, for VoiceOver and for any tool that reads window
    /// titles (Watch). Port42 set none, so every such reader saw only "Port42".
    /// - locked (or not set up): "Port42" alone, so the lock screen names no space or port;
    /// - the galaxy: "Port42 · All spaces";
    /// - a space: its name;
    /// - a focused port: "<space> · <port>", as in "port42-app · Drafts".
    public static func windowTitle(locked: Bool, space: String?, zoom: Zoom, focusedTitle: String?) -> String {
        if locked { return "Port42" }
        let spaceName = (space?.isEmpty == false) ? space! : "Port42"
        switch zoom {
        case .galaxy: return "Port42 · All spaces"
        case .space: return spaceName
        case .focus:
            guard let t = focusedTitle, !t.isEmpty else { return spaceName }
            return "\(spaceName) · \(t)"
        }
    }

    /// This window's title now.
    public var windowTitle: String {
        var focused: String?
        if case .focus(let id) = zoom {
            focused = appState.portWindows.panels.first { $0.id == id || $0.udid == id }?.title
        }
        return Self.windowTitle(locked: appState.showDreamscape || !appState.isSetupComplete,
                                space: appState.currentSpace?.name, zoom: zoom, focusedTitle: focused)
    }

    /// What VoiceOver says for a port's tile: its name and what kind of port it is, and whether it
    /// is the one in focus.
    public static func tileAccessibilityLabel(title: String, portType: String?, focused: Bool) -> String {
        let kind: String
        switch portType {
        case "terminal": kind = "terminal"
        case "browser": kind = "browser"
        default: kind = "port"
        }
        let name = title.isEmpty ? "Untitled" : title
        return focused ? "\(name), \(kind), in focus" : "\(name), \(kind)"
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
    /// Re-seeds against the LIVE panels first, so this authority never drifts BELOW a panel stamped
    /// by `PortWindowManager.bringToFront` (max+1 — e.g. terminal focus). Without the re-seed the
    /// counter goes stale and a freshly created/restored port gets a z UNDER existing tiles (measured:
    /// counter at 80 while live tiles were at 171, so new ports landed behind everything).
    @discardableResult
    public func nextZ() -> Int {
        zCounter = max(zCounter, appState.portWindows.panels.map(\.z).max() ?? 0) + 1
        return zCounter
    }

    /// Keep the counter ahead of any restored `z` so freshly focused ports still land on top.
    public func seedZCounter(from panels: [PortPanel]) {
        zCounter = max(zCounter, panels.map(\.z).max() ?? 0)
    }

    // MARK: Tile geometry (S3 — movable tiles; positions live in state, not a render grid)

    /// A tile's default full size (titlebar + body) when a panel carries none yet.
    public static let defaultTileSize = CGSize(width: 460, height: 400)

    /// Minimum tile size (drag-resize floor). Below card size (220x160), so a tile resized small becomes
    /// its state card, as a peek is, and grows back into its content (GM, 2026-09-29).
    nonisolated public static let minTileSize = CGSize(width: 150, height: 110)

    /// The right-edge rail's three drop zones, top to bottom: park (paused, listed in one control),
    /// hide (the port keeps running with no tile, shown as a card) and close (delete the port). Hide moved from the top bar to the rail, so everything a tile is dragged to
    /// is on the right (GM, 2026-09-29).
    public enum ParkZone: Equatable { case park, close, hide }

    /// Which rail zone the in-progress tile drag is currently over (drives the rail highlight); nil
    /// when the drag isn't over the rail.
    @Published public var draggingOverPark: ParkZone?
    /// The rail slot a drag would land in, while one is over the park zone: the rail draws a gap
    /// there so the drop is visible before it happens (GM, 2026-09-25).
    @Published public var railDropSlot: Int?
    /// The chip being dragged within the rail, if any: the gap is placed among the OTHER chips.
    @Published public var railDraggingId: String?

    /// Where the drop gap goes in the rail as drawn: before the chip at the returned index, or at the
    /// end when nil and `slot` is past the last. `slot` counts only the chips other than `dragging`,
    /// which stays in place while it is dragged. Pure.
    nonisolated public static func railGapIndex(ids: [String], dragging: String?, slot: Int) -> Int? {
        let others = ids.filter { $0 != dragging }
        guard slot < others.count else { return nil }
        return ids.firstIndex(of: others[slot])
    }
    /// True while a tile is being dragged/resized — suppresses hover-to-front so tiles you drag OVER
    /// don't pop in front of the one in your hand.
    @Published public var isDraggingTile: Bool = false

    /// The right rail's width when open: 140, wide enough for a hidden port's card (GM, 2026-09-29). It
    /// was `max(64, screenW·0.05)` while it held only parked chips.
    nonisolated public static func parkWidth(_ screenW: CGFloat) -> CGFloat { 140 }

    /// The rail folded: a thin edge, so the desktop runs up to it and a tile beside it can still be
    /// grabbed and resized (#192: a tile under the open rail was lost behind it). Tiles are placed up to
    /// this edge; the rail opens over them on hover and while a tile is dragged.
    nonisolated public static let railFoldedWidth: CGFloat = 12

    /// The rail's width as drawn.
    nonisolated public static func railWidth(open: Bool, screenW: CGFloat) -> CGFloat {
        open ? parkWidth(screenW) : railFoldedWidth
    }

    /// The pointer has the rail open: on the edge, or swept toward it (see `railWantsOpen`).
    @Published public var railHovered = false
    /// A tile or peek is being moved, so its drop zones must be there to drop on.
    @Published public var tileMoving = false
    /// A running port has just started needing the person: the rail shows it for a moment.
    @Published public var railAlerting = false
    /// Whether the rail is open: for the pointer, for the whole of a move so every zone can take the
    /// drop, and for a moment when a running port newly needs you.
    public var railOpen: Bool { railHovered || tileMoving || railAlerting }

    /// How far out a quick sweep toward the edge opens the rail ahead of the pointer (GM: "if I'm moving
    /// to that edge it should pre-emptively open"), and how quick: points per mouse event, rightward.
    /// A slow approach does not open it, so a tile's right edge beside the rail can still be resized.
    nonisolated public static let railApproachBand: CGFloat = 160
    nonisolated public static let railApproachSpeed: CGFloat = 6
    /// How long a new problem holds the rail open.
    nonisolated public static let railAlertTime: TimeInterval = 4

    /// Whether the pointer wants the rail open. `distance` is from the desktop's right edge, `deltaX` the
    /// pointer's last move (positive is rightward). Open at once on the edge or on a quick sweep toward it;
    /// once open, stay open only while the pointer is over it (GM: shut as soon as you are off it). Pure.
    nonisolated public static func railWantsOpen(isOpen: Bool, distance: CGFloat, deltaX: CGFloat,
                                                 screenW: CGFloat) -> Bool {
        if isOpen { return distance <= parkWidth(screenW) }
        if distance <= railFoldedWidth { return true }
        return distance <= railApproachBand && deltaX >= railApproachSpeed
    }

    /// A tile move ended. Dropped on the rail, the pointer is over it, so the rail stays open until the
    /// pointer leaves (GM, 2026-09-29); pointer moves are not reported during a drag, so it is set here.
    public func endTileMove(overRail: Bool) {
        railHovered = overRail
        tileMoving = false
    }

    /// The pointer moved over the desktop. Opens the rail the moment it is wanted and folds it the moment
    /// the pointer is off it.
    public func pointerMoved(distanceFromRight distance: CGFloat, deltaX: CGFloat, screenW: CGFloat) {
        let want = Self.railWantsOpen(isOpen: railHovered, distance: distance, deltaX: deltaX, screenW: screenW)
        if want != railHovered { railHovered = want }
    }

    /// The running ports that already had the rail's attention, so each problem opens it once.
    private var railAlerted: Set<String>?
    private var railAlertTask: Task<Void, Never>?

    /// The ports whose problem is new since the last look. Pure.
    nonisolated public static func newAlerts(previous: Set<String>, current: Set<String>) -> Set<String> {
        current.subtracting(previous)
    }

    /// The running ports that need the person right now. The first report only records them (a launch
    /// does not throw the rail open for old news); after that, a new one opens the rail for a moment.
    public func noteRunningAlerts(_ ids: Set<String>) {
        guard let previous = railAlerted else { railAlerted = ids; return }
        railAlerted = ids
        guard !Self.newAlerts(previous: previous, current: ids).isEmpty else { return }
        openRailBriefly(Self.railAlertTime)
    }

    /// How long the rail shows a port going back into it after a look.
    nonisolated public static let railReturnTime: TimeInterval = 2.5

    /// Hold the rail open for a moment, for something the person should see land there.
    public func openRailBriefly(_ seconds: TimeInterval) {
        railAlerting = true
        railAlertTask?.cancel()
        railAlertTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.railAlerting = false
        }
    }

    /// Whether the folded edge shows a red dot: some running port's card says something needs you.
    nonisolated public static func railNeedsAttention(_ cards: [PortCard]) -> Bool {
        cards.contains { $0.needsAttention }
    }

    /// Rail geometry, fixed so a point maps to a slot exactly (Phase 2 step 3): the chrome clearance
    /// plus the tray icon put the first chip's top here, and every chip is one pitch below the last.
    nonisolated public static let railChipHeight: CGFloat = 44
    nonisolated public static let railChipSpacing: CGFloat = 10
    nonisolated public static let railFirstChipTop: CGFloat = parkZoneHeight + railHeaderHeight + railChipSpacing
    /// The park section's heading row, under the hidden section.
    nonisolated public static let railHeaderHeight: CGFloat = 26

    /// The rail slot under a desktop-space y, among `count` chips (count = append at the bottom).
    nonisolated public static func railSlot(forY y: CGFloat, count: Int) -> Int {
        let pitch = railChipHeight + railChipSpacing
        let slot = Int(((y - railFirstChipTop) / pitch).rounded())
        return min(max(0, slot), count)
    }

    /// The rail top to bottom (GM, 2026-09-29, swapped the same day): parked (one row, a count and a
    /// list, since a parked port is paused), hidden (the rest: a card per hidden port, since it is still
    /// running and worth watching), and the close zone (a trash icon) at the bottom.
    nonisolated public static let parkZoneHeight: CGFloat = 40
    nonisolated public static let closeZoneHeight: CGFloat = 64
    /// A card in the rail is one fixed height, so a point maps to a slot exactly.
    nonisolated public static let railCardHeight: CGFloat = 64
    nonisolated public static let railCardSpacing: CGFloat = 6
    nonisolated public static let pausedMaxHeight: CGFloat = 260

    /// How tall the Paused section's cards are, open, for `count` paused ports (0 when folded).
    nonisolated public static func pausedCardsHeight(open: Bool, count: Int) -> CGFloat {
        guard open, count > 0 else { return 0 }
        return min(pausedMaxHeight, CGFloat(count) * (railCardHeight + railCardSpacing) + railCardSpacing)
    }

    /// The Running slot under a desktop-space y, among `count` cards (count = after the last). The cards
    /// start below the Paused header, Paused's open cards, and the Running header.
    nonisolated public static func runningSlot(forY y: CGFloat, pausedHeight: CGFloat, count: Int) -> Int {
        let top = parkZoneHeight + pausedHeight + railHeaderHeight
        let slot = Int(((y - top) / (railCardHeight + railCardSpacing)).rounded())
        return min(max(0, slot), count)
    }

    /// Classify a point (in desktop coordinates) against the right rail: the top band of the strip is
    /// **park**, the bottom **close**, the rest **hide** (where the hidden ports' cards are), and
    /// everything left of the strip is nil. Pure → headless-testable.
    nonisolated public static func parkZone(at p: CGPoint, in area: CGSize, pausedHeight: CGFloat = 0) -> ParkZone? {
        guard p.x >= area.width - parkWidth(area.width) else { return nil }
        if p.y < parkZoneHeight + pausedHeight { return .park }
        return p.y >= area.height - closeZoneHeight ? .close : .hide
    }

    /// Whether the rail's Paused section is unfolded (GM, 2026-09-29). Remembered across launches.
    @Published public var pausedOpen: Bool = UserDefaults.standard.bool(forKey: "railPausedOpen") {
        didSet { UserDefaults.standard.set(pausedOpen, forKey: "railPausedOpen") }
    }

    /// The space's own chat, dropped down from the top bar. A space is a port, so its chat is the
    /// same panel every port carries (docs/design-chat-port.md).
    @Published public var spaceChatOpen = false
    /// The space's chat zoomed to a full view, like a focused port (GM, 2026-09-25).
    @Published public var spaceChatExpanded = false
    /// Chats are resized by dragging (GM, 2026-09-26, release hit list): a port's chat by the share of
    /// the port's body it covers, up to all of it, by port udid; the space chat by its size. Unset is
    /// the default drop-down.
    @Published public var portChatShare: [String: CGFloat] = [:]
    @Published public var spaceChatSize: CGSize?

    nonisolated static let chatMinHeight: CGFloat = 100
    nonisolated static let spaceChatMin = CGSize(width: 320, height: 220)
    nonisolated static let spaceChatDefault = CGSize(width: 440, height: 360)

    /// The height of a port's open chat over a body `body` tall: dragged to a share of it (at least
    /// `chatMinHeight`, at most the whole body), or the default.
    nonisolated static func portChatHeight(share: CGFloat?, body: CGFloat) -> CGFloat {
        guard body > 0 else { return 0 }
        guard let share else { return min(max(150, body * 0.45), max(0, body - 60)) }
        return min(body, max(min(chatMinHeight, body), share * body))
    }

    /// The share a drag to `height` sets, kept in range.
    nonisolated static func portChatShare(height: CGFloat, body: CGFloat) -> CGFloat {
        guard body > 0 else { return 1 }
        return min(1, max(min(chatMinHeight, body) / body, height / body))
    }

    /// The space chat's size: dragged (kept between its minimum and the room there is), or the default.
    nonisolated static func spaceChatSize(_ proposed: CGSize?, room: CGSize) -> CGSize {
        let p = proposed ?? spaceChatDefault
        return CGSize(width: min(max(spaceChatMin.width, p.width), max(spaceChatMin.width, room.width)),
                      height: min(max(spaceChatMin.height, p.height), max(spaceChatMin.height, room.height)))
    }

    /// Clicking a companion in the dock/member list. A CLI companion (claude/gemini, `openInTerminal`)
    /// launches/reveals its terminal port; a headless one is reached in the space's chat.
    public func activateCompanion(_ companion: AgentConfig) {
        if companion.openInTerminal {
            guard let sid = appState.currentSpace?.id else { return }
            // Spawn/restore the terminal if needed, then bring it to the front so clicking the dock
            // avatar always switches to the companion's window (not a no-op when already live).
            appState.ensureTerminalLive(companion: companion, spaceId: sid)
            zoom = .space
            appState.focusTerminal(companionName: companion.displayName)
        } else {
            spaceChatOpen = true
        }
    }

    /// Drop every surfaced DM (used when leaving a desktop — DMs belong to the working session on the
    /// space you opened them from, not the one you switch to).
    public func clearOpenDMs() {
        // (Adopted ports are NOT cleared — Phase 3: adoption lives on the panel, persisted,
        // so a kept port is still on this desktop when you come back. Peeks stay transient.)
        peekingPorts.removeAll()             // peeks belong to the desktop you were on
        peekRemaining.removeAll()
        peekTimer?.invalidate(); peekTimer = nil
    }

    /// Dismiss a tile via its ✕. A surfaced foreign chat/port is DETACHED (removed from this desktop,
    /// but lives on in its home space); a native tile of THIS space is actually closed.
    public func dismissTile(_ panel: PortPanel) {
        if let cur = appState.currentSpace?.id, panel.adoptedSpaceIds.contains(cur) {
            appState.portWindows.unadopt(id: panel.id, from: cur)   // adopted foreign port → detach (persisted)

            return
        }
        appState.portWindows.close(panel.id)                         // a real tile of this space → close it
    }

    /// Hide a port (GM, 2026-09-26): off the desktop and the rail, still running, listed under the top
    /// bar's "N hidden" to show again. From the port's "…" or by dragging it onto the top bar.
    public func hideTile(_ id: String, at slot: Int? = nil) {
        if let slot { appState.portWindows.minimize(id, at: slot) } else { appState.portWindows.applyPresentation("hidden", to: id) }
    }

    /// How tall the rail's open Paused cards are right now, in the current space.
    public var pausedCardsHeight: CGFloat {
        Self.pausedCardsHeight(open: pausedOpen, count: appState.portWindows.railIds(in: appState.currentSpace?.id).count)
    }

    /// A running port popped up from the rail for a look (#191), and the Running slot it came from.
    public struct PoppedRunning: Equatable { public let id: String; public let slot: Int }
    @Published public private(set) var poppedRunning: PoppedRunning?
    /// The Running card under the pointer, so a pinch or ⌘↓ pops that port up.
    public var hoveredRunningId: String?

    /// Pop a running port up for a look: zoomed to focus and live, but not kept (GM: "zoom into running
    /// ports and pop them up, and then zoom out will pop them back in"). One at a time.
    public func popRunning(_ id: String) {
        returnPopped()
        guard let panel = appState.portWindows.panels.first(where: { $0.id == id }) else { return }
        let slot = appState.portWindows.hiddenPanels(in: panel.spaceId).firstIndex { $0.id == id } ?? 0
        showHidden(id)
        hoveredRunningId = nil
        poppedRunning = PoppedRunning(id: id, slot: slot)
        withAnimation(.spring(response: 0.4)) { zoom = .focus(id) }
    }

    /// Keep the popped-up port: it is already a tile, so it simply stops being on loan (a click on it
    /// in zoom view, as for a peek).
    public func keepPopped() { poppedRunning = nil }

    /// Send the popped-up port back into Running, in the slot it came from.
    public func returnPopped() {
        guard let p = poppedRunning else { return }
        poppedRunning = nil
        hideTile(p.id, at: p.slot)
        // Show it going back, so a zoom out does not seem to lose the port (GM, 2026-09-29).
        openRailBriefly(Self.railReturnTime)
    }

    /// Zooming anywhere but the popped-up port sends it back.
    private func returnPoppedIfLeft() {
        guard let p = poppedRunning, zoom != .focus(p.id) else { return }
        returnPopped()
    }

    /// Show a hidden port (Phase 3.2): on its home desktop, going there if it is another space, placed
    /// if it has no spot, and frontmost. Its view was running all along, so it only remounts.
    public func showHidden(_ id: String) {
        guard let panel = appState.portWindows.panels.first(where: { $0.id == id }) else { return }
        if let sid = panel.spaceId, sid != appState.currentSpace?.id,
           let space = appState.spaces.first(where: { $0.id == sid }) {
            appState.selectSpace(space)
        }
        appState.portWindows.restore(id)
        placeUnpositioned(area: lastDesktopArea)
        bringToFront(id)
    }

    /// Bring a tile to the front (focus/hover/drag-start): stamp it frontmost via `nextZ()` and
    /// select it. `setZ` no-ops if the id isn't a panel, so it's safe for any tile.
    public func bringToFront(_ tileId: String) {
        selectedTileId = tileId
        appState.portWindows.setZ(id: tileId, z: nextZ())
    }

    /// Give every unplaced tile on this desktop a spot, moving NOTHING that already has one.
    ///
    /// Phase 1, and the whole point of the unit: a birth places, it does not re-grid. Everything that
    /// places a port (a spawn, a park restore, an adoption, the first paint of a desktop) calls this.
    /// There is no re-grid at all: ⌘L went in nautilus Phase 2. Tiles are walked in z order so `place` sees the
    /// frontmost tile last, which is what its cascade fallback stacks on.
    public func placeUnpositioned(area: CGSize) {
        guard let desktop = appState.currentSpace?.id else { return }
        let panels = desktopTilePanels.sorted { $0.z < $1.z }
        // Occupied = every tile placed ON THIS DESKTOP, plus the peek column, which is drawn OVER the
        // tiles at a fixed left-edge slot. Without the peeks a newborn lands under one.
        var occupied = panels.compactMap { p in p.position(on: desktop).map { CGRect(origin: $0, size: p.size) } }
        occupied.insert(contentsOf: peekingPorts.indices.map { ShellPlacement.railSlot($0, in: area) }, at: 0)

        for p in panels where p.position(on: desktop) == nil {
            let origin = ShellPlacement.place(p.size, among: occupied, in: area)
            ArrangeLog.note("place", "id=\(shortId(p.id)) at=\(Int(origin.x)),\(Int(origin.y)) "
                            + "size=\(Int(p.size.width))x\(Int(p.size.height)) among=\(occupied.count) "
                            + "desktop=\(shortId(desktop))")
            appState.portWindows.updateTileFrame(id: p.id, position: origin, size: nil, on: desktop)
            occupied.append(CGRect(origin: origin, size: p.size))
        }
    }

    /// Rescue tiles the window shrank out from under. A tile holds an absolute position and nothing
    /// re-clamps it, so making the window smaller (or restoring a layout saved on a bigger display)
    /// can leave a tile completely outside the visible desktop with no drag able to reach it. Phase 1
    /// removes the accidental re-grids that used to rescue it by luck, so this is the replacement:
    /// it moves ONLY what is off-screen, and never the rest.
    public func clampTilesIntoView(area: CGSize) {
        guard let desktop = appState.currentSpace?.id else { return }
        let bounds = ShellPlacement.workArea(in: area)
        for p in desktopTilePanels {
            guard let pos = p.position(on: desktop) else { continue }
            let frame = CGRect(origin: pos, size: p.size)
            // Off-screen means genuinely unreachable, not merely hanging over an edge: a hand-placed
            // tile that overlaps the dock or the rail is a choice, and it stays.
            guard !bounds.intersects(frame) || frame.minX >= bounds.maxX || frame.minY >= bounds.maxY
                    || frame.maxX <= bounds.minX || frame.maxY <= bounds.minY else { continue }
            let fixed = ShellPlacement.clamped(pos, size: p.size, in: bounds)
            ArrangeLog.note("clampIntoView", "id=\(shortId(p.id)) \(Int(pos.x)),\(Int(pos.y))→\(Int(fixed.x)),\(Int(fixed.y))")
            appState.portWindows.updateTileFrame(id: p.id, position: fixed, size: nil, on: desktop)
        }
    }

    /// Log-friendly id: the tail is what distinguishes two ports, and a full UUID per tile makes a
    /// line unreadable.
    nonisolated static func shortId(_ id: String) -> String { String(id.suffix(6)) }
    nonisolated func shortId(_ id: String) -> String { Self.shortId(id) }

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
