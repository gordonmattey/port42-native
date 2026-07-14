import Testing
import Foundation
import AppKit
@testable import Port42Lib

/// SHELL — S1 test gate, post-retirement: the PORT42_SHELL flag is GONE (the shell IS the
/// app), so only the takeover frame fallback remains — it must hold when no display is
/// reachable (`NSScreen.main == nil` in the headless test runner).
@Suite("Shell mode flag + takeover frame (S1)")
struct ShellModeTests {

    @Test("takeover frame falls back to a sane frame when NSScreen.main is nil (headless)")
    func fallbackFrameHolds() {
        let f = ShellMode.windowFrame(for: nil)
        #expect(f == ShellMode.fallbackFrame)
        #expect(f.width > 100 && f.height > 100)
    }
}
