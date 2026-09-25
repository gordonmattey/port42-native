import Testing
@testable import Port42Lib

/// The ambient background pauses only when none of it can be seen (nautilus Phase 2 step 4, GM
/// 2026-09-25): not behind a focused port, which dims it but leaves it visible.
@Suite("Ambient background pause")
struct AmbientPauseTests {
    @Test("runs on a visible desktop, including behind a focused port")
    func runsWhenVisible() {
        // Focus is not an input to the rule at all: a focused port never pauses it.
        #expect(!ShellState.ambientPaused(windowVisible: true, wallpaperShown: false))
    }

    @Test("pauses when the window is hidden, minimized or covered")
    func pausesWhenUnseen() {
        #expect(ShellState.ambientPaused(windowVisible: false, wallpaperShown: false))
    }

    @Test("pauses under a wallpaper port")
    func pausesUnderWallpaper() {
        #expect(ShellState.ambientPaused(windowVisible: true, wallpaperShown: true))
    }
}
