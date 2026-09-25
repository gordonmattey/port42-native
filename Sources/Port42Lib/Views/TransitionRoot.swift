import SwiftUI
import AVKit

// MARK: - Root screen selection (pure)

/// Which screen the app root shows. Extracted from `TransitionRoot.body` so the truth table is
/// testable headlessly (the views, videos and dive overlays are not).
///
/// `none` is the gap before the boot cinematic has finished on a fresh install — the cinematic
/// overlay covers it.
public enum RootScreen: Equatable {
    case lock
    case shell
    case setup
    case none

    /// The root's only branch.
    public static func decide(showDreamscape: Bool,
                              isSetupComplete: Bool,
                              bootCinematicDone: Bool) -> RootScreen {
        if showDreamscape { return .lock }
        if isSetupComplete { return .shell }
        if bootCinematicDone { return .setup }
        return .none
    }

    /// Whether the pre-boot cinematic plays at LAUNCH.
    ///
    /// It belongs to a FIRST BOOT and nothing else: with no identity there is no lock screen to
    /// launch it from (first boot skips it to kill the dreamscape loop), so the root has to. A
    /// locked or returning launch already has an identity and goes to the lock screen or straight
    /// to the shell.
    ///
    /// Whoever answers `true` here MUST leave `bootCinematicDone` false until the cinematic
    /// finishes, or `decide` returns `.setup` and the boot terminal renders under the video.
    public static func playsBootCinematicAtLaunch(hasIdentity: Bool, isSetupComplete: Bool) -> Bool {
        !hasIdentity && !isSetupComplete
    }
}

// MARK: - Transition Root (shared between Port42 and Port42B)

public struct TransitionRoot: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    @State private var isKeyWindow = false
    @State private var nsWindow: NSWindow? = nil
    @State private var prevSetupComplete = false
    @State private var diveProgress: CGFloat = 0.0  // 0 = surface, 1 = submerged
    @State private var isDiving = false
    @State private var showDolphinProtocol = false
    @State private var showBootCinematic = false
    @State private var bootCinematicDone = false
    @State private var launchRevealProgress: CGFloat = 1.0  // 1 = hidden, 0 = revealed
    @State private var onboardingReveal: CGFloat = 0.0      // black cover over the setup → shell swap
    /// 1 = not yet materialized, 0 = settled. The focused chat grows and fades UP out of the
    /// black rather than being switched on under it. Scale + opacity only: a blur over a live
    /// surface forces offscreen rendering, which this shell cannot afford.
    @State private var onboardingMaterialize: CGFloat = 0.0

    /// The dreamscape video plays behind the LOCK screen and through a dive. The boot terminal
    /// (name/auth/consent) runs with NO video behind it — the terminal is the whole surface.
    private var showDreamscapeVideo: Bool {
        appState.showDreamscape || isDiving
    }

    private var rootScreen: RootScreen {
        RootScreen.decide(showDreamscape: appState.showDreamscape,
                          isSetupComplete: appState.isSetupComplete,
                          bootCinematicDone: bootCinematicDone)
    }

    @ViewBuilder
    private var rootContent: some View {
        switch rootScreen {
        case .lock:
            LockScreenView()
        case .shell:
            // The shell IS the app (classic ContentView retired).
            ShellView(appState: appState)
        case .setup:
            // Black plate: with the dreamscape video gone, the boot terminal needs its own ground.
            ZStack {
                Color.black.ignoresSafeArea()
                SetupView()
            }
        case .none:
            EmptyView()
        }
    }

    public var body: some View {
        ZStack {
            // Shared dreamscape video background (lock screen / dive only)
            if showDreamscapeVideo {
                DreamscapeVideoLayer()
                    .ignoresSafeArea()

                Color.black.opacity(0.3)
                    .ignoresSafeArea()
            }

            // The actual content (renders underneath the dive overlay).
            // Lock screen stays until unlock() clears showDreamscape at peak opacity.
            // The materialize values are NEUTRAL (0) outside first-run, and applied
            // unconditionally so the modifier chain never changes the content's identity.
            rootContent
                .scaleEffect(1 + 0.05 * onboardingMaterialize)
                .opacity(1 - onboardingMaterialize)

            // Full-screen dive overlay (blur + zoom + tint on top of everything)
            if isDiving {
                Color(red: 0.0, green: 0.15, blue: 0.3)
                    .ignoresSafeArea()
                    .opacity(diveProgress * 0.7)
                    .allowsHitTesting(false)

                // Frosted glass effect
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .opacity(diveProgress)
                    .allowsHitTesting(false)
            }

            // First-run reveal: black over the setup → shell swap, fading off the focused chat.
            if onboardingReveal > 0 {
                Color.black
                    .ignoresSafeArea()
                    .opacity(onboardingReveal)
                    .allowsHitTesting(false)
            }

            // Launch reveal overlay (blue flash before content appears)
            if launchRevealProgress > 0 {
                Color(red: 0.0, green: 0.15, blue: 0.3)
                    .ignoresSafeArea()
                    .opacity(launchRevealProgress)
                    .allowsHitTesting(false)
            }

            // Dolphin Protocol cinematic overlay (manual trigger from settings/lock screen)
            if showDolphinProtocol {
                DolphinProtocolView(isPresented: $showDolphinProtocol)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // Boot cinematic (fresh start only, skips BIOS since SetupView has its own)
            if showBootCinematic {
                DolphinProtocolView(isPresented: $showBootCinematic, skipBios: true)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dolphinProtocolRequested)) { _ in
            if !appState.isSetupComplete {
                withAnimation(.easeIn(duration: 0.5)) {
                    showBootCinematic = true
                }
            } else {
                withAnimation(.easeIn(duration: 0.5)) {
                    showDolphinProtocol = true
                }
            }
        }
        .onChange(of: showBootCinematic) { _, newValue in
            NSLog("[TransitionRoot] showBootCinematic changed to %d, bootCinematicDone=%d, showDreamscape=%d", newValue ? 1 : 0, bootCinematicDone ? 1 : 0, appState.showDreamscape ? 1 : 0)
            if !newValue {
                bootCinematicDone = true
                appState.showDreamscape = false
                NSLog("[TransitionRoot] Set bootCinematicDone=true, showDreamscape=false")
            }
        }
        .onAppear {
            // FIRST BOOT plays the pre-boot cinematic from HERE. It used to hang off the lock
            // screen's `diveIn()`, which first boot no longer renders, so nothing posted
            // `.dolphinProtocolRequested` and fresh installs dropped straight into the BIOS.
            // `bootCinematicDone` stays FALSE across it (`decide` → `.none`, the overlay covers
            // the gap); the `showBootCinematic` onChange flips it when the cinematic dismisses.
            // Every other launch (locked or returning) has already satisfied the flag.
            if RootScreen.playsBootCinematicAtLaunch(hasIdentity: appState.currentUser != nil,
                                                     isSetupComplete: appState.isSetupComplete) {
                showBootCinematic = true
            } else {
                bootCinematicDone = true
            }
            // Returning user: resize window while covered by launch overlay, then reveal.
            // Call unlock() after the animation so port windows appear (same gate as post-lock reveal).
            if appState.isSetupComplete && !appState.showDreamscape {
                restoreWindowFrame()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.8)) {
                        launchRevealProgress = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        appState.unlock()
                    }
                }
            } else {
                launchRevealProgress = 0.0
            }
        }
        .onChange(of: appState.isSetupComplete) { _, newValue in
            if newValue && !prevSetupComplete {
                // FIRST RUN: hold the setup transition's BLACK across the swap and fade it off
                // Echo's focused terminal. No dive (its blue tint belongs to lock/unlock).
                if appState.isOnboarding {
                    onboardingReveal = 1.0
                    onboardingMaterialize = 1.0
                    // Hold the black while the shell mounts, the focus lands and the agent CLI
                    // draws, then reveal it FAST. GM, 2026-09-25: the pause is wanted, a slow reveal
                    // is not (a live terminal scaling over seconds reads as a glitch).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation(.easeOut(duration: 0.35)) { onboardingReveal = 0.0 }
                        withAnimation(.easeOut(duration: 0.5)) { onboardingMaterialize = 0.0 }
                    }
                } else {
                    // Simple fade transition
                    isDiving = true
                    withAnimation(.easeIn(duration: 0.5)) { diveProgress = 1.0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation(.easeOut(duration: 0.8)) { diveProgress = 0.0 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { isDiving = false }
                    }
                }
            }
            prevSetupComplete = newValue
        }
        .onAppear {
            prevSetupComplete = appState.isSetupComplete
        }
        .onReceive(NotificationCenter.default.publisher(for: .diveRequested)) { _ in
            startDiveTransition()
        }
        .background(WindowRefAccessor { w in nsWindow = w })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let w = nsWindow, note.object as? NSWindow == w { isKeyWindow = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if let w = nsWindow, note.object as? NSWindow == w { isKeyWindow = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .handleDeepLink)) { note in
            if let url = note.object as? URL {
                handleDeepLink(url)
            }
        }
    }

    private func startDiveTransition() {
        isDiving = true
        withAnimation(.easeIn(duration: 2.0)) {
            diveProgress = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Restore main window frame and port panels together at peak opacity
            restoreWindowFrame()
            appState.unlock()
            withAnimation(.easeOut(duration: 1.2)) {
                diveProgress = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                isDiving = false
            }
        }
    }

    private func restoreWindowFrame() {
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey }) else { return }
        // Re-apply the shell window presentation after every unlock/dive transition (which
        // otherwise resets the frame + presentationOptions). Fullscreen takeover is OPT-IN:
        // with it off, the shell restores to its remembered windowed frame.
        ShellMode.applyShellWindow(to: window)
    }

    /// The deep-link door stays; what came through it is gone. `port42://agent` recipes went with LLM
    /// companions, and `port42://space` invites rode the messaging hub (nautilus Phase 1 step 4).
    /// Phase 4 routes the per-port invite (D10) through here.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "port42" else { return }
        NSLog("[Port42] Unhandled deep link: %@", url.host ?? "nil")
    }
}

// MARK: - Deep Link Notification

public extension Notification.Name {
    static let handleDeepLink = Notification.Name("Port42HandleDeepLink")
}
