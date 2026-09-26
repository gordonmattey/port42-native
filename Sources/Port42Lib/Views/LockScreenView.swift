import SwiftUI
import AVKit

public struct LockScreenView: View {
    @EnvironmentObject var appState: AppState
    @State private var buttonOpacity: Double = 0.0

    public init() {}

    private var isReturningUser: Bool {
        appState.currentUser != nil
    }

    @State private var ripples: [UUID] = []
    @State private var isHovered = false

    public var body: some View {
        ZStack {
            VStack {
                Spacer()

                Button(action: diveIn) {
                    ZStack {
                        // Ripple rings
                        ForEach(ripples, id: \.self) { id in
                            RippleRing()
                        }

                        // Main circle
                        Circle()
                            .fill(Port42Theme.accent.opacity(isHovered ? 0.2 : 0.1))
                            .frame(width: 80, height: 80)
                            .overlay(
                                Circle()
                                    .stroke(Port42Theme.accent.opacity(0.6), lineWidth: 1)
                            )

                        // Content
                        if isReturningUser {
                            VStack(spacing: 4) {
                                userAvatar
                                Text("swim")
                                    .font(Port42Theme.mono(10))
                                    .foregroundStyle(Port42Theme.accent)
                            }
                        } else {
                            Text("swim")
                                .font(Port42Theme.monoBold(14))
                                .foregroundStyle(Port42Theme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        DolphinCursor.shared.push()
                    } else {
                        DolphinCursor.shared.pop()
                    }
                }
                .opacity(buttonOpacity)

                Spacer()
                    .frame(height: 80)
            }
        }
        .onAppear {
            Analytics.shared.screen("LockScreen")
            startRipples()
        }
        .onAppear {
            withAnimation(.easeIn(duration: 1.5).delay(0.5)) {
                buttonOpacity = 1.0
            }
        }
    }

    @ViewBuilder
    private var userAvatar: some View {
        if let user = appState.currentUser,
           let data = user.avatarData,
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        } else if let user = appState.currentUser {
            // Initials fallback
            let initial = String(user.displayName.prefix(1)).uppercased()
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.4))
                    .frame(width: 28, height: 28)
                Text(initial)
                    .font(Port42Theme.monoBold(14))
                    .foregroundStyle(Port42Theme.accent)
            }
        }
    }

    private func startRipples() {
        // Spawn a new ripple every 1.5s, remove after it fades (3s)
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            let id = UUID()
            ripples.append(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                ripples.removeAll { $0 == id }
            }
        }
        // Kick off the first one immediately
        let id = UUID()
        ripples.append(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            ripples.removeAll { $0 == id }
        }
    }

    private func diveIn() {
        if isReturningUser {
            withAnimation(.easeOut(duration: 0.3)) {
                buttonOpacity = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: .diveRequested, object: nil)
            }
        } else {
            NotificationCenter.default.post(name: .dolphinProtocolRequested, object: nil)
        }
    }
}

public extension Notification.Name {
    static let diveRequested = Notification.Name("diveRequested")
}

// MARK: - Ripple Ring

private struct RippleRing: View {
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 0.35

    var body: some View {
        Circle()
            .stroke(Port42Theme.accent.opacity(opacity), lineWidth: 1)
            .frame(width: 80 * scale, height: 80 * scale)
            .onAppear {
                withAnimation(.easeOut(duration: 3)) {
                    scale = 2.0
                    opacity = 0
                }
            }
    }
}

// MARK: - Looping Video Player

/// A bare player layer: the video and nothing else.
///
/// NOT `AVPlayerView` (2026-09-26). AVKit's view carries an `AVPlayerController` that polls the
/// item's current time ON THE MAIN THREAD, controls hidden or not. When the queue player moved on
/// to the next video, a media thread tore down the old decoder holding a lock and waited on its
/// frames, while the main thread waited on that lock: the app froze and every gateway call timed
/// out (sampled on Dev4 under load, main thread in `-[AVPlayerController updateAtMinMaxTime]` →
/// `-[AVPlayerItem currentTime]` → mutex wait). A background has no controller to poll.
public final class LoopingVideoView: NSView {
    public let playerLayer = AVPlayerLayer()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// The dreamscape clips, looped behind the lock screen.
///
/// ONE ITEM, NO TRANSITIONS (2026-09-26). This used to be an `AVQueuePlayer` topped up from an
/// end-of-item notification on the main thread, observed for every player item in the app. Twice
/// the app froze at the switch from one clip to the next: sampled on Dev4 with the main thread in
/// AVFoundation's own advance callback (`_advanceCurrentItemAccordingToFigPlaybackItem`), and before
/// that inserting the next item, each waiting on a queue that waited on the new item's timebase, while
/// every gateway call timed out. Now the clips are loaded off the main thread into one composition,
/// played as a single item, and looped by an asynchronous seek to its start, so the player never
/// changes item.
public struct DreamscapeVideoLayer: NSViewRepresentable {
    public init() {}

    static let clips = ["dreamscape", "dream-architect"]

    public func makeNSView(context: Context) -> LoopingVideoView {
        let view = LoopingVideoView()
        let player = AVPlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        view.playerLayer.player = player
        context.coordinator.start(player)
        return view
    }

    public func updateNSView(_ nsView: LoopingVideoView, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator() }

    /// The clips back to back, as one asset. Loaded with the async API, so no file is read on the
    /// caller's thread.
    static func composition(_ urls: [URL]) async throws -> AVComposition {
        let comp = AVMutableComposition()
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            _ = try await asset.loadTracks(withMediaType: .video)
            try await comp.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: comp.duration)
        }
        return comp
    }

    public class Coordinator: NSObject {
        private var player: AVPlayer?
        private var observation: NSObjectProtocol?
        private var loading: Task<Void, Never>?

        func start(_ player: AVPlayer) {
            self.player = player
            let urls = DreamscapeVideoLayer.clips.compactMap { Bundle.port42.url(forResource: $0, withExtension: "mp4") }
            guard !urls.isEmpty else { return }
            loading = Task { @MainActor [weak self] in
                guard let comp = try? await DreamscapeVideoLayer.composition(urls), let self, let player = self.player,
                      !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: comp)
                self.observation = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
                ) { [weak player] _ in
                    player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
                }
                player.replaceCurrentItem(with: item)
                player.play()
            }
        }

        deinit {
            loading?.cancel()
            if let observation { NotificationCenter.default.removeObserver(observation) }
            player?.pause()
        }
    }
}
