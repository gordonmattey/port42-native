import SwiftUI
import AVKit

// MARK: - Transition Root (shared between Port42 and Port42B)

public struct TransitionRoot: View {
    @ObservedObject var appState: AppState
    let useBreakoutVideo: Bool

    public init(appState: AppState, useBreakoutVideo: Bool = true) {
        self.appState = appState
        self.useBreakoutVideo = useBreakoutVideo
    }

    @State private var transitionPhase: TransitionPhase = .none
    @State private var prevSetupComplete = false
    @State private var diveProgress: CGFloat = 0.0  // 0 = surface, 1 = submerged
    @State private var isDiving = false
    @State private var showDolphinProtocol = false
    @State private var showBootCinematic = false
    @State private var bootCinematicDone = false
    @State private var launchRevealProgress: CGFloat = 1.0  // 1 = hidden, 0 = revealed
    @State private var preWarmBreakoutVideo = false  // Mount video view hidden to avoid resize glitch

    private var showDreamscapeVideo: Bool {
        appState.showDreamscape || isDiving || (!appState.isSetupComplete && transitionPhase == .none)
    }

    enum TransitionPhase {
        case none
        case playingVideo  // aquarium breakout video playing
        case fadingOut     // video fading out to reveal aquarium
    }

    public var body: some View {
        ZStack {
            // Shared dreamscape video background (only during dreamscape or setup)
            if showDreamscapeVideo {
                DreamscapeVideoLayer()
                    .ignoresSafeArea()

                Color.black.opacity(0.3)
                    .ignoresSafeArea()
            }

            // The actual content (renders underneath the dive overlay)
            // Lock screen stays until unlock() clears showDreamscape at peak opacity
            if appState.showDreamscape {
                LockScreenView()
            } else if transitionPhase != .none || (appState.isSetupComplete && transitionPhase == .none) {
                ContentView()
            } else if !appState.showDreamscape && bootCinematicDone {
                SetupView()
            }

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
            if appState.isSetupComplete || appState.showDreamscape {
                bootCinematicDone = true
            }
            // Returning user: blue flash then reveal
            if appState.isSetupComplete && !appState.showDreamscape {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.8)) {
                        launchRevealProgress = 0.0
                    }
                }
            } else {
                launchRevealProgress = 0.0
            }
        }
        .onChange(of: appState.isSetupComplete) { _, newValue in
            if newValue && !prevSetupComplete {
                if useBreakoutVideo {
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
        .onReceive(NotificationCenter.default.publisher(for: .enterAquariumRequested)) { _ in
            startEnterAquariumTransition()
        }
        .onChange(of: appState.activeSwimSession != nil) { _, hasSession in
            if hasSession && !appState.isSetupComplete && useBreakoutVideo {
                preWarmBreakoutVideo = true
            }
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
            appState.unlock()
            withAnimation(.easeOut(duration: 1.2)) {
                diveProgress = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                isDiving = false
            }
        }
    }

    private func startEnterAquariumTransition() {
        isDiving = true
        withAnimation(.easeIn(duration: 1.0)) {
            diveProgress = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            appState.isSetupComplete = true
        }
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

        case "channel":
            guard let invite = ChannelInvite.parse(url: url) else {
                NSLog("[Port42] Failed to parse channel invite: %@", url.absoluteString)
                return
            }
            appState.joinChannelFromInvite(invite)

        case "openclaw":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let inviteParam = components?.queryItems?.first(where: { $0.name == "invite" })?.value {
                NSLog("[Port42] OpenClaw deep link with invite: %@", inviteParam)
                if let channel = appState.currentChannel {
                    appState.openClawChannel = channel
                    appState.showOpenClawSheet = true
                }
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
