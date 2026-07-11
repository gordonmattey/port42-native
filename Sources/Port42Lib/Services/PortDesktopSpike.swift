//  PortDesktopSpike.swift
//
//  Spike 2 (pre-Phase 0) for the "Port Units — resize, don't reparent" refactor
//  (docs/plan-port-units-render-refactor.md §6). Spike 1 proved I2 for ONE persistent host
//  in a clean ZStack; the real desktop adds stressors it never exercised. This spike runs
//  FOUR persistent web units (A–D, each a live WKWebView with a ticking JS counter) through:
//
//    1. REORDER    — bringToFront bumps a unit's z and re-sorts the ForEach data array
//                    (exactly the desktop's hover → bringToFront → sorted-by-z churn).
//                    Answers: does a stable-id ForEach REORDER remake NSViews?
//    2. CHURN      — a fifth unit (X) inserted/removed while the others sit, with the
//                    desktop's insertion spring attached. Survivors must stay make==1.
//    3. SCALE      — scaleEffect toggled on the units (exposé).
//    4. OVERLAY    — a conditional chrome subview toggled inside each unit.
//    5. COMBINED   — focus-resize (mini↔focusRect) + reorder + churn interleaved, the way
//                    a real desktop actually moves.
//
//  Hit-test slice (manual, 10s): each page has a "click me" button showing its own click
//  count — while a unit is focused over the dim backdrop, a click must reach the page.
//
//  Read the result: /tmp/spike2-desktop.log — SPIKE2 RESULT prints PASS iff every core
//  unit has make==1 and no unit was ever windowless at a step boundary. X (the churn unit)
//  is EXEMPT from make==1 — it re-mounts by design; its count is logged for the record.
//  A remake under one stressor is a design input, not a kill (§8 gate 1).
//
//  Launch: Debug menu → "Port Desktop Spike (I2 stressors)", or hands-free via the
//  one-shot `PORT42_SPIKE2_AUTORUN` defaults flag.

#if DEBUG
import SwiftUI
import AppKit
import WebKit

enum Spike2Log {
    static func p(_ s: String) {
        let url = URL(fileURLWithPath: "/tmp/spike2-desktop.log")
        let line = "\(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}

@MainActor
final class Spike2Counters {
    static var makes: [String: Int] = [:]
    static var updates = 0
    static var windowless: [String] = []          // "id@phase" events at step boundaries
    static func reset() { makes = [:]; updates = 0; windowless = [] }
}

/// The persistent host — same contract as ShellPortHost: reparent on make, no-op on update.
struct Spike2Host: NSViewRepresentable {
    let id: String
    let web: WKWebView

    func makeNSView(context: Context) -> NSView {
        Spike2Counters.makes[id, default: 0] += 1
        let c = NSView()
        web.removeFromSuperview()
        c.addSubview(web)
        web.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: c.topAnchor),
            web.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: c.trailingAnchor),
        ])
        Spike2Log.p("MAKE \(id) #\(Spike2Counters.makes[id]!)  window=\(web.window != nil)")
        return c
    }

    func updateNSView(_ nsView: NSView, context: Context) { Spike2Counters.updates += 1 }
}

struct DesktopSpikeUnit: Identifiable, Equatable { let id: String; var z: Int }

struct PortDesktopSpikeView: View {
    let webs: [String: WKWebView]
    var autorun = false
    @State private var units: [DesktopSpikeUnit]
    @State private var scaled = false
    @State private var overlayOn = false
    @State private var focusedId: String?
    @State private var zCounter: Int
    @State private var status = "idle — press 'run all' (or autorun); hit-test: focus a unit, click its button"
    @State private var tick = 0

    static let coreIds = ["A", "B", "C", "D"]

    init(webs: [String: WKWebView], autorun: Bool = false) {
        self.webs = webs
        self.autorun = autorun
        _units = State(initialValue: Self.coreIds.enumerated().map { DesktopSpikeUnit(id: $1, z: $0 + 1) })
        _zCounter = State(initialValue: Self.coreIds.count)
    }

    /// A fixed home slot per id (frames never depend on ARRAY ORDER — so a reorder that
    /// visually moves nothing but remakes a view is unmistakably identity churn).
    private func slot(_ id: String) -> CGRect {
        let w: CGFloat = 300, h: CGFloat = 200
        switch id {
        case "A": return CGRect(x: 40,  y: 60,  width: w, height: h)
        case "B": return CGRect(x: 360, y: 60,  width: w, height: h)
        case "C": return CGRect(x: 40,  y: 280, width: w, height: h)
        case "D": return CGRect(x: 360, y: 280, width: w, height: h)
        default:  return CGRect(x: 40,  y: 500, width: w, height: h)   // X, the churn unit
        }
    }
    private func rect(_ id: String, _ area: CGSize) -> CGRect {
        focusedId == id
            ? CGRect(x: area.width * 0.11, y: area.height * 0.06, width: area.width * 0.78, height: area.height * 0.68)
            : slot(id)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25).ignoresSafeArea()

                // Focus backdrop sibling (the desktop's tap-to-exit dim layer) — hit-testable,
                // BELOW the focused unit: clicks on the focused page must still land (the slice).
                if focusedId != nil {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.spring(response: 0.3)) { focusedId = nil } }
                        .zIndex(999)
                }

                ForEach(units) { u in
                    unit(u, geo.size)
                        .zIndex(focusedId == u.id ? 1_000 : Double(u.z))
                }

                controls
            }
        }
        // The desktop's own animation modifiers, reproduced:
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: units.count)   // insertion spring
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: scaled)      // exposé spring
        .onAppear {
            if autorun { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runAll() } }
        }
    }

    private func unit(_ u: DesktopSpikeUnit, _ area: CGSize) -> some View {
        let r = rect(u.id, area)
        return VStack(spacing: 0) {
            if overlayOn {                       // conditional chrome churn INSIDE the unit
                Text("CHROME \(u.id)")
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity).padding(3)
                    .background(Color.blue.opacity(0.6))
            }
            Spike2Host(id: u.id, web: webs[u.id]!)
        }
        .frame(width: r.width, height: r.height)
        .scaleEffect(scaled && focusedId != u.id ? 0.6 : 1.0)     // exposé shrinks non-focused units
        .position(x: r.midX, y: r.midY)
        .id(u.id)                                                  // identity = port id ONLY (I4)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Text(status).font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(status.hasPrefix("PASS") ? .green : (status.hasPrefix("FAIL") ? .red : .white))
            Text("makes \(Self.coreIds.map { "\($0)=\(Spike2Counters.makes[$0] ?? 0)" }.joined(separator: " "))  X=\(Spike2Counters.makes["X"] ?? 0)  updates=\(Spike2Counters.updates)  windowless=\(Spike2Counters.windowless.count)  tick=\(tick)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.cyan)
            HStack(spacing: 10) {
                Button("run all") { runAll() }
                Button("reorder") { bringToFront(Self.coreIds[tick % 4]); tick += 1 }
                Button("churn X") { toggleChurn(); tick += 1 }
                Button("scale") { scaled.toggle(); tick += 1 }
                Button("overlay") { overlayOn.toggle(); tick += 1 }
                Button("focus A") { withAnimation(.spring(response: 0.3)) { focusedId = focusedId == nil ? "A" : nil }; tick += 1 }
                Button("reset") { Spike2Counters.reset(); tick += 1; status = "reset (makes recount from live mounts)" }
            }.font(.system(size: 12, design: .monospaced))
        }
        .padding(16)
        .zIndex(2_000)
    }

    /// The desktop's hover/focus z-bump: stamp frontmost AND re-sort the data array —
    /// the exact ForEach data-order churn `ShellDesktopView` produces today.
    private func bringToFront(_ id: String) {
        zCounter += 1
        guard let i = units.firstIndex(where: { $0.id == id }) else { return }
        units[i].z = zCounter
        units.sort { $0.z < $1.z }
    }

    private func toggleChurn() {
        if units.contains(where: { $0.id == "X" }) {
            units.removeAll { $0.id == "X" }
        } else {
            zCounter += 1
            units.append(DesktopSpikeUnit(id: "X", z: zCounter))
            units.sort { $0.z < $1.z }
        }
    }

    /// Step-boundary health check: any core unit without a window will blank in production.
    private func check(_ phase: String) {
        for id in Self.coreIds where webs[id]?.window == nil {
            Spike2Counters.windowless.append("\(id)@\(phase)")
            Spike2Log.p("WINDOWLESS \(id) @ \(phase)")
        }
    }

    /// All five stressors, chained: reorder ×10 → churn ×6 → scale ×6 → overlay ×6 →
    /// combined ×12 (focus + reorder + churn interleaved). Verdict to the log.
    private func runAll() {
        status = "running…"
        Spike2Log.p("RUN ALL — start")
        var steps: [(String, () -> Void)] = []
        for k in 0..<10 { steps.append(("reorder", { bringToFront(Self.coreIds[k % 4]) })) }
        for _ in 0..<6  { steps.append(("churn",   { toggleChurn() })) }
        for _ in 0..<6  { steps.append(("scale",   { scaled.toggle() })) }
        for _ in 0..<6  { steps.append(("overlay", { overlayOn.toggle() })) }
        for k in 0..<12 {
            steps.append(("combined", {
                focusedId = (focusedId == nil ? Self.coreIds[k % 4] : nil)
                bringToFront(Self.coreIds[(k + 1) % 4])
                if k % 4 == 0 { toggleChurn() }
            }))
        }
        var i = 0
        func step() {
            guard i < steps.count else {
                withAnimation(.spring(response: 0.3)) { focusedId = nil }
                if units.contains(where: { $0.id == "X" }) { toggleChurn() }   // leave the field clean
                let badMakes = Self.coreIds.filter { (Spike2Counters.makes[$0] ?? 0) != 1 }
                let pass = badMakes.isEmpty && Spike2Counters.windowless.isEmpty
                let makesDesc = Self.coreIds.map { "\($0)=\(Spike2Counters.makes[$0] ?? 0)" }.joined(separator: " ")
                status = "\(pass ? "PASS" : "FAIL")  makes[\(makesDesc)] churnX=\(Spike2Counters.makes["X"] ?? 0) windowless=\(Spike2Counters.windowless.count) updates=\(Spike2Counters.updates)"
                Spike2Log.p("SPIKE2 RESULT — \(status)")
                tick += 1
                return
            }
            let (phase, act) = steps[i]
            withAnimation(.spring(response: 0.25)) { act() }
            i += 1; tick += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { check(phase); step() }
        }
        step()
    }
}

/// Opens the spike in its own floating panel (mirrors the other spike harnesses).
@MainActor
public final class PortDesktopSpikeHarness: NSObject, NSWindowDelegate {
    public static let shared = PortDesktopSpikeHarness()
    private var panel: NSPanel?
    private var webs: [String: WKWebView] = [:]

    public func run(autorun: Bool = false) {
        if let panel { panel.makeKeyAndOrderFront(nil); return }

        let hues = ["A": 160, "B": 210, "C": 280, "D": 330, "X": 40]
        for (id, hue) in hues { webs[id] = Self.makeWeb(id: id, hue: hue) }

        Spike2Counters.reset()
        Spike2Log.p("=== SPIKE 2 (desktop conditions) START\(autorun ? " (autorun)" : "") ===")

        let hosting = NSHostingView(rootView: PortDesktopSpikeView(webs: webs, autorun: autorun))
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 860)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.title = "Port Desktop Spike — I2 under desktop stressors (reorder/churn/scale/overlay/combined)"
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
        Spike2Log.p("panel shown")
    }

    private static func makeWeb(id: String, hue: Int) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let html = """
        <html><body style="margin:0;height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px;background:hsl(\(hue),60%,12%);color:#9ff;font-family:monospace">
        <div style="font-size:34px;font-weight:bold">\(id)</div>
        <div id="c" style="font-size:40px">0</div>
        <button style="font-size:15px;padding:6px 14px;cursor:pointer" onclick="document.getElementById('k').textContent=(++m)">click me</button>
        <div style="opacity:.7">clicks: <span id="k">0</span></div>
        <div style="opacity:.5;font-size:11px">frozen counter or blank = FAIL</div>
        <script>let n=0,m=0;setInterval(()=>{document.getElementById('c').textContent=(++n)},200)</script>
        </body></html>
        """
        w.loadHTMLString(html, baseURL: nil)
        return w
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        panel = nil
        webs.removeAll()
        return true
    }
}
#endif
