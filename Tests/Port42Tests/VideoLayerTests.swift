import Testing
import Foundation
@testable import Port42Lib

// The app froze under load (2026-09-26, sampled on Dev4): AVKit's `AVPlayerView` carries an
// `AVPlayerController` that polls the player item's time on the main thread, and it deadlocked with a
// media thread tearing down the previous video's decoder. Every gateway call then timed out. A
// background or cinematic video is drawn with a bare `AVPlayerLayer` (`LoopingVideoView`) instead.
@Suite("Background video has no player controller")
struct VideoLayerTests {
    @Test("no view in the app uses AVPlayerView")
    func noAVPlayerView() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Port42Lib")
        var uses: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" {
            for (i, line) in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                if line.contains("AVPlayerView(") || line.contains("-> AVPlayerView") { uses.append("\(url.lastPathComponent):\(i + 1)") }
            }
        }
        #expect(uses.isEmpty, "AVPlayerView brings a main-thread player controller that deadlocked the app: \(uses)")
    }

    @Test("the looping video view fills its bounds with the player layer")
    @MainActor
    func layerFills() {
        let v = LoopingVideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        v.layout()
        #expect(v.playerLayer.frame == v.bounds)
        #expect(v.playerLayer.videoGravity == .resizeAspectFill)
    }
}
