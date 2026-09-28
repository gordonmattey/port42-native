import Testing
import Foundation
import WebKit
@testable import Port42Lib

/// A browser port that cannot reach its page says so, instead of showing nothing (GM, 2026-09-27: a
/// port whose local server had stopped showed its chrome and a blank page).
@Suite("Browser port error page")
@MainActor
struct BrowserErrorPageTests {
    @Test("it names the place, the reason and what to do, and escapes what it shows")
    func page() {
        let local = PortBrowserNavigation.errorPage(url: URL(string: "http://127.0.0.1:4299/index.html"),
                                                    reason: "Could not connect to the server.")
        #expect(local.contains("Can't reach 127.0.0.1:4299") && local.contains("a server on this Mac"))
        #expect(local.contains("data-u=\"http://127.0.0.1:4299/index.html\""))
        let hostile = PortBrowserNavigation.errorPage(url: URL(string: "https://example.com"), reason: "<script>x</script>")
        #expect(!hostile.contains("<script>x") && hostile.contains("&lt;script&gt;"))
    }

    /// WebKit starts no network load in the test process, so the failure WebKit would report is handed
    /// to the handler directly; what the port then shows is real.
    @Test("a page that cannot be reached shows the error page under its own URL; a cancelled load shows nothing")
    func unreachableShowsIt() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let nav = PortBrowserNavigation()
        web.navigationDelegate = nav
        let dead = URL(string: "http://127.0.0.1:4299/index-nautilus.html")!
        func fail(_ code: Int) {
            nav.webView(web, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: code,
                        userInfo: [NSURLErrorFailingURLErrorKey: dead, NSLocalizedDescriptionKey: "Could not connect to the server."]))
        }
        fail(NSURLErrorCancelled)
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(web.url == nil, "a cancelled load (a new navigation replacing it) showed the error page")
        fail(NSURLErrorCannotConnectToHost)
        var text = ""
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 100_000_000)
            text = (try? await web.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String) ?? ""
            if text.contains("Can't reach") { break }
        }
        #expect(text.contains("Can't reach 127.0.0.1:4299") && text.contains("Could not connect"), "the port stayed blank: \(text.prefix(120))")
        #expect(web.url == dead, "the address bar lost the failing URL")
        withExtendedLifetime(nav) {}
    }
}
