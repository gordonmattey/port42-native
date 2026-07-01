import SwiftUI
import AppKit

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
            // Layer 0 — the living ambient surface, always alive underneath everything.
            DreamscapeVideoLayer()
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
        }
        .ignoresSafeArea()                                            // edge-to-edge: fill the screen
        .animation(.spring(response: 0.4), value: shell.zoom)
        .onAppear { installInputMonitors(); applyTakeoverToWindow() }
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

        // Keys — ⌘↑/↓ ladder, ⌘1…N space jump, Esc peels one rung.
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let cmd = e.modifierFlags.contains(.command)
            // Yield to a focused text editor unless it's a ⌘-shortcut (typing must not move the ladder).
            let editing = (e.window?.firstResponder is NSText) || (e.window?.firstResponder is NSTextView)

            if e.keyCode == 53 {   // Esc — peel back to the desktop from either end; pass through at .space
                guard shell.zoom != .space else { return e }
                shell.galaxyHover = nil
                withAnimation(.spring(response: 0.4)) { shell.zoom = .space }
                return nil
            }
            guard cmd, !editing else { return e }
            if e.keyCode == 126 { shell.zoomOut(); return nil }   // ⌘↑ → up toward galaxy
            if e.keyCode == 125 { shell.zoomIn();  return nil }   // ⌘↓ → down toward focus
            if let s = e.charactersIgnoringModifiers, let n = Int(s), n >= 1, n <= 9 {
                shell.jumpToSpace(index: n - 1)                   // ⌘1…9 → Nth space
                return nil
            }
            return e
        }

        monitors = [magnify, keys].compactMap { $0 }
    }

    private func removeInputMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }
}

// MARK: - Galaxy (all spaces as worlds; zoom UP)

/// The all-spaces constellation. Each space is a stylized accent-orb world (cheap `Canvas`, not a
/// live preview) with its name + port count. Hovering arms `galaxyHover` (so ⌘↓ / pinch-in dives
/// into it); clicking enters it.
struct ShellGalaxyView: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { shell.zoomIn() }   // tap empty space → drop back into the current space
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
                        }
                        .frame(maxWidth: avail)
                        .padding(.vertical, 6)
                    }
                    Text("hover + ⌘↓ / pinch-in to dive in · ⌘1…9 jump · ⌘↑ / pinch-out to zoom")
                        .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .padding(.vertical, 30)
            }
        }
    }

    private func portCount(_ space: Space) -> Int {
        appState.portWindows.panels.filter { $0.spaceId == space.id && !$0.isBackground && !$0.isChatPort }.count
    }

    @ViewBuilder
    private func world(_ space: Space, index: Int) -> some View {
        let on = space.id == appState.currentSpace?.id
        let hovered = shell.galaxyHover == index
        let hot = on || hovered
        Button {
            shell.jumpToSpace(index: index)
        } label: {
            VStack(spacing: 13) {
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                        ctx.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)),
                                 with: .radialGradient(Gradient(colors: [Port42Theme.accent.opacity(0.5), Port42Theme.accent.opacity(0.03), .clear]),
                                                       center: c, startRadius: 0, endRadius: size.width / 2))
                        let r = size.width * 0.26 + sin(t * 1.4 + Double(index)) * 4
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                 with: .color(Port42Theme.accent.opacity(0.9)))
                        let n = max(portCount(space), 1)
                        for s in 0..<min(n, 8) {
                            let a = t * 0.6 + Double(s) / Double(n) * 6.283
                            let rr = size.width * 0.42
                            let mx = c.x + cos(a) * rr, my = c.y + sin(a) * rr * 0.46
                            ctx.fill(Path(ellipseIn: CGRect(x: mx - 3, y: my - 3, width: 6, height: 6)), with: .color(.white.opacity(0.9)))
                        }
                    }
                }.frame(width: 120, height: 120)
                Text(space.name.uppercased()).font(Port42Theme.monoBold(14)).foregroundStyle(hot ? Port42Theme.accent : Port42Theme.textPrimary).tracking(2)
                Text("\(portCount(space)) ports").font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
            }
            .padding(18).frame(maxWidth: .infinity)
            .background(hot ? Port42Theme.accent.opacity(0.10) : Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(hot ? Port42Theme.accent.opacity(0.7) : Color.white.opacity(0.15), lineWidth: hot ? 1.5 : 1))
            .shadow(color: hovered ? Port42Theme.accent.opacity(0.4) : .clear, radius: 16)
            .scaleEffect(hovered ? 1.04 : (on ? 1.02 : 1))
        }
        .buttonStyle(.plain)
        // Only SET on enter (don't clear on exit) so the last-hovered world stays the dive target
        // for a pinch-in / ⌘↓ that follows the hover.
        .onHover { hovering in if hovering { shell.galaxyHover = index } }
        .animation(.spring(response: 0.3), value: hovered)
    }
}
