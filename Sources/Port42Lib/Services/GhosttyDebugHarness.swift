#if DEBUG
import AppKit
import GhosttyKit

// Step 2 harness: create a Ghostty app + surface around a bare NSView, spawn
// /bin/zsh, confirm the shell is alive, then free — all without crashing.
// This de-risks the mandatory-callback wiring (gap #3), the app_new/surface_new
// ABI, the struct layouts, the NSView-before-surface ordering (gap #4), and the
// single-string `command` format (gap #8). It is intentionally minimal: no tee
// callback (Step 3), no resize/retina/focus handling (Step 4), no SwiftUI
// wrapping (Step 5). Triggered from the DEBUG-only "Ghostty Debug" menu.
@MainActor
public final class GhosttyDebugHarness: NSObject, NSWindowDelegate {
    public static let shared = GhosttyDebugHarness()
    private override init() {}

    private static var didGlobalInit = false

    private var app: ghostty_app_t?
    private var surface: ghostty_surface_t?
    private var window: NSWindow?

    public func runSurfaceTest() {
        // 1. Global init (once per process). Pass no argv.
        if !Self.didGlobalInit {
            let rc = ghostty_init(0, nil)
            NSLog("[Ghostty] ghostty_init -> \(rc) (0 == success)")
            Self.didGlobalInit = true
        }

        // 2. Config: create + finalize (required before app_new).
        let cfg = ghostty_config_new()
        ghostty_config_finalize(cfg)

        // 3. Runtime config — all 7 callbacks are mandatory (gap #3).
        //    wakeup_cb drives ghostty_app_tick on the main thread; the rest are
        //    no-op stubs. userdata is an unretained pointer back to self so the
        //    C callback can find the app handle.
        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { ud in
            guard let ud else { return }
            let me = Unmanaged<GhosttyDebugHarness>.fromOpaque(ud).takeUnretainedValue()
            // Ghostty calls wakeup from its IO thread; tick must run on main.
            DispatchQueue.main.async { me.tick() }
        }
        rt.action_cb = { _, _, _ in false }
        rt.read_clipboard_cb = { _, _, _ in false }
        rt.confirm_read_clipboard_cb = { _, _, _, _ in }
        rt.write_clipboard_cb = { _, _, _, _, _ in }
        rt.close_surface_cb = { _, _ in }
        rt.tmux_control_cb = { _, _, _, _, _ in }

        // 4. App.
        guard let app = ghostty_app_new(&rt, cfg) else {
            NSLog("[Ghostty] ghostty_app_new returned nil")
            return
        }
        self.app = app
        NSLog("[Ghostty] app created: \(app)")

        // 5. NSView must exist BEFORE surface creation (gap #4). Host it in a
        //    plain throwaway window so the prompt is actually visible.
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.wantsLayer = true
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Ghostty Debug Surface (Step 2) — type here, close to tear down"
        win.contentView = view
        win.center()
        win.delegate = self          // teardown when the user closes the window
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win

        let scale = win.backingScaleFactor

        // 6. Surface config from defaults, then override the fields we need.
        var sc = ghostty_surface_config_new()
        sc.platform_tag = GHOSTTY_PLATFORM_MACOS
        sc.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        sc.scale_factor = scale

        // 7. Surface — `command` is a single const char*; keep it valid across
        //    the call via withCString. /bin/zsh with no args (gap #8).
        let created: ghostty_surface_t? = "/bin/zsh".withCString { cmd in
            sc.command = cmd
            return ghostty_surface_new(app, &sc)
        }
        guard let surface = created else {
            NSLog("[Ghostty] ghostty_surface_new returned nil")
            return
        }
        self.surface = surface
        NSLog("[Ghostty] surface created: \(surface)")

        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_app_tick(app)  // initial pump so the shell starts producing IO

        // 8. After ~1.5s, log liveness WITHOUT tearing down — the window stays
        //    open so the prompt is visibly persistent and typeable. Teardown
        //    happens when the user closes the window (windowWillClose).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let surface = self.surface else { return }
            let exited = ghostty_surface_process_exited(surface)
            NSLog("[Ghostty] process_exited=\(exited) (expect false = shell alive). Window stays open; close it to tear down.")
        }
    }

    private func tick() {
        if let app { ghostty_app_tick(app) }
    }

    // Teardown when the user closes the debug window.
    public func windowWillClose(_ notification: Notification) {
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        if let app { ghostty_app_free(app) }
        app = nil
        window = nil
        NSLog("[Ghostty] torn down cleanly (window closed)")
    }
}
#endif
