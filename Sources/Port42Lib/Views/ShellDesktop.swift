import SwiftUI
import AppKit
import WebKit

/// SHELL — S2.2b. The real shell desktop that replaces `ContentView` at the space rung: a Chrome
/// top bar (§7a) + a grid of tiled ports (the chat is a tile) composited over the dreamscape, plus
/// a bottom launcher dock. Every port is ONE persistent unit (Port Units, plan §3): tile / peek /
/// focus are geometry states of the same mounted view — no reparenting, no focus overlay.
/// Chat is a real `isChatPort` PortPanel rendered as an ordinary tile (no special-casing).

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
                withAnimation(.spring(response: 0.4)) {
                    if shell.zoom == .galaxy { shell.zoom = .space } else { shell.zoomOut() }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(shell.accent)
                    Text(appState.currentSpace?.name ?? "—").font(Port42Theme.monoBold(12)).foregroundStyle(Port42Theme.textPrimary)
                }
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(shell.accent.opacity(shell.zoom == .galaxy ? 0.2 : 0.12), in: Capsule())
                .overlay(Capsule().stroke(shell.accent.opacity(shell.zoom == .galaxy ? 0.7 : 0.4), lineWidth: 1))
                .frame(height: 26)
            }
            .buttonStyle(.plain).help("All spaces (⌘↑ / pinch out)")

            chromeButton("rectangle.3.group", "Arrange (⌘L)") { shell.arrangeBump += 1 }
            // New Space lives in the galaxy now (spaces are the galaxy's business), not the Chrome.

            Spacer()

            // Same order as the pre-shell header cluster: status dots → pause → usage → settings.
            // (Power/sign-out/reset moved to the PORT42 mark menu on the left.)
            chromeRow { statusCluster }                      // gateway · tunnel · auth-key
            stopAllButton                                    // kill switch for every companion call
            // Reset background — a SHELL-level control, not a per-port one. Appears only when a port
            // is set as the background; clears it back to the ambient dreamscape and pops the port
            // back onto the desktop.
            if shell.backgroundPortHtml != nil {
                chromeButton("moon.stars", "Reset background") { shell.clearBackgroundToTile() }
            }
            chromeButton("chart.bar", "Token usage") { shell.showUsage = true }
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

    /// gateway (bolt) · tunnel (globe, when active) · Anthropic auth (key, colored by state).
    private var statusCluster: some View {
        HStack(spacing: 9) {
            // Every indicator ALWAYS shows — the icon+color carry on/off state, they never disappear.
            Image(systemName: appState.sync.isConnected ? "bolt.fill" : "bolt.slash").font(.system(size: 10))
                .foregroundStyle(appState.sync.isConnected ? .green : Port42Theme.textSecondary)
                .appKitTooltip(appState.sync.isConnected ? "Gateway connected" : "Gateway disconnected")
            Image(systemName: "globe").font(.system(size: 10))
                .foregroundStyle(appState.tunnel.publicURL != nil ? shell.accent : Port42Theme.textSecondary.opacity(0.4))
                .appKitTooltip(appState.tunnel.publicURL != nil ? "Remote access on — \(appState.tunnel.publicURL ?? "")" : "Remote access off")
            Image(systemName: "key.fill").font(.system(size: 10)).foregroundStyle(authDotColor)
                .appKitTooltip(authTooltip)
        }
    }

    /// Pause/resume EVERY companion call in one place — the global kill switch.
    private var stopAllButton: some View {
        Button {
            appState.aiPaused.toggle()
            LLMEngine.paused = appState.aiPaused
        } label: {
            Image(systemName: appState.aiPaused ? "pause.circle.fill" : "pause.circle").font(.system(size: 13))
                .foregroundStyle(appState.aiPaused ? .red : Port42Theme.textSecondary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).appKitTooltip(appState.aiPaused ? "AI paused — resume all" : "Pause all AI")
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

    private var authDotColor: Color {
        switch appState.authStatus {
        case .connected: return .green
        case .checking, .unknown: return Port42Theme.accent
        case .noCredential: return .orange
        case .error: return .red
        }
    }
    private var authTooltip: String {
        switch appState.authStatus {
        case .connected: return "Anthropic auth active"
        case .checking, .unknown: return "Checking credentials…"
        case .noCredential: return "No Anthropic key — open Settings"
        case .error(let msg): return "Anthropic auth error: \(msg)"
        }
    }
}

// MARK: - Desktop (tiled ports over the dreamscape; movable + resizable, z-ordered)

struct ShellDesktopView: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    /// The space the tile count last belonged to — so a count change from a SPACE SWITCH doesn't
    /// re-grid (tiles keep their saved per-space positions); only spawn/park/close within a space does.
    @State private var arrangedForSpace: String?

    private var sid: String? { appState.currentSpace?.id }

    /// The tiled ports on this desktop — `ShellState.desktopTilePanels`, the ONE predicate
    /// shared with `applyArrange` and ShellView's focus branch (Phase 0: no drift possible).
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
                ForEach(contextItems) { item in
                    let fallbackIdx = tiledPanels.firstIndex { $0.id == item.id } ?? 0
                    let pl = ShellPlacement.placement(
                        id: item.id, position: item.panel?.position,
                        size: item.panel?.size ?? ShellPlacement.peekSize,
                        z: item.panel?.z ?? 0,
                        zoom: shell.zoom, onDesktop: true,
                        peekIndex: item.peekIndex, fallbackIndex: fallbackIdx,
                        area: geo.size)
                    ShellTile(shell: shell, appState: appState,
                              tile: ShellTileModel(id: item.id,
                                                   title: item.peek?.title ?? item.panel?.title ?? "port",
                                                   panel: item.panel),
                              frame: ShellPlacement.resolvedTileFrame(
                                  position: item.panel?.position,
                                  size: item.panel?.size ?? ShellPlacement.peekSize,
                                  fallbackIndex: fallbackIdx),
                              area: geo.size,
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
                ShellParkRail(shell: shell, appState: appState, area: geo.size)
                    .zIndex(10_000)
            }
            .coordinateSpace(name: "desktop")   // tile drags read the pointer here for park/close hit-testing
            // arrange animates via its own withAnimation (ShellState.applyArrange); here we only
            // spring unit insertion/removal (tiles + peeks) and the exposé transition.
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: tiledPanels.count)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: shell.peekingPorts)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: shell.exposeActive)
            .onAppear { seedIfNeeded(area: geo.size); arrangedForSpace = sid }
            .onChange(of: appState.currentSpace?.id) { _, _ in
                shell.clearOpenDMs()                                                       // DMs are per-desktop
                if let sid { appState.portWindows.ensureChatTiled(spaceId: sid) }         // chat → visible tile
            }
            .onChange(of: tiledPanels.count) { _, _ in
                // A spawn/park/close WITHIN the current space re-grids; a space SWITCH also changes the
                // count, but each space's tiles keep their saved positions — adopt the space, don't arrange.
                guard arrangedForSpace == sid else { arrangedForSpace = sid; return }
                shell.applyArrange(area: geo.size)
            }
            .onChange(of: shell.arrangeBump) { _, _ in shell.applyArrange(area: geo.size) }   // ⌘L
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
        let workW = max(240, area.width - side - ShellState.parkWidth(area.width) - 20)
        let workH = max(200, area.height - top - bottom)
        let colW = workW / Double(cols), rowH = workH / Double(rows)
        return CGRect(x: side + Double(idx % cols) * colW + gap / 2,
                      y: top + Double(idx / cols) * rowH + gap / 2,
                      width: colW - gap, height: rowH - gap)
    }

    /// Seed the grid on first entry into a space (nothing positioned yet). Hand-tuned layouts that
    /// come back from the DB with positions are left exactly as-is (arrange only re-grids on spawn/⌘L).
    private func seedIfNeeded(area: CGSize) {
        if let sid { appState.portWindows.ensureChatTiled(spaceId: sid) }      // chat → visible tile
        if tiledPanels.contains(where: { $0.position == nil }) {               // a never-positioned port →
            shell.applyArrange(area: area)                                     // grid everything once
        }
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
    var exposeFrame: CGRect? = nil        // set in exposé → scale-to-fit this cell (transient)
    /// Set when this tile is focused (Phase 0): the tile's ONE view animates to this rect in
    /// place — focus is a geometry state, not a second mount. nil = normal tile geometry.
    var focusFrame: CGRect? = nil
    /// Set while this unit is a PEEK (Phase 1): the peek entry + its rail rect. The same view
    /// renders peek chrome at railSlot; preview resizes it to focus, adopt slides it to grid.
    var peek: ShellState.PeekPort? = nil
    var peekFrame: CGRect? = nil

    /// A tile corner (any corner resizes; the opposite corner stays pinned).
    enum Corner { case nw, ne, sw, se }

    @State private var moveDelta: CGSize = .zero
    @State private var resizeCorner: Corner? = nil
    @State private var resizeDelta: CGSize = .zero
    @State private var peekHovered = false
    @State private var showVersions = false
    @State private var showMore = false

    /// Refresh + versions apply to authored HTML ports only: a terminal has no HTML to reload,
    /// and chat is native, not authored.
    private var isEditablePort: Bool {
        guard let p = tile.panel else { return false }
        return p.portType == "web" && !p.isChatPort
    }

    /// The version history, as a picker. Every version is already kept forever in `port_versions`;
    /// this is the first thing that lets a human reach one. Split into its own View: inlined here
    /// it made SwiftUI's type-checker sit for >7 minutes without finishing. The popover fetches on
    /// appear (not in the button action) — fetching into @State then flipping the popover in one
    /// action builds the popover with the OLD empty list, which is why the first open showed nothing.
    @ViewBuilder
    private var versionPicker: some View {
        PortVersionsPopover(accent: shell.accent,
                            fetchGrouped: { appState.portWindows.fetchVersionSummaries(tile.id) },
                            fetchAllSaves: { appState.portWindows.fetchSaveList(tile.id) }) { version in
            appState.portWindows.restoreVersion(tile.id, version: version)
            showVersions = false
            appState.toastMessage = "Restored version \(version)"
        }
    }

    static let titleBarH: CGFloat = 34
    private var titleBarH: CGFloat { Self.titleBarH }
    private let peekHeaderH: CGFloat = 24

    private var isFocused: Bool { shell.zoom == .focus(tile.id) }
    private var isPeeking: Bool { peekFrame != nil && !isFocused }
    private var isSelected: Bool { shell.selectedTileId == tile.id }
    private var sid: String? { appState.currentSpace?.id }
    private var headerH: CGFloat { isPeeking ? peekHeaderH : titleBarH }

    /// The accent of the space a peek CAME FROM (its home) — the edge signals origin.
    private func peekAccent(_ p: ShellState.PeekPort) -> Color {
        if let s = appState.spaces.first(where: { $0.id == p.spaceId }) { return shell.accent(for: s) }
        return shell.accent
    }

    /// Two-state peek click: unseen previews (zoom in, in place); seen keeps (adopts as a tile).
    private func clickPeek(_ p: ShellState.PeekPort) {
        let cur = shell.peekingPorts.first { $0.id == p.id } ?? p
        if cur.seen { shell.keepPeek(cur) } else { shell.previewPeek(cur) }
    }

    /// A tile that belongs to ANOTHER space (adopted from a peek) keeps its HOME space's accent, so it
    /// still reads as "from elsewhere"; native tiles use the current space's accent.
    private var tileAccent: Color {
        guard let s = tile.panel?.spaceId, s != sid,
              let space = appState.spaces.first(where: { $0.id == s }) else { return shell.accent }
        return shell.accent(for: space)
    }

    /// The DM partner when this tile is a surfaced DIRECT-message chat (else nil). A notification can
    /// also surface a regular space's chat through the same set, so require an actual direct space —
    /// direct spaces are excluded from `appState.spaces` (getRegularSpaces).
    private var dmTileCompanion: AgentConfig? {
        guard tile.panel?.isChatPort == true, let s = tile.panel?.spaceId,
              shell.openDMSpaceIds.contains(s),
              !appState.spaces.contains(where: { $0.id == s }) else { return nil }
        return appState.companions(forSpace: s).first
    }
    /// A surfaced REGULAR space's chat (from a notification) → show the space name, not "chat".
    private var surfacedSpaceTitle: String? {
        guard tile.panel?.isChatPort == true, let s = tile.panel?.spaceId,
              s != appState.currentSpace?.id else { return nil }
        return appState.spaces.first(where: { $0.id == s })?.name
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
    static func resized(_ f: CGRect, corner c: Corner, by d: CGSize) -> CGRect {
        let minW = ShellState.minTileSize.width, minH = ShellState.minTileSize.height
        let east = (c == .ne || c == .se), south = (c == .sw || c == .se)
        let fixedX = east ? f.minX : f.maxX               // pinned (opposite) edge
        let fixedY = south ? f.minY : f.maxY
        let dragX = (east ? f.maxX : f.minX) + d.width    // dragged edge, moved by the delta
        let dragY = (south ? f.maxY : f.minY) + d.height
        // The dragged edge's side is fixed by the corner (east→right edge, west→left edge); clamp to
        // the min without flipping past the pinned edge — so dragging a corner across just stops.
        let x: CGFloat, w: CGFloat, y: CGFloat, h: CGFloat
        if east { x = fixedX; w = max(minW, dragX - fixedX) } else { w = max(minW, fixedX - dragX); x = fixedX - w }
        if south { y = fixedY; h = max(minH, dragY - fixedY) } else { h = max(minH, fixedY - dragY); y = fixedY - h }
        return CGRect(x: x, y: y, width: w, height: h)
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
            Group {
                if let peek, peek.isChat, tile.panel == nil {
                    ChatView(spaceId: peek.spaceId).environmentObject(appState)   // chat peek, live miniature
                } else {
                    ShellTileBody(shell: shell, appState: appState, tile: tile)
                }
            }
            .frame(width: liveSize.width, height: max(0, liveSize.height - headerH))
            // A real AppKit view over a PEEKING unit's content wins the hit-test vs the hosted
            // NSView — the only thing that reliably captures the click (preview / keep).
            .overlay { if isPeeking, let peek { PeekClickCatcher { clickPeek(peek) } } }
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
        // Invisible resize zones on ALL four corners (no visible grip). Overlaid on top so a corner
        // grab resizes even over the titlebar/body; the buttons are inset to clear the top corners.
        // Focused/peeking units aren't corner-resizable — the handles come off.
        .overlay(alignment: .topLeading)     { if !isFocused && !isPeeking { cornerHandle(.nw) } }
        .overlay(alignment: .topTrailing)    { if !isFocused && !isPeeking { cornerHandle(.ne) } }
        .overlay(alignment: .bottomLeading)  { if !isFocused && !isPeeking { cornerHandle(.sw) } }
        .overlay(alignment: .bottomTrailing) { if !isFocused && !isPeeking { cornerHandle(.se) } }
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
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: exposeFrame)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: focusFrame)   // focus = the unit's frame animating
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: peekHovered)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            // Drag handle = dot + title + trailing gap; scoped so the focus/close buttons still tap.
            HStack(spacing: 8) {
                if let dm = dmTileCompanion {                                    // DM tile → partner's swatch + name
                    Circle().fill(ShellDock.avatarColor(dm.id).gradient).frame(width: 7, height: 7)
                    Text(dm.displayName).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                    Text("· DM").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
                } else {
                    Circle().fill(isFocused ? Port42Theme.textSecondary : tileAccent).frame(width: 7, height: 7)
                    Text(surfacedSpaceTitle ?? tile.title).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                    if surfacedSpaceTitle != nil { Text("· from").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary) }
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
            // Trailing chrome — the SAME controls whether tiled or focused (GM: "literally the same
            // code"). Secondary actions live under "…"; only focus-toggle and close stay visible.
            if isEditablePort, let bridge = tile.panel?.bridge {
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
                        onRefresh: { appState.portWindows.reloadPort(tile.id); showMore = false },
                        onHistory: { showMore = false; showVersions = true },
                        onSetBackground: {
                            // Move the port to the background rather than clone it: set (captures the
                            // HTML) then close the tile, so you don't see it twice. "port still stays
                            // open" → gone; it lives as the background now (recoverable from history).
                            appState.shell?.setBackgroundPort(id: tile.panel?.udid ?? tile.id)
                            if let panel = tile.panel { shell.dismissTile(panel) }
                            showMore = false
                        })
                }
                .popover(isPresented: $showVersions, arrowEdge: .bottom) { versionPicker }
            }
            // Focus toggle: enter focus, or shrink back out if already focused.
            Button {
                if isFocused {
                    withAnimation(.spring(response: 0.4)) { shell.zoom = .space }
                } else {
                    shell.bringToFront(tile.id)
                    withAnimation(.spring(response: 0.4)) { shell.zoom = .focus(tile.id) }
                }
            } label: {
                Image(systemName: isFocused ? "arrow.down.right.and.arrow.up.left" : "viewfinder")
                    .font(.system(size: isFocused ? 11 : 9)).foregroundStyle(Port42Theme.textSecondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help(isFocused ? "Exit focus (Esc)" : "Focus (⌘↓)")
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
            Image(systemName: p.isChat ? "bubble.left.fill" : "square.stack.3d.up")
                .font(.system(size: 9)).foregroundStyle(col)
            Text(p.title).font(Port42Theme.monoBold(9)).foregroundStyle(Port42Theme.textPrimary).lineLimit(1)
            Text("· \(p.spaceName)").font(Port42Theme.mono(8)).foregroundStyle(col.opacity(0.85)).lineLimit(1)
            Spacer(minLength: 4)
            if let rem = shell.peekRemaining[p.id] {            // seen → countdown ring (pauses on hover)
                ZStack {
                    Circle().stroke(col.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0, rem / 10))
                        .stroke(col, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }.frame(width: 11, height: 11)
            }
            Button { shell.dismissPeek(p) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 9).frame(height: peekHeaderH).background(Color.black.opacity(0.45))
        .contentShape(Rectangle())
        .onTapGesture { clickPeek(p) }                          // tap → preview (unseen) / keep (seen)
        .gesture(moveGesture)                                   // drag-to-keep starts from the header too
    }

    /// An invisible 16×16 corner drag zone that resizes from that corner.
    private func cornerHandle(_ corner: Corner) -> some View {
        Color.clear
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .gesture(resizeGesture(corner))
    }

    private var moveGesture: some Gesture {
        // Read the pointer in the desktop space so a drop onto the right rail parks/closes the port.
        DragGesture(coordinateSpace: .named("desktop"))
            .onChanged { v in
                guard !isFocused else { return }                        // a focused unit doesn't drag
                if moveDelta == .zero { shell.bringToFront(tile.id); shell.isDraggingTile = true }   // grabbing a tile raises it
                moveDelta = v.translation
                shell.draggingOverPark = railZone(at: v.location)       // highlight the rail zone under the drag
            }
            .onEnded { v in
                guard !isFocused else { return }
                shell.draggingOverPark = nil
                shell.isDraggingTile = false
                moveDelta = .zero
                // Drag-to-keep (Phase 1): pulling a peek into the space ADOPTS it as a tile at
                // the drop spot (no re-grid — the user chose the place); the close zone dismisses.
                if isPeeking, let peek, let pf = peekFrame {
                    guard hypot(v.translation.width, v.translation.height) > 40 else { return }   // a wiggle isn't a keep
                    if railZone(at: v.location) == .close { shell.dismissPeek(peek); return }
                    if peek.isChat {                                     // chat adopts via surface, not panel adoption
                        shell.dismissPeek(peek)
                        shell.surfaceSpaceChat(spaceId: peek.spaceId, spaceName: peek.spaceName)
                        return
                    }
                    shell.keepPeek(peek, arrange: false)
                    commit(origin: CGPoint(x: pf.minX + v.translation.width, y: pf.minY + v.translation.height),
                           size: tile.panel?.size ?? pf.size)
                    return
                }
                let zone = railZone(at: v.location)
                switch zone {                                                    // any tile (chat included) — count↓ re-grids
                case .close: if let panel = tile.panel { shell.dismissTile(panel) }
                case .park:  if let panel = tile.panel { appState.portWindows.park(id: panel.id) }
                case nil:
                    commit(origin: CGPoint(x: frame.minX + v.translation.width, y: frame.minY + v.translation.height),
                           size: CGSize(width: frame.width, height: frame.height))
                }
            }
    }

    /// The rail zone under a desktop-space point. The chat is NOT exempt — it parks/closes too.
    private func railZone(at p: CGPoint) -> ShellState.ParkZone? {
        ShellState.parkZone(at: p, in: area)
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        // Measure in the FIXED desktop space, not the handle's local space — the handle rides the
        // corner that the resize is moving, so a local-space translation lags behind the cursor.
        DragGesture(coordinateSpace: .named("desktop"))
            .onChanged { v in
                if resizeCorner == nil { shell.bringToFront(tile.id); shell.isDraggingTile = true }
                resizeCorner = corner
                resizeDelta = v.translation
            }
            .onEnded { v in
                let f = Self.resized(frame, corner: corner, by: v.translation)
                commit(origin: f.origin, size: f.size)
                resizeCorner = nil
                resizeDelta = .zero
                shell.isDraggingTile = false
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
        appState.portWindows.updateTileFrame(
            id: tile.id, position: Self.clampedOrigin(origin, size: size, area: area), size: size)
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

    /// Ports put away in the rail. Only `parked` — the shell has NO floating presentation
    /// (Phase 2): a port here is tiled, parked, or peeking. One click restores a chip to a tile.
    private var railPanels: [PortPanel] {
        guard let sid = appState.currentSpace?.id else { return [] }
        let allowed = Set([sid] + shell.openDMSpaceIds)              // parked DM tiles dock here too
        return appState.portWindows.panels.filter {
            allowed.contains($0.spaceId ?? "") && $0.presentation == "parked"
        }
    }

    var body: some View {
        let w = ShellState.parkWidth(area.width)
        let overPark = shell.draggingOverPark == .park
        let overClose = shell.draggingOverPark == .close

        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 12))
                .foregroundStyle(Port42Theme.textSecondary.opacity(overPark ? 1 : 0.5))
                .padding(.top, 12)
            ForEach(railPanels, id: \.id) { chip($0) }   // parked/floating ports incl. the chat panel
            Spacer(minLength: 12)
            closeZone(height: ShellState.closeZoneHeight(area.height), active: overClose)
        }
        .frame(width: w)
        .padding(.top, 46)                       // clear the Chrome
        .background(Rectangle().fill(shell.accent.opacity(overPark ? 0.16 : 0.05)))
        .overlay(Rectangle().fill(shell.accent.opacity(overPark ? 0.6 : 0.15)).frame(width: 1), alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.easeOut(duration: 0.15), value: shell.draggingOverPark)
    }

    private func chip(_ p: PortPanel) -> some View {
        Button {
            appState.portWindows.unpark(id: p.id)
            shell.arrangeBump += 1
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "square.on.square").font(.system(size: 13)).foregroundStyle(shell.accent)
                Text(p.title.prefix(6)).font(Port42Theme.mono(8)).foregroundStyle(Port42Theme.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(shell.accent.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain).help("Restore \(p.title)")
        .padding(.horizontal, 6)
    }

    private func closeZone(height: CGFloat, active: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: "trash").font(.system(size: 15, weight: active ? .bold : .regular))
                .foregroundStyle(active ? Color.red : Port42Theme.textSecondary.opacity(0.5))
            Text("close").font(Port42Theme.mono(8)).foregroundStyle(active ? Color.red : Port42Theme.textSecondary.opacity(0.5))
        }
        .frame(maxWidth: .infinity).frame(height: height)
        .background(Rectangle().fill(Color.red.opacity(active ? 0.22 : 0)))
        .overlay(Rectangle().fill(Color.red.opacity(active ? 0.7 : 0.12)).frame(height: 1), alignment: .top)
    }
}

/// A tile's live body: the chat surface (with a member header), or a tiled port's re-parented webview.
struct ShellTileBody: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    let tile: ShellTileModel

    var body: some View {
        if tile.panel?.isChatPort == true {                             // the chat panel: ChatView + a hover member strip
            ZStack(alignment: .top) {
                ChatView(spaceId: tile.panel?.spaceId).environmentObject(appState).padding(.top, 26)   // its OWN space
                ShellMemberRow(shell: shell, appState: appState, accent: shell.accent, spaceId: tile.panel?.spaceId)
            }
        } else if let panel = tile.panel, panel.portType == "browser",
                  let wv = appState.portWindows.hostView(for: panel.id) as? WKWebView {
            ShellBrowserTile(webView: wv, accent: shell.accent, initialURL: panel.html,
                             probeId: panel.id)   // address bar + page
        } else if let panel = tile.panel, let v = appState.portWindows.hostView(for: panel.id) {
            ShellPortHost(view: v, bridge: panel.bridge, probeId: panel.id)   // web OR terminal — one host
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
    @State private var urlText: String

    init(webView: WKWebView, accent: Color, initialURL: String, probeId: String? = nil) {
        self.webView = webView
        self.accent = accent
        self.probeId = probeId
        _urlText = State(initialValue: initialURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                navButton("chevron.left") { webView.goBack() }
                navButton("chevron.right") { webView.goForward() }
                navButton("arrow.clockwise") { webView.reload() }
                TextField("search or type a URL", text: $urlText)
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
        }
    }

    private func navigate() {
        if let url = URL(string: PortWindowManager.normalizedBrowserURL(urlText)) {
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
        // Don't reclaim the view if it moved to another container (tile/focus/rail reparenting).
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
                ForEach(appState.spaceCompanions) { companionChip($0) }
                addCompanionButton
            }
            dockAligned { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 40) }
            HStack(spacing: 10) {                                   // — PORTS —
                portButton("bubble.left.and.bubble.right", "Chat") { openChat() }
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

    /// Chat: bring this space's chat tile back to the desktop (from parked / popped-out / closed).
    private func openChat() {
        guard let s = appState.currentSpace else { return }
        appState.portWindows.revealChat(spaceId: s.id, spaceName: s.name)
        shell.arrangeBump += 1
    }

    /// Dock "Terminal" → a real plain-shell terminal port. In the shell it's a tile (hoisted Ghostty
    /// surface, re-parents like any tile); "" startup means it just drops into an interactive shell.
    private func spawnTerminal() {
        guard let space = appState.currentSpace else { return }
        // Open in the space working directory (docs/plan-companion-cwd.md), else home.
        let cwd = TerminalCwd.resolve(override: nil, spaceDir: space.workingDirectory)
        // Give the terminal a friendly codename up front. If the user runs `claude` in it, it
        // auto-registers as that companion (docs/summer2026-todo.md); the name must be baked at
        // spawn since a CLI companion's name can't be re-baked without a respawn. Seeded by a fresh
        // id so distinct terminals get distinct, stable names.
        let name = CompanionCodename.generate(seed: UUID().uuidString)
        if let id = appState.spawnNativeTerminalPort(command: "/bin/zsh", cwd: cwd, spaceId: space.id,
                                                     title: name, companionName: name,
                                                     postCard: false, startupCommandOverride: "") {
            shell.noteUserSpawn(id)                       // your own spawn shouldn't peek at you
        }
        shell.arrangeBump += 1
    }

    /// Dock "Browser" → an embedded WebKit browser tile (address bar + real navigation) at a start page.
    private func spawnBrowser() {
        guard let sid = appState.currentSpace?.id else { return }
        let id = appState.portWindows.addTiledBrowserPanel(url: "https://duckduckgo.com", spaceId: sid,
                                                           createdBy: nil, title: "browser")
        shell.noteUserSpawn(id)                           // your own spawn shouldn't peek at you
        shell.arrangeBump += 1
    }
}

// MARK: - Chat member row (you + the space's companions, with live status)

/// The chat tile's members — a THIN strip at rest (overlapping avatars + count, a pulse if anyone's
/// thinking); **hover expands** it into the full list (you + companions, each with status). It's an
/// overlay, so it doesn't permanently eat chat space. Click a companion → its 1:1 DM.
struct ShellMemberRow: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    let accent: Color
    /// Which space's members to show — nil means the current space (the group chat tile). DM tiles
    /// pass their own space id so each chat window shows its OWN crew.
    var spaceId: String? = nil
    @State private var expanded = false
    @State private var hoveredId: String?
    @State private var hoverGen = 0     // hysteresis token so a brief exit doesn't flap the expansion

    private var members: [AgentConfig] { appState.companions(forSpace: spaceId ?? appState.currentSpace?.id) }

    var body: some View {
        let sid = spaceId ?? appState.currentSpace?.id ?? ""
        let thinking = appState.typingAgentNamesBySpace[sid] ?? []
        VStack(spacing: 0) {
            collapsedStrip(anyThinking: !thinking.isEmpty)
            if expanded { fullList(thinking: thinking) }
        }
        .onHover { hovering in
            hoverGen += 1
            if hovering {
                expanded = true
            } else {
                // Collapse after a short grace window; a fast sweep that clips the titlebar seam and
                // comes back cancels it (newer hoverGen), so the list neither flaps nor sticks open.
                let gen = hoverGen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    if gen == hoverGen { expanded = false }
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: expanded)
    }

    private func collapsedStrip(anyThinking: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: -6) {                                        // overlapping avatars
                ForEach(members.prefix(5)) { c in
                    Circle().fill(ShellDock.avatarColor(c.id).gradient).frame(width: 15, height: 15)
                        .overlay(Text(initials(c.displayName)).font(.system(size: 6, weight: .bold)).foregroundStyle(.white))
                        .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                }
            }
            Text("\(members.count) + you").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
            Spacer(minLength: 6)
            if anyThinking { statusDot(thinking: true); Text("thinking").font(Port42Theme.mono(8)).foregroundStyle(accent) }
            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 7)).foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Color.black.opacity(0.35))
        .overlay(Rectangle().fill(accent.opacity(0.15)).frame(height: 1), alignment: .bottom)
    }

    private func fullList(thinking: Set<String>) -> some View {
        VStack(spacing: 2) {
            memberRow(color: Port42Theme.textSecondary, name: appState.currentUser?.displayName ?? "you",
                      thinking: false, companion: nil)
            ForEach(members) { c in
                memberRow(color: ShellDock.avatarColor(c.id), name: c.displayName,
                          thinking: thinking.contains(c.displayName), companion: c)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .background(Color(red: 0.05, green: 0.06, blue: 0.08))
        .overlay(Rectangle().fill(accent.opacity(0.15)).frame(height: 1), alignment: .bottom)
        .transition(.opacity)   // fade only — a move-from-top slid the list up into the titlebar (glitch)
    }

    private func memberRow(color: Color, name: String, thinking: Bool, companion: AgentConfig?) -> some View {
        let isYou = companion == nil
        let hot = companion.map { hoveredId == $0.id } ?? false
        return HStack(spacing: 8) {
            Circle().fill(isYou ? AnyShapeStyle(color.opacity(0.5)) : AnyShapeStyle(color.gradient))
                .frame(width: 20, height: 20)
                .overlay(Text(initials(name)).font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
            Text(name).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary).lineLimit(1)
            if isYou { Text("you").font(Port42Theme.mono(8)).foregroundStyle(Port42Theme.textSecondary) }
            Spacer(minLength: 6)
            if companion != nil { statusView(thinking: thinking) }
            if hot, let c = companion {
                // The eye — inspect this companion's epistemic memory (fold/position/creases/
                // engravings) in THIS chat's space. Migrated from the swim window's titlebar.
                Button {
                    if let sid = spaceId ?? appState.currentSpace?.id {
                        shell.inspecting = ShellState.InspectTarget(companion: c, spaceId: sid)
                    }
                } label: {
                    Image(systemName: "eye").font(.system(size: 9)).foregroundStyle(Port42Theme.textSecondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Inspect \(c.displayName)'s inner state")
                Image(systemName: "bubble.left").font(.system(size: 9)).foregroundStyle(accent)   // → DM hint
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(hot ? Color.white.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { h in if let c = companion { hoveredId = h ? c.id : (hoveredId == c.id ? nil : hoveredId) } }
        .onTapGesture { if let c = companion { shell.activateCompanion(c) } }   // CLI → terminal, else DM
    }

    @ViewBuilder private func statusView(thinking: Bool) -> some View {
        if thinking {
            HStack(spacing: 4) {
                statusDot(thinking: true)
                Text("thinking").font(Port42Theme.mono(8)).foregroundStyle(accent)
            }
        } else {
            statusDot(thinking: false)
        }
    }

    @ViewBuilder private func statusDot(thinking: Bool) -> some View {
        if thinking {
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Circle().fill(accent).frame(width: 6, height: 6)
                    .opacity(0.4 + 0.6 * abs(sin(t * 3)))     // pulse while thinking
            }
        } else {
            Circle().fill(Color.white.opacity(0.22)).frame(width: 6, height: 6)   // idle
        }
    }

    private func initials(_ name: String) -> String { name.isEmpty ? "?" : String(name.prefix(2)).uppercased() }
}

// MARK: - Port version history (chrome)

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
        if raw == Principal.localGatewayID { return "Local (gateway)" }
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
    let onRefresh: () -> Void
    let onHistory: () -> Void
    let onSetBackground: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // AI pause — stays open so you see it flip to Resume. Same behaviour as the token guard.
            row(bridge.aiPaused ? "Resume AI" : "Pause AI",
                icon: bridge.aiPaused ? "play.circle" : "pause.circle") {
                bridge.aiPaused.toggle()
                if bridge.aiPaused { bridge.suspendAI() }
            }
            row("Refresh", icon: "arrow.clockwise", action: onRefresh)
            row("History…", icon: "clock.arrow.circlepath", action: onHistory)
            Divider().opacity(0.4)
            // Set-only: clearing is a shell-level action (the "reset background" control in the top
            // chrome), not something that belongs on a random port.
            row("Set as background", icon: "photo", action: onSetBackground)
        }
        .padding(.vertical, 4)
        .frame(width: 200)
        .background(Port42Theme.bgPrimary)
    }

    private func row(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(accent).frame(width: 16)
                Text(title).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
