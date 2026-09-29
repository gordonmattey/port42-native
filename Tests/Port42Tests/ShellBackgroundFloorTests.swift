import Testing
@testable import Port42Lib

/// The floor's lines fade out before the bottom edge, so a line leaving the screen does not flash
/// (GM, 2026-09-29).
@Suite("The background's floor lines")
struct ShellBackgroundFloorTests {

    @Test("a line is invisible as it reaches the bottom, and never jumps on the way")
    func fadesBeforeTheBottom() {
        #expect(ShellBackground.floorLineOpacity(1) == 0, "a line leaves the screen at full brightness")
        #expect(ShellBackground.floorLineOpacity(0.999) < 0.01)
        // The fade is at the last moment: at 97% of the way down the line is still at full brightness.
        #expect(ShellBackground.floorLineOpacity(0.97) > 0.2)
        // It still brightens as it comes forward, before the fade.
        #expect(ShellBackground.floorLineOpacity(0.7) > ShellBackground.floorLineOpacity(0.2))
        // No visible step from one frame to the next: at 24 fps a line moves 1/576 of its way a frame.
        let frame = 1.0 / 576
        var f = 0.0, last = ShellBackground.floorLineOpacity(0)
        while f < 1 {
            f = min(1, f + frame)
            let o = ShellBackground.floorLineOpacity(f)
            #expect(abs(o - last) < 0.03)
            last = o
        }
    }
}
