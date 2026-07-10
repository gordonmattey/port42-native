//  PortResizeSpike.swift
//
//  De-risking spike for the "Port Units — resize, don't reparent" refactor
//  (docs/plan-port-units-render-refactor.md). Validates the two load-bearing invariants
//  in isolation, with ZERO production code touched:
//
//    I1 — a WKWebView hosted by a PERSISTENT representable survives resize/reposition
//         without blanking (the blank came from window-DETACH; resize must be safe).
//    I2 — SwiftUI keeps ONE backing NSView (makeNSView called exactly once) when the
//         representable keeps stable identity and only .frame/.position/.zIndex change.
//
//  How to read the result:
//    • Visual: the page shows a JS counter ticking every 200ms. If it keeps ticking and
//      stays crisp after cycling mini↔full, I1 holds (no blank, no content-process suspend).
//    • Programmatic: /tmp/spike.log — "MAKE #1" should appear ONCE; every UPDATE logs
//      web.window and super===container. CYCLE DONE prints PASS iff make==1 && window!=nil.
//
//  Launch: Debug menu → "Port Resize Spike (I1+I2)".

import SwiftUI
import AppKit
import WebKit

enum SpikeLog {
    static func p(_ s: String) {
        let url = URL(fileURLWithPath: "/tmp/spike.log")
        let line = "\(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}

/// Global make/update counters — the crux of I2. A remake here == a reparent in production.
final class SpikeCounters {
    static var make = 0
    static var update = 0
}

/// The persistent host — mirrors ShellPortHost's reparent-on-make, no-op-on-update contract.
struct SpikeWebHost: NSViewRepresentable {
    let web: WKWebView

    func makeNSView(context: Context) -> NSView {
        SpikeCounters.make += 1
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
        SpikeLog.p("MAKE #\(SpikeCounters.make)  web.window=\(web.window != nil) super=\(web.superview != nil)")
        return c
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        SpikeCounters.update += 1
        SpikeLog.p("UPDATE #\(SpikeCounters.update) make=\(SpikeCounters.make) web.window=\(web.window != nil) superIsContainer=\(web.superview === nsView) size=\(Int(nsView.frame.width))x\(Int(nsView.frame.height))")
    }
}

struct PortResizeSpikeView: View {
    let web: WKWebView
    @State private var isFull = false
    @State private var showChrome = false
    @State private var status = "idle — press cycle 10×"
    @State private var tick = 0   // forces the readout to refresh

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25).ignoresSafeArea()

                // The unit: optional chrome header (swap test for I4/I6) + the persistent host.
                // Identity is keyed on a constant, NEVER on isFull/showChrome — that's the I2 bet.
                VStack(spacing: 0) {
                    if showChrome {
                        Text("CHROME (swap test)")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity).padding(4)
                            .background(Color.blue.opacity(0.6))
                    }
                    SpikeWebHost(web: web)
                }
                .frame(width: isFull ? geo.size.width - 40 : 210,
                       height: isFull ? geo.size.height - 140 : 140)
                .position(x: isFull ? geo.size.width / 2 : 120,
                          y: isFull ? geo.size.height / 2 : 100)
                .zIndex(isFull ? 5 : 1)
                .id("spike-web-unit")   // stable ⇒ SwiftUI should reuse (I2). Never state-keyed.

                // Controls + live readout
                VStack(alignment: .leading, spacing: 8) {
                    Spacer()
                    Text(status).font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(status.hasPrefix("PASS") ? .green : (status.hasPrefix("FAIL") ? .red : .white))
                    Text("make=\(SpikeCounters.make)  update=\(SpikeCounters.update)  window=\(web.window != nil ? "Y" : "N")  tick=\(tick)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.cyan)
                    HStack(spacing: 10) {
                        Button("toggle size") { withAnimation(.spring(response: 0.4)) { isFull.toggle() } }
                        Button("cycle 10×") { runCycle(10) }
                        Button("swap chrome") { withAnimation { showChrome.toggle() } }
                        Button("reset") { SpikeCounters.make = 0; SpikeCounters.update = 0; tick += 1; status = "reset" }
                    }.font(.system(size: 12, design: .monospaced))
                }
                .padding(16)
            }
        }
    }

    /// Toggle mini↔full n times with animation, then assert I2 (make==1) + window attached.
    private func runCycle(_ n: Int) {
        status = "cycling…"
        var i = 0
        func step() {
            guard i < n * 2 else {
                let pass = SpikeCounters.make == 1 && web.window != nil
                status = "\(pass ? "PASS" : "FAIL")  make=\(SpikeCounters.make) update=\(SpikeCounters.update) window=\(web.window != nil ? "Y" : "N")"
                SpikeLog.p("CYCLE DONE — \(status)")
                tick += 1
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

/// Opens the spike in its own floating panel (mirrors GhosttyDebugHarness).
public final class PortResizeSpikeHarness: NSObject, NSWindowDelegate {
    public static let shared = PortResizeSpikeHarness()
    private var panel: NSPanel?
    private var web: WKWebView?

    public func run() {
        if let panel { panel.makeKeyAndOrderFront(nil); return }

        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let html = """
        <html><body style="margin:0;height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;background:linear-gradient(135deg,#0d2e28,#12082e);color:#9ff;font-family:monospace">
        <h1 style="font-size:44px;margin:0">SPIKE</h1>
        <div id="c" style="font-size:72px">0</div>
        <div style="opacity:.6">if this counter freezes or goes blank, I1 FAILED</div>
        <script>let n=0;setInterval(()=>{document.getElementById('c').textContent=(++n)},200)</script>
        </body></html>
        """
        w.loadHTMLString(html, baseURL: nil)
        self.web = w

        SpikeCounters.make = 0
        SpikeCounters.update = 0
        SpikeLog.p("=== SPIKE START ===")

        let hosting = NSHostingView(rootView: PortResizeSpikeView(web: w))
        hosting.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.title = "Port Resize Spike — I1 (no blank on resize) + I2 (make==1)"
        p.isReleasedWhenClosed = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.delegate = self
        p.contentView = hosting
        p.center()
        self.panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        SpikeLog.p("panel shown")
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        panel = nil
        web = nil
        return true
    }
}
