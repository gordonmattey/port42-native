//  PortRenderProbe.swift
//
//  Tier B instrument for the "Port Units — resize, don't reparent" refactor
//  (docs/plan-port-units-render-refactor.md §9). Turns "did it blank" into checkable
//  conditions: for every staged port, across every transition,
//
//    • makeNSView ran EXACTLY ONCE per port lifetime  (>1 ⇒ a reparent/remake — the bug),
//    • the live view's window is never nil            (windowless ⇒ surface discarded ⇒ blank),
//    • the view stays in the container its host made  (orphaned/stolen ⇒ competing mounts).
//
//  If those hold, the port CANNOT blank. Deviation from the §9 sketch: violations are
//  RECORDED and reported as FAIL(id, reason) instead of crashing on assert — the
//  calibration run (point the harness at TODAY'S reparenting code, expect FAIL) needs the
//  app alive to finish the cycle and print its verdict. In production this is all dormant
//  (`enabled == false`, wire points are #if DEBUG).
//
//  The harness ("Port Units — cycle") drives the REAL shell: it focuses/unfocuses a real
//  desktop tile 10× with `enabled = true` (plus a ~30Hz health sweep), then prints
//  PASS / FAIL(id, reason) to /tmp/portunit.log. Debug menu → "Port Units — cycle", or
//  hands-free at launch via the one-shot `PORT42_PROBE_AUTORUN` defaults flag (it waits
//  for the shell to be unlocked and a tile to exist, then runs).

#if DEBUG
import SwiftUI
import AppKit

@MainActor
public enum PortRenderProbe {
    /// On only during a harness run; every hook is a no-op otherwise.
    public static var enabled = false

    private struct Tracked { weak var view: NSView?; weak var container: NSView? }
    private static var tracked: [String: Tracked] = [:]
    public private(set) static var makes: [String: Int] = [:]
    /// Deduped "id | reason" violations collected during a run.
    public private(set) static var violations: [String] = []
    private static var seenViolations: Set<String> = []

    /// Call from every ShellPortHost.makeNSView that hosts a port's live view.
    public static func recordMake(_ id: String, view: NSView, container: NSView) {
        makes[id, default: 0] += 1
        let alreadyMounted = tracked[id]?.view != nil     // a make on a tracked id = a REMOUNT
        tracked[id] = Tracked(view: view, container: container)
        log("MAKE \(id) #\(makes[id]!)")
        if enabled, alreadyMounted || makes[id]! > 1 {
            violate(id, "remade (run-make #\(makes[id]!)) — reparent leak")
        }
    }

    /// Health of one staged port: in a window, still in its own container.
    public static func assertHealthy(_ id: String, phase: String) {
        guard enabled, let t = tracked[id], let v = t.view else { return }
        if v.window == nil {
            violate(id, "WINDOWLESS (\(phase)) — will blank")
        } else if let c = t.container, v.superview !== c {
            violate(id, "orphaned/stolen from its container (\(phase))")
        }
    }

    /// Sweep every tracked port (the harness calls this per transition + ~30Hz).
    public static func checkAll(_ phase: String) {
        for id in tracked.keys { assertHealthy(id, phase: phase) }
    }

    /// Clear counters/violations for a fresh run — but KEEP the tracked views: a port mounted
    /// BEFORE the run (the fixed, mount-once world) must still get health sweeps during it. On
    /// the fixed code a clean run shows zero makes (never remounted) and a swept, healthy view.
    public static func reset() {
        makes.removeAll(); violations.removeAll(); seenViolations.removeAll()
    }

    public static var makesDescription: String {
        makes.isEmpty ? "makes[—]"
            : "makes[" + makes.keys.sorted().map { "\($0.prefix(8))=\(makes[$0]!)" }.joined(separator: " ") + "]"
    }

    private static func violate(_ id: String, _ reason: String) {
        let key = "\(id)|\(reason.prefix(24))"                 // dedupe the per-frame spam
        guard !seenViolations.contains(key) else { return }
        seenViolations.insert(key)
        violations.append("\(id): \(reason)")
        log("VIOLATION \(id): \(reason)")
    }

    public static func log(_ s: String) {
        let url = URL(fileURLWithPath: "/tmp/portunit.log")
        let line = "\(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}

/// The Tier-B acceptance harness: cycles a real desktop tile focus ↔ space ×10 on the LIVE
/// shell with the probe armed. §9: "This is the acceptance test — a FAIL means the root
/// cause isn't fixed; do not proceed." Run first against today's code as calibration
/// (expected: FAIL, make > 1 — proves the instrument detects the disease).
@MainActor
public final class PortUnitCycleHarness {
    public static let shared = PortUnitCycleHarness()
    private var running = false
    private var sweep: Timer?

    /// Debug-menu entry — the shell must be unlocked with a web/browser/terminal tile on it.
    public func run() {
        guard !running else { return }
        if let (shell, id) = target() { start(shell: shell, id: id) }
        else { PortRenderProbe.log("CYCLE — no target (shell locked / no non-chat tile with a live view)") }
    }

    /// Autorun entry (launch flag): wait until the shell is up + a tile exists, then run.
    public func runWhenReady() {
        guard !running else { return }
        if let (shell, id) = target() { start(shell: shell, id: id); return }
        PortRenderProbe.log("CYCLE — waiting for shell + tile…")
        poll()
    }
    private func poll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.running else { return }
            if let (shell, id) = self.target() { self.start(shell: shell, id: id) } else { self.poll() }
        }
    }

    /// The first current-space tiled non-chat panel with a live registry view.
    private func target() -> (ShellState, String)? {
        guard let shell = ShellState.debugCurrent, let app = shell.debugAppState,
              let sid = app.currentSpace?.id else { return nil }
        let panel = app.portWindows.panels.first {
            $0.spaceId == sid && $0.presentation == "tiled" && !$0.isChatPort
                && app.portWindows.hostView(for: $0.id) != nil
        }
        guard let panel else { return nil }
        return (shell, panel.id)
    }

    private func start(shell: ShellState, id: String) {
        running = true
        PortRenderProbe.reset()
        PortRenderProbe.enabled = true
        PortRenderProbe.log("=== PORT UNITS CYCLE — target \(id) ===")
        // The tile's initial mount happened before reset(), so during the run ANY make is a
        // remount: today's reparenting code produces make≥1 + container churn (FAIL); the
        // fixed unit model produces zero makes and a continuously healthy view (PASS).
        sweep = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in PortRenderProbe.checkAll("frame") }
        }
        var i = 0
        func step() {
            guard i < 20 else { finish(shell: shell); return }
            let toFocus = i % 2 == 0
            withAnimation(.spring(response: 0.4)) { shell.zoom = toFocus ? .focus(id) : .space }
            i += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                PortRenderProbe.checkAll(toFocus ? "focus" : "space")
                step()
            }
        }
        step()
    }

    private func finish(shell: ShellState) {
        sweep?.invalidate(); sweep = nil
        withAnimation(.spring(response: 0.4)) { shell.zoom = .space }
        let v = PortRenderProbe.violations
        if v.isEmpty {
            PortRenderProbe.log("PASS  \(PortRenderProbe.makesDescription)")
        } else {
            PortRenderProbe.log("FAIL  \(PortRenderProbe.makesDescription)")
            for viol in v { PortRenderProbe.log("  FAIL(\(viol))") }
        }
        PortRenderProbe.enabled = false
        running = false
    }
}
#endif
