import SwiftUI
import AppKit
import WebKit

/// SHELL — S2.2b. The real shell desktop that replaces `ContentView` at the space rung: a Chrome
/// top bar (§7a) + a grid of tiled ports composited over the dreamscape, plus
/// a bottom launcher dock. Every port is ONE persistent unit (Port Units, plan §3): tile / peek /
/// focus are geometry states of the same mounted view — no reparenting, no focus overlay.
/// Every port carries its own chat, opened from its title bar; the space's is in the top bar.

// MARK: - Chrome (Layer 2 top bar, §7a)

struct ShellChrome: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState

    var body: some View {
        // Every element sits in a 26pt-tall container (chromeRow) so all their vertical
        // centers coincide — intrinsic sizes differ (Menu, padded capsule, bare icons).
        HStack(spacing: 16) {
            chromeRow { markMenu }
            // ✨ + active-space name → toggles the galaxy (the only way up).
            Button {
                withAnimation(.spring(response: 0.4)) { shell.toggleGalaxy() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(shell.accent)
                    Text(shell.space?.name ?? "—").font(Port42Theme.monoBold(12)).foregroundStyle(Port42Theme.textPrimary)
                }
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(shell.accent.opacity(shell.zoom == .galaxy ? 0.2 : 0.12), in: Capsule())
                .overlay(Capsule().stroke(shell.accent.opacity(shell.zoom == .galaxy ? 0.7 : 0.4), lineWidth: 1))
                .frame(height: 26)
            }
            .buttonStyle(.plain).help("All spaces (⌘G)")

            // The space's own chat: a space is a port, so it carries the same companion bar.
            if let sid = shell.spaceId {
                chromeRow {
                    PortChatBar(chats: appState.chats, key: sid, me: appState.currentUser?.id,
                                accent: shell.accent, open: shell.spaceChatOpen) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { shell.spaceChatOpen.toggle() }
                    }
                }
                .onAppear { appState.chats.load(sid, from: appState.db) }
                .onChange(of: sid) { _, new in appState.chats.load(new, from: appState.db) }
            }

            // New Space lives in the galaxy now (spaces are the galaxy's business), not the Chrome.

            Spacer()

            // Same order as the pre-shell header cluster: status dots → pause → usage → settings.
            // (Power/sign-out/reset moved to the PORT42 mark menu on the left.)
            chromeRow { statusCluster }                      // gateway
            // Reset background — a SHELL-level control, not a per-port one. Appears only when a port
            // is set as the background; clears it back to the ambient dreamscape and pops the port
            // back onto the desktop.
            if shell.hasBackgroundPort {
                chromeButton("moon.stars", "Reset background") { shell.clearBackgroundToTile() }
            }
            // Voice, when it has something to say about itself (a download, a load, a refusal). It sits in the
            // chrome next to the other app-level state rather than floating over the desktop, where it overlaid
            // the rail (GM, 2026-09-27). A hold shows on the tile it is going into, not here.
            if let voice = shell.voiceIndicatorForSpace {
                chromeRow {
                    VoiceStatus(accent: shell.accent, label: voice.label, live: voice.live)
                        .help("Voice input")
                }
            }
            chromeButton("gearshape", "Settings") { shell.showSettings = true }

            chromeRow { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 20) }
            chromeRow { profileChip }                        // name + PFP, far right
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(.black.opacity(0.45))
        .overlay(Rectangle().fill(shell.accent.opacity(0.25)).frame(height: 1), alignment: .bottom)
    }

    /// The PORT42 mark is the session menu: sign out (lock) · power down (reboot) · reset (erase).
    private var markMenu: some View {
        Menu {
            Button { appState.lockApp() } label: { Label("Sign out — screensaver lock", systemImage: "moon.zzz") }
            Button { NSApp.terminate(nil) } label: { Label("Power down — quit", systemImage: "power") }
            Divider()
            Button(role: .destructive) { appState.resetApp() } label: { Label("Reset — erase all", systemImage: "trash") }
        } label: {
            mark
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .appKitTooltip("Session — sign out · power · reset")
    }

    /// The Port42 diamond — icon only (no "PORT42 // SHELL" wordmark). It IS the session menu button,
    /// like the Apple menu. A rotated square renders reliably as a Menu label (a Canvas doesn't).
    private var mark: some View {
        Rectangle().fill(shell.accent)
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(45))
            .frame(width: 24, height: 24)                 // hit box around the diamond
            .shadow(color: shell.accent.opacity(0.8), radius: 5)
            .contentShape(Rectangle())
    }

    /// The Chrome's uniform 26pt row container — centers any element on the shared axis.
    private func chromeRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(height: 26)
    }

    private func chromeButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Port42Theme.textSecondary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).appKitTooltip(help)
    }

    // MARK: global status + kill switch (ported from the pre-shell header cluster)

    /// gateway (bolt).
    private var statusCluster: some View {
        HStack(spacing: 9) {
            // Every indicator ALWAYS shows — the icon+color carry on/off state, they never disappear.
            Image(systemName: appState.door.isConnected ? "bolt.fill" : "bolt.slash").font(.system(size: 10))
                .foregroundStyle(appState.door.isConnected ? .green : Port42Theme.textSecondary)
                .appKitTooltip(appState.door.isConnected ? "Gateway connected" : "Gateway disconnected")
        }
    }


    /// Account identity on the far right: display name, then the PFP disc (name left of the PFP).
    private var profileChip: some View {
        HStack(spacing: 8) {
            Text(appState.currentUser?.displayName ?? "you").font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
            Circle().fill(shell.accent.gradient).frame(width: 22, height: 22)
                .overlay(Text(userInitials).font(Port42Theme.monoBold(9)).foregroundStyle(.white))
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
        }
    }
    private var userInitials: String {
        let n = appState.currentUser?.displayName ?? "you"
        let parts = n.split(separator: " ")
        if parts.count >= 2 { return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased() }
        return String(n.prefix(2)).uppercased()
    }

}

// MARK: - Desktop (tiled ports over the dreamscape; movable + resizable, z-ordered)

struct ShellDesktopView: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    /// Shared namespace for the park-rail-chip → tile restore morph (Bug 2): a parked port's chip
    /// (isSource) and its tile (dest) are never present together, so the tile animates OUT of the
    /// chip's location on restore instead of sliding in from the screen edge.
    @Namespace private var restoreNS

    private var sid: String? { shell.spaceId }

    /// The tiled ports on this desktop — `ShellState.desktopTilePanels`, the ONE predicate
    /// shared with placement and ShellView's focus branch (Phase 0: no drift possible).
    private var tiledPanels: [PortPanel] { shell.desktopTilePanels }

    /// Everything the desktop renders (Phase 1): tiles ∪ peeks, one unit per id — a peek is
    /// the same unit as the tile it may become; adopt/preview never remounts.
    private var contextItems: [ShellState.PortContextItem] { shell.contextItems }

    /// The desktop unit currently focused (resize-in-place) — a tile OR a previewed peek.
    private var focusedUnitId: String? {
        if case .focus(let id) = shell.zoom, contextItems.contains(where: { $0.id == id }) { return id }
        return nil
    }


    var body: some View {
        GeometryReader { geo in
            // Each tile places itself with `.position` (which sets a real layout frame, so its
            // hover/hit region lands where the tile is drawn — `.offset` leaves the layout frame at
            // the origin, piling every tile's tracking area on the top-left). The trick that stops a
            // greedy positioned frame from swallowing clicks: NO interactive modifier (onHover /
            // gesture) is attached AFTER `.position` — they all sit on the bounded tile content.
            ZStack {
                // Exposé backdrop: dim behind the spread tiles; tapping empty space exits (no pick).
                if shell.exposeActive {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .onTapGesture { withAnimation(.spring(response: 0.4)) { shell.exposeActive = false } }
                        .zIndex(1)
                }
                // Focus backdrop: dims the desktop + rails behind a focused unit (tile OR
                // previewed peek); tap → back to the space. The unit sits above at focusZ.
                if focusedUnitId != nil {
                    Color.black.opacity(0.75).ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.spring(response: 0.4)) { shell.zoom = .space } }
                        .zIndex(ShellPlacement.backdropZ)
                        .transition(.opacity)
                }
                // Every desktop unit — tiles AND peeks, ONE ForEach (I3), identity = port id
                // (I4). Tile / peek / focus are geometry states of the same mounted view
                // (placement §3): a previewed peek resizes railSlot → focusRect in place; an
                // adopted peek slides rail → grid — never re-mounted. Paint order is zIndex.
                // Pinned tiles paint above unpinned ones (ShellState.stackRank).
                let ranks = ShellState.stackRank(contextItems.compactMap(\.panel))
                ForEach(contextItems) { item in
                    let fallbackIdx = tiledPanels.firstIndex { $0.id == item.id } ?? 0
                    let pl = ShellPlacement.placement(
                        id: item.id, position: item.panel?.position(on: sid),
                        size: item.panel?.size ?? ShellPlacement.peekSize,
                        z: ranks[item.id] ?? item.panel?.z ?? 0,
                        zoom: shell.zoom, onDesktop: true,
                        peekIndex: item.peekIndex, fallbackIndex: fallbackIdx,
                        area: geo.size)
                    ShellTile(shell: shell, appState: appState,
                              tile: ShellTileModel(id: item.id,
                                                   title: item.peek?.title ?? item.panel?.title ?? "port",
                                                   panel: item.panel),
                              // #196: a neighbor giving way to a resize is drawn where it goes.
                              frame: shell.makeRoomPreview[item.id] ?? ShellPlacement.resolvedTileFrame(
                                  position: item.panel?.position(on: sid),
                                  size: item.panel?.size ?? ShellPlacement.peekSize,
                                  fallbackIndex: fallbackIdx),
                              area: geo.size,
                              restoreNS: restoreNS,
                              exposeFrame: (shell.exposeActive && item.peek == nil && item.panel != nil)
                                  ? exposeRect(item.panel!, geo.size) : nil,
                              focusFrame: pl.chrome == .focus ? pl.rect : nil,
                              peek: item.peek,
                              peekFrame: pl.chrome == .peek ? pl.rect : nil)
                        // Cycling (§B): the burst's landing renders on TOP transiently — no z
                        // stamp until the burst commits, so intermediates don't pollute MRU.
                        .zIndex(shell.exposeActive && item.peek == nil
                                ? 5 : (shell.cycleBoostId == item.id ? 8_500 : pl.z))
                        .transition(item.peek != nil
                            ? AnyTransition.move(edge: .leading).combined(with: .opacity)
                            : AnyTransition.opacity)
                }
                // #196: while a resize is making room, how to keep it or only look; after, one action
                // puts the layout back.
                if shell.resizingTile || (shell.tileMoving && !shell.makeRoomPreview.isEmpty) {
                    VStack { Spacer()
                        Text(shell.makeRoomPreview.isEmpty ? "hold ⇧ to make room"
                             : NSEvent.modifierFlags.contains(.command) ? "making room · let go of ⌘ to snap"
                             : "snapping · add ⌘ to slide instead · let go of ⇧ to cover")
                            .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                            .padding(.bottom, ShellState.layoutPillBottom)
                    }.zIndex(9_000).allowsHitTesting(false)
                } else if let undo = shell.layoutUndo, undo.space == sid {
                    VStack { Spacer()
                        HStack(spacing: 8) {
                            Button { withAnimation(.spring(response: 0.4)) { shell.putLayoutBack() } } label: {
                                Label("Put the layout back", systemImage: "arrow.uturn.backward")
                                    .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                            }
                            .buttonStyle(.plain)
                            Button { shell.layoutUndo = nil } label: {
                                Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Port42Theme.textSecondary)
                                    .frame(width: 20, height: 20).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityLabel("Keep this layout")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Port42Theme.bgPrimary.opacity(0.92), in: Capsule())
                        .overlay(Capsule().stroke(shell.accent.opacity(0.4), lineWidth: 1))
                        .padding(.bottom, ShellState.layoutPillBottom)
                    }.zIndex(9_000)
                }
                if shell.exposeActive {
                    VStack { Spacer()
                        Text("EXPOSÉ · click a tile · Tab / Esc to exit")
                            .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                            .padding(.bottom, 96)
                    }.zIndex(9_000).allowsHitTesting(false)
                }
                // Right-edge rail: park (main strip) + close (bottom zone). On top of the tiles.
                // (The old left-edge notification rail is gone — peeks are absolutely-positioned
                // units in the ForEach above, Phase 1.)
                ShellParkRail(shell: shell, appState: appState, area: geo.size, restoreNS: restoreNS)
                    .zIndex(10_000)
            }
            .coordinateSpace(name: "desktop")   // tile drags read the pointer here for park/close hit-testing
            // Here we only spring unit insertion/removal (tiles + peeks) and the exposé transition.
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: tiledPanels.count)
            .animation(.easeOut(duration: 0.12), value: shell.makeRoomPreview)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: shell.peekingPorts)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: shell.exposeActive)
            .onAppear {
                // Phase 0: the desktop appearing is candidate #1 for "I came back and the tiles moved" —
                // it is logged whether or not it ends up arranging.
                ArrangeLog.note("desktop.onAppear",
                                "space=\(ShellState.shortId(sid ?? "-")) "
                                + "area=\(Int(geo.size.width))x\(Int(geo.size.height)) tiles=\(tiledPanels.count) "
                                + "unpositioned=\(tiledPanels.filter { $0.position(on: sid) == nil }.count)")
                shell.lastDesktopArea = geo.size; seedIfNeeded(area: geo.size)
            }
            .onChange(of: geo.size) { old, s in
                // Candidate #4: a resize does not arrange by itself, but it changes the area every
                // later arrange grids into. Logged so a resize-while-away shows up in the trace.
                ArrangeLog.note("desktop.resize",
                                "from=\(Int(old.width))x\(Int(old.height)) to=\(Int(s.width))x\(Int(s.height)) tiles=\(tiledPanels.count)")
                shell.lastDesktopArea = s   // keep the presentation card size honest
                // A resize arranges NOTHING. It only rescues tiles the smaller window pushed out of
                // reach — without this they are unreachable, since nothing re-clamps at render.
                shell.clampTilesIntoView(area: s)
            }
            .onChange(of: shell.spaceId) { old, new in
                ArrangeLog.note("desktop.spaceChanged",
                                "from=\(ShellState.shortId(old ?? "-")) to=\(ShellState.shortId(new ?? "-"))")
                shell.clearOpenDMs()                                                       // peeks are per-desktop
                shell.placeUnpositioned(area: geo.size)    // an unplaced tile on the arriving desktop
            }
            .onChange(of: tiledPanels.count) { old, new in
                // Phase 1: a birth PLACES. This used to re-grid every tile on the desktop, which is
                // why adding one port threw the others around (and why closing one did it again).
                //
                // The `arrangedForSpace` guard that used to sit here is GONE with the re-grid it was
                // protecting against: it existed only to stop a space switch from arranging, and
                // placement cannot arrange — it touches unplaced tiles and nothing else, so on a
                // switch (every tile already placed) it is a no-op. That also retires Phase 0's
                // candidate 3, where two spaces with EQUAL tile counts left the flag naming the space
                // you had left.
                ArrangeLog.note("desktop.countChanged", "count=\(old)→\(new) space=\(ShellState.shortId(sid ?? "-"))")
                shell.placeUnpositioned(area: geo.size)
            }
            // Phase 0: app-switch markers, so a trace shows what (if anything) a return actually did.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                ArrangeLog.note("app.resignActive", "tiles=\(tiledPanels.count) area=\(Int(geo.size.width))x\(Int(geo.size.height))")
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                ArrangeLog.note("app.becomeActive", "tiles=\(tiledPanels.count) area=\(Int(geo.size.width))x\(Int(geo.size.height))")
            }
            // L2.e: one driver subscription per visible port, kept in step with the unit set.
            .onAppear { shell.syncDriverSubscriptions() }
            .onChange(of: shell.contextItems.map(\.id)) { _, _ in shell.syncDriverSubscriptions() }
        }
    }

    /// Exposé target cell for a tile — a uniform grid over the work area. The tile keeps its real
    /// size and is SCALED (aspect-preserved) to fit this cell, so varied tiles land roughly — not
    /// perfectly — equal (that imperfection is the charm; a strict grid would feel mechanical).
    /// Transient: nothing is written back, so exiting exposé snaps tiles to their real frames.
    private func exposeRect(_ p: PortPanel, _ area: CGSize) -> CGRect {
        let items = tiledPanels.sorted { $0.z < $1.z }
        guard let idx = items.firstIndex(where: { $0.id == p.id }) else { return .zero }
        let n = items.count
        let cols = max(1, Int(ceil(sqrt(Double(n)))))
        let rows = max(1, Int(ceil(Double(n) / Double(cols))))
        let top: CGFloat = 70, bottom: CGFloat = 100, side: CGFloat = 40, gap: CGFloat = 30
        let workW = max(240, area.width - side - ShellState.railFoldedWidth - 20)
        let workH = max(200, area.height - top - bottom)
        let colW = workW / Double(cols), rowH = workH / Double(rows)
        return CGRect(x: side + Double(idx % cols) * colW + gap / 2,
                      y: top + Double(idx / cols) * rowH + gap / 2,
                      width: colW - gap, height: rowH - gap)
    }

    /// Seed the grid on first entry into a space (nothing positioned yet). Hand-tuned layouts that
    /// come back from the DB with positions are left exactly as-is (arrange only re-grids on spawn/⌘L).
    private func seedIfNeeded(area: CGSize) {
        let unpositioned = tiledPanels.filter { $0.position(on: sid) == nil }
        if !unpositioned.isEmpty {                                             // never-positioned ports →
            ArrangeLog.note("seedIfNeeded.placing",
                            "unpositioned=\(unpositioned.map { ShellState.shortId($0.id) }.joined(separator: ",")) of \(tiledPanels.count)")
            shell.placeUnpositioned(area: area)                                // place THOSE, move nothing else
        } else {
            ArrangeLog.note("seedIfNeeded.noop", "tiles=\(tiledPanels.count)")
        }
        // A layout restored from the database can be off-screen if the window is smaller than the
        // one it was saved on. Same rescue as a resize, at the only other moment it can happen.
        shell.clampTilesIntoView(area: area)
    }
}

struct ShellTileModel: Identifiable { let id: String; let title: String; let panel: PortPanel? }

// MARK: - A single tile (draggable titlebar, bottom-right resize grip, z-order on grab/focus)

struct ShellTile: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    let tile: ShellTileModel
    let frame: CGRect
    let area: CGSize
    /// Shared namespace for the dock-chip → tile restore morph (Bug 2). The tile is the dest
    /// (isSource: false); the parked chip is the source. Threaded from ShellDesktopView.
    var restoreNS: Namespace.ID
    var exposeFrame: CGRect? = nil        // set in exposé → scale-to-fit this cell (transient)
    /// Set when this tile is focused (Phase 0): the tile's ONE view animates to this rect in
    /// place — focus is a geometry state, not a second mount. nil = normal tile geometry.
    var focusFrame: CGRect? = nil
    /// Set while this unit is a PEEK (Phase 1): the peek entry + its rail rect. The same view
    /// renders peek chrome at railSlot; preview resizes it to focus, adopt slides it to grid.
    var peek: ShellState.PeekPort? = nil
    var peekFrame: CGRect? = nil

    /// A tile corner (any corner resizes; the opposite corner stays pinned).
    /// Where a tile is grabbed to resize it: a corner (both axes) or a side (one axis; GM,
    /// 2026-09-27: sides should drag too, not only corners).
    enum Corner { case nw, ne, sw, se, n, s, e, w }

    @State private var moveDelta: CGSize = .zero
    /// #251: where the port was when ⇧ went down in this move. Room is made from here, not from where the
    /// drag began, so a port picked up on top of another, moved clear, and then given ⇧ pushes the port
    /// it was over too. nil while ⇧ is up.
    @State private var roomAnchor: CGRect? = nil
    /// The last pointer position of this move, so pressing or letting go of ⇧ or ⌘ without moving the
    /// pointer takes effect at once.
    @State private var lastMove: (translation: CGSize, location: CGPoint)? = nil
    /// #251, the same for a resize: the port's frame when ⇧ went down, so a port that started over another,
    /// pulled clear and then given ⇧ pushes the one it was over (Gordon: "shift does nothing and you can
    /// just drag over the window below"). And the last translation, so ⇧ or ⌘ pressed with the pointer
    /// still takes effect at once.
    @State private var resizeAnchor: CGRect? = nil
    @State private var lastResize: (corner: Corner, translation: CGSize)? = nil
    @State private var resizeCorner: Corner? = nil
    @State private var resizeDelta: CGSize = .zero
    @State private var peekHovered = false
    @State private var showVersions = false
    @State private var showMore = false
    @State private var showSpaces = false
    @State private var showCompanions = false
    /// The port's chat is slid down from its companion bar.
    @State private var chatOpen = false
    /// The port's console, opened from its title bar (it used to be a ">" drawn inside the page).
    @State private var consoleOpen = false
    /// Errors already seen, so the badge counts only new ones.
    @State private var seenErrors = 0
    @ObservedObject private var console = PortConsole.shared

    /// Web and browser ports get a console; a terminal shows its own output.
    private var consoleKey: String? {
        guard let p = tile.panel, p.portType != "terminal" else { return nil }
        return PortConsole.key(udid: p.udid, id: p.id, messageId: p.messageId)
    }
    private var consolePanelH: CGFloat {
        guard consoleOpen, consoleKey != nil, !isPeeking else { return 0 }
        let body = liveSize.height - headerH - chatPanelH
        return min(max(110, (liveSize.height - headerH) * 0.3), max(0, body - 60))
    }

    /// The key this port's chat is filed under (`PortRef.key`: the udid).
    private var chatKey: String? { tile.panel?.udid }
    /// Height the open chat takes from the port body.
    private var chatPanelH: CGFloat {
        guard chatOpen, let key = chatKey, !isPeeking else { return 0 }
        return ShellState.portChatHeight(share: shell.portChatShare[key], body: liveSize.height - headerH)
    }

    /// Refresh + versions apply to authored HTML ports only: a terminal has no HTML to reload,
    /// and chat is native, not authored.
    private var isEditablePort: Bool {
        guard let p = tile.panel else { return false }
        return p.portType == "web"
    }

    /// A web port of this instance, not a tile of someone else's: the only kind that can be shared.
    private var shareablePort: Bool {
        guard let p = tile.panel else { return false }
        return AppState.shareable(p) && appState.mirroredRemote(p.id) == nil
    }

    /// This tile lives in another space and is shown here: its menu offers taking it off this desktop.
    private var shownHereFromElsewhere: Bool {
        guard let p = tile.panel, let cur = shell.spaceId else { return false }
        return p.spaceId != cur && p.adoptedSpaceIds.contains(cur)
    }

    /// The version history, as a picker. Every version is already kept forever in `port_versions`;
    /// this is the first thing that lets a human reach one. Split into its own View: inlined here
    /// it made SwiftUI's type-checker sit for >7 minutes without finishing. The popover fetches on
    /// appear (not in the button action) — fetching into @State then flipping the popover in one
    /// action builds the popover with the OLD empty list, which is why the first open showed nothing.
    @ViewBuilder
    private var versionPicker: some View {
        // A tile of someone else's port shows the host's history and restores there (one history).
        let mirrored = appState.mirroredRemote(tile.id) != nil
        return PortVersionsPopover(accent: shell.accent,
                            fetchGrouped: { mirrored ? (appState.mirrorHistory[tile.id] ?? []) : appState.portWindows.fetchVersionSummaries(tile.id) },
                            fetchAllSaves: { mirrored ? (appState.mirrorHistory[tile.id] ?? []) : appState.portWindows.fetchSaveList(tile.id) }) { version in
            showVersions = false
            if mirrored {
                Task { @MainActor in
                    do {
                        try await appState.restoreMirroredVersion(tile: tile.id, version: version)
                        appState.toastMessage = "Restored version \(version)"
                    } catch { appState.toastMessage = "Could not restore: \(error.localizedDescription)" }
                }
            } else {
                appState.portWindows.restoreVersion(tile.id, version: version)
                appState.toastMessage = "Restored version \(version)"
            }
        }
    }

    static let titleBarH: CGFloat = 34
    private var titleBarH: CGFloat { Self.titleBarH }
    private let peekHeaderH: CGFloat = 24

    private var isFocused: Bool { shell.zoom == .focus(tile.id) }
    /// Being dragged or resized by the person right now (#195).
    private var isMoving: Bool { moveDelta != .zero || resizeCorner != nil }
    private var isPeeking: Bool { peekFrame != nil && !isFocused }
    private var isSelected: Bool { shell.selectedTileId == tile.id }
    private var sid: String? { shell.spaceId }
    private var headerH: CGFloat { isPeeking ? peekHeaderH : titleBarH }

    /// The accent of the space a peek CAME FROM (its home) — the edge signals origin.
    private func peekAccent(_ p: ShellState.PeekPort) -> Color {
        if let s = appState.spaces.first(where: { $0.id == p.spaceId }) { return shell.accent(for: s) }
        return shell.accent
    }

    /// Two-state peek click: unseen previews (zoom in, in place); seen keeps (adopts as a tile).
    /// Clicking a peek keeps it as a tile here (GM, 2026-09-29): the confident action is one click.
    /// Looking is the magnifier (or ⌘↓ / a pinch while hovering); skipping is the ✕ or a flick left.
    /// A kept tile you did not want costs one ✕, which only takes it off this space.
    private func clickPeek(_ p: ShellState.PeekPort) {
        shell.keepPeek(shell.peekingPorts.first { $0.id == p.id } ?? p)
    }

    /// A tile that belongs to ANOTHER space (adopted from a peek) keeps its HOME space's accent, so it
    /// still reads as "from elsewhere"; native tiles use the current space's accent.
    private var tileAccent: Color {
        guard let s = tile.panel?.spaceId, s != sid,
              let space = appState.spaces.first(where: { $0.id == s }) else { return shell.accent }
        return shell.accent(for: space)
    }

    /// The tile's live frame = its committed frame plus an in-progress move OR corner-resize.
    /// A FOCUSED unit's frame is the focus rect (drags don't apply); a PEEKING unit rides its
    /// rail slot plus any drag-to-keep translation (peeks stay unclamped — drag-to-keep/close
    /// wants freedom, and a peek can't strand: it evaporates). A TILE's live frame clamps to
    /// the work area AS IT DRAGS — the pointer can wander, the tile stops at the edge, so it
    /// can never even transiently disappear under the Chrome / out of the window.
    private var liveFrame: CGRect {
        if let f = focusFrame { return f }
        if let pf = peekFrame {
            return CGRect(x: pf.minX + moveDelta.width, y: pf.minY + moveDelta.height,
                          width: pf.width, height: pf.height)
        }
        if let c = resizeCorner {
            var f = Self.resized(frame, corner: c, by: resizeDelta)
            f.origin = Self.clampedOrigin(f.origin, size: f.size, area: area)
            return f
        }
        let origin = Self.clampedOrigin(
            CGPoint(x: frame.minX + moveDelta.width, y: frame.minY + moveDelta.height),
            size: frame.size, area: area)
        return CGRect(origin: origin, size: frame.size)
    }
    private var liveSize: CGSize { liveFrame.size }
    /// Center for `.position`. The tile's own frame stays bounded (liveSize), so its hover/hit region
    /// tracks where it's drawn — unlike `.offset`, which leaves the layout frame at the origin.
    private var liveCenter: CGPoint { CGPoint(x: liveFrame.midX, y: liveFrame.midY) }

    /// Exposé: scale the tile (aspect-preserved) to fit its cell, centered there — real frame untouched,
    /// so varied tiles land ROUGHLY (not perfectly) equal. `nil` ⇒ 1×, at the tile's real place.
    private var exposeScale: CGFloat {
        guard let f = exposeFrame else { return 1 }
        return min(f.width / max(1, liveSize.width), f.height / max(1, liveSize.height))
    }
    private var placedCenter: CGPoint { exposeFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? liveCenter }

    /// Apply a corner drag to a frame: the dragged corner follows the delta, the OPPOSITE corner
    /// stays pinned, and the result clamps to the min tile size (so a corner can't cross past it).
    /// Pure + static → headless-testable (`ShellLayoutTests`).
    /// The drag that takes `f` to `target` from this corner: the inverse of `resized`, for a resize that
    /// was limited. Pure.
    static func delta(from f: CGRect, to target: CGRect, corner c: Corner) -> CGSize {
        let east = [.ne, .se, .e].contains(c), south = [.sw, .se, .s].contains(c)
        let dx: CGFloat = (c == .n || c == .s) ? 0 : (east ? target.maxX - f.maxX : target.minX - f.minX)
        let dy: CGFloat = (c == .e || c == .w) ? 0 : (south ? target.maxY - f.maxY : target.minY - f.minY)
        return CGSize(width: dx, height: dy)
    }

    static func resized(_ f: CGRect, corner c: Corner, by d: CGSize) -> CGRect {
        let minW = ShellState.minTileSize.width, minH = ShellState.minTileSize.height
        let east = [.ne, .se, .e].contains(c), south = [.sw, .se, .s].contains(c)
        let movesX = c != .n && c != .s, movesY = c != .e && c != .w   // a side moves one axis only
        let fixedX = east ? f.minX : f.maxX               // pinned (opposite) edge
        let fixedY = south ? f.minY : f.maxY
        let dragX = (east ? f.maxX : f.minX) + d.width    // dragged edge, moved by the delta
        let dragY = (south ? f.maxY : f.minY) + d.height
        // The dragged edge's side is fixed by the corner (east→right edge, west→left edge); clamp to
        // the min without flipping past the pinned edge — so dragging a corner across just stops.
        var x = f.minX, w = f.width, y = f.minY, h = f.height
        if movesX {
            if east { x = fixedX; w = max(minW, dragX - fixedX) } else { w = max(minW, fixedX - dragX); x = fixedX - w }
        }
        if movesY {
            if south { y = fixedY; h = max(minH, dragY - fixedY) } else { h = max(minH, fixedY - dragY); y = fixedY - h }
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Drawn at card size: the unit shows its state card. Measured on the unit, as the presentation
    /// event measures it, so the card and what the port is told agree.
    private var showsCard: Bool {
        !isFocused && exposeFrame == nil && PortPresentation.tier(liveSize) == .card
    }

    private var cornerRadius: CGFloat {
        isFocused ? ShellPlacement.focusCorner : (isPeeking ? ShellPlacement.peekCorner : 10)
    }
    /// The unit's edge color: a peek glows in its HOME space's accent; tiles use tileAccent.
    private var unitAccent: Color { peek.map(peekAccent) ?? tileAccent }
    private var strokeColor: Color {
        if isPeeking { return unitAccent.opacity(peekHovered ? 1 : 0.7) }
        if isFocused { return unitAccent.opacity(0.5) }
        return isSelected ? unitAccent.opacity(0.7) : unitAccent.opacity(0.25)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Chrome by state (a chrome swap never remakes the hosted view — Spike 1).
            if isPeeking, let peek { peekHeader(peek) } else { titleBar }
            // The body stays mounted through peek/tile/focus: state changes only resize this
            // SAME view — no placeholder, no second mount, the webview never detaches.
            ShellTileBody(shell: shell, appState: appState, tile: tile)
            .frame(width: liveSize.width, height: max(0, liveSize.height - headerH))
            // #195: the body alone fades, to its own level and further while it is being moved, so
            // what is behind shows through; the title bar, chat and card above stay solid.
            .opacity(ShellState.bodyOpacity(level: tile.panel?.opacity ?? 1, moving: isMoving))
            .animation(.easeOut(duration: 0.15), value: isMoving)
            // At card size (a peek is card-sized) Port42 draws the port's state over its content, not a
            // miniature of it (docs/plan-port-state-v1.md). The content stays mounted underneath, so
            // growing the unit shows it again with no reload.
            .overlay {
                if showsCard, let panel = tile.panel {
                    AppKitLayer(content: PortStateCard(appState: appState, states: appState.portStates,
                                                       presence: appState.presence, chats: appState.chats, panel: panel,
                                                       size: CGSize(width: liveSize.width, height: max(0, liveSize.height - headerH)),
                                                       accent: unitAccent))
                }
            }
            // A real AppKit view over a PEEKING unit's content wins the hit-test vs the hosted
            // NSView — the only thing that reliably captures the click (preview / keep).
            .overlay { if isPeeking, let peek { PeekClickCatcher { clickPeek(peek) } } }
            // Zoomed in on a peek or a running port popped up from the rail, but not kept: a click on it
            // keeps it (GM, 2026-09-29), and zooming out without one sends it back.
            .overlay {
                if isFocused {
                    if let peek = shell.peekingPorts.first(where: { $0.id == tile.id }) {
                        PeekClickCatcher { shell.keepPeek(peek, arrange: false) }
                    } else if shell.poppedRunning?.id == tile.id {
                        PeekClickCatcher { shell.keepPopped() }
                    }
                }
            }
            // The chat and console slide down OVER the port from its title bar. They used to push the
            // port down, which resized it, so a shader redrew squeezed every time the chat opened (GM,
            // 2026-09-25). Hosted in their own AppKit view, so they take clicks over a web or terminal
            // port, which plain SwiftUI drawn on top does not.
            .overlay(alignment: .top) {
                if chatPanelH + consolePanelH > 0 {
                    AppKitLayer(content: VStack(spacing: 0) {
                        if chatPanelH > 0, let key = chatKey {
                            let body = liveSize.height - headerH
                            // Its bottom edge drags, down to covering the whole port: a grip strip of
                                // the panel's own, below its input (#127).
                            PortChatPanel(chats: appState.chats, appState: appState, key: key, accent: tileAccent,
                                          resize: .init(edge: .bottom, size: CGSize(width: liveSize.width, height: chatPanelH)) { proposed in
                                              shell.portChatShare[key] = ShellState.portChatShare(height: proposed.height, body: body)
                                          })
                                .frame(width: liveSize.width, height: chatPanelH)
                        }
                        if consolePanelH > 0, let key = consoleKey {
                            PortConsolePanel(key: key, accent: tileAccent)
                                .frame(width: liveSize.width, height: consolePanelH)
                        }
                    })
                    .frame(width: liveSize.width, height: chatPanelH + consolePanelH)
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(width: liveSize.width, height: liveSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(
            strokeColor, lineWidth: isPeeking ? (peekHovered ? 2 : 1.5) : 1))
        // ⌘` landing flash (§B): a brief bright accent ring so the hop is visible; the state
        // clears cycleFlashId ~0.35s after each step and the ring fades out.
        .overlay(RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(unitAccent, lineWidth: 2.5)
            .opacity(shell.cycleFlashId == tile.id ? 1 : 0)
            .animation(.easeOut(duration: 0.3), value: shell.cycleFlashId)
            .allowsHitTesting(false))
        // Hold-to-talk, over the tile being dictated into: the words are about to land here, so the
        // indicator belongs here and not in the middle of the desktop. Drawn by the shell, inside the
        // unit, so a port can neither fake it nor hide it.
        .overlay(alignment: .bottomTrailing) {
            if let voice = shell.voiceIndicator(forPort: tile.id) {
                VoiceStatus(accent: unitAccent, label: voice.label, live: voice.live)
                    .padding([.trailing, .bottom], 12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        // Invisible resize zones on ALL four corners (no visible grip). Overlaid on top so a corner
        // grab resizes even over the titlebar/body; the buttons are inset to clear the top corners.
        // Focused/peeking units aren't corner-resizable — the handles come off.
        // The four sides first, so the corners (drawn after) win where they overlap.
        .overlay(alignment: .top)            { if !isFocused && !isPeeking { sideHandle(.n) } }
        .overlay(alignment: .bottom)         { if !isFocused && !isPeeking { sideHandle(.s) } }
        .overlay(alignment: .leading)        { if !isFocused && !isPeeking { sideHandle(.w) } }
        .overlay(alignment: .trailing)       { if !isFocused && !isPeeking { sideHandle(.e) } }
        .overlay(alignment: .topLeading)     { if !isFocused && !isPeeking { cornerHandle(.nw) } }
        .overlay(alignment: .topTrailing)    { if !isFocused && !isPeeking { cornerHandle(.ne) } }
        .overlay(alignment: .bottomLeading)  { if !isFocused && !isPeeking { cornerHandle(.sw) } }
        .overlay(alignment: .bottomTrailing) { if !isFocused && !isPeeking { cornerHandle(.se) } }
        // #130: VoiceOver finds the tile by its port's name and kind, and hears which one is in
        // focus; the port's own content stays inside it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ShellState.tileAccessibilityLabel(title: tile.title, portType: tile.panel?.portType,
                                                              focused: isFocused))
        // In exposé, the whole tile is a pick target (over the body/handles): click → select + exit.
        .overlay {
            if shell.exposeActive && !isPeeking {
                Button {
                    withAnimation(.spring(response: 0.4)) { shell.exposeActive = false }
                    shell.bringToFront(tile.id)
                } label: { Color.white.opacity(0.001) }
                .buttonStyle(.plain)
            }
        }
        .shadow(color: unitAccent.opacity(isPeeking ? (peekHovered ? 0.75 : 0.45)
                                                    : (isFocused ? 0.4 : (isSelected ? 0.3 : 0.12))),
                radius: isPeeking ? (peekHovered ? 28 : 16) : (isFocused ? 50 : (isSelected ? 22 : 12)))
        .scaleEffect(isPeeking ? (peekHovered ? 1.03 : 1.0) : exposeScale, anchor: .center)
        .onHover { h in
            if isPeeking, let peek {
                peekHovered = h                                       // glow + pauses the countdown
                shell.hoveredPeekId = h ? peek.id : (shell.hoveredPeekId == peek.id ? nil : shell.hoveredPeekId)
            } else if h && !shell.isDraggingTile && !isFocused {
                shell.bringToFront(tile.id)                           // hover raises to front
                // FOCUS FOLLOWS MOUSE (GM call): hovering a tile hands it the KEYBOARD too —
                // terminal/web surfaces via first responder, the chat via its input field —
                // so "mouse over it, start typing" just works. Same one entry point as ⌘`.
                appState.portWindows.focusKeyboard(on: tile.id)
            }
        }
        .position(x: placedCenter.x, y: placedCenter.y)       // place last; exposé re-centers into its cell
        // Restore morph (Bug 2): dest of the dock-chip match. Position-only so it composes with the
        // absolute .position above (no size fight); when this port has no parked chip there is no
        // source, so the effect is inert and the tile keeps its own placement.
        .matchedGeometryEffect(id: "restore-\(tile.id)", in: restoreNS, properties: .position, anchor: .center, isSource: false)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: exposeFrame)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: focusFrame)   // focus = the unit's frame animating
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: peekHovered)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            // Drag handle = dot + title + trailing gap; scoped so the focus/close buttons still tap.
            HStack(spacing: 8) {
                Circle().fill(isFocused ? Port42Theme.textSecondary : tileAccent).frame(width: 7, height: 7)
                Text(tile.title).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                // At card size the bar keeps the title and close; the rest is out of room (GM, 2026-09-29).
                if !showsCard {
                // The companion bar: who is in this port's chat, and what you have not read. Left of the
                // header, next to the title, where the space's own bar sits next to its name (#254).
                if let key = chatKey {
                    PortChatBar(chats: appState.chats, key: key, me: appState.currentUser?.id,
                                accent: tileAccent, open: chatOpen) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { chatOpen.toggle() }
                    }
                    .onAppear { appState.chats.load(key, from: appState.db) }
                }
                // The sharing pill (nautilus Phase 4, 4.6b): whose this port is and who else is in it,
                // with everything about sharing one click behind it. Silent on a port nobody shares.
                if let id = tile.panel?.id, let pill = appState.sharePill(tile: id, key: tile.panel?.udid) {
                    SharePillButton(appState: appState, pill: pill, tileId: id, portKey: tile.panel?.udid,
                                    accent: tileAccent) { shell.shareMove = false; shell.shareTarget = tile.panel?.udid }
                }
                // PRESENCE (L2, demoted from right-of-way by R1): someone ELSE drove this port most
                // recently. Silent when it is you — the chrome speaks only when there is contention.
                //
                // The copy said "your writes are refused until they finish", which R1 made UNTRUE:
                // presence refuses nothing, last driver wins. It is a report, not an arbitration.
                // What actually refuses is CAS (R3), and only for a write composed against state the
                // port has already moved past. Same untruth as the architecture page (plan §D), but
                // in-product rather than in copy, so it is a defect and not a positioning call.
                if let held = shell.otherDriver(of: tile.panel?.udid) {
                    Text("✋ \(held.name)")
                        .font(Port42Theme.mono(9))
                        .foregroundStyle(Port42Theme.textPrimary.opacity(0.9))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Port42Theme.bgHover, in: Capsule())
                        .help("\(held.name) drove this port most recently. Your writes are not blocked; a write composed against stale state is refused, not applied.")
                }
                // Pinned: a mark in the bar, so a tile that will not go under the others says why.
                if let pin = tile.panel?.pin, pin != .none {
                    Image(systemName: pin == .everywhere ? "pin.circle.fill" : "pin.fill")
                        .font(.system(size: 8)).foregroundStyle(tileAccent.opacity(0.8))
                        .help(pin == .everywhere ? "Pinned in every space" : "Pinned in this space")
                }
                }
                Spacer(minLength: 8)
            }
            .frame(maxHeight: .infinity)          // fill the full titlebar height so the WHOLE bar drags
            .contentShape(Rectangle())
            // Double-click the header TOGGLES focus (GM ask; a bigger target than the
            // viewfinder button): zoom into an unfocused tile, back out of a focused one.
            // Attached BEFORE the drag so both arbitrate: a still double-click toggles,
            // any movement drags.
            .onTapGesture(count: 2) {
                if isFocused {
                    withAnimation(.spring(response: 0.4)) { shell.zoom = .space }
                } else {
                    shell.bringToFront(tile.id)
                    withAnimation(.spring(response: 0.4)) { shell.zoom = .focus(tile.id) }
                }
            }
            .gesture(moveGesture)
            // #251: ⇧ or ⌘ pressed or let go mid-move, with the pointer still, takes effect at once.
            .onChange(of: shell.heldModifiers) { _, _ in
                if let r = lastResize { applyResize(r.corner, r.translation) }
                else if let m = lastMove { applyMove(m.translation, at: m.location) }
            }
            // The console: new errors counted on the icon; the panel slides down like the chat.
            if !showsCard, let key = consoleKey {
                let errors = console.errorCounts[key] ?? 0
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { consoleOpen.toggle() }
                    seenErrors = errors
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 9))
                            .foregroundStyle(consoleOpen ? tileAccent : Port42Theme.textSecondary)
                        if errors > seenErrors {
                            Text("\(errors - seenErrors)").font(Port42Theme.monoBold(8)).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1).background(Color.red, in: Capsule())
                        }
                    }
                    .frame(height: 22).padding(.horizontal, 4).contentShape(Rectangle())
                    .background(consoleOpen ? Port42Theme.bgHover : .clear, in: Capsule())
                }
                .buttonStyle(.plain).help(consoleOpen ? "Close console" : "Console")
                .onChange(of: errors) { _, n in if consoleOpen { seenErrors = n } }
            }
            // Trailing chrome — the SAME controls whether tiled or focused (GM: "literally the same
            // code"). Secondary actions live under "…"; only focus-toggle and close stay visible.
            // Every port type can be the background (GM, 2026-09-25); refresh and history are for
            // authored web ports only.
            if !showsCard, let bridge = tile.panel?.bridge {
                // Overflow popover (NOT a SwiftUI Menu — Menu won't open reliably inside this
                // scaled/positioned/animated tile). Holds pause, refresh, history, background.
                Button { showMore = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10)).foregroundStyle(Port42Theme.textSecondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())   // generous hit target
                }
                .buttonStyle(.plain)
                .help("More…")
                .popover(isPresented: $showMore, arrowEdge: .bottom) {
                    PortMorePopover(
                        bridge: bridge,
                        accent: shell.accent,
                        editable: isEditablePort,
                        onRefresh: { appState.portWindows.reloadPort(tile.id); showMore = false },
                        onHistory: { showMore = false; showVersions = true },
                        onHide: {
                            shell.hideTile(tile.panel?.id ?? tile.id)
                            showMore = false
                        },
                        onShare: shareablePort ? { showMore = false; shell.shareMove = false; shell.shareTarget = tile.panel?.udid } : nil,
                        onFork: shareablePort ? {
                            showMore = false
                            let id = tile.panel?.id ?? tile.id
                            Task { @MainActor in
                                if let copy = try? await appState.forkPort(id) { shell.bringToFront(copy) }
                            }
                        } : nil,
                        onSpaces: tile.panel == nil ? nil : { showMore = false; showSpaces = true },
                        onCompanions: appState.mirroredRemote(tile.id) == nil ? nil : { showMore = false; showCompanions = true },
                        opacity: tile.panel?.opacity ?? 1,
                        onOpacity: { level in
                            if let id = tile.panel?.id { appState.portWindows.setOpacity(id: id, level) }
                        },
                        pin: tile.panel?.pin ?? .none,
                        onPin: { pin in
                            if let id = tile.panel?.id { appState.portWindows.setPin(id: id, pin) }
                            showMore = false
                        },
                        onSetBackground: {
                            // MOVE the port to the background — a position change, not a clone. Its
                            // presentation flips to "background", so it drops out of the tile grid and
                            // re-parents full-bleed at Layer 0. The live surface (and any running
                            // shader) keeps running: no dismiss, no reload.
                            shell.setBackgroundPort(id: tile.panel?.id ?? tile.id)   // this window's space (#189)
                            showMore = false
                        })
                }
                .popover(isPresented: $showVersions, arrowEdge: .bottom) { versionPicker }
                .popover(isPresented: $showCompanions, arrowEdge: .bottom) {
                    TileCompanionsPopover(appState: appState, tile: tile.panel?.id ?? tile.id, accent: shell.accent)
                }
                .popover(isPresented: $showSpaces, arrowEdge: .bottom) {
                    PortSpacesPopover(
                        accent: shell.accent,
                        spaces: appState.spaces.filter { $0.id != tile.panel?.spaceId },
                        shownIn: Set(tile.panel?.adoptedSpaceIds ?? []),
                        canMove: shareablePort,
                        removeHere: shownHereFromElsewhere) { action in
                        showSpaces = false
                        let id = tile.panel?.id ?? tile.id
                        switch action {
                        case .move(let sid): appState.portWindows.move(id: id, toSpace: sid)
                        case .show(let sid): appState.portWindows.adopt(id: id, into: sid)
                        case .stopShowing(let sid): appState.portWindows.unadopt(id: id, from: sid)
                        case .removeHere:
                            if let cur = shell.spaceId { appState.portWindows.unadopt(id: id, from: cur) }
                        case .machine: shell.shareMove = true; shell.shareTarget = tile.panel?.udid
                        }
                    }
                }
            }
            // Focus toggle: enter focus, or shrink back out if already focused.
            if !showsCard {
            Button {
                if isFocused {
                    withAnimation(.spring(response: 0.4)) { shell.zoom = .space }
                } else {
                    shell.bringToFront(tile.id)
                    withAnimation(.spring(response: 0.4)) { shell.zoom = .focus(tile.id) }
                }
            } label: {
                // The magnifier, on every port as on peeks and Running cards: a pinch is learned, a
                // magnifier is seen (GM, 2026-09-29).
                Image(systemName: isFocused ? "arrow.down.right.and.arrow.up.left" : "magnifyingglass")
                    .font(.system(size: isFocused ? 11 : 9, weight: isFocused ? .regular : .semibold))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help(isFocused ? "Zoom out (⌘↑, Esc)" : "Zoom in (⌘↓, pinch)")
            }
            // Close.
            if let panel = tile.panel {
                Button { shell.dismissTile(panel) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Close")
            }
        }
        .padding(.leading, 10).padding(.trailing, 18)   // trailing inset clears the top-right resize zone
        .frame(maxWidth: .infinity)          // span the tile so the drag handle is easy to grab
        .frame(height: titleBarH)
        .background(Port42Theme.shellCard)
    }

    /// A peeking unit's mini header (folded in from the old ShellPeekTile, Phase 1): origin
    /// icon + title + home space, the 10s countdown ring once seen, and ✕ to dismiss.
    private func peekHeader(_ p: ShellState.PeekPort) -> some View {
        let col = peekAccent(p)
        return HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 9)).foregroundStyle(col)
            Text(p.title).font(Port42Theme.monoBold(9)).foregroundStyle(Port42Theme.textPrimary).lineLimit(1)
            Text("· \(p.spaceName)").font(Port42Theme.mono(8)).foregroundStyle(col.opacity(0.85)).lineLimit(1)
            Spacer(minLength: 4)
            if let rem = shell.peekRemaining[p.id] {            // countdown ring (pauses on hover)
                let total = shell.peekTotal[p.id] ?? ShellState.unseenPeekLifetime
                ZStack {
                    Circle().stroke(col.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0, rem / total))
                        .stroke(col, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }.frame(width: 11, height: 11)
            }
            // On hover only, so the peek stays clean: look (zoom in; zoom back out and it goes) and
            // skip (it stays in its own space).
            if peekHovered {
                Button { shell.previewPeek(p) } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .semibold)).foregroundStyle(col)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Look (⌘↓)")
                Button { shell.dismissPeek(p) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Skip: it stays in \(p.spaceName)")
            }
        }
        .padding(.horizontal, 9).frame(height: peekHeaderH).background(Color.black.opacity(0.45))
        .contentShape(Rectangle())
        .onTapGesture { clickPeek(p) }                          // tap → keep
        .gesture(moveGesture)                                   // drag-to-keep starts from the header too
    }

    /// An invisible 16×16 corner drag zone that resizes from that corner.
    private func cornerHandle(_ corner: Corner) -> some View {
        Color.clear
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .resizeCursor(ResizeCursor.cursor(for: corner))
            .gesture(resizeGesture(corner))
    }

    /// A side: a strip along the edge, short of the corners. Left and right are the wider ones (GM,
    /// 2026-09-27: easier to catch); top and bottom stay narrower so they do not steal the title bar's
    /// drag or the port's own clicks.
    private func sideHandle(_ side: Corner) -> some View {
        let horizontal = side == .n || side == .s
        return Color.clear
            .frame(width: horizontal ? max(0, liveSize.width - 32) : 10,
                   height: horizontal ? 7 : max(0, liveSize.height - 32))
            .contentShape(Rectangle())
            .resizeCursor(ResizeCursor.cursor(for: side))
            .gesture(resizeGesture(side))
    }

    /// Place the moving port for a pointer translation (#251). With ⇧ held the ports it touches give way,
    /// snapped (⌘ as well: they slide), and the move stops where one would be pushed off the screen, as
    /// a ⇧ resize does. Room is made from where the port was when ⇧ went down.
    private func applyMove(_ translation: CGSize, at location: CGPoint) {
        lastMove = (translation, location)
        let flags = NSEvent.modifierFlags
        let target = frame.offsetBy(dx: translation.width, dy: translation.height)
        guard ShellState.resizeMakesRoom(flags), !isPeeking, railZone(at: location) == nil else {
            roomAnchor = nil
            moveDelta = translation
            shell.clearMakeRoomPreview()
            return
        }
        let anchor = roomAnchor ?? frame.offsetBy(dx: moveDelta.width, dy: moveDelta.height)
        roomAnchor = anchor
        let limited = shell.limitedMove(tile.id, from: anchor, to: target)
        moveDelta = CGSize(width: limited.minX - frame.minX, height: limited.minY - frame.minY)
        shell.previewMakeRoom(resizing: tile.id, from: anchor, to: limited,
                              snap: ShellState.resizeSnaps(flags), moving: true)
    }

    private var moveGesture: some Gesture {
        // Read the pointer in the desktop space so a drop onto the right rail parks/closes the port.
        DragGesture(coordinateSpace: .named("desktop"))
            .onChanged { v in
                guard !isFocused else { return }                        // a focused unit doesn't drag
                if lastMove == nil {                                     // grabbing a tile raises it
                    shell.bringToFront(tile.id); shell.isDraggingTile = true
                    shell.tileMoving = true                             // and opens the rail to drop on
                }
                applyMove(v.translation, at: v.location)
                shell.draggingOverPark = railZone(at: v.location)       // highlight the rail zone under the drag
                // Over Running, show where it would land among the cards.
                if shell.draggingOverPark == .hide, let panel = tile.panel {
                    let count = appState.portWindows.hiddenPanels(in: panel.spaceId).filter { $0.id != panel.id }.count
                    let slot = ShellState.runningSlot(forY: v.location.y, pausedHeight: shell.pausedCardsHeight, count: count)
                    if shell.railDropSlot != slot { shell.railDropSlot = slot }
                } else if shell.railDropSlot != nil {
                    shell.railDropSlot = nil
                }
            }
            .onEnded { v in
                guard !isFocused else { return }
                shell.draggingOverPark = nil
                shell.railDropSlot = nil
                shell.isDraggingTile = false
                shell.endTileMove(overRail: railZone(at: v.location) != nil)
                let anchor = roomAnchor
                moveDelta = .zero
                roomAnchor = nil
                lastMove = nil
                // Drag-to-keep (Phase 1): pulling a peek into the space ADOPTS it as a tile at
                // the drop spot (no re-grid — the user chose the place); the close zone dismisses.
                if isPeeking, let peek, let pf = peekFrame {
                    guard hypot(v.translation.width, v.translation.height) > 40 else { return }   // a wiggle isn't a keep
                    if railZone(at: v.location) == .close { shell.dismissPeek(peek); return }
                    // Flicked off the left edge: skipped, as the ✕ does.
                    if v.translation.width < -60 || v.location.x < 8 { shell.dismissPeek(peek); return }
                    shell.keepPeek(peek, arrange: false)
                    commit(origin: CGPoint(x: pf.minX + v.translation.width, y: pf.minY + v.translation.height),
                           size: tile.panel?.size ?? pf.size)
                    return
                }
                let zone = railZone(at: v.location)
                switch zone {                                                    // any tile (chat included) — count↓ re-grids
                case .close: if let panel = tile.panel { shell.dismissTile(panel) }
                case .hide:
                    if let panel = tile.panel {
                        let count = appState.portWindows.hiddenPanels(in: panel.spaceId).filter { $0.id != panel.id }.count
                        shell.hideTile(panel.id, at: ShellState.runningSlot(forY: v.location.y,
                                                                            pausedHeight: shell.pausedCardsHeight, count: count))
                    }
                case .park:
                    // The newest parked port goes last in the list.
                    if let panel = tile.panel {
                        appState.portWindows.park(id: panel.id, at: appState.portWindows.railIds(in: panel.spaceId).count)
                    }
                case nil:
                    if ShellState.resizeMakesRoom(NSEvent.modifierFlags), let anchor {   // #251: a ⇧ move keeps the room it made
                        let limited = shell.limitedMove(tile.id, from: anchor, to: frame.offsetBy(dx: v.translation.width, dy: v.translation.height))
                        shell.endMakeRoom(resizing: tile.id, from: frame, keep: true)
                        commit(origin: limited.origin, size: frame.size)
                    } else {
                        shell.clearMakeRoomPreview()
                        commit(origin: CGPoint(x: frame.minX + v.translation.width, y: frame.minY + v.translation.height),
                               size: CGSize(width: frame.width, height: frame.height))
                    }
                }
                if zone != nil { shell.endMakeRoom(resizing: tile.id, from: frame, keep: false) }
            }
    }

    /// The rail zone under a desktop-space point. The chat is NOT exempt — it parks/closes too.
    private func railZone(at p: CGPoint) -> ShellState.ParkZone? {
        ShellState.parkZone(at: p, in: area, pausedHeight: shell.pausedCardsHeight)
    }

    /// Size the port for a resize translation (#196, #251). With ⇧ held the neighbors give way as it grows,
    /// snapped (⌘ as well: they slide), and the edge stops where one would be pushed off the screen;
    /// without ⇧ it covers them. Room is made from where the port was when ⇧ went down.
    private func applyResize(_ corner: Corner, _ translation: CGSize) {
        lastResize = (corner, translation)
        let flags = NSEvent.modifierFlags
        guard ShellState.resizeMakesRoom(flags) else {
            resizeAnchor = nil
            resizeDelta = translation
            shell.clearMakeRoomPreview()
            return
        }
        let anchor = resizeAnchor ?? Self.resized(frame, corner: corner, by: resizeDelta)
        resizeAnchor = anchor
        let limited = shell.limitedResize(tile.id, from: anchor, to: Self.resized(frame, corner: corner, by: translation))
        resizeDelta = Self.delta(from: frame, to: limited, corner: corner)
        shell.previewMakeRoom(resizing: tile.id, from: anchor, to: limited, snap: ShellState.resizeSnaps(flags))
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        // Measure in the FIXED desktop space, not the handle's local space — the handle rides the
        // corner that the resize is moving, so a local-space translation lags behind the cursor.
        DragGesture(coordinateSpace: .named("desktop"))
            .onChanged { v in
                if resizeCorner == nil { shell.bringToFront(tile.id); shell.isDraggingTile = true; shell.resizingTile = true }
                resizeCorner = corner
                applyResize(corner, v.translation)
            }
            .onEnded { v in
                let anchor = resizeAnchor
                let pushed = ShellState.resizeMakesRoom(NSEvent.modifierFlags) && anchor != nil
                let raw = Self.resized(frame, corner: corner, by: v.translation)
                let f = pushed ? shell.limitedResize(tile.id, from: anchor!, to: raw) : raw
                resizeAnchor = nil
                lastResize = nil
                if !pushed { shell.clearMakeRoomPreview() }
                shell.endMakeRoom(resizing: tile.id, from: frame, keep: pushed)
                commit(origin: f.origin, size: f.size)
                resizeCorner = nil
                resizeDelta = .zero
                shell.isDraggingTile = false
                shell.resizingTile = false
            }
    }

    /// Clamp a committed tile origin so its HEADER stays reachable: never above the desktop's
    /// top edge (y ≥ 0 — beyond it the titlebar slides under the Chrome / the macOS title
    /// area and the tile can never be grabbed again), never below the bottom with the header
    /// off-screen, and never fully off the sides. Pure + static → headless (`ShellLayoutTests`).
    static func clampedOrigin(_ o: CGPoint, size: CGSize, area: CGSize) -> CGPoint {
        let minVisibleX: CGFloat = 60                       // a grabbable sliver must remain
        let x = min(max(o.x, minVisibleX - size.width), max(minVisibleX - size.width, area.width - minVisibleX))
        let y = min(max(o.y, 0), max(0, area.height - Self.titleBarH))
        return CGPoint(x: x, y: y)
    }

    /// Persist the tile's new geometry (drag/resize end) → the panel record (survives restart, §4).
    /// The origin clamps into the work area — a drag can wander, but it can't STICK out of reach.
    private func commit(origin: CGPoint, size: CGSize) {
        // Scoped to the desktop the drag happened on: the same port can be a tile on two desktops,
        // and dragging it here must not move it there (v46, per-desktop positions).
        appState.portWindows.updateTileFrame(
            id: tile.id, position: Self.clampedOrigin(origin, size: size, area: area), size: size, on: sid)
    }
}

// MARK: - Right-edge parking + close rail

/// A real NSView that captures clicks over a peek's live port view — the only thing that reliably
/// beats a hosted WKWebView/Ghostty surface in the AppKit hit-test. On mouseDown it runs `onClick`
/// (which previews an unseen peek, keeps a seen one). Transparent; the live port renders beneath it.
struct PeekClickCatcher: NSViewRepresentable {
    let onClick: () -> Void
    func makeNSView(context: Context) -> NSView { let v = Catcher(); v.onClick = onClick; return v }
    func updateNSView(_ v: NSView, context: Context) { (v as? Catcher)?.onClick = onClick }
    final class Catcher: NSView {
        var onClick: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { self }          // always capture
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            // Run on a FRESH main-loop tick, not nested in this AppKit event — otherwise the animated
            // `zoom = .focus` doesn't reliably drive the SwiftUI focus render.
            DispatchQueue.main.async { [weak self] in self?.onClick?() }
        }
    }
}

/// The right-edge rail: parked ports as clickable chips (click → unpark) with a **close** drop zone
/// at the bottom. It's a drop TARGET only — the drag is owned by the tile's move gesture, which sets
/// `shell.draggingOverPark` for the highlight and calls `park`/`close` on drop. Faint at rest; lights
/// up accent (park) or red (close) while a tile is dragged over the matching zone.
/// (Peeks — the old left-edge strip — are now absolutely-positioned units in the desktop ForEach,
/// rendered by ShellTile's `.peek` chrome. Phase 1.)
struct ShellParkRail: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    let area: CGSize
    /// Shared namespace for the chip → tile restore morph (Bug 2). Each chip is the SOURCE; the tile
    /// is the dest. Threaded from ShellDesktopView.
    var restoreNS: Namespace.ID

    /// Ports put away in the rail. Only `parked` — the shell has NO floating presentation
    /// (Phase 2): a port here is tiled, parked, or peeking. One click restores a chip to a tile.
    private var railPanels: [PortPanel] {
        guard let sid = shell.spaceId else { return [] }
        return appState.portWindows.railIds(in: sid).compactMap { id in
            appState.portWindows.panels.first { $0.id == id }
        }
    }

    var body: some View {
        let open = shell.railOpen
        // Folded (#192), the rail is a thin edge and the desktop is the tiles'; it opens over them on
        // hover and while a tile is dragged, so its drop zones are there when they are needed.
        Group {
            if open { openRail } else { foldedEdge }
        }
        .frame(width: ShellState.railWidth(open: open, screenW: area.width))
        .background(Rectangle().fill(Color.black.opacity(open ? 0.35 : 0.25)))
        .overlay(Rectangle().fill(shell.accent.opacity(0.15)).frame(width: 1), alignment: .leading)
        .contentShape(Rectangle())
        .background(alertWatcher)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.easeOut(duration: 0.15), value: shell.draggingOverPark)
        .animation(.easeOut(duration: 0.15), value: open)
    }

    /// The running ports that need you, rechecked every two seconds: a new one opens the rail for a moment.
    private var alertWatcher: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let ids = Set(appState.portWindows.hiddenPanels(in: shell.spaceId)
                .filter { appState.portCard($0).needsAttention }.map(\.id))
            Color.clear
                .onAppear { shell.noteRunningAlerts(ids) }
                .onChange(of: ids) { _, now in shell.noteRunningAlerts(now) }
        }
    }

    /// Top to bottom (GM, 2026-09-29): parked (a count and a list: a parked port is paused), hidden
    /// (a card per port: it is still running, so it is worth watching), close (a trash icon). Each
    /// lights up while a tile is dragged over it.
    private var openRail: some View {
        VStack(spacing: 0) {
            parkedSection(active: shell.draggingOverPark == .park)
            hiddenCards(active: shell.draggingOverPark == .hide)
                .frame(maxHeight: .infinity)
            closeZone(active: shell.draggingOverPark == .close)
                .frame(height: ShellState.closeZoneHeight)
        }
    }

    /// The folded rail: an edge, with a red dot when a running port needs you, so folding never hides a
    /// problem. Rechecked on the cards' own cadence.
    private var foldedEdge: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let cards = appState.portWindows.hiddenPanels(in: shell.spaceId).map { appState.portCard($0) }
            VStack {
                if let status = ShellState.railEdgeStatus(cards) {
                    Circle().fill(RailPortCard.color(status)).frame(width: 6, height: 6)
                        .padding(.top, ShellState.parkZoneHeight + ShellState.railHeaderHeight)
                        .help("A running port needs you")
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The rail's icons and counts share one color, so the rail reads as one thing.
    static let railInk = Port42Theme.textSecondary.opacity(0.6)

    private func divider(_ color: Color?) -> some View {
        Rectangle().fill(color ?? Color.white.opacity(0.08)).frame(height: 1)
    }

    /// PARKED PORTS in this space, at the top of the rail: the tray and a count, which lists them to
    /// restore. It is also the drop zone that parks a tile.
    private func parkedSection(active: Bool) -> some View {
        let parked = railPanels
        let open = shell.pausedOpen && !parked.isEmpty
        // Words, not icons (GM, 2026-09-29): a parked port is paused (slowed; a terminal keeps running).
        // Paused folds, with an arrow, so it reads as a different thing from Running, which is always
        // open: the ones to watch are the running ones.
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { shell.pausedOpen.toggle() }
            } label: {
                HStack(spacing: 4) {
                    if !parked.isEmpty {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                    }
                    Text("Paused (\(parked.count))")
                        .font(active ? Port42Theme.monoBold(10) : Port42Theme.mono(10))
                }
                .foregroundStyle(active ? shell.accent : Self.railInk)
                .frame(maxWidth: .infinity).frame(height: ShellState.parkZoneHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(parked.isEmpty)
            .help(parked.isEmpty ? "Drag a port here to pause it: off the desktop and slowed (a terminal keeps running)."
                                 : (open ? "Fold the paused ports" : "Show the paused ports"))
            if open {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: ShellState.railCardSpacing) {
                        ForEach(parked) { p in
                            RailPortCard(appState: appState, states: appState.portStates, presence: appState.presence,
                                         chats: appState.chats, panel: p, accent: shell.accent) {
                                appState.portWindows.unpark(id: p.id)
                                shell.bringToFront(p.id)
                            }
                            .opacity(0.55)     // paused: dimmer than the running ones
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
                .frame(height: ShellState.pausedCardsHeight(open: true, count: parked.count))
            }
        }
        .frame(maxWidth: .infinity)
        .background(Rectangle().fill(shell.accent.opacity(active ? 0.18 : 0)))
    }

    /// The slot a drag will land in among the running cards: an accent gap one card tall.
    private var runningGap: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(shell.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .background(shell.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            .frame(height: ShellState.railCardHeight)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    /// HIDDEN PORTS in this space: a card each, with its state, since a hidden port keeps running and
    /// its card is all the person sees of it (docs/plan-port-state-v1.md). Click one to show it. The
    /// area is also the drop zone that hides a tile.
    private func hiddenCards(active: Bool) -> some View {
        let hidden = appState.portWindows.hiddenPanels(in: shell.spaceId)
        return VStack(spacing: 0) {
            Text("Running (\(hidden.count))")
                .font(active ? Port42Theme.monoBold(10) : Port42Theme.mono(10))
                .foregroundStyle(active ? shell.accent : Self.railInk)
                .frame(maxWidth: .infinity).frame(height: ShellState.railHeaderHeight)
                .help("Running with no tile. Drag a port here to keep it running off the desktop.")
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: ShellState.railCardSpacing) {
                    // Where a dragged tile would land, shown as a gap before the drop.
                    let gap = active ? shell.railDropSlot : nil
                    ForEach(Array(hidden.enumerated()), id: \.element.id) { i, p in
                        if gap == i { runningGap }
                        RailPortCard(appState: appState, states: appState.portStates, presence: appState.presence,
                                     chats: appState.chats, panel: p, accent: shell.accent,
                                     onLook: { shell.popRunning(p.id) }) {
                            shell.showHidden(p.id)
                        }
                        .onHover { h in
                            if h { shell.hoveredRunningId = p.id }
                            else if shell.hoveredRunningId == p.id { shell.hoveredRunningId = nil }
                        }
                    }
                    if let g = gap, g >= hidden.count { runningGap }
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(Rectangle().fill(shell.accent.opacity(active ? 0.18 : 0)))
        .overlay(alignment: .top) { divider(active ? shell.accent.opacity(0.6) : nil) }
    }

    /// The close zone at the bottom of the rail: a trash icon, red while a tile is over it.
    private func closeZone(active: Bool) -> some View {
        Image(systemName: "trash").font(.system(size: 18, weight: active ? .bold : .regular))
            .foregroundStyle(active ? Color.red : Self.railInk)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Rectangle().fill(Color.red.opacity(active ? 0.22 : 0)))
            .overlay(alignment: .top) { divider(active ? Color.red.opacity(0.7) : nil) }
            .help("Drag a port here to close it")
    }
}

/// A port's live body: its re-parented web, browser or terminal view.
struct ShellTileBody: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    let tile: ShellTileModel

    var body: some View {
        if let panel = tile.panel, !shell.hostsLive(panel.id) {
            // #189: live in another window for now; a click here makes this the window in use, and
            // the port comes over.
            ZStack {
                Color.black
                VStack(spacing: 6) {
                    Image(systemName: "display.2").font(.system(size: 20)).foregroundStyle(shell.accent)
                    Text("live on the other display").font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                    Text("click to bring it here").font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { shell.window?.makeKeyAndOrderFront(nil) }
        } else if let panel = tile.panel, panel.portType == "browser",
                  let wv = appState.portWindows.hostView(for: panel.id) as? WKWebView {
            ShellBrowserTile(webView: wv, accent: shell.accent, initialURL: panel.html,
                             probeId: panel.id,
                             popup: appState.portWindows.browserPopups[panel.id],
                             onClosePopup: { [weak appState] in appState?.portWindows.closeBrowserPopup(port: panel.id) },
                             // I2 · C3 leaves this in place deliberately, alongside the new KVO
                             // observer that also sees this navigation. They count different
                             // things: this fires on INTENT, before `load()`, and KVO fires on
                             // FACT, when the URL actually changes. Keeping the early one preserves
                             // R2's chosen ordering (bump before the change lands, so a reader in
                             // the gap cannot compose against a token the navigation is about to
                             // invalidate). Double-counting is harmless: the token is a monotonic
                             // counter, not a change log, and only its movement is meaningful.
                             onNavigate: { [weak appState] in
                                 appState?.surfaceWrote(port: panel.udid)
                             })   // address bar + page
        } else if let panel = tile.panel, let v = appState.portWindows.hostView(for: panel.id) {
            ShellPortHost(view: v, bridge: panel.bridge, probeId: panel.id)   // web OR terminal — one host
        } else if let panel = tile.panel, panel.portType == "terminal", appState.terminalStarts.isWaiting(panel.id) {
            // #223: restored and waiting its turn to start; a click starts it now. It was a black rectangle.
            ZStack {
                Color.black
                VStack(spacing: 6) {
                    Image(systemName: "hourglass").font(.system(size: 18)).foregroundStyle(shell.accent)
                    Text("waiting to start").font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                    Text("click to start it now").font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { appState.terminalStarts.startNow(panel.id) }
        } else {
            Color.black
        }
    }
}

/// A browser port's chrome: a slim address bar (back/forward/reload + URL field) over the embedded
/// WKWebView. The webview is the persistent registry view, re-parented via ShellPortHost like any tile.
struct ShellBrowserTile: View {
    let webView: WKWebView
    let accent: Color
    var probeId: String? = nil
    /// R2b / finding 7: a URL typed here REPLACES the whole page, and it reaches the webview without
    /// passing the dispatcher — so the port's token has to move or a companion's write composed
    /// against the old page would still look current.
    var onNavigate: () -> Void = {}
    /// A popup the page opened (an OAuth sign-in), drawn over the page until it closes itself or the
    /// person closes it (docs/plan-browser-use.md, Phase 1).
    var popup: WKWebView? = nil
    var onClosePopup: () -> Void = {}
    @State private var urlText: String
    /// The address field has the keyboard: the page's own navigations do not overwrite what is being typed.
    @FocusState private var editingURL: Bool

    /// What the address bar shows: the page's address as it moves (links, redirects, a site's own
    /// routing), except while the person is typing in it (Gordon, 2026-09-30: going to another site or
    /// page left the old address in the bar). Pure.
    static func addressShown(page: URL?, typed: String, editing: Bool) -> String {
        guard !editing, let page, page.absoluteString != "about:blank" else { return typed }
        return page.absoluteString
    }

    init(webView: WKWebView, accent: Color, initialURL: String, probeId: String? = nil,
         popup: WKWebView? = nil, onClosePopup: @escaping () -> Void = {},
         onNavigate: @escaping () -> Void = {}) {
        self.webView = webView
        self.accent = accent
        self.probeId = probeId
        self.popup = popup
        self.onClosePopup = onClosePopup
        self.onNavigate = onNavigate
        _urlText = State(initialValue: initialURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                navButton("chevron.left") { webView.goBack() }
                navButton("chevron.right") { webView.goForward() }
                navButton("arrow.clockwise") { webView.reload() }
                TextField("search or type a URL", text: $urlText)
                    .focused($editingURL)
                    .onReceive(webView.publisher(for: \.url)) { url in
                        urlText = Self.addressShown(page: url, typed: urlText, editing: editingURL)
                    }
                    .textFieldStyle(.plain).font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .onSubmit(navigate)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(.horizontal, 10).frame(height: ShellPlacement.browserBarH)
            .background(Port42Theme.shellCard)
            .overlay(Rectangle().fill(accent.opacity(0.15)).frame(height: 1), alignment: .bottom)
            ShellPortHost(view: webView, probeId: probeId)   // page rect = unit content − bar
                .overlay { if let popup { popupLayer(popup) } }
        }
    }

    /// The popup over the page: the page dimmed behind it, the popup's site and a close button on top.
    /// Hosted in its own AppKit layer so it takes clicks over the page's web view.
    private func popupLayer(_ popup: WKWebView) -> some View {
        GeometryReader { g in
            let w = min(g.size.width - 32, 520), h = min(g.size.height - 32, 680)
            AppKitLayer(content: ZStack {
                Color.black.opacity(0.45)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Port42Theme.textSecondary)
                        // The site the popup is on right now (a sign-in hops between hosts), rechecked each second.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(popup.url?.host ?? "loading")
                                .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(action: onClosePopup) {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
                                .frame(width: 20, height: 20).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Close this window")
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Port42Theme.shellCard)
                    ShellPortHost(view: popup).id(ObjectIdentifier(popup))
                }
                .frame(width: max(160, w), height: max(160, h))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 20, y: 6)
            })
        }
    }

    private func navigate() {
        if let url = URL(string: PortWindowManager.normalizedBrowserURL(urlText)) {
            onNavigate()
            webView.load(URLRequest(url: url))
        }
    }

    private func navButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Port42Theme.textSecondary)
        }.buttonStyle(.plain)
    }
}

/// One host to re-parent ANY port's persistent view into a shell tile/focus — a web port's WKWebView
/// or a terminal port's Ghostty surface. Mirrors `PortWebViewHost`'s reparent trick; `updateNSView`
/// deliberately does nothing so moving the view between containers (tile ↔ focus ↔ rail) never
/// reclaims or reloads it. This is what makes "a tile hosts any port" literally true.
struct ShellPortHost: NSViewRepresentable {
    let view: NSView
    var bridge: PortBridge? = nil
    /// Port id for the Tier-B render probe (§9, DEBUG-only): lets `PortRenderProbe` count
    /// makes / verify window-attachment per port. nil = unprobed (production behavior).
    var probeId: String? = nil

    func makeNSView(context: Context) -> NSView {
        let container = PortWebViewContainer()
        container.bridge = bridge
        view.removeFromSuperview()
        // DESKTOP host: the port keeps its own wheel (it is the thing being pointed at). The
        // inline chat host sets the opposite on the same webview when it takes it back.
        (view as? FileDropWebView)?.forwardsScrollToParent = false
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        #if DEBUG
        if let pid = probeId { PortRenderProbe.recordMake(pid, view: view, container: container) }
        #endif
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Don't reclaim the view if it moved to another container (tile/focus/rail reparenting), which is in
        // a window on screen. Do take it back when the window it went to is closed or hidden: closing a
        // second window used to leave this tile's port blank (the space background showing through) until
        // the person left the space and came back (#189, Gordon, 2026-10-02).
        guard Self.shouldReclaim(hostedHere: view.superview === container,
                                 viewWindowVisible: view.window?.isVisible ?? false,
                                 containerWindowVisible: container.window?.isVisible ?? false) else { return }
        view.removeFromSuperview()
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    /// Whether a host takes its view back: it is not here, the window it is in is gone or hidden, and this
    /// host is on screen. A view in another visible window (a tile, focus, the rail, the off-screen host for
    /// browser use) is left where it is.
    nonisolated static func shouldReclaim(hostedHere: Bool, viewWindowVisible: Bool, containerWindowVisible: Bool) -> Bool {
        !hostedHere && !viewWindowVisible && containerWindowVisible
    }
}

// (ShellFocusContent is deleted — Phase 2. Focus is the `.focus` chrome of the unit already
// mounted in the desktop ForEach; there is no second mount and no focus overlay.)

// MARK: - Dock (companions | ports)

/// The bottom dock, two separated areas: the current space's COMPANIONS (crew + add) and PORTS to
/// spawn (chat / terminal / browser). Companions are a space primitive — adding one here puts it in
/// THIS space. Generative/arbitrary ports come from asking a companion in chat, not the dock.
struct ShellDock: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {                                   // — COMPANIONS —
                ForEach(shell.companionsHere) { companionChip($0) }   // this window's space (#189)
                addCompanionButton
            }
            dockAligned { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 40) }
            // — PORTS — (no Chat button: the space's chat opens from its bar at the top, GM 2026-09-27)
            HStack(spacing: 10) {
                portButton("terminal", "Terminal") { spawnTerminal() }
                portButton("globe", "Browser") { spawnBrowser() }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(shell.accent.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
    }

    /// Companion PFP — a themed monogram (no real avatars yet): an accent-tinted disc + initials.
    private func companionChip(_ c: AgentConfig) -> some View {
        VStack(spacing: 3) {
            Circle().fill(Self.avatarColor(c.id).gradient).frame(width: 40, height: 40)
                .overlay(Text(initials(c.displayName)).font(Port42Theme.monoBold(14)).foregroundStyle(.white))
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
            Text(c.displayName).font(Port42Theme.mono(8)).foregroundStyle(Port42Theme.textSecondary).lineLimit(1).frame(maxWidth: 54)
        }
        .contentShape(Rectangle())
        .help("\(c.displayName) — click to DM, hold for settings")
        // Hold → settings (high-priority so it wins); a quick tap → open the 1:1 DM (a 2-member space).
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in shell.settingsTarget = .companion(c.id) })
        .onTapGesture { shell.activateCompanion(c) }
    }

    /// One click → the new-companion card shows immediately (no menu). Add-existing lives in the card.
    /// Same VStack skeleton as a companion chip (ghost label) so the circles align in the dock row.
    private var addCompanionButton: some View {
        VStack(spacing: 3) {
            Button { shell.showNewCompanion = true } label: {
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 4])).foregroundStyle(shell.accent.opacity(0.6))
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "plus").font(.system(size: 15, weight: .light)).foregroundStyle(shell.accent))
                    .contentShape(Circle())          // whole disc is the tap target, not just the glyph
            }.buttonStyle(.plain).help("New companion in this space")
            Text(" ").font(Port42Theme.mono(8)).hidden()   // ghost label — matches the chips' name row
        }
    }

    private func portButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        dockAligned {
            Button(action: action) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(shell.accent)
                    .frame(width: 46, height: 46).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(shell.accent.opacity(0.3), lineWidth: 1))
            }.buttonStyle(.plain).help(label)
        }
    }

    /// Center a dock item on the companion CIRCLES' row, not the full chip height: every chip
    /// is circle + name label, so unlabeled items get a ghost label to share the same skeleton.
    private func dockAligned<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 3) {
            content()
            Text(" ").font(Port42Theme.mono(8)).hidden()
        }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 { return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased() }
        return String(name.prefix(2)).uppercased()
    }
    static func avatarColor(_ id: String) -> Color {
        let h = id.utf8.reduce(0) { $0 &+ Int($1) }
        return ShellState.palette[h % ShellState.palette.count]
    }

    /// Dock "Terminal" → a real plain-shell terminal port. In the shell it's a tile (hoisted Ghostty
    /// surface, re-parents like any tile); "" startup means it just drops into an interactive shell.
    private func spawnTerminal() {
        guard let space = shell.space else { return }
        // Open in the space working directory (docs/plan-companion-cwd.md), else home.
        let cwd = TerminalCwd.resolve(override: nil, spaceDir: space.workingDirectory)
        // Give the terminal a friendly codename up front. If the user runs `claude` in it, it
        // auto-registers as that companion (docs/summer2026-todo.md); the name must be baked at
        // spawn since a CLI companion's name can't be re-baked without a respawn. Seeded by a fresh
        // id so distinct terminals get distinct, stable names.
        let name = CompanionCodename.generate(seed: UUID().uuidString)
        // Spawns into the current space → a desktop tile, not a peek (handlePortCreated gates
        // same-space births), so no self-suppression tag is needed.
        _ = appState.spawnNativeTerminalPort(command: "/bin/zsh", cwd: cwd, spaceId: space.id,
                                             title: name, companionName: name,
                                             postCard: false, startupCommandOverride: "")
    }

    /// Dock "Browser" → an embedded WebKit browser tile (address bar + real navigation) at a start page.
    private func spawnBrowser() {
        guard let sid = shell.spaceId else { return }
        // Current-space birth → a tile, not a peek (gated in handlePortCreated).
        _ = appState.portWindows.addTiledBrowserPanel(url: "https://duckduckgo.com", spaceId: sid,
                                                       createdBy: nil, title: "browser")
    }
}

/// A port's kept versions, with restore. Its own View on purpose: inlined into ShellTileView's
/// body the type-checker never finished (>7min). Two things are deliberate here —
/// `Date.formatted(date:time:)` is replaced by a static formatter (it is notoriously slow to
/// type-check), and the sort is precomputed rather than inlined into the ForEach.
struct PortVersionsPopover: View {
    let accent: Color
    let fetchGrouped: () -> [PortVersionSummary]
    let fetchAllSaves: () -> [PortVersionSummary]
    let onRestore: (Int) -> Void

    /// Fetched on appear, NOT passed in — see the note at the call site (first-open-empty bug).
    @State private var grouped: [PortVersionSummary] = []
    @State private var allSaves: [PortVersionSummary] = []
    /// false = grouped by <meta> version; true = every individual save.
    @State private var expanded = false

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    private var rows: [PortVersionSummary] {
        (expanded ? allSaves : grouped).sorted { $0.version > $1.version }
    }

    /// Total DB saves: each `port.update`/`patch` stamps one. These are auto-saves, not hand-made
    /// checkpoints, which is why the raw count runs to the hundreds.
    private var totalSaves: Int {
        grouped.reduce(0) { $0 + ($1.saveCount ?? 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                Text("no saved history")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .padding(10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.version) { v in
                            row(v)
                            Divider().opacity(0.35)
                        }
                    }
                }
                // FIXED height, not maxHeight: macOS NSPopover sizes to content at present-time and
                // won't grow afterward, so toggling 1 grouped row → 349 saves left the fanned list
                // clipped to the popover's original tiny height. A stable frame presents it big
                // enough for either mode.
                .frame(height: 300)
            }
        }
        .frame(width: 340)
        .background(Port42Theme.bgPrimary)
        .onAppear {
            grouped = fetchGrouped()
            allSaves = fetchAllSaves()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("HISTORY")
                .font(Port42Theme.monoBold(9))
                .foregroundStyle(accent)
            Spacer(minLength: 12)
            Text("\(grouped.count) version\(grouped.count == 1 ? "" : "s") · \(totalSaves) saves")
                .font(Port42Theme.mono(9))
                .foregroundStyle(Port42Theme.textSecondary)
            // Toggle: collapse to <meta> versions, or every individual save. The count is on the
            // label on purpose — if it reads "(0)" the fetch is the bug, not the toggle.
            Button { expanded.toggle() } label: {
                Text(expanded ? "grouped" : "all saves (\(allSaves.count))")
                    .font(Port42Theme.mono(8))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse to versions" : "Show every save")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func row(_ v: PortVersionSummary) -> some View {
        Button {
            onRestore(v.version)
        } label: {
            HStack(spacing: 8) {
                // The port's own <meta name="version"> where it set one, not the raw DB counter.
                Text("v\(v.displayVersion)")
                    .font(Port42Theme.monoBold(10))
                    .foregroundStyle(accent)
                    .frame(width: 40, alignment: .leading)
                if let n = v.saveCount, n > 1 {
                    Text("×\(n)")
                        .font(Port42Theme.mono(8))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                }
                Text(who(v.createdBy))
                    .font(Port42Theme.mono(9))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.stamp.string(from: v.createdAt))
                    .font(Port42Theme.mono(9))
                    .foregroundStyle(Port42Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Restore this version")
    }

    /// Translate the internal caller identity into something a human recognises. A local gateway caller
    /// is the stable `local-http` principal; `remote-http…` is the pre-Phase-3 flattened label, kept for
    /// rows written before the fix. Otherwise show the id (a peer's own identity) rather than a raw token.
    private func who(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "you" }
        // `local-http` is deleted (5b): a gateway caller is a named client, so its label comes from
        // its client row rather than being guessed from an id.

        if raw.hasPrefix("remote-http") { return "API / agent" }
        return raw
    }
}


// MARK: - Port overflow actions (chrome "…")

/// Secondary port actions behind the "…" in the chrome. A popover, not a Menu — Menu won't open
/// reliably inside a scaled/positioned tile. Set-as-background is the first tenant; the long tail
/// (park placement, reopen, edit-with-AI) lands here too.
struct PortMorePopover: View {
    @ObservedObject var bridge: PortBridge
    let accent: Color
    /// An authored web port: refresh and history apply. Any port can be the background.
    let editable: Bool
    let onRefresh: () -> Void
    let onHistory: () -> Void
    let onHide: () -> Void
    /// A web port of this instance can be shared (4.6b); nil hides the row.
    var onShare: (() -> Void)? = nil
    /// A copy of this port, beside it (4.6b); nil hides the row.
    var onFork: (() -> Void)? = nil
    /// Which spaces it lives in (GM, 2026-09-30): move its home, also show it elsewhere, take a copy
    /// shown here off this desktop, or hand it to another machine. One row, so the menu stays short.
    var onSpaces: (() -> Void)? = nil
    /// A tile of someone else's port: which of your companions are on it (two agents, decision 6).
    var onCompanions: (() -> Void)? = nil
    /// Where the port is pinned now, and the action that changes it (GM, 2026-09-27).
    /// This port's body opacity and how to change it (#195).
    var opacity: Double = 1
    var onOpacity: ((Double) -> Void)? = nil
    let pin: PortPin
    let onPin: (PortPin) -> Void
    let onSetBackground: () -> Void
    @State private var pinOpen = false
    @State private var opacityOpen = false

    private var pinTitle: String {
        switch pin {
        case .none: return "Pin"
        case .space: return "Pinned in this space"
        case .everywhere: return "Pinned in every space"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if editable {
                row("Refresh", icon: "arrow.clockwise", action: onRefresh)
                row("History…", icon: "clock.arrow.circlepath", action: onHistory)
                Divider().opacity(0.4)
            }
            // Set-only: clearing is a shell-level action (the "reset background" control in the top
            // chrome), not something that belongs on a random port.
            if let onShare {
                row("Share…", icon: "person.2", action: onShare)
            }
            if let onFork {
                row("Fork: a copy", icon: "arrow.triangle.branch", action: onFork)
            }
            if let onCompanions {
                row("Companions…", icon: "person.2", action: onCompanions)
            }
            if let onSpaces {
                row("Spaces…", icon: "square.stack", action: onSpaces)
            }
            if onShare != nil || onFork != nil || onSpaces != nil { Divider().opacity(0.4) }
            row("Hide: keeps running", icon: "eye.slash", action: onHide)
            row("Set as background", icon: "photo", action: onSetBackground)
            // One "Pin" option with its choices under it (GM, 2026-09-27). A popover has no
            // submenus, so the row opens its choices in place.
            row(pinTitle, icon: pin == .none ? "pin" : "pin.fill", trailing: pinOpen ? "▾" : "▸") {
                withAnimation(.easeOut(duration: 0.15)) { pinOpen.toggle() }
            }
            if pinOpen {
                subRow("In this space", on: pin == .space) { onPin(.space) }
                subRow("In every space", on: pin == .everywhere) { onPin(.everywhere) }
                if pin != .none { subRow("Unpin", on: false) { onPin(.none) } }
            }
            // #195: how see-through the port is. The menu stays open, so the person can try levels.
            if let onOpacity {
                row("Opacity: \(Self.percent(opacity))", icon: opacity < 1 ? "circle.lefthalf.filled" : "circle.fill",
                    trailing: opacityOpen ? "▾" : "▸") {
                    withAnimation(.easeOut(duration: 0.15)) { opacityOpen.toggle() }
                }
                if opacityOpen {
                    ForEach(ShellState.portOpacityChoices, id: \.self) { level in
                        subRow(level == 1 ? "Solid" : Self.percent(level), on: abs(opacity - level) < 0.01) { onOpacity(level) }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 200)
        .background(Port42Theme.bgPrimary)
    }

    static func percent(_ level: Double) -> String { "\(Int((level * 100).rounded()))%" }

    private func row(_ title: String, icon: String, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(accent).frame(width: 16)
                Text(title).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing).font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A choice under an opened row, indented, with a check on the current one.
    private func subRow(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(on ? "✓" : "").font(Port42Theme.mono(10)).foregroundStyle(accent).frame(width: 16)
                Text(title).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 28).padding(.trailing, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Resize cursors

/// The cursor over a place that resizes (GM, 2026-09-27: dragging a side or a corner should show that
/// it can be dragged). Sides get the arrows along their axis; corners get the diagonal frame-resize
/// cursors on macOS 15, and the crosshair before it (macOS 14 has no public diagonal cursor).
enum ResizeCursor {
    static func cursor(for c: ShellTile.Corner) -> NSCursor {
        switch c {
        case .e, .w: return .resizeLeftRight
        case .n, .s: return .resizeUpDown
        case .nw, .ne, .sw, .se:
            if #available(macOS 15, *) {
                let p: NSCursor.FrameResizePosition = c == .nw ? .topLeft : c == .ne ? .topRight : c == .sw ? .bottomLeft : .bottomRight
                return .frameResize(position: p, directions: .all)
            }
            return .crosshair
        }
    }
}

extension View {
    /// Show `cursor` while the pointer is over this view.
    func resizeCursor(_ cursor: NSCursor) -> some View {
        onHover { inside in if inside { cursor.push() } else { NSCursor.pop() } }
    }
}
