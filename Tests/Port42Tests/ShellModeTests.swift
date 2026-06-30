import Testing
import Foundation
import AppKit
@testable import Port42Lib

/// SHELL — S1 test gate: shell-mode flag selection + the takeover frame fallback.
///
/// The flag (`PORT42_SHELL`) decides whether launch runs the shell takeover vs. the normal
/// login-screen maximize, and the takeover frame must hold when no display is reachable
/// (`NSScreen.main == nil` in the headless test runner). Both are pure helpers on `ShellMode`,
/// so this gate runs without a window — same as the other headless suites.
@Suite("Shell mode flag + takeover frame (S1)")
struct ShellModeTests {

    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("disabled by default — empty env, fresh defaults")
    func disabledByDefault() {
        let d = freshDefaults("p42.shellmode.test.default")
        #expect(ShellMode.isEnabled(env: [:], defaults: d) == false)
    }

    @Test("env PORT42_SHELL=1 / true enables; 0 / other disables")
    func envFlag() {
        let d = freshDefaults("p42.shellmode.test.env")
        #expect(ShellMode.isEnabled(env: ["PORT42_SHELL": "1"], defaults: d) == true)
        #expect(ShellMode.isEnabled(env: ["PORT42_SHELL": "true"], defaults: d) == true)
        #expect(ShellMode.isEnabled(env: ["PORT42_SHELL": "0"], defaults: d) == false)
        #expect(ShellMode.isEnabled(env: ["PORT42_SHELL": "no"], defaults: d) == false)
    }

    @Test("the persisted UserDefaults toggle enables when env is absent")
    func defaultsToggle() {
        let d = freshDefaults("p42.shellmode.test.defaults")
        d.set(true, forKey: ShellMode.flagKey)
        #expect(ShellMode.isEnabled(env: [:], defaults: d) == true)
    }

    @Test("env wins over the persisted toggle")
    func envOverridesDefaults() {
        let d = freshDefaults("p42.shellmode.test.override")
        d.set(true, forKey: ShellMode.flagKey)
        #expect(ShellMode.isEnabled(env: ["PORT42_SHELL": "0"], defaults: d) == false)
    }

    @Test("takeover frame falls back to a sane frame when NSScreen.main is nil (headless)")
    func fallbackFrameHolds() {
        let f = ShellMode.windowFrame(for: nil)
        #expect(f == ShellMode.fallbackFrame)
        #expect(f.width > 100 && f.height > 100)
    }
}
