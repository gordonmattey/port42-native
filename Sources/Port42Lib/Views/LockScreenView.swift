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
    static let enterAquariumRequested = Notification.Name("enterAquariumRequested")
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

public struct DreamscapeVideoLayer: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspectFill

        let coordinator = context.coordinator
        let player = AVQueuePlayer()
        coordinator.player = player
        coordinator.enqueueVideos()

        playerView.player = player
        player.play()

        return playerView
    }

    public func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator: NSObject {
        var player: AVQueuePlayer?
        private var observation: NSObjectProtocol?

        func enqueueVideos() {
            guard let player else { return }

            let videoNames = ["dreamscape", "dream-architect"]
            var items: [AVPlayerItem] = []
            for name in videoNames {
                if let url = Bundle.port42.url(forResource: name, withExtension: "mp4") {
                    items.append(AVPlayerItem(asset: AVAsset(url: url)))
                }
            }

            guard !items.isEmpty else { return }

            for item in items {
                player.insert(item, after: nil)
            }

            observation = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, let player = self.player else { return }
                guard notification.object is AVPlayerItem else { return }

                if player.items().count <= 1 {
                    for name in videoNames {
                        if let url = Bundle.port42.url(forResource: name, withExtension: "mp4") {
                            let newItem = AVPlayerItem(asset: AVAsset(url: url))
                            player.insert(newItem, after: nil)
                        }
                    }
                }
            }
        }

        deinit {
            if let observation {
                NotificationCenter.default.removeObserver(observation)
            }
            player?.pause()
        }
    }
}
