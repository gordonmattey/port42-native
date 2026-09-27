import SwiftUI
import AVFoundation

/// The first-run breakout (GM, 2026-09-27: brought back): the first time a person zooms out of echo's
/// terminal to their desktop, the aquarium video grows from the port they were in to full screen,
/// plays, and fades to leave them in the space. Removed on 2026-09-25 and restored here.
///
/// A bare player layer (`LoopingVideoView`), not `AVPlayerView`: AVKit's view polls the item's time on
/// the main thread, which deadlocked the app against a media thread (2026-09-26). One item, played
/// once; its end is the only notification.
public struct AquariumBreakoutView: NSViewRepresentable {
    let onFinished: () -> Void

    public init(onFinished: @escaping () -> Void) { self.onFinished = onFinished }

    public static var videoURL: URL? {
        Bundle.port42.url(forResource: "TheAquariumsDoorIsOpen", withExtension: "mp4")
    }

    public func makeNSView(context: Context) -> LoopingVideoView {
        let view = LoopingVideoView()
        guard let url = Self.videoURL else {
            p42log("[Port42] TheAquariumsDoorIsOpen.mp4 is not in the bundle; the breakout is skipped")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onFinished() }
            return view
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        view.playerLayer.player = player
        context.coordinator.player = player
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in onFinished() }
        player.play()
        return view
    }

    public func updateNSView(_ nsView: LoopingVideoView, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var player: AVPlayer?
        var observer: NSObjectProtocol?
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            player?.pause()
        }
    }
}
