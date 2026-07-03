import Testing
import Foundation
@testable import Port42Lib

/// SHELL — browser port URL normalization (the dock Browser button + address bar). Pure function,
/// no webview. Covers pass-through, bare-domain → https, and search fallback.
@Suite("Browser port URL")
@MainActor
struct BrowserPortTests {

    @Test("empty → start page")
    func empty() {
        #expect(PortWindowManager.normalizedBrowserURL("") == "https://duckduckgo.com")
        #expect(PortWindowManager.normalizedBrowserURL("   ") == "https://duckduckgo.com")
    }

    @Test("http(s) passes through untouched")
    func passthrough() {
        #expect(PortWindowManager.normalizedBrowserURL("https://example.com/x") == "https://example.com/x")
        #expect(PortWindowManager.normalizedBrowserURL("http://localhost:3000") == "http://localhost:3000")
    }

    @Test("bare domain → https")
    func bareDomain() {
        #expect(PortWindowManager.normalizedBrowserURL("wikipedia.org") == "https://wikipedia.org")
        #expect(PortWindowManager.normalizedBrowserURL("  spaced.com  ") == "https://spaced.com")
    }

    @Test("text with spaces or no dot → search")
    func search() {
        #expect(PortWindowManager.normalizedBrowserURL("hello world") == "https://duckduckgo.com/?q=hello%20world")
        #expect(PortWindowManager.normalizedBrowserURL("justtext") == "https://duckduckgo.com/?q=justtext")
    }
}
