import SwiftUI
import AppKit
import AVKit
import Port42Lib

@main
struct Port42App: App {
    @StateObject private var appState: AppState

    init() {
        do {
            let db = try DatabaseService()
            _appState = StateObject(wrappedValue: AppState(db: db))
        } catch {
            fatalError("[Port42] Failed to initialize database: \(error)")
        }

        // Set app icon from bundled .icns
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: icnsURL) {
            NSApplication.shared.applicationIconImage = icon
        }

        // Preload breakout video so it's ready instantly
        BreakoutVideoPreloader.shared.preload()
    }

    var body: some Scene {
        WindowGroup {
            TransitionRoot(appState: appState)
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 600)
                .background(Port42Theme.bgPrimary)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Channel") {
                    NotificationCenter.default.post(
                        name: .newChannelRequested, object: nil
                    )
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

// MARK: - Transition Root

struct TransitionRoot: View {
    @ObservedObject var appState: AppState
    @State private var transitionPhase: TransitionPhase = .none
    @State private var prevSetupComplete = false
    @State private var diveProgress: CGFloat = 0.0  // 0 = surface, 1 = submerged
    @State private var isDiving = false

    private var showDreamscapeVideo: Bool {
        appState.showDreamscape || isDiving || (!appState.isSetupComplete && transitionPhase == .none)
    }

    enum TransitionPhase {
        case none
        case playingVideo  // aquarium breakout video playing
        case fadingOut     // video fading out to reveal aquarium
    }

    var body: some View {
        ZStack {
            // Shared dreamscape video background (only during dreamscape or setup)
            if showDreamscapeVideo {
                DreamscapeVideoLayer()
                    .ignoresSafeArea()

                Color.black.opacity(0.3)
                    .ignoresSafeArea()
            }

            // The actual content (renders underneath the dive overlay)
            if appState.showDreamscape && !isDiving {
                LockScreenView()
            } else if transitionPhase != .none || (appState.isSetupComplete && transitionPhase == .none) {
                ContentView()
            } else if !appState.showDreamscape {
                SetupView()
            }

            // Aquarium breakout video overlay
            if transitionPhase == .playingVideo || transitionPhase == .fadingOut {
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
        }
        .onChange(of: appState.isSetupComplete) { _, newValue in
            if newValue && !prevSetupComplete {
                startBreakoutTransition()
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
    }

    private func startDiveTransition() {
        isDiving = true

        // Phase 1: Blur everything (dive under the surface)
        withAnimation(.easeIn(duration: 2.0)) {
            diveProgress = 1.0
        }

        // Phase 2: At peak blur, switch content underneath
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            appState.unlock()

            // Phase 3: Unblur to reveal the new content
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
        // Blur everything first
        withAnimation(.easeIn(duration: 1.0)) {
            diveProgress = 1.0
        }
        // At peak blur, trigger the setup complete which starts breakout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            appState.isSetupComplete = true
        }
    }

    private func startBreakoutTransition() {
        isDiving = true
        // Blur into the video
        withAnimation(.easeIn(duration: 0.8)) {
            diveProgress = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            transitionPhase = .playingVideo
            // Unblur to reveal the video
            withAnimation(.easeOut(duration: 0.6)) {
                diveProgress = 0.0
            }
        }
    }
}

// MARK: - Video Preloader

final class BreakoutVideoPreloader {
    static let shared = BreakoutVideoPreloader()

    private(set) var asset: AVAsset?
    private(set) var thumbnail: NSImage?
    private(set) var videoURL: URL?

    func preload() {
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

        // Preload tracks so playback starts instantly
        avAsset.loadTracks(withMediaType: .video) { [weak self] _, _ in
            // Generate a thumbnail from the first frame
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

struct AquariumBreakoutView: NSViewRepresentable {
    let onFinished: () -> Void
    var playDelay: Double = 0.0

    func makeNSView(context: Context) -> AVPlayerView {
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

        // Show thumbnail as poster frame while waiting
        if let thumb = preloader.thumbnail {
            let imageView = NSImageView(image: thumb)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.frame = playerView.bounds
            imageView.autoresizingMask = [.width, .height]
            playerView.addSubview(imageView)
            context.coordinator.posterView = imageView
        }

        // Use preloaded asset if available for faster start
        let item: AVPlayerItem
        if let asset = preloader.asset {
            item = AVPlayerItem(asset: asset)
        } else {
            item = AVPlayerItem(url: url)
        }

        let player = AVPlayer(playerItem: item)
        playerView.player = player

        // Observe when video ends
        context.coordinator.observation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            onFinished()
        }
        context.coordinator.player = player

        // Delay playback so unblur finishes before video starts
        if playDelay > 0 {
            player.pause()
            DispatchQueue.main.asyncAfter(deadline: .now() + playDelay) {
                player.play()
                // Remove poster once playing
                context.coordinator.posterView?.removeFromSuperview()
            }
        } else {
            player.play()
            // Remove poster once playing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                context.coordinator.posterView?.removeFromSuperview()
            }
        }

        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func findVideoURL() -> URL? {
        if let resourceBundle = Bundle.main.url(forResource: "Port42_Port42Lib", withExtension: "bundle"),
           let bundle = Bundle(url: resourceBundle) {
            return bundle.url(forResource: "TheAquariumsDoorIsOpen", withExtension: "mp4")
        }
        return Bundle.main.url(forResource: "TheAquariumsDoorIsOpen", withExtension: "mp4")
    }

    class Coordinator: NSObject {
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
