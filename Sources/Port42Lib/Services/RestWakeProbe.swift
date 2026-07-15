//  RestWakeProbe.swift
//
//  Tier B instrument for Rest/Wake — the working set (docs/plan-working-set.md §A).
//  Turns "is a rested space actually silent" into checkable conditions on the LIVE shell
//  (belt-and-braces over the headless RestWakeTests — same assertions, real app, real
//  Combine sinks/observations in the loop):
//
//    • rest round-trips through the DB and the space leaves the working set,
//    • a port BORN in a rested space raises no peek (the real portCreated sink path),
//    • a chat-unread bump in a rested space raises no peek,
//    • after WAKE the same bump DOES peek (calibration: proves the instrument can
//      see peeks at all — silence isn't just a dead notification pipe).
//
//  Fabricates one scratch space (+ one port in it) in the DEV instance, cleans both up,
//  returns to the space it started in, and prints REST PASS / REST FAIL(reason…) to
//  /tmp/portunit.log. Debug menu → "Rest/Wake — probe", or hands-free at launch via the
//  one-shot `PORT42_PROBE_REST_AUTORUN` defaults flag.

#if DEBUG
import SwiftUI
import AppKit

@MainActor
public final class RestWakeProbeHarness {
    public static let shared = RestWakeProbeHarness()
    private var running = false
    private var violations: [String] = []

    private func violate(_ reason: String) {
        violations.append(reason)
        PortRenderProbe.log("VIOLATION rest-probe: \(reason)")
    }

    /// Autorun entry (launch flag): wait until the shell is unlocked with a current space.
    public func runWhenReady() {
        if !running, ShellState.debugCurrent?.debugAppState?.currentSpace != nil {
            run(); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.runWhenReady() }
    }

    public func run() {
        guard !running else { return }
        guard let shell = ShellState.debugCurrent, let app = shell.debugAppState,
              let home = app.currentSpace else {
            PortRenderProbe.log("REST — no shell/space; abort"); return
        }
        running = true
        violations = []
        // Lowercased: createSpace normalizes names to lowercase-dashes, and we look the
        // scratch space back up by name.
        let stamp = String(UUID().uuidString.prefix(6)).lowercased()
        let spaceName = "rest-probe-\(stamp)"
        let portId = "rest-probe-port-\(stamp)"
        PortRenderProbe.log("=== REST/WAKE PROBE — scratch \(spaceName), home \(home.name) ===")

        // Fabricate the scratch space (createSpace selects it) and come straight home.
        app.createSpace(name: spaceName)
        guard let scratch = app.spaces.first(where: { $0.name == spaceName }) else {
            PortRenderProbe.log("REST FAIL — could not create scratch space")
            running = false
            return
        }
        app.selectSpace(home)

        /// Bump the scratch space's chat-unread by one over the LIVE counts (merging keeps
        /// every other space's baseline intact, so the direct drive can't raise phantom peeks).
        func bumpChat() {
            var counts = app.unreadCounts
            counts[scratch.id] = (counts[scratch.id] ?? 0) + 1
            shell.refreshNotifications(from: counts)
        }
        func chatPeek() -> ShellState.PeekPort? {
            shell.peekingPorts.first { $0.isChat && $0.spaceId == scratch.id }
        }
        func fresh() -> Space? { app.spaces.first { $0.id == scratch.id } }

        var steps: [(String, () -> Void)] = []

        steps.append(("rest", {
            guard let s = fresh() else { self.violate("scratch space vanished before rest"); return }
            shell.restSpace(s)
            guard let rested = fresh(), rested.isResting else {
                self.violate("restedAt not set after restSpace (round-trip)"); return
            }
            if app.workingSpaces.contains(where: { $0.id == scratch.id }) {
                self.violate("rested space still in workingSpaces")
            }
            if !app.restingSpaces.contains(where: { $0.id == scratch.id }) {
                self.violate("rested space missing from restingSpaces (shelf source)")
            }
        }))
        steps.append(("silent-port-birth", {
            // A port born in the rested space — through the REAL portCreated sink.
            _ = app.portWindows.registerTiledPort(
                id: portId,
                html: "<html><title>rest probe</title><body style=\"background:#1a0f2e;color:#9ff;font-family:monospace\"><h1>REST</h1></body></html>",
                spaceId: scratch.id, createdBy: "rest-probe", title: "rest probe", position: nil)
        }))
        steps.append(("assert-port-silence", {
            if shell.peekingPorts.contains(where: { $0.id == portId }) {
                self.violate("port birth in a rested space raised a peek")
            }
        }))
        steps.append(("silent-chat-bump", {
            bumpChat()
            if chatPeek() != nil { self.violate("chat unread in a rested space raised a peek") }
        }))
        steps.append(("wake", {
            guard let s = fresh() else { self.violate("scratch space vanished before wake"); return }
            app.wakeSpace(s)
            guard let woken = fresh(), !woken.isResting else {
                self.violate("restedAt not cleared after wakeSpace (round-trip)"); return
            }
            if !app.workingSpaces.contains(where: { $0.id == scratch.id }) {
                self.violate("woken space missing from workingSpaces")
            }
        }))
        steps.append(("calibrate-awake-peeks", {
            // The same bump must peek NOW — otherwise the "silence" above proved nothing.
            bumpChat()
            if let p = chatPeek() { shell.dismissPeek(p) }
            else { self.violate("calibration: chat bump in a WORKING space raised no peek — instrument blind") }
        }))

        var i = 0
        func step() {
            guard i < steps.count else {
                // Cleanup: drop the fabricated port + space, land back home.
                if let p = shell.peekingPorts.first(where: { $0.id == portId }) { shell.dismissPeek(p) }
                app.portWindows.close(portId)
                if let s = fresh() { app.deleteSpace(s) }
                app.selectSpace(home)
                let v = self.violations
                if v.isEmpty { PortRenderProbe.log("REST PASS") }
                else {
                    PortRenderProbe.log("REST FAIL")
                    for viol in v { PortRenderProbe.log("  FAIL(\(viol))") }
                }
                self.running = false
                return
            }
            let (phase, act) = steps[i]
            act()
            i += 1
            // Long enough for the portCreated sink / DB observations to deliver between steps.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                PortRenderProbe.log("rest-probe · \(phase) done")
                step()
            }
        }
        // Let createSpace's observations settle before driving.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { step() }
    }
}
#endif
