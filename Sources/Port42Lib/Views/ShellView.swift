import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

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
    /// Observed directly: it's a plain `let` on AppState, so its changes don't come through
    /// AppState's own objectWillChange.
    @ObservedObject private var permissions: PermissionCoordinator

    /// A window of its own on another display (#189), not the app's main window: it does not own the
    /// voice session or the main window's takeover, and it opens on the space it is given.
    private let displayWindow: Bool

    public init(appState: AppState, displayWindow: Bool = false, spaceId: String? = nil) {
        self.appState = appState
        self.permissions = appState.permissions
        self.displayWindow = displayWindow
        _shell = StateObject(wrappedValue: {
            let shell = ShellState(appState: appState)
            shell.isDisplayWindow = displayWindow
            if displayWindow { shell.show(spaceId: spaceId) }
            return shell
        }())
    }

    @State private var monitors: [Any] = []
    /// Hold space to talk. The machine is pure (`VoiceTrigger`); this owns the clock and the timer.
    @State private var voice = VoiceTrigger()
    @State private var voiceTimer: Timer?
    @State private var voiceSession: VoiceSession?
    /// The surface that had the keyboard when the hold began. Held for the length of the hold so a focus
    /// change mid-sentence cannot land the words somewhere else.
    @State private var voiceResponder: NSResponder?
    /// A terminal takes real characters rather than a composition, because it draws marked text on one
    /// line at the cursor and a spoken sentence is longer than that. `voiceStreamed` is what this hold has
    /// already put in the surface, so the next partial only sends the difference.
    @State private var voiceStreamsAsEdits = false
    @State private var voiceStreamed = ""
    /// The recognizer's previous guess, to tell which words have settled.
    @State private var voiceLastGuess = ""
    /// What has been typed into ANOTHER app during this hold, for the same smallest-edit streaming.
    @State private var voiceTyped = ""
    @State private var voiceObservers: [NSObjectProtocol] = []
    @State private var voiceWatchdog: Timer?
    @State private var voiceReleasePoll: Timer?
    @State private var voiceNoticeTimer: Timer?
    /// The space the Quick Switcher opened in — a selection that changed it lands at .space.
    @State private var switcherSpaceId: String?
    /// First run only: the onboarding focus is applied ONCE. Without this latch the reactive
    /// hook would yank a user back to the chat every time the panel set changes.
    @State private var onboardingFocusApplied = false
    /// The breakout's two animated values: false = still on the port's frame; 1 = fully opaque.
    @State private var breakoutExpanded = false
    @State private var breakoutOpacity: Double = 1

    /// First run: Echo's terminal port, which setup spawned (nautilus Phase 1 step 3). nil until the
    /// panel has landed.
    private var onboardingChatUdid: String? {
        guard appState.isOnboarding, !onboardingFocusApplied,
              let id = appState.onboardingFocusPortId,
              appState.portWindows.panels.contains(where: { $0.id == id || $0.udid == id }) else { return nil }
        return appState.portWindows.panels.first(where: { $0.id == id || $0.udid == id })?.udid ?? id
    }

    /// SPIKE 1: `switchToSpace` → `ensureChatPort` guarantees the chat panel EXISTS, but not by
    /// any fixed `onAppear` — so the first-run focus is applied reactively, when the panel
    /// actually appears, and then latched.
    private func applyOnboardingFocus() {
        guard !onboardingFocusApplied, let udid = onboardingChatUdid else { return }
        onboardingFocusApplied = true
        shell.zoom = .focus(udid)
    }

    private var galaxyShown: Bool { shell.zoom == .galaxy }
    /// Focus IS a desktop state (Phase 2): every focusable id is a unit, and focus resizes that
    /// unit in place inside the desktop — there is no focus overlay. `ShellState.zoomIn` only
    /// targets units and `exitFocusIfGone` snaps back when the focused unit leaves the desktop.
    private var focusShown: Bool { if case .focus = shell.zoom { return true } else { return false } }

    /// Chrome sits flush at the very top edge (topInset 0). A center notch, if any, overlaps only
    /// the Chrome's empty middle (mark is left, actions are right), so nothing important is clipped.
    private var topInset: CGFloat { 0 }

    public var body: some View {
        ZStack {
            // Layer 0 — the ambient background. Normally the Canvas dreamscape; but if a port is set
            // as the background (the chrome-is-ports wedge), that port renders full-bleed here
            // instead, non-interactive. Your background is a port you made.
            if let bgId = shell.backgroundPortId, let v = appState.portWindows.hostView(for: bgId) {
                // The LIVE port, re-parented full-bleed as Layer 0 — no reload. Background is just a
                // position of the same surface (like tiled/parked/focus), so a running shader keeps
                // running. Interactive: it's behind the desktop, so ports/chrome on top win their
                // clicks and only the empty gaps fall through to the background.
                ShellPortHost(view: v,
                              bridge: appState.portWindows.panels.first(where: { $0.id == bgId })?.bridge,
                              probeId: bgId)
                    // Each space has its own backdrop: a new identity per port, or the host keeps showing the
                    // first space's surface (its container is built once and never swaps the view).
                    .id(bgId)
                    .ignoresSafeArea()
            } else if let bgHtml = shell.backgroundPortHtml {
                // Fallback: the background port was CLOSED — nothing live to re-parent, so mount a
                // fresh copy from its stored HTML.
                ShellBackgroundPort(html: bgHtml, appState: appState)
                    .id(appState.currentSpace?.id)
                    .ignoresSafeArea()
            } else if ShellBackground.isDisabledForMeasurement {
                // A/B for the scroll-jitter + beachball investigation (summer2026-todo.md). Measured
                // on Dev3 during real wheel-scroll jitter: `CanvasDisplayList` was 8327 main-thread
                // samples against ~2700 for the ENTIRE conversation layout, so the animated
                // background costs about three times the thing the scroll was actually doing.
                // Toggle without a rebuild:
                //   defaults write com.port42.dev3 PORT42_NO_SHELL_BG -bool true   (then relaunch)
                Color.black.ignoresSafeArea()
            } else {
                ShellBackground(shell: shell)
                    .ignoresSafeArea()
            }

            // Layer 2 — the desktop GROUP (Chrome + tiles + dock). Stays mounted across rungs; it
            // recedes (scale + dim) behind the galaxy rather than being torn down. Structure mirrors
            // the prototype: tiles live in their own ZStack (in ShellDesktopView) and the overlays
            // below are translucent .zIndex siblings — SwiftUI composites them above the tiles.
            ZStack {
                VStack(spacing: 0) {
                    ShellChrome(shell: shell, appState: appState)
                    ShellDesktopView(shell: shell, appState: appState)
                }
                // The dock hides while a unit is focused (the focus card doesn't reach it).
                // Pure SwiftUI — safe to unmount.
                if !focusShown {
                    VStack { Spacer(); ShellDock(shell: shell, appState: appState).padding(.bottom, 24) }
                        .transition(.opacity)
                }
            }
            .padding(.top, topInset)                                   // clear the notch / top edge
            .scaleEffect(galaxyShown ? 0.94 : 1.0, anchor: .center)
            .opacity(galaxyShown ? 0.5 : 1.0)
            // A focused unit lives INSIDE this group — it must stay interactive at .focus.
            // Only the galaxy takes input away from the desktop (Phase 2).
            .allowsHitTesting(shell.zoom != .galaxy)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: shell.zoom)

            // Click-shield: a hit-capturing sibling ABOVE the desktop (outside its allowsHitTesting
            // group) while the galaxy owns input. SwiftUI's allowsHitTesting doesn't stop the
            // embedded chat WKWebView from getting AppKit clicks; this real layer does. A focused
            // unit needs no shield — its own backdrop (in ShellDesktopView) covers the rest.
            if galaxyShown {
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

            // (The focus overlay is gone — Phase 2. Focus is a geometry state of the unit
            // already mounted in ShellDesktopView; nothing can focus that isn't a unit.)

            // Settings box (long-press a world / companion) — rename, accent, delete. Top layer.
            // It self-animates in/out (save pops, discard shrinks), so no view-level transition.
            if shell.settingsTarget != nil {
                ShellSettingsView(shell: shell, appState: appState).zIndex(200)
            }

            // New Companion — a shell-native card (creates a real companion in THIS space).
            if shell.showNewCompanion {
                ShellNewCompanionView(shell: shell, appState: appState).zIndex(210)
            }

            // Quick Switcher (⌘K) — fuzzy jump across spaces/companions, migrated from the
            // classic app as a shell overlay. The scrim dismisses; selection lands at .space.
            if shell.showQuickSwitcher {
                ZStack {
                    CommandBackdrop { shell.showQuickSwitcher = false }
                    QuickSwitcher(isPresented: $shell.showQuickSwitcher, shell: shell)
                        .environmentObject(appState)
                        .offset(y: -40)                          // centered, a little above the middle
                }.zIndex(215)
            }

            // Quick imagine (⌘I): one line starts a team in a new space.
            if shell.showImagine {
                ZStack {
                    CommandBackdrop { shell.showImagine = false }
                    ImagineBox(isPresented: $shell.showImagine, appState: appState, shell: shell)
                        .offset(y: -40)
                }.zIndex(216)
            }

            if shell.showImportSessions {
                ZStack {
                    CommandBackdrop { shell.showImportSessions = false }
                    SessionImportBox(isPresented: $shell.showImportSessions, appState: appState)
                        .offset(y: -30)
                }.zIndex(217)
            }

            // Accept an invite to someone's port (4.6b): clicked or pasted into ⌘K.
            if shell.pendingInvite != nil {
                ZStack {
                    CommandBackdrop { shell.pendingInvite = nil }
                    AcceptBox(link: $shell.pendingInvite, appState: appState, shell: shell)
                        .offset(y: -30)
                }.zIndex(219)
            }

            // Share one port with someone on another machine (nautilus Phase 4, 4.6b).
            if shell.shareTarget != nil {
                ZStack {
                    CommandBackdrop { shell.shareTarget = nil }
                    ShareBox(portKey: $shell.shareTarget, appState: appState, moving: shell.shareMove)
                        .offset(y: -30)
                }.zIndex(218)
            }

            // Global Settings — the app's SignOutSheet surfaced as a shell overlay (whole menu brought
            // across; sections to be revisited for the shell over time).
            // The space's chat, dropped down from the top bar under the space name.
            if shell.spaceChatOpen, shell.zoom != .galaxy, let sid = shell.spaceId {
                GeometryReader { geo in
                    // Drop-down size, or zoomed to a full view like a focused port.
                    // Or the size the person dragged it to (GM, 2026-09-26).
                    let expanded = shell.spaceChatExpanded
                    // Clear of the peek rail while a peek is up (#136): it sits where the chat drops down.
                    let peeks = shell.peekingPorts.count
                    let room = CGSize(width: ShellState.spaceChatRoomWidth(geo.size.width, peeks: peeks),
                                      height: geo.size.height - topInset - 50 - 110)
                    let size = expanded ? ShellState.spaceChatSize(room, room: room)
                                        : ShellState.spaceChatSize(shell.spaceChatSize, room: room)
                    let w = size.width, h = size.height
                    VStack {
                        HStack {
                            // Hosted in its own AppKit view, so it wins clicks and scrolls over the ports
                            // beneath it: SwiftUI drawn over a hosted web or terminal view does not
                            // (GM, 2026-09-25: a full space chat could not be used where it covered one).
                            AppKitLayer(content:
                                // Its bottom-right corner drags, like a port's: a grip strip of the
                                // panel's own, below its input, so the rounded corner no longer cuts
                                // it off and it no longer sits on the send button (#127).
                                PortChatPanel(chats: appState.chats, appState: appState, key: sid, accent: shell.accent,
                                              resize: .init(edge: .corner, size: CGSize(width: w, height: h)) { proposed in
                                                  shell.spaceChatExpanded = false
                                                  shell.spaceChatSize = ShellState.spaceChatSize(proposed, room: room)
                                              })
                                    .frame(width: w, height: h)
                                    .frame(width: w, height: h)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(shell.accent.opacity(0.4), lineWidth: 1))
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            withAnimation(.spring(response: 0.4)) { shell.spaceChatExpanded.toggle() }
                                        } label: {
                                            Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                                .font(.system(size: 10)).foregroundStyle(Port42Theme.textSecondary)
                                                .frame(width: 22, height: 22).contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain).help(expanded ? "Back to the drop-down" : "Full view")
                                        .padding(6)
                                    })
                                .frame(width: w, height: h)
                                .shadow(color: .black.opacity(0.5), radius: 24)
                                .id(sid)
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, topInset + 50).padding(.leading, ShellState.spaceChatLeading(peeks: peeks))
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: peeks > 0)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(150)
            }

            // First-run breakout: above everything (it is a moment, not a surface).
            if let from = shell.breakoutFrom {
                breakoutOverlay(from: from).zIndex(240)
            }

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



            // Hold-to-talk. Drawn by the SHELL, never by a port, so nothing on screen can be
            // listening without saying so.
            // Permission — the top layer, above every other overlay, because it BLOCKS: a caller
            // is suspended on the answer. One site for every asker (port JS / companion tool use /
            // gateway); see PermissionCoordinator for why this isn't rendered inside a tile.
            if let request = permissions.current {
                ShellPermissionOverlay(coordinator: permissions,
                                       accent: shell.accent,
                                       request: request)
                    .zIndex(230)
            }
        }
        .ignoresSafeArea()                                            // edge-to-edge: fill the screen
        // #130: the window says where the person is: the space, and the port in focus. Read by
        // VoiceOver and by tools that read window titles. Set on every update of the shell, so a
        // zoom, a focus change, or a rename of the space or port shows at once.
        .background(WindowRefAccessor { w in
            shell.attach(window: w)
            let title = shell.windowTitle
            if let w, w.title != title { w.title = title }
        })
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { _ in
            guard shell.isKey else { return }   // #189: the menu command is the window in use's
            shell.showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newSpaceRequested)) { _ in
            guard shell.isKey else { return }   // #189: the menu command is the window in use's
            // ⌘N and File → New Space: the galaxy's new-space card, from anywhere.
            appState.createSpace(name: "space \(appState.spaces.count + 1)")
            withAnimation(.spring(response: 0.45)) { shell.zoom = .space }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickSwitcherRequested)) { _ in
            guard shell.isKey else { return }   // #189: the menu command is the window in use's
            shell.showQuickSwitcher.toggle()          // ⌘K — migrated from the classic app
        }
        .onReceive(NotificationCenter.default.publisher(for: .imagineRequested)) { _ in
            guard shell.isKey else { return }   // #189: the menu command is the window in use's
            shell.showImagine.toggle()
        }
        // The switcher changed the space → land on the desktop rung (galaxy/focus would
        // otherwise linger over the new space). Scoped to switcher closes, so a space
        // change from galaxy management (e.g. delete) never yanks the ladder.
        .onChange(of: shell.showQuickSwitcher) { _, showing in
            if showing { switcherSpaceId = shell.spaceId }
            else if switcherSpaceId != shell.spaceId {
                withAnimation(.spring(response: 0.4)) { shell.zoom = .space }
            }
        }
        .animation(.spring(response: 0.4), value: shell.zoom)
        .onChange(of: shell.zoom) { old, z in
            // Moving the ladder while the breakout plays SKIPS it: the video is never a wall, and it
            // must not play on over a rung already left. Read before the first-run branch below, so
            // the zoom that STARTS it is exempt.
            let breakoutWasPlaying = shell.breakoutFrom != nil
            // FIRST RUN ends here, the first time you leave Echo's terminal for your desktop (the
            // arrow, ⌘↑, a pinch), and the aquarium breakout plays (GM, 2026-09-27: brought back).
            if case .focus = old, z == .space, appState.isOnboarding {
                appState.endOnboarding()
                shell.startBreakout(area: shell.lastDesktopArea)
                if AquariumBreakoutView.videoURL == nil { appState.openHeldImagineLink(); appState.openHeldWebLinks() }
            } else if breakoutWasPlaying {
                finishBreakout(fade: 0.3)                 // a quick clear, not the full outro
            }
            if z != .space { shell.exposeActive = false }   // exposé lives at .space
            if z == .space { shell.settleAfterPreview() }   // a peek you looked at and did not keep goes
            // Keyboard follows focus (§B): every keyboard-driven path here (⌘` swap, ⌘↓,
            // double-click header, peek preview) skips the AppKit click that would normally
            // move the first responder — hand the keyboard to the focused unit's surface.
            if case .focus(let id) = z {
                appState.portWindows.focusKeyboard(on: id)
                // Focus used to record the human as the port's driver here, and stopped at step 3:
                // presence is derived from whoever moved the token last, and a focus moves nothing.
                // Your first keystroke or click inside the surface names you (`humanInteracted`).
            }
        }
        // The focused unit left the desktop (closed via API, evaporated, detached) → back to
        // the space rung. Focus has no overlay to fall into (Phase 2); this is the safety net.
        .onChange(of: shell.contextItems.map(\.id)) { _, _ in shell.exitFocusIfGone() }
        .onAppear {
            installInputMonitors()
            if !displayWindow {
                applyTakeoverToWindow()
                shell.restoreBackgroundPort()        // a background port set last session
                appState.displaySpaces.restore()     // #189: spaces back on their displays
            }
            // On unlock (TransitionRoot swaps LockScreenView → ShellView) land in the LAST space —
            // `AppState.unlock()` has already restored it as currentSpace. Galaxy if there's no
            // space yet (fresh setup) or every space rests (show the shelf, not a rested inside).
            shell.zoom = ShellState.initialZoom(hasCurrentSpace: shell.space != nil,
                                                allRested: appState.workingSpaces.isEmpty,
                                                onboarding: appState.isOnboarding,
                                                chatUdid: onboardingChatUdid)
            applyOnboardingFocus()
        }
        // First run: the chat panel can land after this view appears (Spike 1) — focus it the
        // moment it does. No-op for a returning user (`onboardingChatUdid` is nil).
        .onChange(of: onboardingChatUdid) { _, _ in applyOnboardingFocus() }
        .onDisappear { removeInputMonitors() }
    }

    /// Esc pressed with a shell modal open → close the topmost one (matches every card's ✕
    /// and scrim-click). Returns false when nothing was open, so Esc falls through to the
    /// exposé/ladder handling. (A focused text field never reaches here — the yield check
    /// hands Esc to the field, whose own onExitCommand closes its card.)

    // MARK: - First-run breakout

    /// End the breakout: fade it off, then clear the state. `fade` is the full outro when the video
    /// played out, and a short clear when the person moved the ladder and skipped it.
    private func finishBreakout(fade: Double) {
        guard shell.breakoutFrom != nil else { return }
        withAnimation(.easeOut(duration: fade)) { breakoutOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + fade) {
            shell.endBreakout()
            breakoutExpanded = false
            breakoutOpacity = 1
            appState.openHeldImagineLink()        // a link held through the first run opens now
            appState.openHeldWebLinks()
        }
    }

    /// The video starts ON the port the person was focused on, grows to full screen while it plays,
    /// then fades off to leave them in their space. The desktop is already behind it at `.space`, so
    /// the fade is the arrival.
    @ViewBuilder
    private func breakoutOverlay(from: CGRect) -> some View {
        GeometryReader { geo in
            let full = CGRect(origin: .zero, size: geo.size)
            let r = breakoutExpanded ? full : from
            AquariumBreakoutView(onFinished: { finishBreakout(fade: 0.9) })
                .frame(width: r.width, height: r.height)
                .clipShape(RoundedRectangle(cornerRadius: breakoutExpanded ? 0 : ShellPlacement.focusCorner))
                .position(x: r.midX, y: r.midY)
                .opacity(breakoutOpacity)
                .allowsHitTesting(false)                  // a moment you watch, not a surface you use
                .onAppear {
                    // It grows with the zoom-out under it, the same spring, at once (GM, 2026-09-27:
                    // the slow grow lagged behind the port shrinking beneath it).
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.4)) { breakoutExpanded = true }
                    }
                }
        }
        .ignoresSafeArea()
    }

    private func closeTopmostModal() -> Bool {
        // Permission is topmost and BLOCKING — Esc is an explicit deny (a caller is suspended on
        // the answer; there is no "close without answering").
        if permissions.current != nil { permissions.resolveCurrent(granted: false); return true }
        // A command box sits over everything else the shell draws, the space chat included.
        if shell.showQuickSwitcher { shell.showQuickSwitcher = false; return true }
        if shell.showImagine { shell.showImagine = false; return true }
        if shell.showImportSessions { shell.showImportSessions = false; return true }
        if shell.shareTarget != nil { shell.shareTarget = nil; return true }
        if shell.pendingInvite != nil { shell.pendingInvite = nil; return true }
        if shell.showSettings { shell.showSettings = false; return true }
        if shell.spaceChatOpen { shell.spaceChatOpen = false; return true }
        if shell.showNewCompanion { shell.showNewCompanion = false; return true }
        if shell.settingsTarget != nil { shell.settingsTarget = nil; return true }
        return false
    }

    /// Set up the shell window when the UI appears — the reliable site (the window exists by now,
    /// unlike `applicationDidFinishLaunching`, and it's independent of which unlock/dive path ran).
    /// Routes through the one authoritative helper (takeover or windowed). Retries cover first-frame timing.
    private func applyTakeoverToWindow() {
        for attempt in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 0.2) {
                guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey }) else { return }
                ShellMode.applyShellWindow(to: window)
            }
        }
    }

    /// What the capsule says when there is no notice to show. The wording lives on the state itself, so
    /// the tile's pill and the shell's say the same thing.
    private var voiceLabel: String { shell.voiceModel.label }

    /// Arm the hold threshold. Cancelled on key-up, and harmless if it fires late: the machine
    /// refuses to start capturing unless a hold is still pending.
    private func armVoiceThreshold() {
        voiceTimer?.invalidate()
        voiceTimer = Timer.scheduledTimer(withTimeInterval: VoiceTrigger.threshold, repeats: false) { _ in
            Task { @MainActor in
                guard voice.thresholdElapsed() == .beginCapture else { return }
                retractOneCharacter()
                shell.voiceCapturing = true
                shell.voiceNotice = nil
                shell.voicePartial = nil
                armVoiceWatchdog()
                armVoiceReleasePoll()
                voiceSession?.destination = .inApp
                voiceTyped = ""
                shell.voiceAnchorPortId = appState.portWindows.portHoldingKeyboard()
                voiceResponder = NSApp.keyWindow?.firstResponder
                voiceStreamed = ""
                voiceLastGuess = ""
                VoiceCue.play(.start)
                voiceStreamsAsEdits = appState.portWindows.panels
                    .first { $0.id == shell.voiceAnchorPortId }?.portType == "terminal"
                voiceSession?.begin()
            }
        }
    }

    /// Whether partials stream into the focused surface as uncommitted text. On by default; a surface
    /// that renders marked text badly can be taken back to pill-only without a build.
    static let streamIntoPortKey = "voiceStreamIntoPort"

    /// Whether letting go of the space sends what was said: Return after the words land (GM, 2026-09-27).
    /// On by default; off in Settings, Voice, for someone who wants to read it over first.
    static let sendOnReleaseKey = "voiceSendOnRelease"
    static var sendsOnRelease: Bool { UserDefaults.standard.object(forKey: sendOnReleaseKey) as? Bool ?? true }
    /// A beat between the words and the Return, so a terminal app does not take text followed at once by
    /// Return for a paste, where Return is a new line rather than send.
    static let sendDelay: TimeInterval = 0.25

    private func sendAfterWords(into target: NSResponder?) {
        guard Self.sendsOnRelease else { return }
        // A hold cut off at the limit is mid-sentence: its words land, and the person sends when done.
        guard voiceSession?.endedAtLimit != true else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sendDelay) {
            if let target { VoiceInserter.submit(into: target) } else { VoiceTyper.pressReturn() }
        }
    }

    /// Let go of a hold without treating it as a finished sentence: no transcription, no insertion, and any
    /// uncommitted text taken back. The focus changes land here.
    @MainActor
    private func abandonVoiceHold() {
        voiceTimer?.invalidate(); voiceTimer = nil
        voiceWatchdog?.invalidate(); voiceWatchdog = nil
        voiceReleasePoll?.invalidate(); voiceReleasePoll = nil
        _ = voice.cancel()
        guard shell.voiceCapturing else { return }
        shell.voiceCapturing = false
        voiceSession?.abandon()
        if voiceStreamsAsEdits {
            voiceStreamed = VoiceInserter.stream("", previous: voiceStreamed, into: voiceResponder)
        } else {
            VoiceInserter.unmark(voiceResponder)
        }
        if !voiceTyped.isEmpty { voiceTyped = VoiceTyper.stream("", previous: voiceTyped) }
        clearVoiceNotice()
    }

    private func endVoice(atLimit: Bool = false) {
        voiceWatchdog?.invalidate(); voiceWatchdog = nil
        voiceReleasePoll?.invalidate(); voiceReleasePoll = nil
        shell.voiceCapturing = false
        VoiceCue.play(.end)
        voiceSession?.end(atLimit: atLimit)
        // A hold that produced nothing must leave no uncommitted text behind. The final text, when it
        // comes, commits over the mark; this is the silence case.
        if voiceSession?.transcription == nil {
            if voiceStreamsAsEdits {
                voiceStreamed = VoiceInserter.stream("", previous: voiceStreamed, into: voiceResponder)
            } else {
                VoiceInserter.unmark(voiceResponder)
            }
        }
        // After release the capsule says only what the surface cannot: that the words are still being
        // worked on, or that there is no model to work on them. On success `onText` clears it.
        if shell.voiceModel == .ready {
            // Nothing to say: the words are already in the surface as uncommitted text, and the release
            // commits over them. The mic simply goes cold.
            clearVoiceNotice()
        } else {
            showVoiceNotice(voiceLabel, seconds: 3)
        }
    }

    /// A hold that reaches the maximum ends as a release does, and its words are kept (not sent). The end cue
    /// tells the person it stopped listening.
    private func armVoiceWatchdog() {
        voiceWatchdog?.invalidate()
        voiceWatchdog = Timer.scheduledTimer(withTimeInterval: VoiceTrigger.maximumHold, repeats: false) { _ in
            Task { @MainActor in
                voiceTimer?.invalidate(); voiceTimer = nil
                guard voice.reachedLimit() == .endCapture, shell.voiceCapturing else { return }
                p42log("[Port42] voice: hold reached %.0fs; ending it and keeping the words", VoiceTrigger.maximumHold)
                endVoice(atLimit: true)
            }
        }
    }

    /// A hold ends if the space bar is no longer down: a release this window never saw must not leave
    /// the hold open to swallow the keyboard.
    private func armVoiceReleasePoll() {
        voiceReleasePoll?.invalidate()
        var upReads = 0
        voiceReleasePoll = Timer.scheduledTimer(withTimeInterval: VoiceTrigger.releasePollInterval, repeats: true) { timer in
            Task { @MainActor in
                guard shell.voiceCapturing else { timer.invalidate(); return }
                upReads = VoiceTrigger.spaceIsDown ? 0 : upReads + 1
                guard VoiceTrigger.releaseMissed(capturing: true, spaceDown: upReads == 0, upReads: upReads) else { return }
                p42log("[Port42] voice: the space bar came up unseen; ending the hold")
                timer.invalidate()
                _ = voice.cancel()
                endVoice()
            }
        }
    }

    private func clearVoiceNotice() {
        voiceNoticeTimer?.invalidate()
        voiceNoticeTimer = nil
        shell.voiceNotice = nil
        shell.voicePartial = nil
        shell.voiceAnchorPortId = nil
    }

    private func showVoiceNotice(_ text: String, seconds: TimeInterval) {
        shell.voiceNotice = text
        voiceNoticeTimer?.invalidate()
        voiceNoticeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in
                shell.voiceNotice = nil
                shell.voiceAnchorPortId = nil
            }
        }
    }

    /// Build the voice session on first install of the monitors. Phase 2 reports the text; Phase 3 is
    /// what puts it into the focused surface.
    private func installVoiceSession() {
        guard voiceSession == nil else { return }
        // The session was built with the app and its model has been loading since launch; the shell only
        // attaches what it draws.
        let session = appState.voice
        session.onPartial = { partial in
            // Another app cannot be composed into, so the words are typed as the smallest edit. The shell's
            // own indicator is not involved: the floating panel is what shows there.
            if session.destination == .otherApp {
                voiceTyped = VoiceTyper.stream(partial, previous: voiceTyped)
                return
            }
            guard shell.voiceCapturing else { return }
            shell.voicePartial = partial
            // Stream it into the surface as uncommitted text, so the words appear where they will land.
            if UserDefaults.standard.object(forKey: Self.streamIntoPortKey) as? Bool ?? true {
                if voiceStreamsAsEdits {
                    // Only settled words, and only ever more of them: no backspacing while you talk, so a
                    // TUI's input box never shrinks and regrows (the flash in a narrow terminal).
                    let settled = VoiceInserter.settled(streamed: voiceStreamed, previousGuess: voiceLastGuess, guess: partial)
                    voiceLastGuess = partial
                    voiceStreamed = VoiceInserter.stream(settled, previous: voiceStreamed, into: voiceResponder)
                } else {
                    VoiceInserter.mark(partial, into: voiceResponder)
                }
            }
        }
        session.onText = { text in
            if session.destination == .otherApp {
                voiceTyped = VoiceTyper.stream(VoiceInserter.payload(for: text), previous: voiceTyped)
                p42log("[Port42] voice typed into %@: %@", VoiceTyper.frontmostAppName ?? "another app", text)
                voiceTyped = ""
                sendAfterWords(into: nil)
                return
            }
            let target = voiceResponder ?? NSApp.keyWindow?.firstResponder
            // A terminal already holds the words as real characters: land the final read as the difference
            // from what is there, so nothing is typed twice and nothing is left half-said.
            if voiceStreamsAsEdits, !voiceStreamed.isEmpty {
                voiceStreamed = VoiceInserter.stream(VoiceInserter.payload(for: text),
                                                     previous: voiceStreamed, into: target)
                p42log("[Port42] voice heard (streamed): %@", text)
                voiceStreamed = ""
                clearVoiceNotice()
                sendAfterWords(into: target)
                return
            }
            let landed = VoiceInserter.insert(text, into: target)
            p42log("[Port42] voice heard (inserted=%d): %@", landed ? 1 : 0, text)
            // The text is now where it was typed, so the capsule goes away rather than repeating it.
            // It only speaks when the words could not land anywhere.
            if landed {
                clearVoiceNotice()
                sendAfterWords(into: target)
            } else {
                showVoiceNotice("nowhere to type: \(text)", seconds: 6)
            }
        }
        session.onModelState = { state in
            shell.voiceModel = state
            appState.voiceModelState = state      // the shell takes this callback over from AppState
            switch state {
            case .downloading, .loading: shell.voiceNotice = nil   // the state speaks for itself
            default: break
            }
        }
        session.onPermissionNeeded = { needed in
            shell.voicePermissionNeeded = needed
            if let needed {
                showVoiceNotice(needed.label, seconds: 6)
            }
        }
        voiceSession = session
        shell.voiceModel = session.model
    }

    /// Take back the space that was typed on the way into a hold, through the same seam the text is
    /// inserted on: the surface that received the space is the one that must delete it.
    ///
    /// The check is conformance, not `responds(to:)`. NSResponder declares both `insertText:` and
    /// `deleteBackward:`, so every responder claims to answer them, including ones that type nothing.
    @MainActor
    private func retractOneCharacter() {
        guard let client = NSApp.keyWindow?.firstResponder as? NSTextInputClient else { return }
        client.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
    }

    // MARK: - Input (kiosk monitors → the zoom ladder)

    private func installInputMonitors() {
        guard monitors.isEmpty else { return }
        if !displayWindow { installVoiceSession() }

        // Trackpad pinch — one rung per gesture (the latch lives in ShellState).
        let magnify = NSEvent.addLocalMonitorForEvents(matching: .magnify) { e in
            guard shell.owns(e) else { return e }   // #189: this window's events only
            shell.pinch(delta: e.magnification, began: e.phase == .began)
            return nil   // consume so webviews don't also zoom
        }

        // Cursor position → the ambient background parallax (don't consume; hover etc. still work).
        let move = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { e in
            guard shell.owns(e) else { return e }   // #189: this window's events only
            if let cv = e.window?.contentView, cv.bounds.width > 0, cv.bounds.height > 0 {
                let lp = e.locationInWindow
                shell.mouse = CGPoint(x: lp.x / cv.bounds.width, y: 1 - lp.y / cv.bounds.height)
                // The rail opens the moment the pointer reaches the edge or sweeps toward it (#192).
                if !(e.window is NSPanel) {
                    shell.pointerMoved(distanceFromRight: cv.bounds.width - lp.x, deltaX: e.deltaX,
                                       screenW: cv.bounds.width)
                }
            }
            return e
        }

        // Keys — ⌘↑/↓ ladder, Esc peels one rung. Yields to a focused text field / web port /
        // terminal first (§3.1) so typing and TUI Esc reach the surface — EXCEPT the few
        // shell-global chords (plan-working-set §B), which drive the shell from anywhere.
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Hold-to-talk is decided BEFORE the chord and editor-yield paths below, because the
            // feature exists to work while a field or a port has the keyboard. It passes every key
            // through unless a hold is actually in progress, so typing is untouched. There is one
            // voice session, so the main window's shell handles it whichever window has the keyboard.
            if !displayWindow {
                switch voice.keyDown(keyCode: e.keyCode,
                                     hasModifiers: !e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                                     isRepeat: e.isARepeat, now: e.timestamp) {
                case .consume: return nil
                case .passThrough:
                    if voice.isPending { armVoiceThreshold() }
                default: break
                }
            }
            guard shell.owns(e) else { return e }   // #189: this window's events only

            // Shell-global chords bypass the editor yield: ⌘`/⇧⌘` cycle, ⌘1…9 jump, ⌘K
            // switcher. Consumed here, so the menu's ⌘K can't double-fire.
            let f = e.modifierFlags
            if let chord = ShellState.shellGlobalChord(
                keyCode: e.keyCode, characters: e.charactersIgnoringModifiers?.lowercased(),
                command: f.contains(.command), shift: f.contains(.shift),
                option: f.contains(.option), control: f.contains(.control)) {
                switch chord {
                case .cycleForward:     shell.cycleStep(forward: true)
                case .cycleBackward:    shell.cycleStep(forward: false)
                case .jumpSpace(let i): shell.jumpToSpace(index: i)
                case .quickSwitcher:    shell.showQuickSwitcher.toggle()
                case .imagine:          shell.showImagine.toggle()
                case .galaxy:
                    withAnimation(.spring(response: 0.4)) { shell.toggleGalaxy() }
                case .zoomOut:
                    withAnimation(.spring(response: 0.4)) { shell.zoomOut() }
                }
                return nil
            }

            let isEditor = Self.responderIsEditor(e.window?.firstResponder)
            if ShellState.shouldYieldKey(isEditor: isEditor, keyCode: e.keyCode,
                                         focusedPortIsTerminal: shell.focusedPortIsTerminal,
                                         commandBoxOpen: shell.commandBoxOpen) {
                return e                                          // hand the key to the field/port
            }

            if e.keyCode == 48 {   // Tab — toggle exposé (a temporary arrange) at the space rung
                guard shell.zoom == .space else { return e }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { shell.exposeActive.toggle() }
                return nil
            }
            if e.keyCode == 53 {   // Esc — close a modal first, then exposé, else peel the ladder
                if closeTopmostModal() { return nil }
                if shell.exposeActive { withAnimation(.spring(response: 0.4)) { shell.exposeActive = false }; return nil }
                guard shell.zoom != .space else { return e }
                shell.galaxyHover = nil
                withAnimation(.spring(response: 0.4)) { shell.zoom = .space }
                return nil
            }
            guard e.modifierFlags.contains(.command) else { return e }
            if e.keyCode == 126 { shell.zoomOut(); return nil }   // ⌘↑ → up toward galaxy
            if e.keyCode == 125 { shell.zoomIn();  return nil }   // ⌘↓ → down toward focus
            return e
        }

        // A hold ends if the app stops being active or the window stops being key. While capturing, the
        // trigger swallows every key, so a release that never arrives (the app switched under the hold) used to
        // leave the keyboard dead until Port42 was quit, and looked like the app had hung (GM, Dev7).
        for name in [NSApplication.willResignActiveNotification, NSWindow.didResignKeyNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in abandonVoiceHold() }
            }
            voiceObservers.append(token)
        }

        let keyUps = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { e in
            guard !displayWindow else { return e }   // #189: voice is the main window's (above)
            voiceTimer?.invalidate(); voiceTimer = nil
            if voice.keyUp(keyCode: e.keyCode, now: e.timestamp) == .endCapture { endVoice() }
            return e
        }
        monitors = [magnify, move, keys, keyUps].compactMap { $0 }
    }

    private func removeInputMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        for o in voiceObservers { NotificationCenter.default.removeObserver(o) }
        voiceObservers = []
        voiceWatchdog?.invalidate(); voiceWatchdog = nil
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
    /// The resting shelf starts collapsed on every galaxy visit (rested worlds stay quiet).
    @State private var shelfExpanded = false
    @State private var shelfHovered: String?
    /// The world currently being dragged to reorder (backlog 3.6). nil = no drag in flight.
    @State private var draggedSpaceId: String?
    /// The tile that FOLLOWS the gap where the dragged world will land (or `endDropTarget` for the
    /// trailing gap = the New Space card). Drives the leading insertion bar; never reorders the grid
    /// mid-drag (that oscillates), so it is a highlight only.
    @State private var dropTargetId: String?
    /// The hovered tile's width, to split it into before/after halves so the cursor can pick either the
    /// gap before this tile or the gap before the next one (backlog 3.6).
    @State private var tileWidth: CGFloat = 240
    /// Sentinel target for the trailing gap (before the New Space card). `Space.reorder` appends because
    /// it matches no space id.
    static let endDropTarget = "__reorder_end__"

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
                        // The galaxy FRONT is the working set only — rested worlds live in the shelf.
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(Array(appState.workingSpaces.enumerated()), id: \.element.id) { index, space in
                                world(space, index: index)
                            }
                            newSpaceCard   // spaces are created here in the galaxy, not the Chrome
                        }
                        .frame(maxWidth: avail)
                        // Center the worlds in the viewport (scrolls only when they overflow it).
                        .frame(maxWidth: .infinity, minHeight: max(0, geo.size.height - 150), alignment: .center)
                        .padding(.vertical, 6)
                    }
                    if !appState.restingSpaces.isEmpty {
                        restShelf
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

    // MARK: the resting shelf (Rest/Wake — plan-working-set §A)

    /// A dim, collapsed row at the galaxy's bottom ("N resting") that expands to the rested
    /// worlds — each a quiet chip with its unread count. Clicking a chip wakes + enters;
    /// long-press opens the same settings card (whose slot reads "Wake" for a rested space).
    private var restShelf: some View {
        VStack(spacing: 12) {
            if shelfExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(appState.restingSpaces) { space in
                            restingChip(space)
                                .onAppear { appState.chats.load(space.id, from: appState.db) }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                }
                .frame(maxWidth: 680)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shelfExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: shelfExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(appState.restingSpaces.count) resting")
                        .font(Port42Theme.mono(10)).tracking(2)
                }
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.85))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.white.opacity(0.04), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(shelfExpanded ? "Collapse the resting shelf" : "Show resting spaces")
        }
    }

    /// One rested world: a small, still, dim orb (no animation — quiet by design) with its
    /// name and accumulated unread count. Tap = wake + enter; long-press = settings.
    private func restingChip(_ space: Space) -> some View {
        let acc = shell.accent(for: space)
        let unread = appState.chats.unread(space.id, me: appState.currentUser?.id)   // its chat's unread
        let hovered = shelfHovered == space.id
        return VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle().fill(RadialGradient(
                        gradient: Gradient(colors: [acc.opacity(hovered ? 0.45 : 0.22), acc.opacity(0.02), .clear]),
                        center: .center, startRadius: 0, endRadius: 24))
                    Circle().fill(acc.opacity(hovered ? 0.75 : 0.4)).frame(width: 14, height: 14)
                }
                .frame(width: 44, height: 44)
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(Port42Theme.monoBold(8)).foregroundStyle(Port42Theme.textPrimary)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(acc.opacity(0.35), in: Capsule())
                        .offset(x: 6, y: -2)
                }
            }
            Text(space.name.uppercased())
                .font(Port42Theme.mono(9)).tracking(1)
                .foregroundStyle(hovered ? acc : Port42Theme.textSecondary.opacity(0.8))
                .lineLimit(1)
        }
        .frame(width: 76)
        .contentShape(Rectangle())
        .onHover { h in shelfHovered = h ? space.id : (shelfHovered == space.id ? nil : shelfHovered) }
        .animation(.spring(response: 0.3), value: hovered)
        // Same arbitration as a front world: hold = settings (where the slot reads "Wake"),
        // tap = wake + enter this space.
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.45)
            .onEnded { _ in shell.settingsTarget = .space(space.id) })
        .onTapGesture {
            appState.wakeAndEnterSpace(space)
            withAnimation(.spring(response: 0.45)) { shell.zoom = .space }
        }
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
        // The trailing gap (backlog 3.6): dropping onto (or just before) the New Space card appends the
        // dragged world to the end. Its leading bar is the end-gap affordance.
        .overlay(alignment: .leading) {
            if draggedSpaceId != nil, dropTargetId == ShellGalaxyView.endDropTarget {
                RoundedRectangle(cornerRadius: 2).fill(shell.accent)
                    .frame(width: 4).padding(.vertical, 10).padding(.leading, 1)
            }
        }
        .onDrop(of: [.plainText], delegate: SpaceReorderDrop(
            targetId: ShellGalaxyView.endDropTarget, appState: appState, tileWidth: tileWidth,
            dragged: $draggedSpaceId, dropTarget: $dropTargetId))
    }

    /// Count exactly what the desktop renders: the space's tiled ports. (The space's chat lives in
    /// the top bar now, not as a port on the desktop.)
    private func portCount(_ space: Space) -> Int {
        appState.portWindows.panels.filter {
            $0.spaceId == space.id && !$0.isBackground && $0.presentation == "tiled"
        }.count
    }

    @ViewBuilder
    private func world(_ space: Space, index: Int) -> some View {
        let on = space.id == shell.spaceId   // the current space — a quiet, persistent marker
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
                // What is happening there, at a glance (#137): who needs you, who is working on what,
                // the ports running and paused, and unread chat.
                SpaceGlanceView(appState: appState, space: space, accent: acc, presence: appState.presence,
                                states: appState.portStates, chats: appState.chats)
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
        // Reorder affordance (backlog 3.6): the lifted world dims; the world it would land in front of
        // shows a bright accent bar on its leading edge. NO live array mutation, so the grid stays put
        // (mutating mid-drag reshuffles tiles under the cursor and oscillates).
        .opacity(draggedSpaceId == space.id ? 0.35 : 1)
        .overlay(alignment: .leading) {   // the gap bar is always on the leading edge (consistent, 3.6)
            if draggedSpaceId != nil, draggedSpaceId != space.id, dropTargetId == space.id {
                RoundedRectangle(cornerRadius: 2).fill(acc)
                    .frame(width: 4).padding(.vertical, 10).padding(.leading, 1)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: dropTargetId)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { tileWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in tileWidth = w }
        })
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.45)
            .onEnded { _ in shell.settingsTarget = .space(space.id) })
        .onTapGesture { shell.jumpToSpace(index: index) }
        // Drag-reorder (backlog 3.6): press + move picks up a world; the accent bar shows where it will
        // land (before OR after a tile, per cursor half, so the trailing slot is reachable); releasing
        // commits the new order (persisted sortIndex). A tap (no move) still enters; a hold opens settings.
        .onDrag {
            dropTargetId = nil
            draggedSpaceId = space.id
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                                visibility: .all) { completion in
                completion(Data(space.id.utf8), nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [.plainText], delegate: SpaceReorderDrop(
            targetId: space.id, appState: appState, tileWidth: tileWidth,
            dragged: $draggedSpaceId, dropTarget: $dropTargetId))
    }
}

/// Galaxy world drag-reorder (backlog 3.6): the cursor's half of the hovered tile picks the insertion
/// gap — left half = the gap before THIS tile, right half = the gap before the NEXT tile (or the
/// trailing end). It records only the gap (never mutates the grid, which oscillates and kills
/// performDrop) and commits on drop. `dropTarget` is always the tile FOLLOWING the gap, so the leading
/// insertion bar and the drop both land in that gap.
private struct SpaceReorderDrop: DropDelegate {
    let targetId: String
    let appState: AppState
    let tileWidth: CGFloat
    @Binding var dragged: String?
    @Binding var dropTarget: String?

    func validateDrop(info: DropInfo) -> Bool { dragged != nil && dragged != targetId }

    /// Fires continuously while hovering, so the gap tracks the cursor's before/after half live.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let d = dragged, d != targetId { dropTarget = resolvedGap(after: info.location.x > tileWidth / 2) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragged = nil; dropTarget = nil }
        guard let d = dragged, let t = dropTarget, d != t else { return false }
        appState.reorderSpaces(moving: d, to: t)   // t == endDropTarget → appends (matches no space)
        return true
    }

    /// The tile following the chosen gap: this tile (before-half), or the next working space / the end
    /// sentinel (after-half).
    private func resolvedGap(after: Bool) -> String {
        guard after else { return targetId }
        let working = appState.workingSpaces
        if let i = working.firstIndex(where: { $0.id == targetId }) {
            return (i + 1 < working.count) ? working[i + 1].id : ShellGalaxyView.endDropTarget
        }
        return targetId
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
                Button { dismiss(save: true) } label: {
                    Text("Done").font(Port42Theme.monoBold(11)).foregroundStyle(Port42Theme.bgPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(col, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help("Save and close (Return)")
                // Closing keeps what you typed, as a click outside does (GM, 2026-09-27: the only
                // button discarded the rename, so it never saved). Esc is the way to throw it away.
                Button { dismiss(save: true) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
                }.buttonStyle(.plain).help("Close (Esc discards changes)")
            }
            HStack(spacing: 12) {
                Circle().fill(col.gradient).frame(width: 46, height: 46)
                    .overlay(Text(String(c.displayName.prefix(2)).uppercased()).font(Port42Theme.monoBold(16)).foregroundStyle(.white))
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                TextField("name", text: $name)
                    .textFieldStyle(.plain).font(Port42Theme.monoBold(16)).foregroundStyle(Port42Theme.textPrimary)
                    .onSubmit { dismiss(save: true) }.onExitCommand { dismiss(save: false) }
            }

            // Every companion is a command companion now: a CLI agent in a terminal port (D7, D9).
            // TRIGGER went (nautilus 3.7): it was stored and never read. What a companion listens to
            // is its space membership and its watches (`companions.watch`).
            if c.openInTerminal {
                fieldLabel("RUNS")
                segmented(["in a port", "running"], selected: c.runsHidden ? "running" : "in a port") { v in
                    edit(c) { $0.runsHidden = v == "running" }
                    appState.setCompanionHidden(c, hidden: v == "running")
                }
            }
            fieldLabel("SYSTEM PROMPT")
            TextEditor(text: $promptDraft)
                .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary).scrollContentBackground(.hidden)
                .frame(height: 96).padding(8)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(col.opacity(0.3), lineWidth: 1))

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
                Button { dismiss(save: true) } label: {
                    Text("Done").font(Port42Theme.monoBold(11)).foregroundStyle(Port42Theme.bgPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(acc, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help("Save and close (Return)")
                // Closing keeps what you typed, as a click outside does (GM, 2026-09-27: the only
                // button discarded the rename, so it never saved). Esc is the way to throw it away.
                Button { dismiss(save: true) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
                }.buttonStyle(.plain).help("Close (Esc discards changes)")
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
            // Working directory (docs/plan-companion-cwd.md): command companions in this space run
            // here so they share one workspace (each keeps its own claude session). Unset = home,
            // with a nudge to pick one.
            VStack(alignment: .leading, spacing: 6) {
                Text("WORKING DIRECTORY").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary).tracking(2)
                HStack(spacing: 8) {
                    // Unset shows the default (home) path, dimmed; an explicit pick shows in full.
                    Text(space.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path)
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(space.workingDirectory == nil ? Port42Theme.textSecondary : Port42Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { pickWorkingDirectory(for: space) } label: {
                        Text("Choose…").font(Port42Theme.mono(11)).foregroundStyle(acc)
                    }.buttonStyle(.plain).help("Pick the directory command companions run in")
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(acc.opacity(0.35), lineWidth: 1))
                if space.workingDirectory != nil {
                    Button { appState.setSpaceWorkingDirectory(nil, spaceId: space.id) } label: {
                        Text("Clear (use home)").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
                    }.buttonStyle(.plain)
                }
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            // Displays (#189): put this space on another connected display, in a window of its own.
            let otherDisplays = appState.displaySpaces.connected().filter { !$0.isMain }
            if !otherDisplays.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DISPLAYS").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary).tracking(2)
                    ForEach(otherDisplays) { d in
                        let showing = appState.displaySpaces.map.space(on: d.id) == space.id
                        Button {
                            dismiss(save: true) {
                                if showing { appState.displaySpaces.clear(d.id) }
                                else { appState.displaySpaces.put(space.id, on: d.id) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "display")
                                Text(showing ? "Stop showing on \(d.name)" : "Show on \(d.name)")
                            }
                            .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                        }.buttonStyle(.plain)
                            .help(showing ? "Close this space's window on that display" : "Open this space on that display")
                    }
                }
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            }
            // Rest / Wake (plan-working-set §A): one slot, two states. Any working space may
            // rest — even the last one (GM call: an all-rested galaxy is an empty front).
            if space.isResting {
                Button { dismiss(save: true) { appState.wakeSpace(space) } } label: {
                    HStack(spacing: 6) { Image(systemName: "sun.max"); Text("Wake") }
                        .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                }.buttonStyle(.plain)
                    .help("Back into the working set — galaxy front, ⌘1…9, peeks")
            } else {
                Button { dismiss(save: true) { shell.restSpace(space) } } label: {
                    HStack(spacing: 6) { Image(systemName: "moon.zzz"); Text("Rest this space") }
                        .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                }.buttonStyle(.plain)
                    .help("Off the galaxy front, fully silent — nothing is lost")
            }
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

    /// Present a directory picker for the space's working directory and persist the choice.
    private func pickWorkingDirectory(for space: Space) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true   // show the "New Folder" button
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Working directory for command companions in #\(space.name)"
        if let cur = space.workingDirectory { panel.directoryURL = URL(fileURLWithPath: cur) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in appState.setSpaceWorkingDirectory(url.path, spaceId: space.id) }
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

}

// MARK: - New companion (shell-native card, every field shown; nautilus Phase 3.7)

/// The shell-native create-companion card. Every choice that matters is on the card, with no
/// "Advanced" to open (GM, 2026-09-26): which CLI and its args, whether it runs in a tile or hidden,
/// what it listens to (this space, or one port and the events that wake it), its working directory,
/// prompt and secrets. No pre-canned types: the prompt is the person's. Every companion is a CLI agent
/// in a terminal, or a custom command run headless.
struct ShellNewCompanionView: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    @State private var name = ""
    @State private var promptText = ""
    @State private var command = ""
    @State private var argsText = ""
    @State private var workingDir = ""
    @State private var cliChoice = ClaudeCodeSetup.findBinary("claude") == nil && ClaudeCodeSetup.findBinary("codex") != nil
        ? "codex" : "claude"                         // claude | codex | custom
    @State private var runs = "in a port"            // in a port | running
    @State private var listensTo = "this space"      // this space | a port
    @State private var watchedPort: String?          // udid
    @State private var watchKinds: Set<String> = ["port"]
    @State private var createError: String?
    // anim
    @State private var cardScale: CGFloat = 0.92
    @State private var cardOpacity: Double = 0
    @State private var scrimOpacity: Double = 0
    @FocusState private var nameFocused: Bool

    private var acc: Color { shell.accent }
    private var isCLI: Bool { cliChoice != "custom" }
    private var canCreate: Bool {
        guard appState.currentUser != nil, !effectiveName.isEmpty else { return false }
        if listensTo == "a port" && (watchedPort == nil || watchKinds.isEmpty) { return false }
        // A CLI carries its own command; only "custom" needs the field.
        return isCLI || !command.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var rosterNotHere: [AgentConfig] {
        let here = Set(appState.spaceCompanions.map(\.id))
        return appState.companions.filter { !here.contains($0.id) }
    }
    /// The ports of this space a companion can watch.
    private var watchablePorts: [PortPanel] {
        appState.portWindows.panels.filter { $0.spaceId == shell.spaceId }
    }
    /// What each watch choice means, in the words a person uses.
    private static let kindChoices: [(kind: String, label: String)] = [
        ("port", "its events"), ("console", "console errors and logs"), ("state", "edits"), ("chat", "its chat"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(scrimOpacity).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { dismiss() }
            ScrollView(showsIndicators: false) { card.padding(22) }
                .frame(width: 420, height: 640)
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
        VStack(alignment: .leading, spacing: 14) {
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

            label("AGENT")
            seg(["claude", "codex", "custom"], sel: cliChoice) { cliChoice = $0 }
            if !isCLI { label("COMMAND"); boxField("my-agent", $command) }
            label("ARGS"); boxField(isCLI ? "--model sonnet" : "--flag value", $argsText)

            label("RUNS")
            if isCLI {
                seg(["in a port", "running"], sel: runs) { runs = $0 }
                Text(runs == "running" ? "off the desktop, a card under Running in the rail: talk to it in its chat, show it from there or ⌘K"
                                      : "a terminal port on this desktop")
                    .font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
            } else {
                Text("headless: a custom command speaks Port42's stdio protocol, with no terminal")
                    .font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
            }

            label("LISTENS TO")
            seg(["this space", "a port"], sel: listensTo) { listensTo = $0 }
            if listensTo == "this space" {
                Text("wakes when @mentioned here, then hears plain posts in this space's chat")
                    .font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
            } else {
                portPicker
                chips
                Text("wakes when that port does one of these; replies in its chat")
                    .font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
            }

            label("WORKING DIR (blank = space cwd)"); boxField("~/project", $workingDir)
            label("SYSTEM PROMPT"); promptBox
            // Secrets are not set here (GM, 2026-09-26): an agent CLI calls APIs from its own shell, so
            // Port42's named secrets for rest.call are rarely wanted at birth. They are in its settings.

            if let createError {
                Text(createError).font(Port42Theme.mono(10)).foregroundStyle(.red.opacity(0.9))
            }
            Button { create() } label: {
                Text("Create companion").font(Port42Theme.monoBold(13)).foregroundStyle(canCreate ? .black : Port42Theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(canCreate ? acc : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).disabled(!canCreate)

            if !rosterNotHere.isEmpty {
                label("OR BRING ONE FROM ANOTHER SPACE")
                Text("it joins this space and hears it; its terminal stays where it runs")
                    .font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
                ForEach(rosterBySpace, id: \.space) { group in
                    Text(group.space).font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(group.companions) { c in
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
    }

    /// The companions not in this space, grouped under the space each is in now (by name).
    private var rosterBySpace: [(space: String, companions: [AgentConfig])] {
        var groups: [String: [AgentConfig]] = [:]
        for c in rosterNotHere {
            // The observed cache, not a query per space per redraw; it updates this view as it changes.
            let home = appState.spaces.first { s in appState.spaceAgentIds[s.id]?.contains(c.id) == true }
            groups["#" + (home?.name ?? "no space"), default: []].append(c)
        }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.displayName < $1.displayName }) }
    }

    private var portPicker: some View {
        Menu {
            ForEach(watchablePorts) { p in Button(p.title) { watchedPort = p.udid } }
        } label: {
            HStack {
                Text(watchablePorts.first { $0.udid == watchedPort }?.title ?? "choose a port in this space")
                    .font(Port42Theme.mono(12)).foregroundStyle(watchedPort == nil ? Port42Theme.textSecondary : Port42Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Port42Theme.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(acc.opacity(0.3), lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(Self.kindChoices, id: \.kind) { choice in
                let on = watchKinds.contains(choice.kind)
                Button { if on { watchKinds.remove(choice.kind) } else { watchKinds.insert(choice.kind) } } label: {
                    Text(choice.label).font(Port42Theme.mono(10)).foregroundStyle(on ? acc : Port42Theme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background((on ? acc.opacity(0.12) : Color.white.opacity(0.04)), in: Capsule())
                        .overlay(Capsule().stroke(on ? acc.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }

    private var promptBox: some View {
        TextEditor(text: $promptText).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary).scrollContentBackground(.hidden)
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

    private var effectiveName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var initials: String { effectiveName.isEmpty ? "?" : String(effectiveName.prefix(2)).uppercased() }

    private func create() {
        guard canCreate, let user = appState.currentUser else { return }
        let c = Self.makeCompanion(owner: user.id, name: effectiveName, cli: cliChoice, command: command,
                                   argsText: argsText, workingDir: workingDir, prompt: promptText,
                                   hidden: runs == "running", secrets: [])
        guard let sid = shell.spaceId else { return }
        // The same path `companions.create` takes, so what the harness proves is what this does.
        do {
            try appState.createCompanion(c, spaceId: sid, watchPort: listensTo == "a port" ? watchedPort : nil,
                                         watchKinds: Array(watchKinds))
            dismiss()
        } catch let e as BridgeError {
            createError = e.message
        } catch {
            createError = error.localizedDescription
        }
    }

    /// The companion the card describes. Pure, so what each field becomes is tested.
    static func makeCompanion(owner: String, name: String, cli: String, command: String, argsText: String,
                              workingDir: String, prompt: String, hidden: Bool, secrets: Set<String>) -> AgentConfig {
        let isCLI = cli != "custom"
        let args = argsText.split(separator: " ").map(String.init)
        func nilIfEmpty(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
        }
        var c = AgentConfig.createCommand(ownerId: owner, displayName: name,
                                          command: isCLI ? cli : command.trimmingCharacters(in: .whitespaces),
                                          args: args.isEmpty ? nil : args, workingDir: nilIfEmpty(workingDir), envVars: nil,
                                          systemPrompt: nilIfEmpty(prompt), openInTerminal: isCLI, trigger: .mentionOnly)
        c.runsHidden = isCLI && hidden
        c.secretNames = secrets.isEmpty ? nil : secrets.sorted()
        return c
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
    /// The header or query parameter a Header or Query secret goes in (#225).
    @State private var newField = ""

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
                    Text(s.placementLabel).font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
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
                Text("Query").tag(Port42AuthStore.SecretType.query)
            }.labelsHidden().pickerStyle(.menu).tint(accent)
            if SignOutSheet.needsField(newType) {
                box(newType == .header ? "header name, e.g. xi-api-key" : "parameter name, e.g. key", $newField)
            }
            secureBox("credential value", $newValue)
            HStack {
                Button("cancel") { adding = false; newName = ""; newValue = ""; newField = "" }
                    .buttonStyle(.plain).font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                Spacer()
                Button("add") { save() }
                    .buttonStyle(.plain).font(Port42Theme.monoBold(10)).foregroundStyle(accent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newValue.trimmingCharacters(in: .whitespaces).isEmpty
                              || (SignOutSheet.needsField(newType) && newField.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(8).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let field = newField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !value.isEmpty, !SignOutSheet.needsField(newType) || !field.isEmpty else { return }
        Port42AuthStore.shared.saveSecret(name: name, type: newType, value: value,
                                          field: SignOutSheet.needsField(newType) ? field : nil)
        secrets = Port42AuthStore.shared.listSecrets()
        selected.insert(name)      // auto-grant the just-created secret
        newName = ""; newValue = ""; newField = ""; adding = false
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

// MARK: - Background-as-port (Layer 0)

/// A port rendered full-bleed as the shell background. Its own dedicated webview + bridge (the
/// live desktop tile, if any, keeps its own — a webview lives in exactly one place). Non-interactive
/// and ambient: it fills the screen behind everything. The first step of "the chrome is ports too".
struct ShellBackgroundPort: View {
    /// The shell background's stable authorization identity (I1.4). One logical port, one identity,
    /// across every remount and launch.
    static let identity = "shell.background"

    let html: String
    let appState: AppState
    @State private var height: CGFloat = 0
    @State private var bridge: PortBridge

    init(html: String, appState: AppState) {
        self.html = html
        self.appState = appState
        // Its own dedicated bridge (ambient: no messageId/space), backed by the real appState so
        // port42.storage / ai / etc. resolve. A background port is a real port.
        //
        // I1.4: a fixed identity, not a heap address. There is exactly one shell background at a
        // time and this view remounts (it is the fallback path, mounted fresh from stored HTML when
        // the live background port was closed), so its grants and storage must survive a remount.
        // Space-less on purpose: the background is ambient across spaces, so its grant is global to
        // this identity rather than scoped to whichever space happened to be open.
        _bridge = State(initialValue: PortBridge(appState: appState, spaceId: nil,
                                                 stableIdentity: ShellBackgroundPort.identity))
    }

    var body: some View {
        GeometryReader { geo in
            PortView(html: html, bridge: bridge, height: $height)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
        // Re-mount if the chosen background changes (new HTML → new surface).
        .id(html.hashValue)
    }
}

/// A galaxy tile's glance at its space (#137). Observes the stores the glance is built from, so it
/// follows presence, terminals and unread live, as the rail and the port cards do.
struct SpaceGlanceView: View {
    let appState: AppState
    let space: Space
    let accent: Color
    @ObservedObject var presence: ChatPresenceStore
    @ObservedObject var states: PortStateStore
    @ObservedObject var chats: PortChatStore

    var body: some View {
        let g = appState.spaceGlance(space)
        VStack(spacing: 4) {
            if g.needsYou {
                HStack(spacing: 5) {
                    Circle().fill(Port42Theme.error).frame(width: 7, height: 7)
                    Text(Self.attentionLine(g)).lineLimit(1).truncationMode(.tail)
                }
                .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.error)
            }
            ForEach(g.working.prefix(2), id: \.self) { line in
                Text(line).font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textPrimary.opacity(0.8))
                    .lineLimit(1).truncationMode(.tail)
            }
            if g.working.count > 2 {
                Text("+\(g.working.count - 2) more working").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary)
            }
            HStack(spacing: 6) {
                Text(Self.portsLine(g)).foregroundStyle(Port42Theme.textSecondary)
                if g.unread > 0 {
                    Text(g.unread > 99 ? "99+ unread" : "\(g.unread) unread").foregroundStyle(accent)
                }
            }
            .font(Port42Theme.mono(10))
        }
        .frame(maxWidth: .infinity)
    }

    /// "wise-hare: needs permission to use Bash", or "2 need you" when more than one does.
    static func attentionLine(_ g: SpaceGlance) -> String {
        let all = g.waiting + g.failed.map { "\($0) failed" }
        return all.count == 1 ? all[0] : "\(all.count) need you: " + all.joined(separator: ", ")
    }

    /// "3 running · 1 paused", or "no ports".
    static func portsLine(_ g: SpaceGlance) -> String {
        if g.running == 0 && g.paused == 0 { return "no ports" }
        return g.paused > 0 ? "\(g.running) running · \(g.paused) paused" : "\(g.running) running"
    }
}
