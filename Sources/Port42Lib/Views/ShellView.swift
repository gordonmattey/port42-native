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

            // Global Settings — the app's SignOutSheet surfaced as a shell overlay (whole menu brought
            // across; sections to be revisited for the shell over time).
            if shell.showSettings {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea().contentShape(Rectangle())
                        .onTapGesture { shell.showSettings = false }
                    SignOutSheet(isPresented: $shell.showSettings, accent: shell.accent)
                        .environmentObject(appState)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(shell.accent.opacity(0.4), lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 40)
                }.zIndex(220)
            }

            // Token Usage — the app's UsageSheet as a shell overlay.
            if shell.showUsage {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea().contentShape(Rectangle())
                        .onTapGesture { shell.showUsage = false }
                    UsageSheet(isPresented: $shell.showUsage, accent: shell.accent)
                        .environmentObject(appState)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(shell.accent.opacity(0.4), lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 40)
                }.zIndex(220)
            }
        }
        .ignoresSafeArea()                                            // edge-to-edge: fill the screen
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { _ in
            shell.showSettings = true
        }
        .animation(.spring(response: 0.4), value: shell.zoom)
        .onChange(of: shell.zoom) { _, z in if z != .space { shell.exposeActive = false } }   // exposé lives at .space
        .onAppear {
            installInputMonitors()
            applyTakeoverToWindow()
            // On unlock (TransitionRoot swaps LockScreenView → ShellView) land in the LAST space —
            // `AppState.unlock()` has already restored it as currentSpace. Galaxy only if there's no
            // space yet (fresh setup).
            shell.zoom = appState.currentSpace != nil ? .space : .galaxy
        }
        .onDisappear { removeInputMonitors() }
    }

    /// Set up the shell window when the UI appears — the reliable site (the window exists by now,
    /// unlike `applicationDidFinishLaunching`, and it's independent of which unlock/dive path ran).
    /// Routes through the one authoritative helper (takeover or windowed). Retries cover first-frame timing.
    private func applyTakeoverToWindow() {
        guard ShellMode.isEnabled() else { return }
        for attempt in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 0.2) {
                guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey }) else { return }
                ShellMode.applyShellWindow(to: window)
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
    @State private var promptDraft = ""            // companion system prompt (committed on save)
    @State private var selectedSecrets: Set<String> = []   // Keychain secrets granted to this companion
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
            promptDraft = companion?.systemPrompt ?? ""
            selectedSecrets = Set(companion?.secretNames ?? [])
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { cardScale = 1; cardOpacity = 1 }
            withAnimation(.easeOut(duration: 0.2)) { scrimOpacity = 0.6 }
        }
    }

    // MARK: companion

    /// Apply a mutation to the companion and persist immediately (discrete controls). The prompt
    /// commits on save instead (it's a text editor). `updateCompanion` refreshes both lists.
    private func edit(_ c: AgentConfig, _ mutate: (inout AgentConfig) -> Void) {
        var x = c; mutate(&x); appState.updateCompanion(x)
    }

    private func companionCard(_ c: AgentConfig) -> some View {
        let col = ShellDock.avatarColor(c.id)
        return ScrollView(showsIndicators: false) {
          VStack(alignment: .leading, spacing: 16) {
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

            fieldLabel("MODE")
            segmented(["llm", "command", "remote"], selected: c.mode.rawValue) { v in
                edit(c) { $0.mode = AgentMode(rawValue: v) ?? .llm }
            }

            if c.mode == .llm {
                fieldLabel("TRIGGER")
                segmented(["mention-only", "all messages"], selected: c.trigger == .allMessages ? "all messages" : "mention-only") { v in
                    edit(c) { $0.trigger = v == "all messages" ? .allMessages : .mentionOnly }
                }
                fieldLabel("PROVIDER")
                segmented(["anthropic", "gemini", "compatible"], selected: (c.provider ?? .anthropic).rawValue) { v in
                    edit(c) { $0.provider = provider(from: v) }
                }
                fieldLabel("MODEL")
                TextField("model id", text: Binding(get: { c.model ?? "" }, set: { m in edit(c) { $0.model = m.isEmpty ? nil : m } }))
                    .textFieldStyle(.plain).font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(col.opacity(0.3), lineWidth: 1))
                HStack {
                    fieldLabel("THINKING").fixedSize()
                    Spacer()
                    Toggle("", isOn: Binding(get: { c.thinkingEnabled }, set: { on in edit(c) { $0.thinkingEnabled = on } }))
                        .labelsHidden().toggleStyle(.switch).tint(col)
                }
                if c.thinkingEnabled {
                    segmented(["low", "medium", "high"], selected: c.thinkingEffort) { v in edit(c) { $0.thinkingEffort = v } }
                }
                fieldLabel("SYSTEM PROMPT")
                TextEditor(text: $promptDraft)
                    .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary).scrollContentBackground(.hidden)
                    .frame(height: 96).padding(8)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(col.opacity(0.3), lineWidth: 1))
            } else {
                Text("\(c.mode.rawValue) config — command / connection editing lands in Advanced (soon)")
                    .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
            }

            fieldLabel("SECRETS")
            ShellSecretsField(selected: Binding(
                get: { selectedSecrets },
                set: { v in selectedSecrets = v; edit(c) { $0.secretNames = v.isEmpty ? nil : v.sorted() } }
            ), accent: col)

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
          .padding(22)
        }
        .frame(width: 360, height: 560)
        .background(Port42Theme.shellCard, in: RoundedRectangle(cornerRadius: 16))
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
        .background(Port42Theme.shellCard, in: RoundedRectangle(cornerRadius: 16))
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

    /// Commit pending text edits for whichever target is open — a space rename (normalized to
    /// lowercase-dashes), or a companion's name + system prompt (free-form). Discrete companion
    /// controls (mode/provider/model/thinking) already persisted on change.
    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = space {
            guard !n.isEmpty else { return }
            let cleaned = n.lowercased().replacingOccurrences(of: " ", with: "-")
            if cleaned != s.name { var x = s; x.name = cleaned; appState.updateSpace(x) }
        } else if var c = companion {
            var changed = false
            if !n.isEmpty, n != c.displayName { c.displayName = n; changed = true }
            if promptDraft != (c.systemPrompt ?? "") { c.systemPrompt = promptDraft.isEmpty ? nil : promptDraft; changed = true }
            if changed { appState.updateCompanion(c) }
        }
    }

    // MARK: small controls

    private func fieldLabel(_ s: String) -> some View {
        Text(s).font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary).tracking(2)
    }

    private func segmented(_ options: [String], selected: String, _ onTap: @escaping (String) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { o in
                let on = o == selected
                Button { onTap(o) } label: {
                    Text(o).font(Port42Theme.mono(10)).foregroundStyle(on ? shell.accent : Port42Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(on ? shell.accent.opacity(0.15) : Color.clear)
                }.buttonStyle(.plain)
            }
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func provider(from v: String) -> AgentProvider {
        switch v { case "gemini": return .gemini; case "compatible": return .compatibleEndpoint; default: return .anthropic }
    }
}

// MARK: - New companion (shell-native card — quick + full "Advanced" inline)

/// The shell-native create-companion card. Default: name + type → a real companion in this space.
/// "Advanced" expands the SAME card (no macOS sheet) to the full option set — mode (LLM/API/Command),
/// provider/model/base-URL, thinking, system prompt, scope, secrets, command config, trigger.
struct ShellNewCompanionView: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    @State private var name = ""
    @State private var selectedType: CompanionTypePreset?
    @State private var showAdvanced = false
    // Advanced fields:
    private enum NMode: String, CaseIterable { case llm, api, command }
    @State private var mode: NMode = .llm
    @State private var providerSel = "anthropic"      // llm: anthropic | gemini
    @State private var model = "claude-opus-4-6"
    @State private var baseURL = ""                   // api mode
    @State private var thinkingOn = false
    @State private var thinkingEffort = "low"
    @State private var promptOverride = ""            // empty → type constitution / default
    @State private var scopePath = ""
    @State private var selectedSecrets: Set<String> = []
    @State private var command = ""
    @State private var argsText = ""
    @State private var workingDir = ""
    @State private var cliChoice = "claude"          // claude | gemini | codex | custom
    @State private var triggerSel = "mention-only"
    // anim
    @State private var cardScale: CGFloat = 0.92
    @State private var cardOpacity: Double = 0
    @State private var scrimOpacity: Double = 0
    @FocusState private var nameFocused: Bool

    private var acc: Color { shell.accent }
    private var canCreate: Bool {
        guard appState.currentUser != nil, !effectiveName.isEmpty else { return false }
        // CLI presets (claude/gemini/codex) carry their own command; only "custom" needs the field.
        if mode == .command { return cliChoice != "custom" || !command.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }
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
            ScrollView(showsIndicators: false) { card.padding(22) }
                .frame(width: 400, height: showAdvanced ? 620 : nil)
                .fixedSize(horizontal: false, vertical: !showAdvanced)
                .background(Port42Theme.shellCard, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(acc.opacity(0.4), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 40)
                .scaleEffect(cardScale).opacity(cardOpacity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { cardScale = 1; cardOpacity = 1 }
            withAnimation(.easeOut(duration: 0.2)) { scrimOpacity = 0.6 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { nameFocused = true }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("NEW COMPANION").font(Port42Theme.monoBold(12)).foregroundStyle(Port42Theme.textSecondary).tracking(3)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
                }.buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                Circle().fill(acc.gradient).frame(width: 46, height: 46)
                    .overlay(Text(initials).font(Port42Theme.monoBold(16)).foregroundStyle(.white))
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                TextField("name your companion", text: $name)
                    .textFieldStyle(.plain).font(Port42Theme.monoBold(16)).foregroundStyle(Port42Theme.textPrimary)
                    .focused($nameFocused).onSubmit { create() }.onExitCommand { dismiss() }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(acc.opacity(0.35), lineWidth: 1))

            if mode != .command {
                label("TYPE — one tap sets identity + prompt")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(CompanionTypePreset.allCases, id: \.rawValue) { t in
                        let on = selectedType == t
                        Button { selectedType = on ? nil : t } label: {
                            HStack(spacing: 6) { Image(systemName: typeIcon(t)).font(.system(size: 10)); Text(t.displayName).font(Port42Theme.mono(11)) }
                                .foregroundStyle(on ? acc : Port42Theme.textPrimary)
                                .padding(.horizontal, 11).padding(.vertical, 7)
                                .background((on ? acc.opacity(0.12) : Color.white.opacity(0.04)), in: Capsule())
                                .overlay(Capsule().stroke(on ? acc.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1))
                        }.buttonStyle(.plain).help(t.label)
                    }
                }
            }

            if showAdvanced { advancedFields }

            HStack(spacing: 10) {
                Button { create() } label: {
                    Text("Create companion").font(Port42Theme.monoBold(13)).foregroundStyle(canCreate ? .black : Port42Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(canCreate ? acc : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(!canCreate)
                Button { withAnimation(.spring(response: 0.3)) { showAdvanced.toggle() } } label: {
                    HStack(spacing: 4) { Text("Advanced"); Image(systemName: showAdvanced ? "chevron.up" : "chevron.down").font(.system(size: 8)) }
                        .font(Port42Theme.mono(11)).foregroundStyle(showAdvanced ? acc : Port42Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke((showAdvanced ? acc : Color.white).opacity(0.2), lineWidth: 1))
                }.buttonStyle(.plain)
            }

            if !rosterNotHere.isEmpty {
                label("OR ADD EXISTING")
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

    @ViewBuilder private var advancedFields: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
        label("MODE")
        seg(["llm", "api", "command"], sel: mode.rawValue) { mode = NMode(rawValue: $0) ?? .llm }
        label("TRIGGER")
        seg(["mention-only", "all messages"], sel: triggerSel) { triggerSel = $0 }

        switch mode {
        case .llm:
            label("PROVIDER");  seg(["anthropic", "gemini"], sel: providerSel) { providerSel = $0 }
            label("MODEL");     boxField("model id", $model)
            thinkingRow
            label("SYSTEM PROMPT (overrides type)"); promptBox
            label("KNOWLEDGE-BASE SCOPE"); boxField("scopes/…", $scopePath)
        case .api:
            label("BASE URL");  boxField("https://…/v1", $baseURL)
            label("MODEL");     boxField("model id", $model)
            label("SYSTEM PROMPT"); promptBox
        case .command:
            // Two kinds of command companion: a CLI LLM (claude/gemini/codex) that lives in a
            // terminal tile, or a straight custom command that runs headless (NDJSON) — no terminal.
            label("CLI")
            seg(["claude", "gemini", "codex", "custom"], sel: cliChoice) { cliChoice = $0 }
            if cliChoice == "custom" {
                label("COMMAND");   boxField("my-cli", $command)
                label("ARGS");      boxField("--flag value", $argsText)
                Text("runs headless (NDJSON) — no terminal").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
            } else {
                Text("opens in a terminal tile").font(Port42Theme.mono(9)).foregroundStyle(acc.opacity(0.8))
            }
            label("WORKING DIR (blank = space cwd)"); boxField("~/project", $workingDir)
            label("SYSTEM PROMPT"); promptBox
        }
        // Secrets apply to any mode (rest.call / provider keys) — create + grant inline.
        label("SECRETS"); ShellSecretsField(selected: $selectedSecrets, accent: acc)
    }

    private var thinkingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { label("THINKING"); Spacer(); Toggle("", isOn: $thinkingOn).labelsHidden().toggleStyle(.switch).tint(acc) }
            if thinkingOn { seg(["low", "medium", "high"], sel: thinkingEffort) { thinkingEffort = $0 } }
        }
    }
    private var promptBox: some View {
        TextEditor(text: $promptOverride).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary).scrollContentBackground(.hidden)
            .frame(height: 84).padding(8)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(acc.opacity(0.3), lineWidth: 1))
    }
    private func boxField(_ ph: String, _ text: Binding<String>) -> some View {
        TextField(ph, text: text).textFieldStyle(.plain).font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(acc.opacity(0.3), lineWidth: 1))
    }
    private func label(_ s: String) -> some View {
        Text(s).font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary).tracking(2)
    }
    private func seg(_ opts: [String], sel: String, _ onTap: @escaping (String) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(opts, id: \.self) { o in
                let on = o == sel
                Button { onTap(o) } label: {
                    Text(o).font(Port42Theme.mono(10)).foregroundStyle(on ? acc : Port42Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 6).background(on ? acc.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var effectiveName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? (selectedType?.displayName ?? "") : n
    }
    private var initials: String { effectiveName.isEmpty ? "?" : String(effectiveName.prefix(2)).uppercased() }

    private func create() {
        guard canCreate, let user = appState.currentUser else { return }
        let nm = effectiveName
        let trig: AgentTrigger = triggerSel == "all messages" ? .allMessages : .mentionOnly
        var c: AgentConfig
        if mode == .command {
            // CLI LLM (claude/gemini/codex) → a terminal tile; custom → headless NDJSON command.
            let isCLI = cliChoice != "custom"
            let cmd = isCLI ? cliChoice : command.trimmingCharacters(in: .whitespaces)
            let args = isCLI ? [] : argsText.split(separator: " ").map(String.init)
            c = AgentConfig.createCommand(ownerId: user.id, displayName: nm, command: cmd,
                                          args: args.isEmpty ? nil : args, workingDir: nilIfEmpty(workingDir), envVars: nil,
                                          systemPrompt: nilIfEmpty(promptOverride), openInTerminal: isCLI, trigger: trig)
        } else {
            let prov: AgentProvider = mode == .api ? .compatibleEndpoint : (providerSel == "gemini" ? .gemini : .anthropic)
            let prompt = !promptOverride.isEmpty ? promptOverride
                : (selectedType.map(loadConstitution) ?? "You are \(nm), a companion in Port42. Not an assistant, a companion.")
            c = AgentConfig.createLLM(ownerId: user.id, displayName: nm, systemPrompt: prompt, provider: prov,
                                      model: nilIfEmpty(model) ?? "claude-opus-4-6", trigger: trig)
            c.providerBaseURL = mode == .api ? nilIfEmpty(baseURL) : nil
            c.thinkingEnabled = thinkingOn; c.thinkingEffort = thinkingEffort
            c.scopePath = nilIfEmpty(scopePath) ?? selectedType?.defaultKBPath
        }
        c.secretNames = selectedSecrets.isEmpty ? nil : selectedSecrets.sorted()   // any mode
        appState.addCompanion(c)
        if let s = appState.currentSpace { appState.addCompanionToSpace(c, space: s) }
        dismiss()
    }

    private func nilIfEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
    }
    private func loadConstitution(_ t: CompanionTypePreset) -> String {
        guard let url = Bundle.module.url(forResource: t.constitutionFile, withExtension: "md", subdirectory: "constitutions"),
              let text = try? String(contentsOf: url) else { return "You are \(t.displayName), a companion in Port42. \(t.label)." }
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

/// Shell-native named-secrets editor (the old Settings → Secrets, brought into the shell). Toggle
/// which Keychain secrets a companion may use (`selected`), and create/delete secrets inline. Used by
/// both the new-companion card and companion settings — the value never leaves the Keychain; a
/// companion references it by name.
struct ShellSecretsField: View {
    @Binding var selected: Set<String>
    let accent: Color
    @State private var secrets: [Port42AuthStore.Secret] = Port42AuthStore.shared.listSecrets()
    @State private var adding = false
    @State private var newName = ""
    @State private var newValue = ""
    @State private var newType: Port42AuthStore.SecretType = .bearerToken

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(secrets) { row($0) }
            if secrets.isEmpty && !adding {
                Text("No secrets yet — add one for rest.call or provider keys.")
                    .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
            }
            if adding { addForm } else {
                Button { adding = true } label: {
                    HStack(spacing: 5) { Image(systemName: "plus"); Text("new secret") }
                        .font(Port42Theme.mono(10)).foregroundStyle(accent)
                }.buttonStyle(.plain)
            }
        }
    }

    private func row(_ s: Port42AuthStore.Secret) -> some View {
        let on = selected.contains(s.name)
        return HStack(spacing: 8) {
            Button { if on { selected.remove(s.name) } else { selected.insert(s.name) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12)).foregroundStyle(on ? accent : Port42Theme.textSecondary)
                    Text(s.name).font(Port42Theme.monoBold(12)).foregroundStyle(Port42Theme.textPrimary)
                    Text(s.type.rawValue).font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.white.opacity(0.06), in: Capsule())
                }
            }.buttonStyle(.plain)
            Spacer()
            Button {
                Port42AuthStore.shared.deleteSecret(name: s.name)
                selected.remove(s.name)
                secrets = Port42AuthStore.shared.listSecrets()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
            }.buttonStyle(.plain).help("Delete secret from Keychain")
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            box("name (e.g. stripe)", $newName)
            Picker("", selection: $newType) {
                Text("Bearer").tag(Port42AuthStore.SecretType.bearerToken)
                Text("API Key").tag(Port42AuthStore.SecretType.apiKey)
                Text("Basic").tag(Port42AuthStore.SecretType.basicAuth)
                Text("Header").tag(Port42AuthStore.SecretType.header)
                Text("LLM").tag(Port42AuthStore.SecretType.llm)
            }.labelsHidden().pickerStyle(.menu).tint(accent)
            secureBox("credential value", $newValue)
            HStack {
                Button("cancel") { adding = false; newName = ""; newValue = "" }
                    .buttonStyle(.plain).font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                Spacer()
                Button("add") { save() }
                    .buttonStyle(.plain).font(Port42Theme.monoBold(10)).foregroundStyle(accent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !value.isEmpty else { return }
        Port42AuthStore.shared.saveSecret(name: name, type: newType, value: value)
        secrets = Port42AuthStore.shared.listSecrets()
        selected.insert(name)      // auto-grant the just-created secret
        newName = ""; newValue = ""; adding = false
    }

    private func box(_ ph: String, _ t: Binding<String>) -> some View {
        TextField(ph, text: t).textFieldStyle(.plain).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
    private func secureBox(_ ph: String, _ t: Binding<String>) -> some View {
        SecureField(ph, text: t).textFieldStyle(.plain).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}
