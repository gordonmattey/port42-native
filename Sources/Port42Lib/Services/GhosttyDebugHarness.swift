#if DEBUG
import AppKit
import GhosttyKit

// Step 2/3 harness: create a Ghostty app + surface around a bare NSView, spawn
// /bin/zsh, confirm the shell is alive. De-risks the mandatory-callback wiring
// (gap #3), the app_new/surface_new ABI, struct layouts, NSView-before-surface
// ordering (gap #4), and the single-string `command` format (gap #8).
// Step 3 adds the PTY tee callback to prove the cmux fork's pty_tee_cb exists and
// that bytes can be copied off the IO thread (gap #5). Still minimal: no
// resize/retina/focus handling (Step 4), no SwiftUI wrapping (Step 5).
//
// IMPORTANT lifecycle rule (learned the hard way): the Ghostty *app* handle is a
// process-wide singleton that registers global/atexit cleanup (with JIT
// trampolines). It must be created ONCE and live for the whole process — freeing
// it mid-process unmaps those pages and `exit()`'s __cxa_finalize later jumps
// into the invalidated page → SIGKILL (Code Signature Invalid). So we free only
// the *surface* per window; the app is never freed.

// Step 4: NSView subclass that forwards AppKit input to a Ghostty surface and
// keeps surface pixel-size / content-scale / display-id in sync with the view.
// No SwiftUI — this is the isolated AppKit host so any Step 5 failure is provably
// SwiftUI-specific. The surface pointer is injected AFTER ghostty_surface_new
// (which needs this view's pointer first — gap #4), and nulled on teardown so
// queued AppKit events can't call into a freed surface.
@MainActor
final class GhosttyInputView: NSView {
    var surface: ghostty_surface_t?
    private var screenObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    // MARK: focus
    override func becomeFirstResponder() -> Bool {
        if let s = surface { ghostty_surface_set_focus(s, true) }
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        if let s = surface { ghostty_surface_set_focus(s, false) }
        return super.resignFirstResponder()
    }

    // MARK: size & content scale
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pushSize()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let s = surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(s, scale, scale)
        pushSize()
    }
    func pushSize() {
        guard let s = surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        // CORRECTION to plan: ghostty_surface_set_size takes PIXELS (width_px,
        // height_px), NOT cols/rows. Ghostty derives the grid from cell size.
        let w = UInt32(max(1, bounds.width * scale))
        let h = UInt32(max(1, bounds.height * scale))
        ghostty_surface_set_size(s, w, h)
    }

    // MARK: display id (HiDPI / multi-monitor → CVDisplayLink on the right display)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        pushDisplayID()
        if let win = window {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: win, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pushDisplayID() }
            }
        }
    }
    private func pushDisplayID() {
        guard let s = surface,
              let num = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        ghostty_surface_set_display_id(s, num.uint32Value)
    }

    // MARK: keyboard
    override func keyDown(with event: NSEvent) {
        sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }
    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }
    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let s = surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = Self.mods(from: event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)          // macOS virtual keycode; Ghostty maps via Carbon
        key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
        key.composing = false

        // Provide committed text only for printable input; for control / nav /
        // function keys leave text null so Ghostty synthesizes the sequence from
        // keycode+mods. (IME / dead keys deferred to Step 5 NSTextInputClient.)
        let chars = event.characters ?? ""
        let printable: Bool = {
            guard let first = chars.unicodeScalars.first else { return false }
            if first.value < 0x20 || first.value == 0x7f { return false }   // control / DEL
            if (0xF700...0xF8FF).contains(first.value) { return false }     // function-key PUA
            if event.modifierFlags.contains(.command) { return false }     // ⌘ shortcuts
            return true
        }()
        if printable {
            chars.withCString { cptr in
                key.text = cptr
                _ = ghostty_surface_key(s, key)
            }
        } else {
            _ = ghostty_surface_key(s, key)
        }
    }
    static func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift)    { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control)  { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)   { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command)  { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: m)
    }

    // MARK: mouse (cheap usability; not part of the Step-4 verify list)
    override func mouseDown(with e: NSEvent)      { mouseButton(e, GHOSTTY_MOUSE_PRESS,   GHOSTTY_MOUSE_LEFT) }
    override func mouseUp(with e: NSEvent)        { mouseButton(e, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT) }
    override func rightMouseDown(with e: NSEvent) { mouseButton(e, GHOSTTY_MOUSE_PRESS,   GHOSTTY_MOUSE_RIGHT) }
    override func rightMouseUp(with e: NSEvent)   { mouseButton(e, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) }
    override func mouseDragged(with e: NSEvent)   { mousePos(e) }
    private func mouseButton(_ e: NSEvent, _ state: ghostty_input_mouse_state_e, _ btn: ghostty_input_mouse_button_e) {
        guard let s = surface else { return }
        mousePos(e)
        _ = ghostty_surface_mouse_button(s, state, btn, Self.mods(from: e.modifierFlags))
    }
    private func mousePos(_ e: NSEvent) {
        guard let s = surface else { return }
        let p = convert(e.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(s, Double(p.x), Double(bounds.height - p.y), Self.mods(from: e.modifierFlags))
    }
    override func scrollWheel(with e: NSEvent) {
        guard let s = surface else { return }
        ghostty_surface_mouse_scroll(s, Double(e.scrollingDeltaX), Double(e.scrollingDeltaY), 0)
    }

    deinit {
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
    }
}

@MainActor
public final class GhosttyDebugHarness: NSObject, NSWindowDelegate {
    public static let shared = GhosttyDebugHarness()
    private override init() {}

    private static var didGlobalInit = false
    private static var sharedApp: ghostty_app_t?

    private var surface: ghostty_surface_t?
    private var window: NSWindow?
    private weak var inputView: GhosttyInputView?   // Step 4: window owns it; we null its surface ref on teardown
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
            w.title = "Ghostty Debug Surface (Step 4) — type/resize/retina; close to free surface"
            w.isReleasedWhenClosed = false   // we own the lifetime; avoid AppKit release
            w.delegate = self
            w.center()
            return w
        }()
        self.window = win

        // NSView must exist BEFORE surface creation (gap #4). Step 4: input-handling
        // subclass. Fresh view per run.
        let view = GhosttyInputView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.wantsLayer = true
        win.contentView = view
        self.inputView = view
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
        view.surface = surface   // Step 4: now the view can forward input / sync size
        NSLog("[Ghostty] surface created: \(surface)")

        // Step 3: install the PTY tee. Fires on Ghostty's IO read thread for every
        // byte slice BEFORE the VT parser. The bytes pointer is valid ONLY during
        // the call (gap #5) — copy synchronously, then hand off to main. Never touch
        // MainActor state inline on the IO thread. debugDescription so CR/LF/ANSI
        // escapes are visible (proves bytes are intact + fragmentation is observable).
        ghostty_surface_set_pty_tee_cb(surface, { _, bytes, len in
            guard let bytes, len > 0 else { return }
            let copied = Data(bytes: UnsafeRawPointer(bytes), count: Int(len))
            let str = String(decoding: copied, as: UTF8.self)
            Task { @MainActor in NSLog("[tee] \(str.debugDescription)") }
        }, Unmanaged.passUnretained(self).toOpaque())

        ghostty_surface_set_content_scale(surface, scale, scale)

        // Step 4: focus + explicit initial pixel size, then make the view key so
        // keyDown/keyUp flow to ghostty_surface_key.
        win.makeFirstResponder(view)
        ghostty_surface_set_focus(surface, true)
        view.pushSize()

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
        inputView?.surface = nil   // Step 4: stop AppKit events reaching the surface being freed
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
