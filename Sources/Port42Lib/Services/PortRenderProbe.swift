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
import WebKit

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

    /// A port was legitimately CLOSED — drop it from the watch. Its view going windowless is
    /// correct (it's gone), not a violation; without this, a harness that closes a fabricated
    /// port poisons every later sweep (the kinds run's terminal flagged the browser's run).
    public static func untrack(_ id: String) {
        tracked.removeValue(forKey: id)
        makes.removeValue(forKey: id)
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

    // MARK: - Phase 1 gate: the peek repro, scripted (§9 "THE regression that would've
    // caught the original grey"). Fabricates two web ports in ANOTHER space (their births
    // raise peeks), then drives `preview ONE → out → preview TWO → out → preview ONE → out`,
    // then KEEPS one mid-run (adopt must not remount). Kill criterion 3: any windowless →
    // the root cause isn't fixed; stop.

    public func runPeekRepro() {
        guard !running else { return }
        guard let shell = ShellState.debugCurrent, let app = shell.debugAppState,
              let current = app.currentSpace?.id,
              let other = app.spaces.first(where: { $0.id != current })?.id else {
            PortRenderProbe.log("PEEK REPRO — no shell / no second space; abort")
            return
        }
        running = true
        PortRenderProbe.reset()
        PortRenderProbe.enabled = true
        PortRenderProbe.log("=== PEEK REPRO — ports in \(other.prefix(8)), watched from \(current.prefix(8)) ===")

        let stamp = String(UUID().uuidString.prefix(6))
        let ids = ["peek-\(stamp)-1", "peek-\(stamp)-2"]
        for (i, id) in ids.enumerated() {
            _ = app.portWindows.registerTiledPort(
                id: id,
                html: "<html><title>peek \(i + 1)</title><body style=\"background:#1a0f2e;color:#9ff;font-family:monospace;display:flex;align-items:center;justify-content:center;height:100vh\"><h1>PEEK \(i + 1)</h1><script>setInterval(()=>{document.title='t'+Date.now()},500)</script></body></html>",
                spaceId: other, createdBy: "peek-repro", title: "peek \(i + 1)", position: nil)
        }

        sweep = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in PortRenderProbe.checkAll("frame") }
        }

        func peek(_ id: String) -> ShellState.PeekPort? { shell.peekingPorts.first { $0.id == id } }
        var steps: [(String, () -> Void)] = []
        func preview(_ id: String) { if let p = peek(id) { shell.previewPeek(p) } else { PortRenderProbe.log("MISSING peek \(id)") } }
        func out() { withAnimation(.spring(response: 0.4)) { shell.zoom = .space }; shell.settleAfterPreview() }

        steps.append(("peeks-raised", {
            if shell.peekingPorts.filter({ ids.contains($0.id) }).count != 2 {
                PortRenderProbe.log("VIOLATION setup: expected 2 peeks, have \(shell.peekingPorts.count)")
            }
        }))
        steps.append(("preview-1", { preview(ids[0]) }))
        steps.append(("out-1",     { out() }))
        steps.append(("preview-2", { preview(ids[1]) }))
        steps.append(("out-2",     { out() }))
        steps.append(("preview-1-again", { preview(ids[0]) }))   // the original grey trigger
        steps.append(("out-3",     { out() }))
        steps.append(("keep-2",    { if let p = peek(ids[1]) { shell.keepPeek(p) } }))   // adopt: no remount
        steps.append(("post-keep", { }))

        var i = 0
        func step() {
            guard i < steps.count else {
                // Cleanup: drop the fabricated ports + any leftover peek/surfaced entries.
                for id in ids {
                    if let p = peek(id) { shell.dismissPeek(p) }
                    shell.surfacedPortIds.remove(id)
                    app.portWindows.close(id)
                    PortRenderProbe.untrack(id)   // closed = correctly windowless, off the watch
                }
                finish(shell: shell)
                return
            }
            let (phase, act) = steps[i]
            act()
            i += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                PortRenderProbe.checkAll(phase)
                step()
            }
        }
        // Let the portCreated sink deliver + the peek units mount before driving.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { step() }
    }

    /// Autorun entry for the peek repro (launch flag): wait for the shell — and for any
    /// other harness run (the Phase 0 cycle) to finish — then run.
    public func runPeekReproWhenReady() {
        if !running, ShellState.debugCurrent?.debugAppState?.currentSpace != nil {
            runPeekRepro(); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.runPeekReproWhenReady() }
    }

    // MARK: - Phase 2 gate: per-kind cycles (§9 Phase 2 Tier B). Every port kind — web,
    // terminal, browser — rides the same unit path; each gets its own 10× focus↔space cycle
    // with the probe armed. Browser additionally navigates MID-RUN (the live webview must
    // survive a load across focus geometry). Uses an existing tile of the kind when one is
    // on the desktop, else fabricates one (and cleans it up after). Terminal PTY integrity
    // is Spike 3's harness + Tier C typing; here the terminal proves mount/window health.

    private struct KindRun { let kind: String; let id: String; let fabricated: Bool }
    private var kindVerdicts: [String] = []

    public func runKinds() {
        guard !running else { return }
        guard let shell = ShellState.debugCurrent, let app = shell.debugAppState,
              let sid = app.currentSpace?.id else {
            PortRenderProbe.log("KINDS — no shell/space; abort"); return
        }
        running = true
        kindVerdicts = []
        PortRenderProbe.log("=== PORT UNITS KINDS — web / terminal / browser ===")
        nextKind(0, shell: shell, app: app, sid: sid)
    }

    private func nextKind(_ i: Int, shell: ShellState, app: AppState, sid: String) {
        let kinds = ["web", "terminal", "browser"]
        guard i < kinds.count else {
            let pass = kindVerdicts.allSatisfy { $0.hasSuffix("PASS") }
            PortRenderProbe.log("KINDS \(pass ? "PASS" : "FAIL")  [\(kindVerdicts.joined(separator: " · "))]")
            running = false
            return
        }
        let kind = kinds[i]
        guard let run = acquireKind(kind, app: app, sid: sid) else {
            kindVerdicts.append("\(kind) FAIL")
            PortRenderProbe.log("KINDS \(kind) — could not acquire a tile; FAIL")
            nextKind(i + 1, shell: shell, app: app, sid: sid)
            return
        }
        // Let the unit mount; a fabricated same-space birth peeks — clear the peek entry so
        // the unit settles to a plain tile (geometry only; the mounted view is untouched).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if let p = shell.peekingPorts.first(where: { $0.id == run.id }) { shell.dismissPeek(p) }
            self.cycleOneKind(run, shell: shell, app: app) {
                self.nextKind(i + 1, shell: shell, app: app, sid: sid)
            }
        }
    }

    /// An existing tiled non-chat panel of this kind with a live view, else a fabricated one.
    private func acquireKind(_ kind: String, app: AppState, sid: String) -> KindRun? {
        if let p = app.portWindows.panels.first(where: {
            $0.spaceId == sid && $0.presentation == "tiled" && !$0.isChatPort
                && $0.portType == kind && app.portWindows.hostView(for: $0.id) != nil
        }) { return KindRun(kind: kind, id: p.id, fabricated: false) }
        let stamp = String(UUID().uuidString.prefix(6))
        switch kind {
        case "web":
            let id = "kind-web-\(stamp)"
            _ = app.portWindows.registerTiledPort(
                id: id,
                html: "<html><title>kind web</title><body style=\"background:#102a1a;color:#9f9;font-family:monospace;display:flex;align-items:center;justify-content:center;height:100vh\"><h1>WEB</h1><script>setInterval(()=>{document.title='t'+Date.now()},500)</script></body></html>",
                spaceId: sid, createdBy: "kinds-harness", title: "kind web", position: nil)
            return KindRun(kind: kind, id: id, fabricated: true)
        case "browser":
            let id = app.portWindows.addTiledBrowserPanel(url: "https://example.com",
                                                          spaceId: sid, createdBy: "kinds-harness",
                                                          title: "kind browser")
            return id.isEmpty ? nil : KindRun(kind: kind, id: id, fabricated: true)
        case "terminal":
            guard let id = app.spawnNativeTerminalPort(
                command: "/bin/zsh", cwd: NSHomeDirectory(), spaceId: sid,
                title: "kind term", companionName: "kinds-harness",
                postCard: false, startupCommandOverride: "") else { return nil }
            return KindRun(kind: kind, id: id, fabricated: true)
        default: return nil
        }
    }

    /// One kind's 10× focus↔space cycle with the probe armed (browser navigates mid-run).
    private func cycleOneKind(_ run: KindRun, shell: ShellState, app: AppState,
                              completion: @escaping () -> Void) {
        PortRenderProbe.reset()
        PortRenderProbe.enabled = true
        PortRenderProbe.log("--- KINDS \(run.kind) — target \(run.id.prefix(8)) (\(run.fabricated ? "fabricated" : "existing")) ---")
        sweep = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in PortRenderProbe.checkAll("frame") }
        }
        var step = 0
        func finishKind() {
            self.sweep?.invalidate(); self.sweep = nil
            withAnimation(.spring(response: 0.4)) { shell.zoom = .space }
            let v = PortRenderProbe.violations
            let verdict = v.isEmpty ? "PASS" : "FAIL"
            self.kindVerdicts.append("\(run.kind) \(verdict)")
            PortRenderProbe.log("KINDS \(run.kind) \(verdict)  \(PortRenderProbe.makesDescription)")
            for viol in v { PortRenderProbe.log("  FAIL(\(viol))") }
            PortRenderProbe.enabled = false
            if run.fabricated {
                shell.surfacedPortIds.remove(run.id)
                app.portWindows.close(run.id)
                PortRenderProbe.untrack(run.id)   // closed = correctly windowless, off the watch
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completion() }
        }
        func tick() {
            guard step < 20 else { finishKind(); return }
            let toFocus = step % 2 == 0
            withAnimation(.spring(response: 0.4)) { shell.zoom = toFocus ? .focus(run.id) : .space }
            // Browser: navigate mid-run — a load must not detach/blank the unit.
            if run.kind == "browser", step == 9,
               let wv = app.portWindows.hostView(for: run.id) as? WKWebView {
                wv.loadHTMLString(
                    "<html><body style=\"background:#0b2239;color:#8fd;font-family:monospace\"><h1>NAVIGATED MID-CYCLE</h1></body></html>",
                    baseURL: nil)
            }
            step += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                PortRenderProbe.checkAll(toFocus ? "focus" : "space")
                tick()
            }
        }
        tick()
    }

    /// Autorun entry for the kinds cycle (launch flag): wait for the shell, then run.
    public func runKindsWhenReady() {
        if !running, ShellState.debugCurrent?.debugAppState?.currentSpace != nil {
            runKinds(); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.runKindsWhenReady() }
    }
}
#endif
