import Testing
import Foundation
import AVFoundation
@testable import Port42Lib

// The lock screen's video froze the app twice at the switch from one clip to the next (2026-09-26,
// sampled on Dev4). It now plays one composition and loops by seeking, so it never changes item.
@Suite("Dreamscape video")
struct DreamscapeVideoTests {

    @Test("both clips load off the main thread into one composition as long as the two together")
    func composition() async throws {
        let urls = DreamscapeVideoLayer.clips.compactMap { Bundle.port42.url(forResource: $0, withExtension: "mp4") }
        #expect(urls.count == 2, "a clip is missing from the bundle")
        let comp = try await DreamscapeVideoLayer.composition(urls)
        var sum = CMTime.zero
        for u in urls { sum = CMTimeAdd(sum, try await AVURLAsset(url: u).load(.duration)) }
        #expect(abs(comp.duration.seconds - sum.seconds) < 0.1, "\(comp.duration.seconds)s against \(sum.seconds)s")
    }

    @Test("no player in the app changes item: no queue player, no inserted items, no end observer for every item")
    func noItemChanges() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var offenders: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.contains("AVQueuePlayer") || code.contains("AVPlayerLooper")
                    || code.range(of: #"\.insert\([^)]*,\s*after:"#, options: .regularExpression) != nil {
                    offenders.append("\(url.lastPathComponent):\(i + 1)")
                }
            }
            if text.range(of: #"AVPlayerItemDidPlayToEndTime,\s*object:\s*nil"#, options: .regularExpression) != nil {
                offenders.append("\(url.lastPathComponent): an end observer for every item")
            }
        }
        #expect(offenders.isEmpty, "a player that changes item: \(offenders)")
    }
}
