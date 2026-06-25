import AppKit
import SwiftUI
import GhosttyKit

// Config describing one native terminal port. JSON-encoded into `PortPanel.html`
// so the existing port persistence/restore plumbing carries it unchanged (Step 8).
// Env/hooks fields (spaceId/spaceName/…) are unused until Steps 7–8 but are present
// now so the view signature doesn't churn later.
struct TerminalPortConfig: Codable {
    let command: String
    let args: [String]
    let cwd: String
    let spaceId: String
    let spaceName: String
    let companionName: String
    let createdBy: String
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
        win.makeFirstResponder(self)
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
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

// SwiftUI wrapper — the production hosting stack. Placed inside NSHostingView →
// NSPanel by PortWindowManager (Step 8). Step 5 proves it survives the SwiftUI
// layer: render, resize-reflow, focus toggle. The tee just reports bytes via
// `onTee`; wiring into TerminalOutputProcessor is Step 6.
struct GhosttyTerminalView: NSViewRepresentable {
    let config: TerminalPortConfig
    var onTee: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onTee: onTee) }

    func makeNSView(context: Context) -> GhosttyInputView {
        let view = GhosttyInputView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.wantsLayer = true

        guard let app = GhosttyApp.shared.ensureApp() else {
            NSLog("[Ghostty] makeNSView: no app singleton")
            return view
        }

        // View not yet in a window here → scale unknown. Use a sane default; the
        // real scale is applied in viewDidMoveToWindow / viewDidChangeBackingProperties.
        var sc = ghostty_surface_config_new()
        sc.platform_tag = GHOSTTY_PLATFORM_MACOS
        sc.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        sc.scale_factor = 2.0

        // `command` is a single const char*; keep it valid across the call via
        // withCString (gap #8). args passing is Step 8.
        let surface: ghostty_surface_t? = config.command.withCString { cmd in
            sc.command = cmd
            return ghostty_surface_new(app, &sc)
        }
        guard let surface else {
            NSLog("[Ghostty] makeNSView: ghostty_surface_new returned nil")
            return view
        }
        view.surface = surface
        context.coordinator.surface = surface
        context.coordinator.view = view
        NSLog("[Ghostty] makeNSView: surface created \(surface) for '\(config.companionName)'")

        // PTY tee → copy bytes synchronously off the IO thread (gap #5), hand to
        // main, deliver via the coordinator's onTee. userdata = coordinator.
        ghostty_surface_set_pty_tee_cb(surface, { ud, bytes, len in
            guard let ud, let bytes, len > 0 else { return }
            let coord = Unmanaged<Coordinator>.fromOpaque(ud).takeUnretainedValue()
            let copied = Data(bytes: UnsafeRawPointer(bytes), count: Int(len))
            let str = String(decoding: copied, as: UTF8.self)
            Task { @MainActor in coord.onTee?(str) }
        }, Unmanaged.passUnretained(context.coordinator).toOpaque())

        GhosttyApp.shared.tick()  // initial pump so the shell starts producing IO
        return view
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
        init(onTee: ((String) -> Void)?) { self.onTee = onTee }

        func teardown() {
            guard let s = surface else { return }
            surface = nil
            view?.surface = nil
            ghostty_surface_set_pty_tee_cb(s, nil, nil)  // detach before free
            ghostty_surface_free(s)
            NSLog("[Ghostty] dismantleNSView: surface freed (app singleton kept).")
        }
    }
}
