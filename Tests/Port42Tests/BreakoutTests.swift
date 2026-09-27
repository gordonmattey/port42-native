import Testing
import Foundation
import CoreGraphics
@testable import Port42Lib

/// The first-run breakout (GM, 2026-09-27: brought back): the aquarium video on the first zoom-out of
/// echo's terminal. Its file is gitignored like every video, so it was deleted from the working tree
/// with no trace when the breakout was removed; the bundle check catches that.
@Suite("First-run breakout")
@MainActor
struct BreakoutTests {
    @Test("the aquarium video is in the source Resources and in the built bundle")
    func videoIsBundled() throws {
        // The source file first: a built bundle keeps an old copy after the file is gone, which is
        // how its loss went unnoticed.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Port42Lib/Resources/TheAquariumsDoorIsOpen.mp4").standardized
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        #expect(size > 1_000_000, "TheAquariumsDoorIsOpen.mp4 is missing from Sources/Port42Lib/Resources")
        #expect(AquariumBreakoutView.videoURL != nil, "the video is not in the built bundle")
    }

    @Test("it starts from the focused port's frame, once, and ends")
    func startsOnceAndEnds() throws {
        let shell = ShellState(appState: AppState(db: try DatabaseService(inMemory: true)))
        let area = CGSize(width: 1400, height: 900)
        shell.startBreakout(area: area)
        #expect(shell.breakoutFrom == ShellPlacement.focusRect(in: area))
        shell.startBreakout(area: CGSize(width: 10, height: 10))
        #expect(shell.breakoutFrom == ShellPlacement.focusRect(in: area), "a second start restarted it")
        shell.endBreakout()
        #expect(shell.breakoutFrom == nil)
    }
}
