import AppKit
import SwiftUI
import GhosttyKit

// Config describing one native terminal port. JSON-encoded into `PortPanel.html`
// so the existing port persistence/restore plumbing carries it unchanged (Step 8).
// Env/hooks fields (spaceId/spaceName/…) are unused until Steps 7–8 but are present
// now so the view signature doesn't churn later.
struct TerminalPortConfig: Codable {
    /// The surface's process — an interactive login shell (e.g. /bin/zsh). Ghostty's
    /// `command` is a single binary path with no args (gap #8), and the hooks shim is
    /// verified against an interactive zsh (ZDOTDIR function), so the companion's real
    /// command is TYPED IN via `startupCommand` rather than exec'd as the surface process.
    let command: String
    let args: [String]
    /// Full shell line typed into the shell once it's ready (companion command + quoted
    /// args). Empty = just an interactive shell, type nothing.
    var startupCommand: String = ""
    var cwd: String
    let spaceId: String
    let spaceName: String
    let companionName: String
    let createdBy: String
    /// Companion identity/behaviour, injected into the CLI via the shim's
    /// `--append-system-prompt` (env `PORT42_COMPANION_PROMPT`). No file mutation; empty =
    /// don't append anything.
    var companionPrompt: String = ""
    /// Custom environment variables for the surface's shell (full Command-Companion parity —
    /// `port.create({type:"terminal", env:{…}})`). Carried in the persisted config and merged into
    /// the live session env by `TerminalSessionBootstrap.make` (as the base layer — the Port42
    /// hooks/identity vars overlay it, so custom env can't clobber the socket/PATH/ZDOTDIR).
    /// Empty = none.
    var env: [String: String] = [:]

    init(command: String, args: [String], startupCommand: String = "", cwd: String,
         spaceId: String, spaceName: String, companionName: String, createdBy: String,
         companionPrompt: String = "", env: [String: String] = [:]) {
        self.command = command; self.args = args; self.startupCommand = startupCommand
        self.cwd = cwd; self.spaceId = spaceId; self.spaceName = spaceName
        self.companionName = companionName; self.createdBy = createdBy
        self.companionPrompt = companionPrompt; self.env = env
    }

    // Tolerant decoder: Swift's synthesized Decodable throws on a missing key even when a
    // property has a default, so older stored panel JSON (no startupCommand/companionPrompt/env)
    // would fail to decode → blank terminal. decodeIfPresent restores the defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand) ?? ""
        cwd = try c.decode(String.self, forKey: .cwd)
        spaceId = try c.decode(String.self, forKey: .spaceId)
        spaceName = try c.decode(String.self, forKey: .spaceName)
        companionName = try c.decode(String.self, forKey: .companionName)
        createdBy = try c.decode(String.self, forKey: .createdBy)
        companionPrompt = try c.decodeIfPresent(String.self, forKey: .companionPrompt) ?? ""
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }
}

// NSView subclass that forwards AppKit input to a Ghostty surface and keeps the
// surface's pixel-size / content-scale / display-id in sync with the view. Promoted
// to production in Step 5 (was DEBUG-only in Step 4). The surface pointer is injected
// AFTER ghostty_surface_new (which needs this view's pointer first — gap #4), and
// nulled on teardown so queued AppKit events can't call into a freed surface.
@MainActor
final class GhosttyInputView: NSView {
    var surface: ghostty_surface_t?
    private var observers: [NSObjectProtocol] = []
    /// When this view is hoisted OUT of SwiftUI (shell tile path), it owns its Coordinator so the
    /// pty-tee callback's unretained userdata stays alive. Nil for the SwiftUI-managed floating path.
    var retainedCoordinator: AnyObject?

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
        // ghostty_surface_set_size takes PIXELS (width_px, height_px), NOT cols/rows
        // (verified Step 4). Ghostty derives the grid from cell size.
        let w = UInt32(max(1, bounds.width * scale))
        let h = UInt32(max(1, bounds.height * scale))
        ghostty_surface_set_size(s, w, h)
    }

    // MARK: window / display id (HiDPI / multi-monitor → CVDisplayLink on right display)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        guard let win = window else { return }

        // Window scale is only known once we've joined a window — apply it now
        // (config used a default at surface creation). Then size + display + focus.
        let scale = win.backingScaleFactor
        if let s = surface { ghostty_surface_set_content_scale(s, scale, scale) }
        pushSize()
        pushDisplayID()
        // NO keyboard claim here. Joining a window happens on every mount — spawn, peek
        // arrival, space-switch return — and claiming the first responder from whatever the
        // user was typing in is a keyboard STEAL (it also made "last mounted terminal keeps
        // the keys" the de-facto focus model once port units stopped re-mounting on focus).
        // The keyboard moves on the user's intent only: a click (mouseDown above) or a
        // keyboard-driven focus (⌘`/⌘↓/double-click → PortWindowManager.focusKeyboard).
        setFocus(win.isKeyWindow)

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didChangeScreenNotification, object: win, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.pushDisplayID() }
        })
        // Focus must track WINDOW key state, not just first-responder: when the
        // window resigns key the view stays its first responder, so resignFirstResponder
        // never fires. Without this the cursor keeps blinking on an unfocused terminal.
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.setFocus(true) }
        })
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: win, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.setFocus(false) }
        })
    }
    private func setFocus(_ focused: Bool) {
        if let s = surface { ghostty_surface_set_focus(s, focused) }
    }
    private func pushDisplayID() {
        guard let s = surface,
              let num = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        ghostty_surface_set_display_id(s, num.uint32Value)
    }

    // MARK: keyboard
    override func keyDown(with event: NSEvent) {
        // ⌘V / ⌘C (no other modifiers) → clipboard, not a key to the PTY. Ghostty's
        // own clipboard callbacks are stubbed off, so we drive the pasteboard directly.
        let f = event.modifierFlags
        if f.contains(.command), !f.contains(.control), !f.contains(.option) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": pasteFromClipboard(); return
            case "c": if copySelectionToClipboard() { return }   // no selection → fall through
            default: break
            }
        }
        sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    // MARK: clipboard
    private func pasteFromClipboard() {
        guard let s = surface,
              let str = NSPasteboard.general.string(forType: .string), !str.isEmpty else { return }
        // ghostty_surface_text = bracketed-paste delivery (vs. text_input keystrokes).
        str.withCString { ghostty_surface_text(s, $0, UInt(strlen($0))) }
    }

    // MARK: file drop — paste dropped file paths into the terminal (Step 5c)
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let s = surface,
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        let pasted = escapeDroppedPaths(urls.map { $0.path })
        pasted.withCString { ghostty_surface_text(s, $0, UInt(strlen($0))) }
        return true
    }
    @discardableResult
    private func copySelectionToClipboard() -> Bool {
        guard let s = surface, ghostty_surface_has_selection(s) else { return false }
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &t) else { return false }
        defer { ghostty_surface_free_text(s, &t) }
        guard let ptr = t.text, t.text_len > 0 else { return false }
        let str = String(decoding: Data(bytes: ptr, count: Int(t.text_len)), as: UTF8.self)
        guard !str.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
        return true
    }
    // Standard responder actions so the Edit menu's ⌘V/⌘C (handled before keyDown
    // when an Edit menu exists) also reach us.
    @objc func paste(_ sender: Any?) { pasteFromClipboard() }
    @objc func copy(_ sender: Any?) { copySelectionToClipboard() }
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
        // keycode+mods. (IME / dead keys deferred to a later polish step.)
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

    // MARK: mouse
    override func mouseDown(with e: NSEvent) {
        // Click-to-focus: AppKit does NOT hand a custom view the keyboard on click (text
        // views do it themselves in mouseDown) — without this, clicking a terminal never
        // moved the first responder and typing kept flowing to the previously focused
        // surface. This is the terminal's ONE legitimate keyboard claim alongside the
        // shell's keyboard-driven focus (`PortWindowManager.focusKeyboard`).
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        mouseButton(e, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
    }
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
        // Build the packed scroll-mods: bit 0 = precision, bits 1-3 = momentum (Ghostty's
        // mouse.zig). Without the precision bit, trackpad PIXEL deltas (large) are interpreted
        // as LINE counts → the terminal whizzes. Setting it makes Ghostty scale pixels by cell
        // height, matching native Ghostty.app feel. Mouse-wheel (non-precise) is unaffected.
        var mods: Int32 = e.hasPreciseScrollingDeltas ? 1 : 0
        let momentum: ghostty_input_mouse_momentum_e
        switch e.momentumPhase {
        case .began:      momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed:    momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended:      momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled:  momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin:   momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default:          momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        mods |= Int32(momentum.rawValue) << 1
        ghostty_surface_mouse_scroll(s, Double(e.scrollingDeltaX), Double(e.scrollingDeltaY), mods)
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

// SwiftUI wrapper — the production hosting stack. Placed inside NSHostingView →
// NSPanel by PortWindowManager (Step 8). Step 5 proves it survives the SwiftUI
// layer: render, resize-reflow, focus toggle. The tee just reports bytes via
// `onTee`; wiring into TerminalOutputProcessor is Step 6.
struct GhosttyTerminalView: NSViewRepresentable {
    let config: TerminalPortConfig
    // Extra environment injected into the surface's shell at spawn (Step 7): hooks socket,
    // shim PATH, real-claude path, space identity, CLI OAuth token. Assembled by the caller
    // (TerminalSessionBootstrap); the view just applies it to env_vars.
    var env: [String: String] = [:]
    var onTee: ((String) -> Void)? = nil
    /// Called once the surface exists (and with nil on teardown) to hand the owner a writer
    /// that injects bytes into this surface — used for chat→terminal routing.
    var onInject: (((String) -> Void)?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTee: onTee, startupCommand: config.startupCommand, onInject: onInject)
    }

    func makeNSView(context: Context) -> GhosttyInputView {
        let view = GhosttyInputView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        Self.buildSurface(into: view, config: config, env: env, coordinator: context.coordinator)
        return view
    }

    /// Create a Ghostty surface view OUTSIDE SwiftUI's lifecycle so it can be re-parented between a
    /// shell tile, focus, and the park rail WITHOUT freeing the surface (exactly how the persistent
    /// WKWebView is re-hosted). The view retains its Coordinator; the caller owns teardown (call
    /// `coordinator.teardown()` when the PORT closes, not when a SwiftUI host unmounts).
    @MainActor
    static func makeDetached(config: TerminalPortConfig, env: [String: String],
                             onTee: @escaping (String) -> Void,
                             onInject: @escaping (((String) -> Void)?) -> Void) -> (view: GhosttyInputView, coordinator: Coordinator) {
        let coordinator = Coordinator(onTee: onTee, startupCommand: config.startupCommand, onInject: onInject)
        let view = GhosttyInputView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.retainedCoordinator = coordinator   // keep the coordinator alive with the view (tee cb userdata)
        buildSurface(into: view, config: config, env: env, coordinator: coordinator)
        return (view, coordinator)
    }

    /// The surface construction shared by the SwiftUI (`makeNSView`) and detached (`makeDetached`)
    /// paths — one source of truth for the Ghostty C setup.
    @MainActor
    private static func buildSurface(into view: GhosttyInputView, config: TerminalPortConfig,
                                     env: [String: String], coordinator: Coordinator) {
        view.wantsLayer = true
        view.registerForDraggedTypes([.fileURL])  // Step 5c: drop a file → paste its path

        guard let app = GhosttyApp.shared.ensureApp() else {
            NSLog("[Ghostty] buildSurface: no app singleton")
            return
        }

        // View not yet in a window here → scale unknown. Use a sane default; the
        // real scale is applied in viewDidMoveToWindow / viewDidChangeBackingProperties.
        var sc = ghostty_surface_config_new()
        sc.platform_tag = GHOSTTY_PLATFORM_MACOS
        sc.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        sc.scale_factor = 2.0

        // Build the env_vars C array. Both `command` and the env strings must stay valid
        // across ghostty_surface_new (Ghostty copies them internally during the call), so we
        // strdup the env strings, hold a stable pointer to the array, and free after.
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        func dup(_ s: String) -> UnsafePointer<CChar>? {
            guard let p = strdup(s) else { return nil }
            cStrings.append(p)
            return UnsafePointer(p)
        }
        var envVars: [ghostty_env_var_s] = env.map { key, value in
            ghostty_env_var_s(key: dup(key), value: dup(value))
        }

        // Run the companion in its configured working directory (not the app's cwd).
        // Expand a leading `~` — chdir/working_directory does NOT expand it (only shells do),
        // so a stored "~/projects/x" would silently fail and inherit the app's cwd.
        if !config.cwd.isEmpty {
            let expanded = (config.cwd as NSString).expandingTildeInPath
            if let cwd = dup(expanded) { sc.working_directory = cwd }
        }

        // `command` is a single const char*; keep it valid across the call via
        // withCString (gap #8). args passing is Step 8.
        let surface: ghostty_surface_t? = config.command.withCString { cmd in
            sc.command = cmd
            return envVars.withUnsafeMutableBufferPointer { buf -> ghostty_surface_t? in
                if let base = buf.baseAddress, !buf.isEmpty {
                    sc.env_vars = base
                    sc.env_var_count = buf.count
                }
                return ghostty_surface_new(app, &sc)
            }
        }
        cStrings.forEach { free($0) }
        guard let surface else {
            NSLog("[Ghostty] buildSurface: ghostty_surface_new returned nil")
            return
        }
        view.surface = surface
        coordinator.surface = surface
        coordinator.view = view
        NSLog("[Ghostty] buildSurface: surface created \(surface) for '\(config.companionName)'")

        // PTY tee → copy bytes synchronously off the IO thread (gap #5), hand to
        // main, deliver via the coordinator's onTee. userdata = coordinator.
        ghostty_surface_set_pty_tee_cb(surface, { ud, bytes, len in
            guard let ud, let bytes, len > 0 else { return }
            let coord = Unmanaged<Coordinator>.fromOpaque(ud).takeUnretainedValue()
            let copied = Data(bytes: UnsafeRawPointer(bytes), count: Int(len))
            let str = String(decoding: copied, as: UTF8.self)
            Task { @MainActor in coord.handleTee(str) }
        }, Unmanaged.passUnretained(coordinator).toOpaque())

        // Hand the controller a writer for this surface so chat→terminal routing
        // (routeMentionsToTerminals → controller.inject) can reach it. Reads the
        // coordinator's current surface each call, so it no-ops after teardown.
        coordinator.onInject({ [weak coord = coordinator] line in
            guard let s = coord?.surface else { return }
            // Send the body, then Enter SEPARATELY after a short delay. Claude Code's TUI
            // heuristically treats a fast input burst as a paste, so a trailing "\r" in the same
            // write is kept as a literal newline — the message drafts in the input box and never
            // submits (worse for longer messages). Splitting Enter into its own keypress, after
            // the body burst has settled, makes it submit reliably.
            let body = line.hasSuffix("\r") ? String(line.dropLast()) : line
            body.withCString { ghostty_surface_text_input(s, $0, UInt(strlen($0))) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak coord] in
                guard let s = coord?.surface else { return }
                "\r".withCString { ghostty_surface_text_input(s, $0, 1) }
            }
        })

        GhosttyApp.shared.tick()  // initial pump so the shell starts producing IO
    }

    func updateNSView(_ nsView: GhosttyInputView, context: Context) {
        // Terminal state lives inside Ghostty; nothing to push from SwiftUI.
    }

    static func dismantleNSView(_ nsView: GhosttyInputView, coordinator: Coordinator) {
        // SwiftUI calls this on view dealloc (NOT panel close — the explicit
        // willCloseNotification unregister is Step 9). Safe teardown ordering:
        // null the view's surface ref + clear the tee BEFORE free, so no queued
        // AppKit event or tee callback reaches the freed surface.
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        var surface: ghostty_surface_t?
        weak var view: GhosttyInputView?
        let onTee: ((String) -> Void)?
        let onInject: (((String) -> Void)?) -> Void
        private let startupCommand: String
        private var startupSent = false
        init(onTee: ((String) -> Void)?, startupCommand: String = "",
             onInject: @escaping (((String) -> Void)?) -> Void = { _ in }) {
            self.onTee = onTee
            self.startupCommand = startupCommand
            self.onInject = onInject
        }

        /// Per-chunk tee handler: forward bytes, and once the shell has produced its first
        /// output, type the companion's startup command (only once). A short delay lets the
        /// prompt settle. Ghostty's `command` can't carry args, so the command is typed in.
        func handleTee(_ str: String) {
            onTee?(str)
            guard !startupSent, !startupCommand.isEmpty, surface != nil else { return }
            startupSent = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, let s = self.surface else { return }
                let line = self.startupCommand + "\r"
                line.withCString { ghostty_surface_text_input(s, $0, UInt(strlen($0))) }
                NSLog("[Ghostty] typed startup command (%d chars)", self.startupCommand.count)
            }
        }

        func teardown() {
            onInject(nil)   // controller drops its surface writer
            guard let s = surface else { return }
            surface = nil
            view?.surface = nil
            ghostty_surface_set_pty_tee_cb(s, nil, nil)  // detach before free
            ghostty_surface_free(s)
            NSLog("[Ghostty] dismantleNSView: surface freed (app singleton kept).")
        }
    }
}
