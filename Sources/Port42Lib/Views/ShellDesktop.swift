import SwiftUI
import AppKit
import WebKit

/// SHELL — S2.2b. The real shell desktop that replaces `ContentView` at the space rung: a Chrome
/// top bar (§7a) + a grid of tiled ports (the chat is a tile) composited over the dreamscape, plus
/// a bottom launcher dock. Tiles re-parent their registry webview into the focus overlay with no
/// reload. Chat is a real `isChatPort` PortPanel rendered as an ordinary tile (no special-casing).

// MARK: - Chrome (Layer 2 top bar, §7a)

struct ShellChrome: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            markMenu
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
            }
            .buttonStyle(.plain).help("All spaces (⌘↑ / pinch out)")

            chromeButton("rectangle.3.group", "Arrange (⌘L)") { shell.arrangeBump += 1 }
            // New Space lives in the galaxy now (spaces are the galaxy's business), not the Chrome.

            Spacer()

            // Same order as the pre-shell header cluster: status dots → pause → usage → settings.
            // (Power/sign-out/reset moved to the PORT42 mark menu on the left.)
            statusCluster                                    // gateway · tunnel · auth-key
            stopAllButton                                    // kill switch for every companion call
            chromeButton("chart.bar", "Token usage") { shell.showUsage = true }
            chromeButton("gearshape", "Settings") { shell.showSettings = true }

            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 20)
            profileChip                                      // name + PFP, far right
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

    private var sid: String? { appState.currentSpace?.id }

    /// The tiled ports on this desktop: the current space's, plus any open DM chats surfaced as
    /// tiles alongside it (B — the space chat and each DM coexist as separate live windows).
    private var tiledPanels: [PortPanel] {
        guard let sid else { return [] }
        let allowed = Set([sid] + shell.openDMSpaceIds)
        return appState.portWindows.panels.filter { p in
            p.presentation == "tiled" && (allowed.contains(p.spaceId ?? "") || shell.surfacedPortIds.contains(p.id))
        }
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
                // All tiled ports (the chat is one of them), painted back-to-front by z. In exposé
                // they spread to the fit grid (a TEMPORARY arrange — real positions are untouched).
                ForEach(tiledPanels.sorted { $0.z < $1.z }, id: \.id) { p in
                    ShellTile(shell: shell, appState: appState,
                              tile: ShellTileModel(id: p.id, title: p.title, panel: p),
                              frame: resolvedPortFrame(p, area: geo.size), area: geo.size,
                              exposeFrame: shell.exposeActive ? exposeRect(p, geo.size) : nil)
                        .zIndex(shell.exposeActive ? 5 : Double(max(p.z, 1)))
                }
                if shell.exposeActive {
                    VStack { Spacer()
                        Text("EXPOSÉ · click a tile · Tab / Esc to exit")
                            .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                            .padding(.bottom, 96)
                    }.zIndex(9_000).allowsHitTesting(false)
                }
                // Right-edge rail: park (main strip) + close (bottom zone). On top of the tiles.
                ShellParkRail(shell: shell, appState: appState, area: geo.size)
                    .zIndex(10_000)
                // Left-edge peeking notifications: a live chat/port from another space (§8b).
                ShellNotificationRail(shell: shell, appState: appState)
                    .zIndex(10_500)
            }
            .coordinateSpace(name: "desktop")   // tile drags read the pointer here for park/close hit-testing
            // arrange animates via its own withAnimation (ShellState.applyArrange); here we only
            // spring tile insertion/removal and the exposé transition.
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: tiledPanels.count)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: shell.exposeActive)
            .onAppear { seedIfNeeded(area: geo.size) }
            .onChange(of: appState.currentSpace?.id) { _, _ in
                shell.clearOpenDMs()                                                       // DMs are per-desktop
                if let sid { appState.portWindows.ensureChatTiled(spaceId: sid) }         // chat → visible tile
            }
            .onChange(of: tiledPanels.count) { _, _ in shell.applyArrange(area: geo.size) }   // spawn/park/close re-grids
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

    /// A port tile's frame — its persisted position/size, or a cheap cascade seed until arrange runs.
    private func resolvedPortFrame(_ p: PortPanel, area: CGSize) -> CGRect {
        if let pos = p.position { return CGRect(origin: pos, size: p.size) }
        let i = tiledPanels.firstIndex { $0.id == p.id } ?? 0
        return CGRect(x: 330 + Double(i % 4) * 90, y: 200 + Double(i % 3) * 80, width: p.size.width, height: p.size.height)
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

    /// A tile corner (any corner resizes; the opposite corner stays pinned).
    enum Corner { case nw, ne, sw, se }

    @State private var moveDelta: CGSize = .zero
    @State private var resizeCorner: Corner? = nil
    @State private var resizeDelta: CGSize = .zero

    private let titleBarH: CGFloat = 34

    private var isFocused: Bool { shell.zoom == .focus(tile.id) }
    private var isSelected: Bool { shell.selectedTileId == tile.id }
    private var sid: String? { appState.currentSpace?.id }

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

    /// The tile's live frame = its committed frame plus an in-progress move OR corner-resize. The
    /// tile is placed top-left via `.offset`, so both move and resize just recompute this rect.
    private var liveFrame: CGRect {
        if let c = resizeCorner { return Self.resized(frame, corner: c, by: resizeDelta) }
        return CGRect(x: frame.minX + moveDelta.width, y: frame.minY + moveDelta.height,
                      width: frame.width, height: frame.height)
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

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ZStack {
                if isFocused {
                    VStack(spacing: 6) {
                        Image(systemName: "viewfinder").font(.system(size: 22)).foregroundStyle(Port42Theme.textSecondary)
                        Text("focused — Esc to return").font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.5))
                } else {
                    ShellTileBody(shell: shell, appState: appState, tile: tile)
                }
            }
            .frame(width: liveSize.width, height: max(0, liveSize.height - titleBarH))
        }
        .frame(width: liveSize.width, height: liveSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? shell.accent.opacity(0.7) : shell.accent.opacity(0.25), lineWidth: 1))
        // Invisible resize zones on ALL four corners (no visible grip). Overlaid on top so a corner
        // grab resizes even over the titlebar/body; the buttons are inset to clear the top corners.
        .overlay(cornerHandle(.nw), alignment: .topLeading)
        .overlay(cornerHandle(.ne), alignment: .topTrailing)
        .overlay(cornerHandle(.sw), alignment: .bottomLeading)
        .overlay(cornerHandle(.se), alignment: .bottomTrailing)
        // In exposé, the whole tile is a pick target (over the body/handles): click → select + exit.
        .overlay {
            if shell.exposeActive {
                Button {
                    withAnimation(.spring(response: 0.4)) { shell.exposeActive = false }
                    shell.bringToFront(tile.id)
                } label: { Color.white.opacity(0.001) }
                .buttonStyle(.plain)
            }
        }
        .shadow(color: shell.accent.opacity(isSelected ? 0.3 : 0.12), radius: isSelected ? 22 : 12)
        .scaleEffect(exposeScale, anchor: .center)            // exposé shrinks/grows the tile to ~fit its cell
        .onHover { if $0 { shell.bringToFront(tile.id) } }   // hover raises the tile to the front + selects (BEFORE .position → tracking on the bounded tile)
        .position(x: placedCenter.x, y: placedCenter.y)       // place last; exposé re-centers into its cell
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: exposeFrame)
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
                    Circle().fill(isFocused ? Port42Theme.textSecondary : shell.accent).frame(width: 7, height: 7)
                    Text(surfacedSpaceTitle ?? tile.title).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                    if surfacedSpaceTitle != nil { Text("· from").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary) }
                }
                Spacer(minLength: 8)
            }
            .frame(maxHeight: .infinity)          // fill the full titlebar height so the WHOLE bar drags
            .contentShape(Rectangle())
            .gesture(moveGesture)
            Button { shell.bringToFront(tile.id); withAnimation(.spring(response: 0.4)) { shell.zoom = .focus(tile.id) } } label: {
                Image(systemName: "viewfinder").font(.system(size: 9)).foregroundStyle(Port42Theme.textSecondary)
            }.buttonStyle(.plain).help("Focus (⌘↓)")
            if let panel = tile.panel {
                // No "pop out to floating window": a tile IS the floating window. States are tile ⇄
                // parked (rail) ⇄ focus — one frame, not two.
                Button { shell.dismissTile(panel) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.leading, 10).padding(.trailing, 18)   // trailing inset clears the top-right resize zone
        .frame(maxWidth: .infinity)          // span the tile so the drag handle is easy to grab
        .frame(height: titleBarH)
        .background(Port42Theme.shellCard)
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
                if moveDelta == .zero { shell.bringToFront(tile.id) }   // grabbing a tile raises it
                moveDelta = v.translation
                shell.draggingOverPark = railZone(at: v.location)       // highlight the rail zone under the drag
            }
            .onEnded { v in
                let zone = railZone(at: v.location)
                shell.draggingOverPark = nil
                moveDelta = .zero
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
                if resizeCorner == nil { shell.bringToFront(tile.id) }
                resizeCorner = corner
                resizeDelta = v.translation
            }
            .onEnded { v in
                let f = Self.resized(frame, corner: corner, by: v.translation)
                commit(origin: f.origin, size: f.size)
                resizeCorner = nil
                resizeDelta = .zero
            }
    }

    /// Persist the tile's new geometry (drag/resize end) → the panel record (survives restart, §4).
    private func commit(origin: CGPoint, size: CGSize) {
        appState.portWindows.updateTileFrame(id: tile.id, position: origin, size: size)
    }
}

// MARK: - Right-edge parking + close rail

/// The right-edge rail: parked ports as clickable chips (click → unpark) with a **close** drop zone
/// at the bottom. It's a drop TARGET only — the drag is owned by the tile's move gesture, which sets
/// `shell.draggingOverPark` for the highlight and calls `park`/`close` on drop. Faint at rest; lights
/// up accent (park) or red (close) while a tile is dragged over the matching zone.
/// Left-edge peeking notifications (§8b): a companion reply / chat from ANOTHER space, coalesced one
/// card per space. Click → surface that space's chat as a live tile here and zoom in (no space
/// switch); ✕ dismisses. Stays until acknowledged.
struct ShellNotificationRail: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState

    var body: some View {
        // Pin to the top-left with Spacers — a greedy `.frame(maxWidth/Height: .infinity)` here would
        // capture input across the WHOLE desktop and block tile focus / galaxy zoom. Spacers don't
        // hit-test, so only the cards themselves are interactive.
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(shell.notifications) { n in card(n) }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12).padding(.top, 60)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: shell.notifications)
    }

    private func card(_ n: ShellState.ShellNotification) -> some View {
        let col = ShellDock.avatarColor(n.companionName ?? n.spaceId)
        return HStack(spacing: 8) {
            Circle().fill(col.gradient).frame(width: 26, height: 26)
                .overlay(Group {
                    if n.portId != nil { Image(systemName: "square.stack.3d.up").font(.system(size: 11)).foregroundStyle(.white) }
                    else { Text(String((n.companionName ?? n.spaceName).prefix(1)).uppercased()).font(Port42Theme.monoBold(11)).foregroundStyle(.white) }
                })
            VStack(alignment: .leading, spacing: 1) {
                Text(n.portTitle ?? n.companionName ?? n.spaceName).font(Port42Theme.monoBold(11)).foregroundStyle(Port42Theme.textPrimary).lineLimit(1)
                Text(n.portId != nil ? "port · \(n.spaceName)" : "\(n.count) new · \(n.spaceName)")
                    .font(Port42Theme.mono(8)).foregroundStyle(Port42Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { shell.acknowledgeNotification(n) } label: {
                Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 8).frame(width: 210)
        .background(Port42Theme.shellCard, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(shell.accent.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, x: 4, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture { shell.openNotification(n) }        // click → surface + zoom in
        .transition(.move(edge: .leading).combined(with: .opacity))
    }
}

struct ShellParkRail: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    let area: CGSize

    /// Ports put away in the rail. Only `parked` now — there's no in-shell floating; a tile that isn't
    /// parked is on the desktop. One click docks a parked port back to a tile.
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
        let floating = p.presentation == "floating"
        return Button {
            if floating { appState.portWindows.dockToTile(id: p.id) } else { appState.portWindows.unpark(id: p.id) }
            shell.arrangeBump += 1
        } label: {
            VStack(spacing: 4) {
                Image(systemName: floating ? "macwindow" : "square.on.square").font(.system(size: 13)).foregroundStyle(shell.accent)
                Text(p.title.prefix(6)).font(Port42Theme.mono(8)).foregroundStyle(Port42Theme.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(shell.accent.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain).help(floating ? "Dock \(p.title) back to a tile" : "Restore \(p.title)")
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
            ShellBrowserTile(webView: wv, accent: shell.accent, initialURL: panel.html)   // address bar + page
        } else if let panel = tile.panel, let v = appState.portWindows.hostView(for: panel.id) {
            ShellPortHost(view: v, bridge: panel.bridge)      // web OR terminal — one host
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
    @State private var urlText: String

    init(webView: WKWebView, accent: Color, initialURL: String) {
        self.webView = webView
        self.accent = accent
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
            .padding(.horizontal, 10).frame(height: 34)
            .background(Port42Theme.shellCard)
            .overlay(Rectangle().fill(accent.opacity(0.15)).frame(height: 1), alignment: .bottom)
            ShellPortHost(view: webView)
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
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Don't reclaim the view if it moved to another container (tile/focus/rail reparenting).
    }
}

// MARK: - Focus content (the immersive single port; same webview, re-parented)

struct ShellFocusContent: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    let id: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
                .onTapGesture { withAnimation(.spring(response: 0.4)) { shell.zoom = .space } }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let dm = dmCompanion {                         // DM → show the partner, not a generic dot
                        Circle().fill(ShellDock.avatarColor(dm.id).gradient).frame(width: 18, height: 18)
                            .overlay(Text(String(dm.displayName.prefix(1)).uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                    } else {
                        Circle().fill(shell.accent).frame(width: 8, height: 8)
                    }
                    Text(title).font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                    Text(dmCompanion != nil ? "· DM" : "· focus").font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                    Spacer()
                    Button { withAnimation(.spring(response: 0.4)) { shell.zoom = .space } } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11)).foregroundStyle(Port42Theme.textSecondary)
                    }.buttonStyle(.plain).help("Exit focus (Esc)")
                }.padding(.horizontal, 16).padding(.vertical, 11).background(Port42Theme.shellCard)
                body(for: id)
            }
            .frame(width: NSScreen.main.map { $0.frame.width * 0.78 } ?? 1100,
                   height: NSScreen.main.map { $0.frame.height * 0.8 } ?? 700)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(shell.accent.opacity(0.5), lineWidth: 1))
            .shadow(color: shell.accent.opacity(0.4), radius: 50)
        }
    }

    private var panel: PortPanel? { appState.portWindows.panels.first { $0.id == id } }
    /// The DM partner when focusing a chat that belongs to a 2-member `direct` space (else nil).
    /// Derived from the TILE's own space, so it works for a DM surfaced over a non-direct desktop.
    private var dmCompanion: AgentConfig? {
        guard panel?.isChatPort == true, let sid = panel?.spaceId else { return nil }
        let isDirect = shell.openDMSpaceIds.contains(sid)
            || (sid == appState.currentSpace?.id && appState.currentSpace?.type == "direct")
        guard isDirect else { return nil }
        return appState.companions(forSpace: sid).first
    }
    private var title: String { dmCompanion?.displayName ?? panel?.title ?? "port" }

    @ViewBuilder
    private func body(for id: String) -> some View {
        if panel?.isChatPort == true {
            ZStack(alignment: .top) {                                    // same member strip as the tile
                ChatView(spaceId: panel?.spaceId).environmentObject(appState).padding(.top, 26)
                ShellMemberRow(shell: shell, appState: appState, accent: shell.accent, spaceId: panel?.spaceId)
            }
        } else if let p = panel, let v = appState.portWindows.hostView(for: p.id) {
            ShellPortHost(view: v, bridge: p.bridge)
        } else {
            Color.black
        }
    }
}

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
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 40)
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
    private var addCompanionButton: some View {
        Button { shell.showNewCompanion = true } label: {
            Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 4])).foregroundStyle(shell.accent.opacity(0.6))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "plus").font(.system(size: 15, weight: .light)).foregroundStyle(shell.accent))
                .contentShape(Circle())          // whole disc is the tap target, not just the glyph
        }.buttonStyle(.plain).help("New companion in this space")
    }

    private func portButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(shell.accent)
                .frame(width: 46, height: 46).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(shell.accent.opacity(0.3), lineWidth: 1))
        }.buttonStyle(.plain).help(label)
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
        guard let sid = appState.currentSpace?.id else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        _ = appState.spawnNativeTerminalPort(command: "/bin/zsh", cwd: home, spaceId: sid,
                                             title: "terminal", companionName: "terminal",
                                             postCard: false, startupCommandOverride: "")
        shell.arrangeBump += 1
    }

    /// Dock "Browser" → an embedded WebKit browser tile (address bar + real navigation) at a start page.
    private func spawnBrowser() {
        guard let sid = appState.currentSpace?.id else { return }
        _ = appState.portWindows.addTiledBrowserPanel(url: "https://duckduckgo.com", spaceId: sid,
                                                      createdBy: nil, title: "browser")
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
            if hot { Image(systemName: "bubble.left").font(.system(size: 9)).foregroundStyle(accent) }   // → DM hint
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
