import SwiftUI
import AppKit
import WebKit

/// SHELL — S2.1. The shell root: the living ambient surface (Layer 0) with the real space desktop
/// composited over it, and the zoom spine made visible (galaxy ↔ space ↔ focus). Selected instead
/// of `ContentView` when `PORT42_SHELL` is on (see `TransitionRoot`).
///
/// This first cut makes the spine *demoable on the existing surface*: `ContentView` is the space
/// desktop, a galaxy overlay zooms out to all spaces (hover-dive / click to enter), and the ladder
/// is driven by ⌘↑/↓, trackpad pinch, ⌘1…N, and Esc (peel one rung). Per-port tiles + true
/// focus-immersion land in the next S2 step (the tiled desktop).
public struct ShellView: View {
    @ObservedObject private var appState: AppState
    @StateObject private var shell: ShellState

    public init(appState: AppState) {
        self.appState = appState
        _shell = StateObject(wrappedValue: ShellState(appState: appState))
    }

    @State private var monitors: [Any] = []

    private var galaxyShown: Bool { shell.zoom == .galaxy }
    private var focusShown: Bool { if case .focus = shell.zoom { return true } else { return false } }

    /// Chrome sits flush at the very top edge (topInset 0). A center notch, if any, overlaps only
    /// the Chrome's empty middle (mark is left, actions are right), so nothing important is clipped.
    private var topInset: CGFloat { 0 }

    public var body: some View {
        ZStack {
            // Layer 0 — the signed-in ambient background (prototype's Canvas dreamscape). The video
            // dreamscape is the SCREENSAVER, shown only signed-out/locked (TransitionRoot).
            ShellBackground(shell: shell)
                .ignoresSafeArea()

            // Layer 2 — the desktop GROUP (Chrome + tiles + dock). Stays mounted across rungs; it
            // recedes (scale + dim) behind the galaxy rather than being torn down. Structure mirrors
            // the prototype: tiles live in their own ZStack (in ShellDesktopView) and the overlays
            // below are translucent .zIndex siblings — SwiftUI composites them above the tiles.
            ZStack {
                VStack(spacing: 0) {
                    ShellChrome(shell: shell, appState: appState)
                    ShellDesktopView(shell: shell, appState: appState)
                }
                VStack { Spacer(); ShellDock(shell: shell, appState: appState).padding(.bottom, 24) }
            }
            .padding(.top, topInset)                                   // clear the notch / top edge
            .scaleEffect(galaxyShown ? 0.94 : 1.0, anchor: .center)
            .opacity(galaxyShown ? 0.5 : 1.0)
            .allowsHitTesting(shell.zoom == .space)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: shell.zoom)

            // Click-shield: a hit-capturing sibling ABOVE the desktop (outside its allowsHitTesting
            // group) whenever we're not in the space. SwiftUI's allowsHitTesting doesn't stop the
            // embedded chat WKWebView from getting AppKit clicks; this real layer does.
            if shell.zoom != .space {
                Color.black.opacity(0.001).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { }
                    .zIndex(50)
            }

            // Galaxy — all spaces as worlds (zoom UP). Translucent, so the desktop dims behind it.
            if galaxyShown {
                ShellGalaxyView(shell: shell, appState: appState)
                    .transition(.opacity)
                    .zIndex(110)
            }

            // Focus — one port immersive; its tile shows a placeholder while the webview is
            // re-parented up here (no reload). Translucent overlay above the desktop.
            if case .focus(let id) = shell.zoom {
                ShellFocusContent(shell: shell, appState: appState, id: id)
                    .transition(.opacity)
                    .zIndex(120)
            }

            // Settings box (long-press a world / companion) — rename, accent, delete. Top layer.
            // It self-animates in/out (save pops, discard shrinks), so no view-level transition.
            if shell.settingsTarget != nil {
                ShellSettingsView(shell: shell, appState: appState).zIndex(200)
            }

            // New Companion — a shell-native card (creates a real companion in THIS space).
            if shell.showNewCompanion {
                ShellNewCompanionView(shell: shell, appState: appState).zIndex(210)
            }
        }
        .ignoresSafeArea()                                            // edge-to-edge: fill the screen
        .animation(.spring(response: 0.4), value: shell.zoom)
        .onChange(of: shell.zoom) { _, z in if z != .space { shell.exposeActive = false } }   // exposé lives at .space
        .onAppear {
            installInputMonitors()
            applyTakeoverToWindow()
            // ShellView mounts fresh when you surface from the lock screen (TransitionRoot swaps
            // LockScreenView → ShellView on unlock), so land in the galaxy — "open water" — and swim
            // DOWN into a space from there, rather than snapping to the last space.
            shell.zoom = .galaxy
        }
        .onDisappear { removeInputMonitors() }
    }

    /// Apply the borderless-fullscreen takeover when the shell UI actually appears — the reliable
    /// site (the window exists by now, unlike `applicationDidFinishLaunching`, and this doesn't
    /// depend on which unlock/dive path ran). A few retries cover any first-frame timing.
    private func applyTakeoverToWindow() {
        guard ShellMode.isEnabled() else { return }
        for attempt in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 0.2) {
                guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey }) else { return }
                ShellMode.applyTakeover(to: window)
            }
        }
    }

    // MARK: - Input (kiosk monitors → the zoom ladder)

    private func installInputMonitors() {
        guard monitors.isEmpty else { return }

        // Trackpad pinch — one rung per gesture (the latch lives in ShellState).
        let magnify = NSEvent.addLocalMonitorForEvents(matching: .magnify) { e in
            shell.pinch(delta: e.magnification, began: e.phase == .began)
            return nil   // consume so webviews don't also zoom
        }

        // Cursor position → the ambient background parallax (don't consume; hover etc. still work).
        let move = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { e in
            if let cv = e.window?.contentView, cv.bounds.width > 0, cv.bounds.height > 0 {
                let lp = e.locationInWindow
                shell.mouse = CGPoint(x: lp.x / cv.bounds.width, y: 1 - lp.y / cv.bounds.height)
            }
            return e
        }

        // Keys — ⌘↑/↓ ladder, ⌘1…N space jump, Esc peels one rung. Yields to a focused text
        // field / web port / terminal first (§3.1) so typing and TUI Esc reach the surface.
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let isEditor = Self.responderIsEditor(e.window?.firstResponder)
            if ShellState.shouldYieldKey(isEditor: isEditor, keyCode: e.keyCode,
                                         focusedPortIsTerminal: shell.focusedPortIsTerminal) {
                return e                                          // hand the key to the field/port
            }

            if e.keyCode == 48 {   // Tab — toggle exposé (a temporary arrange) at the space rung
                guard shell.zoom == .space else { return e }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { shell.exposeActive.toggle() }
                return nil
            }
            if e.keyCode == 53 {   // Esc — exit exposé first, else peel back to the desktop
                if shell.exposeActive { withAnimation(.spring(response: 0.4)) { shell.exposeActive = false }; return nil }
                guard shell.zoom != .space else { return e }
                shell.galaxyHover = nil
                withAnimation(.spring(response: 0.4)) { shell.zoom = .space }
                return nil
            }
            guard e.modifierFlags.contains(.command) else { return e }
            if e.keyCode == 126 { shell.zoomOut(); return nil }   // ⌘↑ → up toward galaxy
            if e.keyCode == 125 { shell.zoomIn();  return nil }   // ⌘↓ → down toward focus
            if let s = e.charactersIgnoringModifiers, let n = Int(s), n >= 1, n <= 9 {
                shell.jumpToSpace(index: n - 1)                   // ⌘1…9 → Nth space
                return nil
            }
            return e
        }

        monitors = [magnify, move, keys].compactMap { $0 }
    }

    private func removeInputMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }

    /// Classify the focused responder as a text field / web view / terminal that should own the
    /// keyboard, so the shell yields keys to it instead of driving the ladder (§3.1). Covers plain
    /// text editors, `WKWebView` (a web port's contenteditable/input) — including a nested content
    /// view — and the native terminal surface (Ghostty).
    static func responderIsEditor(_ responder: NSResponder?) -> Bool {
        guard let r = responder else { return false }
        if r is NSText || r is NSTextView || r is WKWebView { return true }
        let name = String(describing: type(of: r))
        if name.contains("WKWeb") || name.contains("WKContent")
            || name.contains("Ghostty") || name.contains("Terminal") || name.contains("Surface") {
            return true
        }
        if let v = r as? NSView {          // a view nested inside a WKWebView
            var s = v.superview
            while let cur = s { if cur is WKWebView { return true }; s = cur.superview }
        }
        return false
    }
}

// MARK: - Galaxy (all spaces as worlds; zoom UP)

/// The all-spaces constellation. Each space is a stylized accent-orb world (cheap `Canvas`, not a
/// live preview) with its name + port count. Hovering arms `galaxyHover` (so ⌘↓ / pinch-in dives
/// into it); clicking enters it.
struct ShellGalaxyView: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState

    @State private var newSpaceHovered = false

    var body: some View {
        ZStack {
            // Modal scrim: captures clicks so the galaxy is its own interactive layer (a click between
            // cards can't fall through to the desktop/chat). Empty clicks do nothing — you leave the
            // galaxy by picking a world, ⌘↓/pinch-in, or the ✨ toggle.
            Color.black.opacity(0.55).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { }
            GeometryReader { geo in
                let avail = geo.size.width * 0.82
                let cols = max(1, min(3, Int(avail / 320)))
                let columns = Array(repeating: GridItem(.flexible(minimum: 200, maximum: 290), spacing: 22), count: cols)
                VStack(spacing: 20) {
                    Text("PORT42 · SPACES").font(Port42Theme.monoBold(13)).foregroundStyle(Port42Theme.textPrimary).tracking(5)
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(Array(appState.spaces.enumerated()), id: \.element.id) { index, space in
                                world(space, index: index)
                            }
                            newSpaceCard   // spaces are created here in the galaxy, not the Chrome
                        }
                        .frame(maxWidth: avail)
                        // Center the worlds in the viewport (scrolls only when they overflow it).
                        .frame(maxWidth: .infinity, minHeight: max(0, geo.size.height - 150), alignment: .center)
                        .padding(.vertical, 6)
                    }
                    Text("hover + ⌘↓ / pinch-in to dive in · ⌘1…9 jump · ⌘↑ / pinch-out to zoom")
                        .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .padding(.vertical, 30)
            }
        }
        .onAppear { shell.galaxyHover = nil }   // no phantom world lit on entry (hover starts fresh)
    }

    /// The galaxy's "new space" affordance — a ghost world-card. Creating a space is a galaxy action
    /// (not a Chrome button): make it + swim straight down into it.
    private var newSpaceCard: some View {
        Button {
            appState.createSpace(name: "space \(appState.spaces.count + 1)")   // createSpace selects the new space
            withAnimation(.spring(response: 0.45)) { shell.zoom = .space }      // dive into it
        } label: {
            let hi = newSpaceHovered
            let acc = shell.accent
            VStack(spacing: 13) {
                // A nascent world: a faint accent orb that lights up on hover, like the real worlds.
                ZStack {
                    Circle().fill(RadialGradient(
                        gradient: Gradient(colors: [acc.opacity(hi ? 0.45 : 0.16), acc.opacity(0.02), .clear]),
                        center: .center, startRadius: 0, endRadius: 62))
                    Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 7]))
                        .foregroundStyle(acc.opacity(hi ? 0.85 : 0.35))
                    Image(systemName: "plus").font(.system(size: 34, weight: .ultraLight))
                        .foregroundStyle(acc.opacity(hi ? 1 : 0.75))
                }
                .frame(width: 120, height: 120)
                Text("NEW SPACE").font(Port42Theme.monoBold(14)).foregroundStyle(hi ? acc : Port42Theme.textPrimary).tracking(2)
                Text("dive into open water").font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
            }
            .padding(18).frame(maxWidth: .infinity)
            .background((hi ? acc.opacity(0.10) : Color.white.opacity(0.02)), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(acc.opacity(hi ? 0.7 : 0.15), lineWidth: hi ? 1.5 : 1))
            .shadow(color: hi ? acc.opacity(0.45) : .clear, radius: 20)
            .scaleEffect(hi ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        // Clear the world hover-highlight when moving onto this card, so the last world doesn't
        // stay lit while you're hovering "new space".
        .onHover { hovering in newSpaceHovered = hovering; if hovering { shell.galaxyHover = nil } }
        .animation(.spring(response: 0.3), value: newSpaceHovered)
    }

    /// Count exactly what the desktop renders as tiles: the space's tiled ports + its chat tile
    /// (every space has one). This is why a chat-only space reads "1 port", not 0 — the old filter
    /// excluded the chat port and so undercounted what you actually see on the desktop.
    private func portCount(_ space: Space) -> Int {
        let tiled = appState.portWindows.panels.filter {
            $0.spaceId == space.id && !$0.isBackground && $0.presentation == "tiled"
        }.count
        return tiled + 1   // + the chat tile
    }

    @ViewBuilder
    private func world(_ space: Space, index: Int) -> some View {
        let on = space.id == appState.currentSpace?.id   // the current space — a quiet, persistent marker
        let hovered = shell.galaxyHover == index          // the mouse — a loud, transient highlight
        let acc = shell.accent(for: space)          // this world's own theme
        // Not a Button: a hold opens settings and must NOT also fire the tap (which zoomed into the
        // space behind). A quick tap enters; a long-press opens settings — arbitrated below.
        Group {
            VStack(spacing: 13) {
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                        ctx.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)),
                                 with: .radialGradient(Gradient(colors: [acc.opacity(0.5), acc.opacity(0.03), .clear]),
                                                       center: c, startRadius: 0, endRadius: size.width / 2))
                        let r = size.width * 0.26 + sin(t * 1.4 + Double(index)) * 4
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                 with: .color(acc.opacity(0.9)))
                        let n = max(portCount(space), 1)
                        for s in 0..<min(n, 8) {
                            let a = t * 0.6 + Double(s) / Double(n) * 6.283
                            let rr = size.width * 0.42
                            let mx = c.x + cos(a) * rr, my = c.y + sin(a) * rr * 0.46
                            ctx.fill(Path(ellipseIn: CGRect(x: mx - 3, y: my - 3, width: 6, height: 6)), with: .color(.white.opacity(0.9)))
                        }
                    }
                }.frame(width: 120, height: 120)
                Text(space.name.uppercased()).font(Port42Theme.monoBold(14)).foregroundStyle(hovered || on ? acc : Port42Theme.textPrimary).tracking(2)
                Text("\(portCount(space)) ports").font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
            }
            .padding(18).frame(maxWidth: .infinity)
            // Hover = loud (fill + bright ring + glow + lift). Current space = quiet (a solid accent
            // ring only), so it's marked without looking permanently moused-over.
            .background(hovered ? acc.opacity(0.10) : Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(
                hovered ? acc.opacity(0.75) : (on ? acc.opacity(0.45) : Color.white.opacity(0.12)),
                lineWidth: hovered ? 1.5 : 1))
            .shadow(color: hovered ? acc.opacity(0.4) : .clear, radius: 16)
            .scaleEffect(hovered ? 1.04 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20))
        // Track the mouse both ways so a world doesn't stay lit after the cursor leaves. (⌘↓/pinch-in
        // with no world hovered falls back to the current space — see ShellState.zoomIn.)
        .onHover { hovering in
            if hovering { shell.galaxyHover = index }
            else if shell.galaxyHover == index { shell.galaxyHover = nil }
        }
        .animation(.spring(response: 0.3), value: hovered)
        // Hold ≥0.45s → settings; a quick tap → enter the space. High-priority long-press wins the
        // arbitration, so the release no longer also fires the tap (which zoomed in behind the box).
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.45)
            .onEnded { _ in shell.settingsTarget = .space(space.id) })
        .onTapGesture { shell.jumpToSpace(index: index) }
    }
}

// MARK: - Settings box (long-press a world / companion)

/// A shell-styled settings overlay — rename, pick accent, delete — for the item in
/// `shell.settingsTarget`. Currently spaces; companions reuse the same box in S4. The scrim dismisses.
struct ShellSettingsView: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    @State private var name = ""
    @State private var confirmingDelete = false
    // Self-animated in/out so save and discard can exit DIFFERENTLY (save pops up, discard shrinks).
    @State private var cardScale: CGFloat = 0.92
    @State private var cardOpacity: Double = 0
    @State private var scrimOpacity: Double = 0

    private var space: Space? {
        if case .space(let id) = shell.settingsTarget { return appState.spaces.first { $0.id == id } }
        return nil
    }
    private var companion: AgentConfig? {
        if case .companion(let id) = shell.settingsTarget { return appState.companions.first { $0.id == id } }
        return nil
    }

    var body: some View {
        ZStack {
            Color.black.opacity(scrimOpacity).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { dismiss(save: true) }   // click away = accept edits
            if let space { spaceCard(space) }
            else if let companion { companionCard(companion) }
        }
        .onAppear {
            name = space?.name ?? companion?.displayName ?? ""
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { cardScale = 1; cardOpacity = 1 }
            withAnimation(.easeOut(duration: 0.2)) { scrimOpacity = 0.6 }
        }
    }

    // MARK: companion

    private func companionCard(_ c: AgentConfig) -> some View {
        let col = ShellDock.avatarColor(c.id)
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("COMPANION SETTINGS").font(Port42Theme.monoBold(12)).foregroundStyle(Port42Theme.textSecondary).tracking(3)
                Spacer()
                Button { dismiss(save: false) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
                }.buttonStyle(.plain).help("Close without saving")
            }
            HStack(spacing: 12) {
                Circle().fill(col.gradient).frame(width: 46, height: 46)
                    .overlay(Text(String(c.displayName.prefix(2)).uppercased()).font(Port42Theme.monoBold(16)).foregroundStyle(.white))
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                TextField("name", text: $name)
                    .textFieldStyle(.plain).font(Port42Theme.monoBold(16)).foregroundStyle(Port42Theme.textPrimary)
                    .onSubmit { dismiss(save: true) }.onExitCommand { dismiss(save: false) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("BRAIN").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary).tracking(2)
                Text("\(c.mode.rawValue) · \(c.model ?? "—")").font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                Text("edit model / prompt / secrets in Advanced (soon)").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            Button { dismiss(save: false) { if let s = appState.currentSpace { appState.removeCompanionFromSpace(c, space: s) } } } label: {
                HStack(spacing: 6) { Image(systemName: "rectangle.portrait.and.arrow.right"); Text("Remove from this space") }
                    .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
            }.buttonStyle(.plain)
            if confirmingDelete {
                HStack(spacing: 10) {
                    Text("Delete this companion?").font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                    Spacer()
                    Button("Cancel") { confirmingDelete = false }.buttonStyle(.plain).foregroundStyle(Port42Theme.textSecondary)
                    Button("Delete") { dismiss(save: false) { appState.deleteCompanion(c) } }.buttonStyle(.plain).foregroundStyle(.red)
                }.font(Port42Theme.mono(12))
            } else {
                Button { confirmingDelete = true } label: {
                    HStack(spacing: 6) { Image(systemName: "trash"); Text("Delete companion") }
                        .font(Port42Theme.mono(12)).foregroundStyle(Color.red.opacity(0.9))
                }.buttonStyle(.plain)
            }
        }
        .padding(22).frame(width: 340)
        .background(Color(red: 0.06, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(col.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 40)
        .scaleEffect(cardScale).opacity(cardOpacity)
    }

    // MARK: space

    private func spaceCard(_ space: Space) -> some View {
        let acc = shell.accent(for: space)
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("SPACE SETTINGS").font(Port42Theme.monoBold(12)).foregroundStyle(Port42Theme.textSecondary).tracking(3)
                Spacer()
                Button { dismiss(save: false) } label: {   // ✕ = discard the rename
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
                }.buttonStyle(.plain).help("Close without saving")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("NAME").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary).tracking(2)
                TextField("name", text: $name)
                    .textFieldStyle(.plain).font(Port42Theme.monoBold(15)).foregroundStyle(Port42Theme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(acc.opacity(0.35), lineWidth: 1))
                    .onSubmit { dismiss(save: true) }        // Return = save + close
                    .onExitCommand { dismiss(save: false) }  // Esc = discard + close
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ACCENT").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary).tracking(2)
                HStack(spacing: 9) {
                    ForEach(ShellState.paletteHex, id: \.self) { hex in
                        Button { var s = space; s.accent = hex; appState.updateSpace(s) } label: {
                            Circle().fill(Color(shellHex: hex) ?? .teal).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.white.opacity(space.accent == hex ? 0.9 : 0), lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            if confirmingDelete {
                HStack(spacing: 10) {
                    Text("Delete this space?").font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                    Spacer()
                    Button("Cancel") { confirmingDelete = false }.buttonStyle(.plain).foregroundStyle(Port42Theme.textSecondary)
                    Button("Delete") { dismiss(save: false) { appState.deleteSpace(space) } }.buttonStyle(.plain).foregroundStyle(.red)
                }.font(Port42Theme.mono(12))
            } else {
                Button { confirmingDelete = true } label: {
                    HStack(spacing: 6) { Image(systemName: "trash"); Text("Delete space") }
                        .font(Port42Theme.mono(12)).foregroundStyle(Color.red.opacity(0.9))
                }.buttonStyle(.plain)
            }
        }
        .padding(22).frame(width: 340)
        .background(Color(red: 0.06, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(acc.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 40)
        .scaleEffect(cardScale).opacity(cardOpacity)
    }

    /// Close the box. `save` commits a pending rename and the card POPS up + fades (a confirming
    /// beat); discard SHRINKS + fades (a dismissive beat). `then` runs a delete/remove in the same
    /// discard motion, just before the target clears.
    private func dismiss(save: Bool, then action: (() -> Void)? = nil) {
        if save { commitName() }
        withAnimation(save ? .spring(response: 0.3, dampingFraction: 0.6) : .easeIn(duration: 0.18)) {
            cardScale = save ? 1.12 : 0.86
            cardOpacity = 0
            scrimOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (save ? 0.28 : 0.2)) {
            action?()
            shell.settingsTarget = nil
        }
    }

    /// Commit a pending rename for whichever target is open. Spaces normalize (lowercase-dashes);
    /// companions keep free-form display names.
    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if let s = space {
            let cleaned = n.lowercased().replacingOccurrences(of: " ", with: "-")
            if cleaned != s.name { var x = s; x.name = cleaned; appState.updateSpace(x) }
        } else if var c = companion {
            if n != c.displayName { c.displayName = n; appState.updateCompanion(c) }
        }
    }
}

// MARK: - New companion (shell-native card)

/// A shell-native create-companion card (replaces the macOS sheet): name → a real LLM companion,
/// created AND joined to the current space. Existing roster companions not here can be added with a
/// tap. Self-animated in/out like the settings box; advanced config lives in companion settings later.
struct ShellNewCompanionView: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    @State private var name = ""
    @State private var selectedType: CompanionTypePreset?      // one tap → identity + constitution
    @State private var showAdvanced = false                    // → the full form (all modes/options)
    @State private var cardScale: CGFloat = 0.92
    @State private var cardOpacity: Double = 0
    @State private var scrimOpacity: Double = 0
    @FocusState private var nameFocused: Bool

    private var acc: Color { shell.accent }
    /// Creatable once there's an identity — either a typed name or a picked type (which names it).
    private var canCreate: Bool {
        (!name.trimmingCharacters(in: .whitespaces).isEmpty || selectedType != nil) && appState.currentUser != nil
    }
    /// Icon per type (mirrors the mockup): ✦ echo · ▲ architect · ⚙ compiler · ◈ operator.
    private func typeIcon(_ t: CompanionTypePreset) -> String {
        switch t { case .echo: return "sparkles"; case .architect: return "triangle"
                   case .compiler: return "gearshape"; case .operatorType: return "diamond" }
    }
    private var rosterNotHere: [AgentConfig] {
        let here = Set(appState.spaceCompanions.map(\.id))
        return appState.companions.filter { !here.contains($0.id) }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(scrimOpacity).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { dismiss() }
            if showAdvanced {
                // The full form (every mode + option), re-hosted in a shell card. Opt-in only.
                NewCompanionSheet(isPresented: $shell.showNewCompanion)
                    .environmentObject(appState)
                    .frame(width: 500, height: 600)
                    .background(Color(red: 0.06, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(acc.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 40)
                    .scaleEffect(cardScale).opacity(cardOpacity)
            } else {
                card
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { cardScale = 1; cardOpacity = 1 }
            withAnimation(.easeOut(duration: 0.2)) { scrimOpacity = 0.6 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { nameFocused = true }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("NEW COMPANION").font(Port42Theme.monoBold(12)).foregroundStyle(Port42Theme.textSecondary).tracking(3)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
                }.buttonStyle(.plain)
            }
            // Preview PFP + name
            HStack(spacing: 12) {
                Circle().fill(acc.gradient).frame(width: 46, height: 46)
                    .overlay(Text(initials).font(Port42Theme.monoBold(16)).foregroundStyle(.white))
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                TextField("name your companion", text: $name)
                    .textFieldStyle(.plain).font(Port42Theme.monoBold(16)).foregroundStyle(Port42Theme.textPrimary)
                    .focused($nameFocused)
                    .onSubmit { create() }
                    .onExitCommand { dismiss() }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(acc.opacity(0.35), lineWidth: 1))

            // TYPE — one tap sets the constitution (system prompt) + KB scope + a default name.
            VStack(alignment: .leading, spacing: 8) {
                Text("TYPE — one tap sets identity + prompt").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary).tracking(2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(CompanionTypePreset.allCases, id: \.rawValue) { t in
                        let on = selectedType == t
                        Button { selectedType = on ? nil : t } label: {
                            HStack(spacing: 6) {
                                Image(systemName: typeIcon(t)).font(.system(size: 10))
                                Text(t.displayName).font(Port42Theme.mono(11))
                            }
                            .foregroundStyle(on ? acc : Port42Theme.textPrimary)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background((on ? acc.opacity(0.12) : Color.white.opacity(0.04)), in: Capsule())
                            .overlay(Capsule().stroke(on ? acc.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1))
                        }.buttonStyle(.plain).help(t.label)
                    }
                }
            }

            HStack(spacing: 10) {
                Button { create() } label: {
                    Text("Create companion").font(Port42Theme.monoBold(13)).foregroundStyle(canCreate ? .black : Port42Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(canCreate ? acc : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(!canCreate)
                // Everything else — modes (API/Command), provider/model, secrets, pods, CLI presets…
                Button { withAnimation(.spring(response: 0.3)) { showAdvanced = true } } label: {
                    Text("Advanced…").font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.14), lineWidth: 1))
                }.buttonStyle(.plain).help("All options — modes, provider/model, secrets, pods")
            }

            if !rosterNotHere.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("OR ADD EXISTING").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary).tracking(2)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(rosterNotHere) { c in
                            Button { addExisting(c) } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(ShellDock.avatarColor(c.id).gradient).frame(width: 18, height: 18)
                                    Text(c.displayName).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary).lineLimit(1)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(Color.white.opacity(0.05), in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(22).frame(width: 380)
        .background(Color(red: 0.06, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(acc.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 40)
        .scaleEffect(cardScale).opacity(cardOpacity)
    }

    /// The effective name: what's typed, else the picked type's name.
    private var effectiveName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? (selectedType?.displayName ?? "") : n
    }
    private var initials: String {
        let n = effectiveName
        return n.isEmpty ? "?" : String(n.prefix(2)).uppercased()
    }

    private func create() {
        guard canCreate, let user = appState.currentUser else { return }
        let nm = effectiveName
        // A picked type brings a real constitution (system prompt) + KB scope; otherwise a plain prompt.
        let prompt = selectedType.map(loadConstitution) ?? """
            You are \(nm), a companion in Port42 — a personal system where humans and AI companions \
            coexist in spaces. You are \(nm). Not an assistant, a companion. Keep replies concise and \
            conversational; lowercase unless emphasis matters.
            """
        var c = AgentConfig.createLLM(ownerId: user.id, displayName: nm, systemPrompt: prompt,
                                      provider: .anthropic, model: "claude-opus-4-6", trigger: .mentionOnly)
        c.scopePath = selectedType?.defaultKBPath
        appState.addCompanion(c)                                              // roster
        if let s = appState.currentSpace { appState.addCompanionToSpace(c, space: s) }   // join THIS space
        dismiss()
    }

    /// Load a type's constitution (system prompt) from the bundle — same source as the old sheet.
    private func loadConstitution(_ t: CompanionTypePreset) -> String {
        guard let url = Bundle.module.url(forResource: t.constitutionFile, withExtension: "md", subdirectory: "constitutions"),
              let text = try? String(contentsOf: url) else {
            return "You are \(t.displayName), a companion in Port42. \(t.label)."
        }
        return text
    }

    private func addExisting(_ c: AgentConfig) {
        if let s = appState.currentSpace { appState.addCompanionToSpace(c, space: s) }
        dismiss()
    }

    private func dismiss() {
        withAnimation(.easeIn(duration: 0.18)) { cardScale = 0.9; cardOpacity = 0; scrimOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { shell.showNewCompanion = false }
    }
}
