// Throwaway (spike/port-subscriptions, #246): what one published event costs to deliver to a port's page,
// the way PortBridge.pushToken does it: escape the whole JSON, embed it in a JS string literal,
// evaluateJavaScript, and JSON.parse it in the page. Not product code.
import AppKit
import WebKit

func escapeJSString(_ str: String) -> String {   // verbatim from PortBridge.swift:298
    str.replacingOccurrences(of: "\\", with: "\\\\")
       .replacingOccurrences(of: "\"", with: "\\\"")
       .replacingOccurrences(of: "\n", with: "\\n")
       .replacingOccurrences(of: "\r", with: "\\r")
       .replacingOccurrences(of: "\t", with: "\\t")
}
setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
win.orderFrontRegardless()
let pool = WKProcessPool()
func ms(_ d: Date) -> Double { Date().timeIntervalSince(d) * 1000 }
func med(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
func p90(_ a: [Double]) -> Double { a.sorted()[Int(Double(a.count) * 0.9)] }

// a "draft": prose with quotes, newlines and unicode, wrapped as a notify envelope
func envelope(bytes: Int) -> String {
    let para = "The Launch desk draft says \"ship on Friday\", then explains why — three bullet points,\n\tone tab-indented line, and a path C:\\drafts\\one. "
    var body = ""; while body.utf8.count < bytes { body += para }
    let obj: [String: Any] = ["topic": "port:abc", "kind": "port.draft", "payload": ["id": 7, "text": body], "token": "1:42"]
    return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}

Task { @MainActor in
    let html = "<html><body><script>window.n=0;window.got=0;function cb(t){const e=JSON.parse(t);window.got+=e.payload.text.length;window.n++;}</script></body></html>"
    var views: [WKWebView] = []
    for i in 0..<10 {
        let c = WKWebViewConfiguration(); c.processPool = pool
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: c)
        if i == 0 { win.contentView = w }
        w.loadHTMLString(html, baseURL: nil); views.append(w)
    }
    try? await Task.sleep(nanoseconds: 2_500_000_000)
    print("size_kb,subscribers,escape_ms(per delivery),main_thread_ms(all subscribers: escape+issue),until_all_ran_ms,p90_until_all_ran_ms")
    for kb in [1, 20, 200, 1000] {
        let json = envelope(bytes: kb * 1024)
        for n in [1, 3, 10] {
            var esc: [Double] = [], main: [Double] = [], done: [Double] = []
            for _ in 0..<(kb >= 1000 ? 8 : 20) {
                let t0 = Date()
                var e = 0.0
                var calls: [(WKWebView, String)] = []
                for i in 0..<n {                      // the bus delivers to each subscriber in turn, each escaping the whole token
                    let te = Date(); let s = escapeJSString(json); e += ms(te)
                    calls.append((views[i], "cb(\"\(s)\")"))
                }
                esc.append(e / Double(n))
                var pending = n
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    for (w, js) in calls { w.evaluateJavaScript(js) { _, _ in pending -= 1; if pending == 0 { c.resume() } } }
                    main.append(ms(t0))
                }
                done.append(ms(t0))
            }
            print(String(format: "%d,%d,%.2f,%.1f,%.1f,%.1f", kb, n, med(esc), med(main), med(done), p90(done)))
        }
    }
    NSApp.terminate(nil)
}
app.run()
