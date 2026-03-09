import SwiftUI
import AVKit

public struct LockScreenView: View {
    @EnvironmentObject var appState: AppState
    @State private var buttonOpacity: Double = 0.0

    public init() {}

    private var isReturningUser: Bool {
        appState.currentUser != nil
    }

    public var body: some View {
        ZStack {
            VStack {
                Spacer()

                Button(action: diveIn) {
                    if isReturningUser {
                        // Returning user: avatar + "Dive In"
                        HStack(spacing: 12) {
                            userAvatar
                            Text("Swim")
                                .font(Port42Theme.monoBold(16))
                                .foregroundStyle(.black)
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 24)
                        .padding(.vertical, 8)
                        .background(Port42Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: Port42Theme.accent.opacity(0.4), radius: 16)
                    } else {
                        // New user: just text
                        Text("Swim")
                            .font(Port42Theme.monoBold(16))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(Port42Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .shadow(color: Port42Theme.accent.opacity(0.4), radius: 16)
                    }
                }
                .buttonStyle(.plain)
                .opacity(buttonOpacity)
                .keyboardShortcut(.defaultAction)

                Spacer()
                    .frame(height: 80)
            }
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
                .frame(width: 32, height: 32)
                .clipShape(Circle())
        } else if let user = appState.currentUser {
            // Initials fallback
            let initial = String(user.displayName.prefix(1)).uppercased()
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.4))
                    .frame(width: 32, height: 32)
                Text(initial)
                    .font(Port42Theme.monoBold(14))
                    .foregroundStyle(Port42Theme.accent)
            }
        }
    }

    private func diveIn() {
        withAnimation(.easeOut(duration: 0.3)) {
            buttonOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(name: .diveRequested, object: nil)
        }
    }
}

public extension Notification.Name {
    static let diveRequested = Notification.Name("diveRequested")
    static let enterAquariumRequested = Notification.Name("enterAquariumRequested")
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
