import AppKit
import GhosttyKit

// Process-wide Ghostty engine. ONE app, MANY surfaces:
// - `ghostty_app` is the IO event loop + runtime callbacks + wakeup→tick pump.
//   Exactly one per process; it is NEVER freed (freeing it mid-process unmaps the
//   JIT/atexit trampolines it registered and `exit()`'s __cxa_finalize later jumps
//   into the invalidated page → SIGKILL "Code Signature Invalid"). Learned in Step 2.
// - `ghostty_surface` is one terminal (its own PTY, shell, grid, Metal layer, NSView).
//   Created via `ghostty_surface_new(app, &cfg)` and freed per-window. Open as many
//   as you want — N terminal windows = N surfaces driven by this one app.
//
// `wakeup_cb` drives `ghostty_app_tick`, which services ALL live surfaces at once,
// so there is no per-surface pumping. Freeing a surface removes it from the app's
// internal list, so a tick after free simply doesn't touch it (free happens on the
// main actor, same serial context as tick — no race).
@MainActor
public final class GhosttyApp {
    public static let shared = GhosttyApp()
    private init() {}

    private var didGlobalInit = false
    private var app: ghostty_app_t?

    /// Create the process-wide Ghostty app exactly once; reuse thereafter.
    public func ensureApp() -> ghostty_app_t? {
        if let app { return app }

        if !didGlobalInit {
            let rc = ghostty_init(0, nil)
            NSLog("[Ghostty] ghostty_init -> \(rc) (0 == success)")
            didGlobalInit = true
        }

        let cfg = ghostty_config_new()
        // Match the Port42 chat-port look: pure-black background (Port42Theme.bgPrimary
        // = 0x000000), accent cursor. Ghostty config syntax; the 4th arg is a source label
        // for diagnostics. Applied to every surface (all terminal ports).
        let cfgText = "background = 000000\ncursor-color = 00d4aa\n"
        cfgText.withCString { s in
            ghostty_config_load_string(cfg, s, UInt(strlen(s)), "port42")
        }
        ghostty_config_finalize(cfg)

        // All 7 callbacks are mandatory (gap #3). wakeup_cb drives the IO loop;
        // the rest are no-op stubs. userdata points back to this singleton so the
        // C callback can reach `tick()`.
        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { ud in
            guard let ud else { return }
            let me = Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
            // Ghostty calls wakeup from its IO thread; tick must run on main.
            DispatchQueue.main.async { me.tick() }
        }
        rt.action_cb = { _, _, _ in false }
        rt.read_clipboard_cb = { _, _, _ in false }
        rt.confirm_read_clipboard_cb = { _, _, _, _ in }
        rt.write_clipboard_cb = { _, _, _, _, _ in }
        rt.close_surface_cb = { _, _ in }
        rt.tmux_control_cb = { _, _, _, _, _ in }

        guard let newApp = ghostty_app_new(&rt, cfg) else {
            NSLog("[Ghostty] ghostty_app_new returned nil")
            return nil
        }
        app = newApp
        NSLog("[Ghostty] app created (singleton): \(newApp)")
        return newApp
    }

    /// Drive one iteration of the app IO loop. Services all live surfaces.
    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }
}
