#if DEBUG
import AppKit
import GhosttyKit

// Step 2 harness: create a Ghostty app + surface around a bare NSView, spawn
// /bin/zsh, confirm the shell is alive. De-risks the mandatory-callback wiring
// (gap #3), the app_new/surface_new ABI, struct layouts, NSView-before-surface
// ordering (gap #4), and the single-string `command` format (gap #8).
// Intentionally minimal: no tee callback (Step 3), no resize/retina/focus
// handling (Step 4), no SwiftUI wrapping (Step 5).
//
// IMPORTANT lifecycle rule (learned the hard way): the Ghostty *app* handle is a
// process-wide singleton that registers global/atexit cleanup (with JIT
// trampolines). It must be created ONCE and live for the whole process — freeing
// it mid-process unmaps those pages and `exit()`'s __cxa_finalize later jumps
// into the invalidated page → SIGKILL (Code Signature Invalid). So we free only
// the *surface* per window; the app is never freed.
@MainActor
public final class GhosttyDebugHarness: NSObject, NSWindowDelegate {
    public static let shared = GhosttyDebugHarness()
    private override init() {}

    private static var didGlobalInit = false
    private static var sharedApp: ghostty_app_t?

    private var surface: ghostty_surface_t?
    private var window: NSWindow?
    private var tearingDown = false   // gates tick() so no app_tick runs against a freed surface

    /// Create the process-wide Ghostty app exactly once; reuse thereafter.
    private func ensureApp() -> ghostty_app_t? {
        if let app = Self.sharedApp { return app }

        if !Self.didGlobalInit {
            let rc = ghostty_init(0, nil)
            NSLog("[Ghostty] ghostty_init -> \(rc) (0 == success)")
            Self.didGlobalInit = true
        }

        let cfg = ghostty_config_new()
        ghostty_config_finalize(cfg)

        // All 7 callbacks are mandatory (gap #3). wakeup_cb drives the IO loop;
        // the rest are no-op stubs. userdata points back to the singleton so the
        // C callback can reach `tick()`.
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

        guard let app = ghostty_app_new(&rt, cfg) else {
            NSLog("[Ghostty] ghostty_app_new returned nil")
            return nil
        }
        Self.sharedApp = app
        NSLog("[Ghostty] app created (singleton): \(app)")
        return app
    }

    public func runSurfaceTest() {
        // Only one debug surface at a time.
        if surface != nil {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let app = ensureApp() else { return }

        // Reuse the (hidden) debug window across runs; closing it only hides it
        // and frees the surface — it must NOT close for real, because closing a
        // throwaway AppKit window in this SwiftUI app terminates the whole app.
        let win = self.window ?? {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Ghostty Debug Surface (Step 2) — close to free surface (app stays up)"
            w.isReleasedWhenClosed = false   // we own the lifetime; avoid AppKit release
            w.delegate = self
            w.center()
            return w
        }()
        self.window = win

        // NSView must exist BEFORE surface creation (gap #4). Fresh view per run.
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.wantsLayer = true
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let scale = win.backingScaleFactor

        var sc = ghostty_surface_config_new()
        sc.platform_tag = GHOSTTY_PLATFORM_MACOS
        sc.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        sc.scale_factor = scale

        // `command` is a single const char*; keep it valid across the call via
        // withCString. /bin/zsh with no args (gap #8).
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let surface = self.surface else { return }
            let exited = ghostty_surface_process_exited(surface)
            let pid = ghostty_surface_foreground_pid(surface)
            NSLog("[Ghostty] shell pid=\(pid), process_exited=\(exited) (expect alive). Close window to free + verify reap.")
        }
    }

    private func tick() {
        // Gate on teardown so no ghostty_app_tick runs against a surface being freed.
        guard !tearingDown, let app = Self.sharedApp else { return }
        ghostty_app_tick(app)
    }

    // Intercept the close: free the surface and HIDE the window, but return false
    // so AppKit never actually closes it — closing this throwaway window was
    // terminating the host app. The app singleton stays alive for the process.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        teardownSurface()
        sender.orderOut(nil)
        return false
    }

    // cmux-faithful teardown ordering: stop ticks touching the surface, null the
    // ref so no new work enqueues, THEN free. All on main (our serial context),
    // so no queued tick can run against the freed surface.
    private func teardownSurface() {
        guard let s = surface else { return }
        // Capture the PTY shell PID BEFORE freeing — positive teardown proof.
        let shellPid = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(s))
        tearingDown = true
        surface = nil
        ghostty_surface_free(s)
        tearingDown = false
        NSLog("[Ghostty] surface freed (window hidden); app singleton kept alive. Shell pid was \(shellPid).")

        // Prove the surface actually shut down: the PTY child must be reaped.
        // kill(pid, 0) returns 0 if the process still exists; ESRCH if gone.
        guard shellPid > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let rc = kill(shellPid, 0)
            if rc != 0 && errno == ESRCH {
                NSLog("[Ghostty] ✅ teardown verified: shell pid \(shellPid) reaped (no orphan).")
            } else {
                NSLog("[Ghostty] ⚠️ teardown: shell pid \(shellPid) still present (rc=\(rc), errno=\(errno)) — possible orphan/zombie.")
            }
        }
    }
}
#endif
