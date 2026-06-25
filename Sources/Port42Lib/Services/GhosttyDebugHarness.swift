#if DEBUG
import AppKit
import SwiftUI
import GhosttyKit

// Debug harness for the incremental Ghostty bring-up. Two entry points:
//
//  • runSurfaceTest()      — Steps 2–4: bare AppKit (NSWindow + GhosttyInputView),
//                            no SwiftUI. Proves app/surface ABI (gap #3/#4/#8), the
//                            PTY tee (gap #5), and AppKit input/resize/scale.
//  • runSwiftUIPanelTest() — Step 5: the PRODUCTION stack — GhosttyTerminalView
//                            (NSViewRepresentable) inside NSHostingView inside NSPanel.
//                            Proves SwiftUI hosting doesn't fight the Metal layer.
//
// The Ghostty *app* is owned by GhosttyApp.shared (one per process, never freed).
// Both paths create/free only *surfaces*.
@MainActor
public final class GhosttyDebugHarness: NSObject, NSWindowDelegate {
    public static let shared = GhosttyDebugHarness()
    private override init() {}

    // Steps 2–4 bare-AppKit path
    private var surface: ghostty_surface_t?
    private var window: NSWindow?
    private weak var inputView: GhosttyInputView?

    // Step 5 SwiftUI-panel path (retain so it isn't deallocated)
    private var panel: NSPanel?
    // Step 6: tee → TerminalOutputProcessor → <p42> extraction (retain it)
    private var outputProcessor: TerminalOutputProcessor?
    // Step 7: hooks receiver + per-session bootstrap (retain so they outlive the panel)
    private var hooksService: TerminalHooksService?
    private var hookSession: TerminalHookSession?
    private var hooksTask: Task<Void, Never>?

    // MARK: Steps 2–4 — bare AppKit surface
    public func runSurfaceTest() {
        if surface != nil { window?.makeKeyAndOrderFront(nil); return }
        guard let app = GhosttyApp.shared.ensureApp() else { return }

        let win = self.window ?? {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Ghostty Debug Surface (Steps 2–4) — bare AppKit"
            w.isReleasedWhenClosed = false   // we own the lifetime; avoid AppKit release
            w.delegate = self
            w.center()
            return w
        }()
        self.window = win

        // NSView must exist BEFORE surface creation (gap #4). Fresh view per run.
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

        let created: ghostty_surface_t? = "/bin/zsh".withCString { cmd in
            sc.command = cmd
            return ghostty_surface_new(app, &sc)
        }
        guard let surface = created else {
            NSLog("[Ghostty] ghostty_surface_new returned nil")
            return
        }
        self.surface = surface
        view.surface = surface
        NSLog("[Ghostty] surface created: \(surface)")

        ghostty_surface_set_pty_tee_cb(surface, { _, bytes, len in
            guard let bytes, len > 0 else { return }
            let copied = Data(bytes: UnsafeRawPointer(bytes), count: Int(len))
            let str = String(decoding: copied, as: UTF8.self)
            Task { @MainActor in NSLog("[tee] \(str.debugDescription)") }
        }, Unmanaged.passUnretained(self).toOpaque())

        ghostty_surface_set_content_scale(surface, scale, scale)
        win.makeFirstResponder(view)
        ghostty_surface_set_focus(surface, true)
        view.pushSize()
        GhosttyApp.shared.tick()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let surface = self.surface else { return }
            let exited = ghostty_surface_process_exited(surface)
            let pid = ghostty_surface_foreground_pid(surface)
            NSLog("[Ghostty] shell pid=\(pid), process_exited=\(exited) (expect alive). Close window to free + verify reap.")
        }
    }

    // MARK: Step 5 — SwiftUI representable in NSHostingView in NSPanel
    public func runSwiftUIPanelTest() {
        if let panel { panel.makeKeyAndOrderFront(nil); return }

        // Step 6: tee bytes → TerminalOutputProcessor → <p42> extraction.
        let processor = TerminalOutputProcessor { signal in
            NSLog("[p42:onFlush] \(signal.debugDescription)")
        }
        processor.onP42Output = { tags in
            NSLog("[p42:TAGS] \(tags)")
        }
        self.outputProcessor = processor

        // Step 6: command is the warmup script (cats a <p42> tag during startup,
        // then exec's an interactive zsh) so every launch exercises the warmup-discard
        // extraction path (gap #9). Falls back to /bin/zsh if the script is absent.
        let warmupScript = "/tmp/p42warmup.sh"
        let command = FileManager.default.isExecutableFile(atPath: warmupScript) ? warmupScript : "/bin/zsh"
        let cfg = TerminalPortConfig(
            command: command, args: [], cwd: NSHomeDirectory(),
            spaceId: "debug", spaceName: "debug", companionName: "step6", createdBy: "debug"
        )
        let root = GhosttyTerminalView(config: cfg) { str in
            NSLog("[tee:swiftui] \(str.debugDescription)")
            processor.receive(str)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 480)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.title = "Ghostty Step 5 — SwiftUI panel (type/resize/focus)"
        p.isReleasedWhenClosed = false
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false   // panel must take key so typing/focus work
        p.delegate = self
        p.contentView = hosting
        p.center()
        self.panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("[Ghostty] Step 5 SwiftUI panel shown")
    }

    // MARK: Step 7 — hooks: env injection + shim + Stop→turnComplete over a socket
    public func runHooksTest() {
        if let panel { panel.makeKeyAndOrderFront(nil); return }

        // Assemble the per-session environment (shim PATH, hooks socket, real-claude path,
        // space identity, CLI OAuth token from the secrets store).
        // Distinct values so `printenv | grep PORT42` clearly shows two SEPARATE variables.
        let sessionId = UUID().uuidString
        let session = TerminalSessionBootstrap.make(
            sessionId: sessionId,
            spaceId: "debug-space-\(sessionId.prefix(8))",
            spaceName: "Debug Space"
        )
        self.hookSession = session
        NSLog("[hooks] session vars=\(session.env.keys.sorted()) socket=\(session.socketPath) shim=\(TerminalSessionBootstrap.bundledShimPath() ?? "nil")")

        // General receiver: decode normalized events, log turnComplete (Step 7 wires only it).
        let hooks = TerminalHooksService(socketPath: session.socketPath)
        self.hooksService = hooks
        self.hooksTask = Task {
            for await event in await hooks.events() {
                switch event {
                case .turnComplete(let text, let code):
                    NSLog("[hooks] ✅ turnComplete (exit=\(code)) text=\(text.debugDescription)")
                default:
                    NSLog("[hooks] event=\(event)")
                }
            }
        }

        // Keep the Step 6 <p42> fallback path live too (harmless here).
        let processor = TerminalOutputProcessor { _ in }
        processor.onP42Output = { tags in NSLog("[p42:TAGS] \(tags)") }
        self.outputProcessor = processor

        let cfg = TerminalPortConfig(
            command: "/bin/zsh", args: [], cwd: NSHomeDirectory(),
            spaceId: "debug", spaceName: "debug", companionName: "step7", createdBy: "debug"
        )
        let root = GhosttyTerminalView(config: cfg, env: session.env) { str in
            processor.receive(str)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 520)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.title = "Ghostty Step 7 — hooks (run: claude -p \"say the word banana\")"
        p.isReleasedWhenClosed = false
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.delegate = self
        p.contentView = hosting
        p.center()
        self.panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("[hooks] Step 7 panel shown. In the terminal: `printenv | grep PORT42`, then `claude -p \"say the word banana\"`.")
    }

    // MARK: teardown (bare-AppKit path)
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The SwiftUI panel frees its surface via dismantleNSView on dealloc; just
        // hide it (don't terminate the host app by truly closing a throwaway window).
        if sender === panel {
            sender.orderOut(nil)
            self.panel = nil   // drop ref → SwiftUI tears down the representable → surface freed
            self.outputProcessor = nil
            // Step 7 teardown: stop the socket listener, cancel the observer, remove temp dir.
            if let hooks = hooksService { Task { await hooks.stop() } }
            hooksService = nil
            hooksTask?.cancel(); hooksTask = nil
            if let dir = hookSession?.tempDir { TerminalSessionBootstrap.cleanup(tempDir: dir) }
            hookSession = nil
            return false
        }
        teardownSurface()
        sender.orderOut(nil)
        return false
    }

    private func teardownSurface() {
        guard let s = surface else { return }
        let shellPid = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(s))
        surface = nil
        inputView?.surface = nil
        ghostty_surface_set_pty_tee_cb(s, nil, nil)
        ghostty_surface_free(s)
        NSLog("[Ghostty] surface freed (window hidden); app singleton kept alive. Shell pid was \(shellPid).")

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
