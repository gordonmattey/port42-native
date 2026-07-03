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

    /// Fullscreen TAKEOVER — a SEPARATE opt-in from the shell UI. Off by default so the shell runs as
    /// a normal window (title bar, Dock, menu bar) unless the user turns takeover on. Env wins for
    /// dogfooding; else the persisted Settings toggle.
    public static let takeoverKey = "PORT42_SHELL_TAKEOVER"
    public static func takeoverEnabled(
        env: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let v = env[takeoverKey] {
            return v == "1" || v.lowercased() == "true"
        }
        return defaults.bool(forKey: takeoverKey)   // default false
    }

    /// Sane fallback when no display is reachable (headless test runner, or some locked states).
    public static let fallbackFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// The takeover frame: the screen's FULL frame (covers the menu-bar strip), not `visibleFrame`.
    /// Guards `NSScreen.main == nil` with `fallbackFrame` so launch never traps.
    public static func windowFrame(for screen: NSScreen?) -> CGRect {
        screen?.frame ?? fallbackFrame
    }

    /// Graduate the reused app window to the prototype's borderless-fullscreen LOOK without swapping
    /// the `WindowGroup` window (which would break SwiftUI/key handling): hide the traffic lights,
    /// let content fill to the top edge, pin it to the full `screen.frame` (physical top-left), and
    /// hide the Dock + menu bar. This is the single authoritative takeover — both the launch path
    /// and every post-transition `restoreWindowFrame` route here, so the result can't drift.
    /// (Pure AppKit; callers invoke it on the main thread.)
    public static func applyTakeover(to window: NSWindow) {
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // A .titled window is frame-constrained to leave the menu-bar strip (the black bar up top),
        // even with the bar hidden + level raised. Borderless removes the constraint so the window
        // covers the FULL screen.frame — the prototype's move.
        window.styleMask = [.borderless, .fullSizeContentView, .resizable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        // Kiosk level (prototype's move): a NORMAL-level window's frame is clamped to visibleFrame,
        // so it can't cover the menu-bar region — that's the black strip up top. Raise it above the
        // menu bar so the full screen.frame actually takes.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.setFrame(windowFrame(for: window.screen ?? NSScreen.main), display: true, animate: false)
    }

    /// THE authoritative shell window presentation: fullscreen takeover if opted in, else a normal
    /// window. Every path that sets up the shell window (launch, unlock/dive, ShellView.onAppear, the
    /// Settings toggle) calls THIS — so the sites can't drift and forget to honor the flag.
    public static func applyShellWindow(to window: NSWindow) {
        if takeoverEnabled() { applyTakeover(to: window) } else { restoreWindow(window) }
    }

    /// Exact inverse of `applyTakeover`: return to a normal titled, movable, normal-level window with
    /// the Dock + menu bar shown — so the toggle can flip fullscreen mode OFF live (no restart). The
    /// shell UI itself is unchanged; it just renders in an ordinary window now.
    public static func restoreWindow(_ window: NSWindow) {
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.titleVisibility = .hidden               // keep chrome flush; content fills under the bar
        window.titlebarAppearsTransparent = true
        window.isMovable = true
        window.level = .normal
        window.collectionBehavior = [.fullScreenPrimary]
        NSApp.presentationOptions = []
        // Remember the windowed size: a saved frame wins; first launch (none saved) fills the display.
        if let saved = savedWindowedFrame(), saved.width > 200, saved.height > 200 {
            window.setFrame(saved, display: true, animate: false)
        } else if let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.visibleFrame, display: true, animate: false)   // first launch = full display
        }
    }

    // MARK: Windowed-frame persistence (remember the user's size across launches)

    public static let windowFrameKey = "PORT42_SHELL_WINDOW_FRAME"

    static func savedWindowedFrame(defaults: UserDefaults = .standard) -> CGRect? {
        guard let s = defaults.string(forKey: windowFrameKey) else { return nil }
        let r = NSRectFromString(s)
        return (r.width > 0 && r.height > 0) ? r : nil
    }

    /// Persist the current window frame — but NEVER while fullscreen, or we'd save the takeover frame
    /// and lose the user's windowed size.
    public static func saveWindowedFrame(_ window: NSWindow, defaults: UserDefaults = .standard) {
        guard !takeoverEnabled() else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: windowFrameKey)
    }
}
