// Step 8 throwaway spike — prove a LIVE WKWebView survives re-parenting without reload.
//
// Spike A: pure AppKit move (window -> NSPanel) via removeFromSuperview/addSubview.
// Spike B: SwiftUI NSViewRepresentable adoption — the representable is torn down &
//          recreated (as on inline<->floating and chat-list recycling); dismantleNSView
//          must NOT destroy the registry-owned webview, makeNSView re-adopts it.
//
// Proof = a JS counter (window.__c, +1 every 50ms). If the surface reloads, __c resets
// to ~0; reads are seconds apart, so a reload shows a SMALLER value than the prior read.
// Monotonically increasing across every move == no reload == PASS.

import AppKit
import WebKit
import SwiftUI

// MARK: - Registry: the ONE webview per port (mirrors PortWindowManager.webViews[id])

final class Registry {
    static let shared = Registry()
    let web: WKWebView

    init() {
        let cfg = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = prefs
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.loadHTMLString("""
        <html><head><meta name=viewport content="width=device-width"></head>
        <body style="margin:0;background:#0b0b0b;color:#00d4aa;font-family:ui-monospace,monospace;
                     display:flex;align-items:center;justify-content:center;height:100vh">
        <div style="text-align:center">
          <div id=c style="font-size:64px;font-weight:700">0</div>
          <div style="font-size:12px;color:#888">window.__c</div>
        </div>
        <script>
          window.__c = 0;
          setInterval(function(){ window.__c++; document.getElementById('c').innerText = window.__c; }, 50);
        </script>
        </body></html>
        """, baseURL: nil)
    }
}

// MARK: - Results log

var log: [String] = []
var lastValue = -1
var monotonic = true   // every reading >= previous reading
func note(_ s: String) { log.append(s); print(s) }

func readCounter(_ label: String, _ done: @escaping () -> Void) {
    Registry.shared.web.evaluateJavaScript("window.__c") { result, err in
        let v = (result as? Int) ?? -1
        let drop = (lastValue >= 0 && v < lastValue)
        if drop { monotonic = false }
        note(String(format: "  read[%@] = %@%@", label, "\(v)",
                    drop ? "   <-- RESET! (value dropped from \(lastValue)) => RELOAD happened" : ""))
        if v >= 0 { lastValue = v }
        done()
    }
}

// MARK: - Spike B: SwiftUI representable that ADOPTS the registry webview (no recreate)

struct AdoptingHost: NSViewRepresentable {
    static var makeCount = 0
    static var dismantleCount = 0

    func makeNSView(context: Context) -> NSView {
        AdoptingHost.makeCount += 1
        let container = NSView()
        let web = Registry.shared.web
        web.removeFromSuperview()                       // reparent the ONE shared webview
        container.addSubview(web)
        web.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // CRITICAL: do NOT tear down the registry webview. Just let the container go.
        AdoptingHost.dismantleCount += 1
    }
}

// Two SwiftUI "slots" the same webview moves between (stands in for inline vs floating),
// plus an .id() churn to simulate List/LazyVStack row recycling.
struct SpikeBView: View {
    @ObservedObject var model: SpikeBModel
    var body: some View {
        VStack {
            if model.slot == 0 {
                AdoptingHost().frame(width: 360, height: 220).id(model.churn)
            } else {
                AdoptingHost().frame(width: 360, height: 220).id(model.churn)
            }
        }
    }
}

final class SpikeBModel: ObservableObject {
    @Published var slot = 0
    @Published var churn = 0
}

// MARK: - Driver

let app = NSApplication.shared
app.setActivationPolicy(.regular)

final class Delegate: NSObject, NSApplicationDelegate {
    var windowA: NSWindow!
    var panel: NSPanel!
    var hosting: NSHostingView<SpikeBView>!
    let model = SpikeBModel()

    func applicationDidFinishLaunching(_ n: Notification) {
        let web = Registry.shared.web

        // Window A hosts the live webview first.
        windowA = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 360, height: 220),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        windowA.title = "Spike A — window"
        windowA.contentView?.addSubview(web)
        web.frame = windowA.contentView!.bounds
        web.autoresizingMask = [.width, .height]
        windowA.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        // floating panel for the AppKit move
        panel = NSPanel(contentRect: NSRect(x: 600, y: 400, width: 360, height: 220),
                        styleMask: [.titled, .closable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "Spike A — NSPanel"

        schedule()
    }

    func at(_ t: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: block)
    }

    func schedule() {
        // ---- SPIKE A: raw AppKit move ----
        at(1.0) { note("\n== SPIKE A: pure AppKit move (window -> NSPanel) ==");
                  readCounter("A.initial(in window)") {} }
        at(1.4) {
            let web = Registry.shared.web
            web.autoresizingMask = []
            web.removeFromSuperview()
            self.panel.contentView?.addSubview(web)
            web.frame = self.panel.contentView!.bounds
            web.autoresizingMask = [.width, .height]
            self.panel.makeKeyAndOrderFront(nil)
            note("  -> moved webview into NSPanel (removeFromSuperview + addSubview)")
        }
        at(1.5) { readCounter("A.afterMove.immediate") {} }
        at(2.5) { readCounter("A.afterMove.delayed") {} }

        // ---- SPIKE B: SwiftUI adoption + teardown/recreate ----
        at(3.0) {
            note("\n== SPIKE B: SwiftUI representable adoption (teardown/recreate) ==")
            let hv = NSHostingView(rootView: SpikeBView(model: self.model))
            self.hosting = hv
            self.panel.contentView = hv     // webview now lives inside a SwiftUI representable
            note("  -> hosted webview inside SwiftUI NSHostingView/AdoptingHost")
        }
        at(3.6) { readCounter("B.hosted") {} }
        at(3.8) { self.model.slot = 1; note("  -> flip slot 0->1 (SwiftUI dismantles + remakes host)") }
        at(4.2) { readCounter("B.afterSlotFlip") {} }
        at(4.4) { self.model.churn += 1; note("  -> bump .id (simulate list-row recycling: dismantle+make)") }
        at(4.8) { readCounter("B.afterRecycleChurn") {} }
        at(5.0) { self.model.slot = 0; self.model.churn += 1; note("  -> flip back + churn again") }
        at(5.4) { readCounter("B.afterFlipBack") {} }

        // ---- verdict ----
        at(6.0) {
            note("\n== VERDICT ==")
            note("  AdoptingHost.makeCount = \(AdoptingHost.makeCount), dismantleCount = \(AdoptingHost.dismantleCount)")
            let pass = monotonic && lastValue > 40
            note("  counter monotonic across all moves: \(monotonic)")
            note("  final counter value: \(lastValue) (a reload would have reset toward 0)")
            note(pass ? "\n  ✅ PASS — live WKWebView survived AppKit move + SwiftUI teardown/recreate with NO reload."
                     : "\n  ❌ FAIL — surface reloaded somewhere (see RESET marker above).")
            self.at(0.5) { NSApp.terminate(nil) }
        }
        // hard safety timeout
        at(12.0) { note("  (safety timeout)"); NSApp.terminate(nil) }
    }
}

let delegate = Delegate()
app.delegate = delegate
app.run()
