import SwiftUI
import AppKit
import AVKit
import Port42Lib
import Sparkle

/// Intercept port42:// URLs at the AppDelegate level so SwiftUI doesn't
/// open a new window for each deep link.
class Port42AppDelegate: NSObject, NSApplicationDelegate {
    /// Sparkle updater controller for automatic + manual update checks
    private(set) var updaterController: SPUStandardUpdaterController!

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Initialize Sparkle (starts automatic update checks)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        NSLog("[Port42] Sparkle updater initialized, canCheckForUpdates=%d", updaterController.updater.canCheckForUpdates ? 1 : 0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupCustomCursor()
        NSLog("[Port42] Sparkle feedURL=%@", updaterController.updater.feedURL?.absoluteString ?? "nil")

        // Listen for manual update check requests from settings
        NotificationCenter.default.addObserver(forName: .checkForUpdatesRequested, object: nil, queue: .main) { [weak self] _ in
            NSLog("[Port42] Check for updates requested via notification")
            self?.updaterController.checkForUpdates(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Dismiss SwiftUI sheets (they block termination)
        NotificationCenter.default.post(name: .dismissAllSheets, object: nil)
        // Also dismiss any AppKit-level attached sheets
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
        return .terminateNow
    }

    private func setupCustomCursor() {
        let size = NSSize(width: 24, height: 24)
        let green = NSColor(red: 0.0, green: 1.0, blue: 0.255, alpha: 1.0) // #00FF41
        let image = NSImage(size: size, flipped: false) { rect in
            // Outer glow (stroke only)
            let glowOuter = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            green.withAlphaComponent(0.1).setStroke()
            glowOuter.lineWidth = 4
            glowOuter.stroke()

            // Inner glow (stroke only)
            let glowInner = NSBezierPath(ovalIn: rect.insetBy(dx: 4.5, dy: 4.5))
            green.withAlphaComponent(0.15).setStroke()
            glowInner.lineWidth = 2
            glowInner.stroke()

            // Circle stroke
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
            green.withAlphaComponent(0.9).setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
        Port42Cursor.shared = cursor
        swizzleArrowCursor()
    }

    private func swizzleArrowCursor() {
        guard let originalMethod = class_getClassMethod(NSCursor.self, #selector(getter: NSCursor.arrow)),
              let swizzledMethod = class_getClassMethod(Port42Cursor.self, #selector(Port42Cursor.port42Arrow)) else { return }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        NotificationCenter.default.post(name: .handleDeepLink, object: url)
    }
}

class Port42Cursor: NSObject {
    static var shared: NSCursor = NSCursor.arrow

    @objc class func port42Arrow() -> NSCursor {
        return Port42Cursor.shared
    }
}

// MARK: - Sparkle Delegate

extension Port42AppDelegate: SPUUpdaterDelegate {
    /// Gracefully stop gateway before bundle replacement
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        NSLog("[Port42] Sparkle will install update %@, stopping gateway...", item.displayVersionString)
        GatewayProcess.shared.stop()
    }
}

extension Notification.Name {
    static let handleDeepLink = Notification.Name("Port42HandleDeepLink")
}

@main
struct Port42App: App {
    @NSApplicationDelegateAdaptor(Port42AppDelegate.self) var delegate
    @StateObject private var appState: AppState

    init() {
        do {
            // Use a separate data directory when running as a test peer
            let subdir = ProcessInfo.processInfo.environment["PORT42_DATA_DIR"] ?? "Port42"
            let db = try DatabaseService(subdirectory: subdir)
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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    NotificationCenter.default.post(name: .checkForUpdatesRequested, object: nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Channel") {
                    NotificationCenter.default.post(
                        name: .newChannelRequested, object: nil
                    )
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Quick Switcher") {
                    NotificationCenter.default.post(
                        name: .quickSwitcherRequested, object: nil
                    )
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Help") {
                    NotificationCenter.default.post(
                        name: .helpRequested, object: nil
                    )
                }
                .keyboardShortcut("/", modifiers: .command)
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
    @State private var showDolphinProtocol = false
    @State private var showBootCinematic = false
    @State private var bootCinematicDone = false

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
            } else if !appState.showDreamscape && bootCinematicDone {
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
                // Fresh user, show cinematic then setup BIOS
                withAnimation(.easeIn(duration: 0.5)) {
                    showBootCinematic = true
                }
            } else {
                // Returning user, show full cinematic with BIOS
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
        .onReceive(NotificationCenter.default.publisher(for: .handleDeepLink)) { note in
            if let url = note.object as? URL {
                handleInviteURL(url)
            }
        }
    }

    private func handleInviteURL(_ url: URL) {
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
            // Deep link from invite page to connect OpenClaw agent
            // The invite URL is passed as a query param
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let inviteParam = components?.queryItems?.first(where: { $0.name == "invite" })?.value {
                NSLog("[Port42] OpenClaw deep link with invite: %@", inviteParam)
                // For now, open the OpenClaw sheet with the current channel
                // Future: parse invite to identify the channel and pre-fill
                if let channel = appState.currentChannel {
                    appState.openClawChannel = channel
                    appState.showOpenClawSheet = true
                }
            }

        default:
            NSLog("[Port42] Unknown invite type: %@", url.host ?? "nil")
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
