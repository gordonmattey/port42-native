//  GhosttyResizeSpike.swift
//
//  Spike 3 (pre-Phase 0) for the "Port Units — resize, don't reparent" refactor
//  (docs/plan-port-units-render-refactor.md §6). Retires invariant I6 BEFORE any Phase 0
//  code: does a live GhosttyInputView tolerate aggressive resize-in-place?
//
//  The terminal is created via GhosttyTerminalView.makeDetached — the EXACT production
//  path the shell uses to hoist a terminal into `terminalViews[id]` — then mounted ONCE
//  in a persistent representable (mirrors ShellPortHost / Spike 1's SpikeWebHost) whose
//  .frame/.position animate mini↔full. Every animation frame drives setFrameSize →
//  pushSize → ghostty_surface_set_size, which is precisely the reflow stress I6 fears.
//
//  How to read the result:
//    • Programmatic: /tmp/spike3-ghostty.log — "MAKE #1" exactly once; SPIKE3 RESULT prints
//      PASS iff make==1 && window!=nil && shell alive && the PTY ROUND-TRIP held: the spike
//      injects `echo` lines through the surface before AND after the resize cycle and
//      verifies each output comes back through the pty tee (typed text ≠ expected output —
//      $((6*7)) → 42 — so the echo of the typing can't false-pass the check).
//    • Autorun: launch with `defaults write com.port42.dev PORT42_SPIKE3_AUTORUN -bool true`
//      (one-shot, self-clearing) — the panel opens at startup and runs the full sequence
//      hands-free. Or open from the Debug menu and press "run full test".
//    • Human residue: run `vim` (or `less ~/.zshrc`), cycle again, quit clean — TUI redraws
//      at both sizes, no corruption. (The typing half is now automated by the round-trip.)
//
//  Green → terminals ride the unit path from Phase 0. Red → Phase 0 ships with the
//  terminal-exclusion predicate from the start (§8 gate note).
//
//  Launch: Debug menu → "Ghostty Resize Spike (I6)".

#if DEBUG
import SwiftUI
import AppKit
import GhosttyKit

enum GhosttySpikeLog {
    static func p(_ s: String) {
        let url = URL(fileURLWithPath: "/tmp/spike3-ghostty.log")
        let line = "\(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}

/// Global make/update counters — a remake here == a reparent in production (the I2 half;
/// I6 adds "and the PTY survived").
final class GhosttySpikeCounters {
    static var make = 0
    static var update = 0
}

/// Accumulates the surface's pty tee output so the round-trip check can search it.
@MainActor
final class GhosttySpikeTeeBuffer {
    private(set) var text = ""
    func append(_ s: String) { text += s }
    func contains(_ needle: String) -> Bool { text.contains(needle) }
}

/// The persistent host — same contract as ShellPortHost: reparent on make, no-op on update.
struct SpikeTerminalHost: NSViewRepresentable {
    let term: GhosttyInputView

    func makeNSView(context: Context) -> NSView {
        GhosttySpikeCounters.make += 1
        let c = NSView()
        term.removeFromSuperview()
        c.addSubview(term)
        term.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: c.topAnchor),
            term.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            term.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: c.trailingAnchor),
        ])
        GhosttySpikeLog.p("MAKE #\(GhosttySpikeCounters.make)  term.window=\(term.window != nil) super=\(term.superview != nil)")
        return c
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        GhosttySpikeCounters.update += 1
        GhosttySpikeLog.p("UPDATE #\(GhosttySpikeCounters.update) make=\(GhosttySpikeCounters.make) term.window=\(term.window != nil) superIsContainer=\(term.superview === nsView) size=\(Int(nsView.frame.width))x\(Int(nsView.frame.height))")
    }
}

struct GhosttyResizeSpikeView: View {
    let term: GhosttyInputView
    let tee: GhosttySpikeTeeBuffer
    var autorun = false
    @State private var isFull = false
    @State private var status = "idle — press 'run full test' (or autorun); vim + cycle is the human residue"
    @State private var tick = 0   // forces the readout to refresh

    /// The shell process behind the surface is still alive (the PTY-intact assertion).
    private var processAlive: Bool {
        guard let s = term.surface else { return false }
        return !ghostty_surface_process_exited(s)
    }

    /// Type a line into the surface (body, then Enter on its own tick — the production
    /// inject pattern) — this is "the human typed" done programmatically.
    private func inject(_ line: String) {
        guard let s = term.surface else { return }
        line.withCString { ghostty_surface_text_input(s, $0, UInt(strlen($0))) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let s = term.surface else { return }
            "\r".withCString { ghostty_surface_text_input(s, $0, 1) }
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25).ignoresSafeArea()

                // The unit: ONE persistent host; only .frame/.position/.zIndex change.
                // Mini = the peek-rail footprint (210 wide) — the harshest real target size.
                // Identity keyed on a constant, NEVER on isFull — the I2 contract.
                SpikeTerminalHost(term: term)
                    .frame(width: isFull ? geo.size.width - 40 : 210,
                           height: isFull ? geo.size.height - 150 : 140)
                    .position(x: isFull ? geo.size.width / 2 : 125,
                              y: isFull ? (geo.size.height - 110) / 2 : 110)
                    .zIndex(isFull ? 5 : 1)
                    .id("spike-ghostty-unit")   // stable ⇒ SwiftUI must reuse (I2)

                // Controls + live readout (bottom, clear of the full-size terminal)
                VStack(alignment: .leading, spacing: 8) {
                    Spacer()
                    Text(status).font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(status.hasPrefix("PASS") ? .green : (status.hasPrefix("FAIL") ? .red : .white))
                    Text("make=\(GhosttySpikeCounters.make)  update=\(GhosttySpikeCounters.update)  window=\(term.window != nil ? "Y" : "N")  ptyAlive=\(processAlive ? "Y" : "N")  tick=\(tick)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.cyan)
                    HStack(spacing: 10) {
                        Button("run full test") { runFullTest() }
                        Button("toggle size") { withAnimation(.spring(response: 0.4)) { isFull.toggle() }; tick += 1 }
                        Button("cycle 10×") { runCycle(10) { _ in } }
                        Button("focus term") { term.window?.makeFirstResponder(term) }
                        Button("reset") { GhosttySpikeCounters.make = 0; GhosttySpikeCounters.update = 0; tick += 1; status = "reset" }
                    }.font(.system(size: 12, design: .monospaced))
                }
                .padding(16)
            }
        }
        .onAppear {
            // Autorun (hands-free CI-ish mode): let the shell prompt settle, then run everything.
            if autorun { DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { runFullTest() } }
        }
    }

    /// The whole I6 sequence, hands-free: PTY round-trip BEFORE (echo through the surface,
    /// output observed on the tee), resize cycle ×10, PTY round-trip AFTER, then one verdict.
    /// `$((6*7))` keeps the expected OUTPUT ("…-42") distinct from the TYPED text, so the
    /// terminal echoing our own keystrokes back can't false-pass the check.
    private func runFullTest() {
        status = "round-trip BEFORE…"
        GhosttySpikeLog.p("FULL TEST — inject before")
        inject("echo SPIKE3-BEFORE-$((6*7))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let before = tee.contains("SPIKE3-BEFORE-42")
            GhosttySpikeLog.p("round-trip before: \(before ? "OK" : "MISSING")")
            status = "cycling…"
            runCycle(10) { cyclePass in
                status = "round-trip AFTER…"
                GhosttySpikeLog.p("FULL TEST — inject after")
                inject("echo SPIKE3-AFTER-$((6*7))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let after = tee.contains("SPIKE3-AFTER-42")
                    let pass = cyclePass && before && after
                    status = "\(pass ? "PASS" : "FAIL")  make=\(GhosttySpikeCounters.make) rtBefore=\(before ? "Y" : "N") rtAfter=\(after ? "Y" : "N") window=\(term.window != nil ? "Y" : "N") ptyAlive=\(processAlive ? "Y" : "N")"
                    GhosttySpikeLog.p("SPIKE3 RESULT — \(status)")
                    tick += 1
                }
            }
        }
    }

    /// Toggle mini↔full n times with animation, then assert I2 (make==1) + window attached
    /// + the shell process alive. Calls `done(pass)` so the full test can chain the after-check.
    private func runCycle(_ n: Int, done: @escaping (Bool) -> Void) {
        status = "cycling…"
        var i = 0
        func step() {
            guard i < n * 2 else {
                let pass = GhosttySpikeCounters.make == 1 && term.window != nil && processAlive
                status = "cycle \(pass ? "ok" : "FAIL")  make=\(GhosttySpikeCounters.make) update=\(GhosttySpikeCounters.update) window=\(term.window != nil ? "Y" : "N") ptyAlive=\(processAlive ? "Y" : "N")"
                GhosttySpikeLog.p("CYCLE DONE — \(status)")
                tick += 1
                term.window?.makeFirstResponder(term)   // hand the keyboard back for the human residue
                done(pass)
                return
            }
            withAnimation(.spring(response: 0.22)) { isFull.toggle() }
            i += 1
            tick += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { step() }
        }
        step()
    }
}

/// Opens the spike in its own floating panel (mirrors PortResizeSpikeHarness). Owns the
/// detached terminal's lifetime: makeDetached's caller owns teardown, so the surface is
/// freed on panel close — never by a SwiftUI unmount.
@MainActor
public final class GhosttyResizeSpikeHarness: NSObject, NSWindowDelegate {
    public static let shared = GhosttyResizeSpikeHarness()
    private var panel: NSPanel?
    private var term: GhosttyInputView?
    private var coordinator: GhosttyTerminalView.Coordinator?

    public func run(autorun: Bool = false) {
        if let panel { panel.makeKeyAndOrderFront(nil); return }

        // The production hoisted-terminal path (what shell tiles host) — not a bespoke rig.
        let cfg = TerminalPortConfig(
            command: "/bin/zsh", args: [], cwd: NSHomeDirectory(),
            spaceId: "spike3", spaceName: "spike3", companionName: "spike3", createdBy: "spike"
        )
        let tee = GhosttySpikeTeeBuffer()
        let (view, coordinator) = GhosttyTerminalView.makeDetached(
            config: cfg, env: [:], onTee: { s in Task { @MainActor in tee.append(s) } }, onInject: { _ in }
        )
        self.term = view
        self.coordinator = coordinator

        GhosttySpikeCounters.make = 0
        GhosttySpikeCounters.update = 0
        GhosttySpikeLog.p("=== SPIKE 3 (Ghostty I6) START\(autorun ? " (autorun)" : "") ===")

        let hosting = NSHostingView(rootView: GhosttyResizeSpikeView(term: view, tee: tee, autorun: autorun))
        hosting.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.title = "Ghostty Resize Spike — I6 (resize-in-place, PTY intact)"
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
        GhosttySpikeLog.p("panel shown")
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        coordinator?.teardown()   // we own the detached surface's lifetime
        coordinator = nil
        term = nil
        panel = nil
        return true
    }
}
#endif
