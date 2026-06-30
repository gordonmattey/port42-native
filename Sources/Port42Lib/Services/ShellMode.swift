import AppKit

/// SHELL — S1. Selects the kiosk shell takeover at launch, behind the `PORT42_SHELL` flag.
///
/// The shell is opt-in and reversible: default off ⇒ the app boots exactly as today. When on, the
/// app takes over the full screen (no Dock, no menu bar) over the living ambient surface (Layer 0,
/// already rendered by `TransitionRoot` / `DreamscapeVideoLayer`).
///
/// This is the cheapest S1 cut (`spec-shell-reimplementation.md` §6.4 / `plan-port42-shell.md` §8
/// S1): it fullscreens the *existing* app window rather than a dedicated borderless `ShellWindow`
/// (the graduation). The logic lives here as pure helpers so the S1 test gate runs headlessly —
/// `NSApp` / `NSScreen.main` are nil in the test runner.
public enum ShellMode {
    /// The flag that turns the shell on: `PORT42_SHELL` as an env var or the persisted Settings key.
    public static let flagKey = "PORT42_SHELL"

    /// Is shell mode enabled? The env var wins (dogfood via `PORT42_SHELL=1 ./build.sh --run`);
    /// otherwise the persisted `UserDefaults` toggle (the in-app Settings switch, S1+) decides.
    public static func isEnabled(
        env: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let v = env[flagKey] {
            return v == "1" || v.lowercased() == "true"
        }
        return defaults.bool(forKey: flagKey)
    }

    /// Sane fallback when no display is reachable (headless test runner, or some locked states).
    public static let fallbackFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// The takeover frame: the screen's FULL frame (covers the menu-bar strip), not `visibleFrame`.
    /// Guards `NSScreen.main == nil` with `fallbackFrame` so launch never traps.
    public static func windowFrame(for screen: NSScreen?) -> CGRect {
        screen?.frame ?? fallbackFrame
    }
}
