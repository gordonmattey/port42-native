import SwiftUI
import AVKit

// MARK: - Root screen selection (pure)

/// Which screen the app root shows. Extracted from `TransitionRoot.body` so the truth table is
/// testable headlessly (the views, videos and dive overlays are not).
///
/// `shell` covers the mid-transition frame too: the breakout video is an OVERLAY composited on
/// top of the shell, not a screen of its own, so the shell must already be mounted under it.
/// `none` is the gap before the boot cinematic has finished on a fresh install — the cinematic
/// overlay covers it.
public enum RootScreen: Equatable {
    case lock
    case shell
    case setup
    case none

    /// The root's only branch. `transitionPlaying` = the breakout video is up.
    public static func decide(showDreamscape: Bool,
                              isSetupComplete: Bool,
                              transitionPlaying: Bool,
                              bootCinematicDone: Bool) -> RootScreen {
        if showDreamscape { return .lock }
        if transitionPlaying || isSetupComplete { return .shell }
        if bootCinematicDone { return .setup }
        return .none
    }
}

// MARK: - Transition Root (shared between Port42 and Port42B)

public struct TransitionRoot: View {
    @ObservedObject var appState: AppState
    let useBreakoutVideo: Bool

    public init(appState: AppState, useBreakoutVideo: Bool = true) {
        self.appState = appState
        self.useBreakoutVideo = useBreakoutVideo
    }

    @State private var isKeyWindow = false
    @State private var nsWindow: NSWindow? = nil
    @State private var transitionPhase: TransitionPhase = .none
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
    @State private var preWarmBreakoutVideo = false  // Mount video view hidden to avoid resize glitch

    /// The dreamscape video plays behind the LOCK screen and through a dive. The boot terminal
    /// (name/auth/consent) runs with NO video behind it — the terminal is the whole surface.
    private var showDreamscapeVideo: Bool {
        appState.showDreamscape || isDiving
    }

    private var rootScreen: RootScreen {
        RootScreen.decide(showDreamscape: appState.showDreamscape,
                          isSetupComplete: appState.isSetupComplete,
                          transitionPlaying: transitionPhase != .none,
                          bootCinematicDone: bootCinematicDone)
    }

    enum TransitionPhase {
        case none
        case playingVideo  // aquarium breakout video playing
        case fadingOut     // video fading out to reveal aquarium
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

            // Pre-warm breakout video (hidden, sized to window so no resize glitch)
            if useBreakoutVideo && preWarmBreakoutVideo && transitionPhase == .none {
                AquariumBreakoutView(onFinished: {}, playDelay: 999999)
                    .ignoresSafeArea()
                    .opacity(0)
                    .allowsHitTesting(false)
            }

            // Aquarium breakout video overlay
            if useBreakoutVideo && (transitionPhase == .playingVideo || transitionPhase == .fadingOut) {
                AquariumBreakoutView(onFinished: {
                    // Video ended, blur out
                    withAnimation(.easeIn(duration: 0.8)) {
                        diveProgress = 1.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        // Resize to sidebar width while fully covered by dive overlay
                        restoreWindowFrame()
                        // Reveal port windows (panelsVisible) — same gate as the post-lock
                        // and returning-user reveals. Without this, fresh onboarding never
                        // sets panelsVisible, so chat-port windows never open.
                        appState.unlock()
                        transitionPhase = .none
                        withAnimation(.easeOut(duration: 1.0)) {
                            diveProgress = 0.0
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            isDiving = false
                        }
                    }
                }, playDelay: 0.6)
                .ignoresSafeArea()
                .transition(.opacity)
            }

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
            // Nothing gates the setup terminal at launch: first boot goes straight to the BIOS,
            // and every other launch (locked or returning) already satisfied this. The flag now
            // only matters for the boot cinematic reached from the lock screen mid-session.
            bootCinematicDone = true
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
                // the focused chat. No dive (its blue tint belongs to lock/unlock) and no
                // breakout video — that moves onto the first zoom-out to open water.
                if appState.isOnboarding {
                    onboardingReveal = 1.0
                    onboardingMaterialize = 1.0
                    // Hold the black long enough for the shell to mount and the chat focus to
                    // land, then lift it while the chat settles up into place — the two overlap,
                    // so it reads as the port materializing, not a screen being switched on.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        withAnimation(.easeOut(duration: 0.55)) { onboardingReveal = 0.0 }
                        withAnimation(.easeOut(duration: 1.2)) { onboardingMaterialize = 0.0 }
                    }
                } else if useBreakoutVideo {
                    startBreakoutTransition()
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
        .onChange(of: appState.currentSpace?.type == "direct") { _, hasSession in
            if hasSession && !appState.isSetupComplete && useBreakoutVideo {
                preWarmBreakoutVideo = true
            }
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

    private func startBreakoutTransition() {
        isDiving = true
        withAnimation(.easeIn(duration: 0.8)) {
            diveProgress = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            transitionPhase = .playingVideo
            withAnimation(.easeOut(duration: 0.6)) {
                diveProgress = 0.0
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "port42" else { return }

        switch url.host {
        case "agent":
            do {
                let invite = try AgentInvite.parse(link: url.absoluteString)
                guard let user = appState.currentUser else {
                    NSLog("[Port42] Cannot add invited agent: no current user")
                    return
                }
                let agent = AgentConfig.createLLM(
                    ownerId: user.id,
                    displayName: invite.displayName,
                    systemPrompt: invite.systemPrompt,
                    provider: invite.provider,
                    model: invite.model,
                    trigger: .mentionOnly
                )
                appState.addCompanion(agent)
                NSLog("[Port42] Added invited agent: %@", invite.displayName)
            } catch {
                NSLog("[Port42] Failed to parse agent invite: %@", error.localizedDescription)
            }

        case "space":
            guard let invite = SpaceInvite.parse(url: url) else {
                NSLog("[Port42] Failed to parse space invite: %@", url.absoluteString)
                return
            }
            // If invite contains an encryption key it's an agent invite — show connect sheet
            if invite.encryptionKey != nil {
                let space = Space.create(name: invite.spaceName)
                appState.agentConnectSpace = space
                appState.agentConnectInviteURL = url.absoluteString
                appState.showAgentConnectSheet = true
            } else {
                appState.joinSpaceFromInvite(invite)
            }

        case "openclaw":
            let outerComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let inviteParam = outerComponents?.queryItems?.first(where: { $0.name == "invite" })?.value {
                NSLog("[Port42] Agent deep link with invite: %@", inviteParam)
                // Parse space name from invite URL (works with both port42:// and https:// formats)
                let innerComponents = URLComponents(string: inviteParam)
                let items = innerComponents?.queryItems ?? []
                let dict = Dictionary(items.compactMap { i in i.value.map { (i.name, $0) } },
                                      uniquingKeysWith: { _, last in last })
                let spaceName = dict["name"] ?? "space"
                let space = Space.create(name: spaceName)
                appState.agentConnectSpace = space
                appState.agentConnectInviteURL = inviteParam
                appState.showAgentConnectSheet = true
            }

        default:
            NSLog("[Port42] Unknown deep link type: %@", url.host ?? "nil")
        }
    }
}

// MARK: - Video Preloader

public final class BreakoutVideoPreloader {
    public static let shared = BreakoutVideoPreloader()

    public private(set) var asset: AVAsset?
    public private(set) var thumbnail: NSImage?
    public private(set) var videoURL: URL?

    public func preload() {
        guard asset == nil else { return }

        let url: URL? = {
            if let resourceBundle = Bundle.main.url(forResource: "Port42_Port42Lib", withExtension: "bundle"),
               let bundle = Bundle(url: resourceBundle) {
                return bundle.url(forResource: "TheAquariumsDoorIsOpen", withExtension: "mp4")
            }
            return Bundle.main.url(forResource: "TheAquariumsDoorIsOpen", withExtension: "mp4")
        }()

        guard let url else {
            NSLog("[Port42] TheAquariumsDoorIsOpen.mp4 not found for preload")
            return
        }

        videoURL = url
        let avAsset = AVAsset(url: url)
        asset = avAsset

        avAsset.loadTracks(withMediaType: .video) { [weak self] _, _ in
            let generator = AVAssetImageGenerator(asset: avAsset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1920, height: 1080)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
                if let cgImage {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    DispatchQueue.main.async {
                        self?.thumbnail = nsImage
                        NSLog("[Port42] Breakout video preloaded with thumbnail")
                    }
                }
            }
        }
    }
}

// MARK: - Aquarium Breakout Video

public struct AquariumBreakoutView: NSViewRepresentable {
    let onFinished: () -> Void
    var playDelay: Double = 0.0

    public init(onFinished: @escaping () -> Void, playDelay: Double = 0.0) {
        self.onFinished = onFinished
        self.playDelay = playDelay
    }

    public func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspectFill

        let preloader = BreakoutVideoPreloader.shared
        guard let url = preloader.videoURL ?? findVideoURL() else {
            NSLog("[Port42] TheAquariumsDoorIsOpen.mp4 not found in any bundle")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                onFinished()
            }
            return playerView
        }

        if let thumb = preloader.thumbnail {
            let imageView = NSImageView(image: thumb)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.frame = playerView.bounds
            imageView.autoresizingMask = [.width, .height]
            playerView.addSubview(imageView)
            context.coordinator.posterView = imageView
        }

        let item: AVPlayerItem
        if let asset = preloader.asset {
            item = AVPlayerItem(asset: asset)
        } else {
            item = AVPlayerItem(url: url)
        }

        let player = AVPlayer(playerItem: item)
        playerView.player = player

        context.coordinator.observation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            onFinished()
        }
        context.coordinator.player = player

        if playDelay > 0 {
            player.pause()
            DispatchQueue.main.asyncAfter(deadline: .now() + playDelay) {
                player.play()
                context.coordinator.posterView?.removeFromSuperview()
            }
        } else {
            player.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                context.coordinator.posterView?.removeFromSuperview()
            }
        }

        return playerView
    }

    public func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator() }

    private func findVideoURL() -> URL? {
        if let resourceBundle = Bundle.main.url(forResource: "Port42_Port42Lib", withExtension: "bundle"),
           let bundle = Bundle(url: resourceBundle) {
            return bundle.url(forResource: "TheAquariumsDoorIsOpen", withExtension: "mp4")
        }
        return Bundle.main.url(forResource: "TheAquariumsDoorIsOpen", withExtension: "mp4")
    }

    public class Coordinator: NSObject {
        var player: AVPlayer?
        var observation: NSObjectProtocol?
        var posterView: NSImageView?

        deinit {
            if let observation {
                NotificationCenter.default.removeObserver(observation)
            }
            player?.pause()
        }
    }
}

// MARK: - Deep Link Notification

public extension Notification.Name {
    static let handleDeepLink = Notification.Name("Port42HandleDeepLink")
}
