import Foundation
import WebKit

// MARK: - Browser Bridge (P-509)

/// Manages headless WKWebView sessions for ports that need to browse the web.
/// Each session is an independent WKWebView with its own navigation state.
/// Max 5 concurrent sessions per port. Sessions use non-persistent data stores.
@MainActor
public final class BrowserBridge {

    private weak var bridge: PortBridge?

    /// Active browser sessions keyed by session ID.
    private var sessions: [String: BrowserSession] = [:]

    /// Maximum concurrent sessions per port.
    private let maxSessions = 5

    init(bridge: PortBridge) {
        self.bridge = bridge
    }

    /// Cleanup all sessions.
    func cleanup() {
        for (_, session) in sessions {
            session.cleanup()
        }
        sessions.removeAll()
    }

    // MARK: - Public API

    /// Open a URL in a new browser session.
    func open(url urlString: String, opts: [String: Any]) async -> [String: Any] {
        guard sessions.count < maxSessions else {
            return ["error": "maximum browser sessions reached (\(maxSessions)). Close a session first."]
        }

        guard let url = validateURL(urlString) else {
            return ["error": "invalid or disallowed URL: \(urlString)"]
        }

        let sessionId = UUID().uuidString.prefix(8).lowercased()
        let width = opts["width"] as? Int ?? 1280
        let height = opts["height"] as? Int ?? 720
        let userAgent = opts["userAgent"] as? String

        let session = BrowserSession(
            id: String(sessionId),
            width: width,
            height: height,
            userAgent: userAgent,
            bridge: bridge
        )

        sessions[String(sessionId)] = session

        let result = await session.navigate(to: url)
        if result["error"] != nil {
            sessions.removeValue(forKey: String(sessionId))
            return result
        }

        NSLog("[Port42] browser.open: session %@ opened %@", String(sessionId), urlString)
        return ["sessionId": String(sessionId), "url": urlString, "title": result["title"] ?? ""]
    }

    /// Navigate an existing session to a new URL.
    func navigate(sessionId: String, url urlString: String) async -> [String: Any] {
        guard let session = sessions[sessionId] else {
            return ["error": "session not found: \(sessionId)"]
        }
        guard let url = validateURL(urlString) else {
            return ["error": "invalid or disallowed URL: \(urlString)"]
        }

        let result = await session.navigate(to: url)
        NSLog("[Port42] browser.navigate: session %@ -> %@", sessionId, urlString)
        return result
    }

    /// Take a screenshot of a browser session.
    func capture(sessionId: String, opts: [String: Any]) async -> [String: Any] {
        guard let session = sessions[sessionId] else {
            return ["error": "session not found: \(sessionId)"]
        }
        return await session.capture(opts: opts)
    }

    /// Extract text content from a browser session.
    func text(sessionId: String, opts: [String: Any]) async -> [String: Any] {
        guard let session = sessions[sessionId] else {
            return ["error": "session not found: \(sessionId)"]
        }
        return await session.text(opts: opts)
    }

    /// Extract HTML from a browser session.
    func html(sessionId: String, opts: [String: Any]) async -> [String: Any] {
        guard let session = sessions[sessionId] else {
            return ["error": "session not found: \(sessionId)"]
        }
        return await session.html(opts: opts)
    }

    /// Execute JavaScript in a browser session.
    func execute(sessionId: String, js: String) async -> [String: Any] {
        guard let session = sessions[sessionId] else {
            return ["error": "session not found: \(sessionId)"]
        }
        return await session.execute(js: js)
    }

    /// Close a browser session.
    func close(sessionId: String) -> [String: Any] {
        guard let session = sessions[sessionId] else {
            return ["error": "session not found: \(sessionId)"]
        }
        session.cleanup()
        sessions.removeValue(forKey: sessionId)
        NSLog("[Port42] browser.close: session %@ closed", sessionId)
        return ["ok": true]
    }

    // MARK: - URL Validation

    private func validateURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        // Only allow http, https, and data URIs
        guard scheme == "http" || scheme == "https" || scheme == "data" else { return nil }
        return url
    }
}

// MARK: - Browser Session

/// A single headless browser session backed by a WKWebView.
@MainActor
private final class BrowserSession: NSObject, WKNavigationDelegate {

    let id: String
    private let webView: WKWebView
    private weak var bridge: PortBridge?
    private var navigationContinuation: CheckedContinuation<[String: Any], Never>?
    private var isLoading = false

    /// Text content size limit (500KB).
    private let textLimit = 500_000
    /// HTML content size limit (1MB).
    private let htmlLimit = 1_000_000

    init(id: String, width: Int, height: Int, userAgent: String?, bridge: PortBridge?) {
        self.id = id
        self.bridge = bridge

        // Non-persistent data store so sessions don't share cookies/cache
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: config)
        if let ua = userAgent {
            webView.customUserAgent = ua
        }
        self.webView = webView

        super.init()
        webView.navigationDelegate = self
    }

    func cleanup() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        navigationContinuation?.resume(returning: ["error": "session closed"])
        navigationContinuation = nil
    }

    // MARK: - Navigation

    func navigate(to url: URL) async -> [String: Any] {
        isLoading = true
        let request = URLRequest(url: url, timeoutInterval: 30)
        webView.load(request)

        return await withCheckedContinuation { continuation in
            navigationContinuation = continuation
        }
    }

    // MARK: - Content Extraction

    func capture(opts: [String: Any]) async -> [String: Any] {
        let config = WKSnapshotConfiguration()

        if let region = opts["region"] as? [String: Any] {
            let x = region["x"] as? Double ?? 0
            let y = region["y"] as? Double ?? 0
            let w = region["width"] as? Double ?? Double(webView.frame.width)
            let h = region["height"] as? Double ?? Double(webView.frame.height)
            config.rect = CGRect(x: x, y: y, width: w, height: h)
        }

        do {
            let image = try await webView.takeSnapshot(configuration: config)
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return ["error": "failed to encode screenshot"]
            }

            let sizeMB = Double(pngData.count) / 1_048_576.0
            NSLog("[Port42] browser.capture: session %@ %dx%d (%.1f MB)", id,
                  Int(webView.frame.width), Int(webView.frame.height), sizeMB)

            return [
                "image": pngData.base64EncodedString(),
                "width": Int(webView.frame.width),
                "height": Int(webView.frame.height)
            ]
        } catch {
            NSLog("[Port42] browser.capture: failed: %@", error.localizedDescription)
            return ["error": "screenshot failed: \(error.localizedDescription)"]
        }
    }

    func text(opts: [String: Any]) async -> [String: Any] {
        let selector = opts["selector"] as? String
        let js: String
        if let sel = selector {
            let escaped = sel.replacingOccurrences(of: "'", with: "\\'")
            js = "(() => { const el = document.querySelector('\(escaped)'); return el ? el.innerText : null; })()"
        } else {
            js = "document.body.innerText"
        }

        do {
            let result = try await webView.evaluateJavaScript(js)
            var text = (result as? String) ?? ""
            if text.count > textLimit {
                text = String(text.prefix(textLimit))
            }
            let title = try? await webView.evaluateJavaScript("document.title") as? String
            let url = webView.url?.absoluteString ?? ""
            return ["text": text, "title": title ?? "", "url": url]
        } catch {
            return ["error": "text extraction failed: \(error.localizedDescription)"]
        }
    }

    func html(opts: [String: Any]) async -> [String: Any] {
        let selector = opts["selector"] as? String
        let js: String
        if let sel = selector {
            let escaped = sel.replacingOccurrences(of: "'", with: "\\'")
            js = "(() => { const el = document.querySelector('\(escaped)'); return el ? el.outerHTML : null; })()"
        } else {
            js = "document.documentElement.outerHTML"
        }

        do {
            let result = try await webView.evaluateJavaScript(js)
            var html = (result as? String) ?? ""
            if html.count > htmlLimit {
                html = String(html.prefix(htmlLimit))
            }
            let title = try? await webView.evaluateJavaScript("document.title") as? String
            let url = webView.url?.absoluteString ?? ""
            return ["html": html, "title": title ?? "", "url": url]
        } catch {
            return ["error": "html extraction failed: \(error.localizedDescription)"]
        }
    }

    func execute(js: String) async -> [String: Any] {
        do {
            let result = try await webView.evaluateJavaScript(js)
            // Try to serialize the result
            if result is NSNull || result == nil {
                return ["result": NSNull()]
            }
            if let str = result as? String {
                return ["result": str]
            }
            if let num = result as? NSNumber {
                return ["result": num]
            }
            if let bool = result as? Bool {
                return ["result": bool]
            }
            // Complex objects: try JSON serialization
            if JSONSerialization.isValidJSONObject(result as Any) {
                return ["result": result as Any]
            }
            return ["result": String(describing: result)]
        } catch {
            return ["error": "js execution failed: \(error.localizedDescription)"]
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            isLoading = false
            let title = webView.title ?? ""
            let url = webView.url?.absoluteString ?? ""

            // Emit load event
            bridge?.pushEvent("browser.load", data: [
                "sessionId": id,
                "url": url,
                "title": title
            ])

            // Resolve navigation promise
            navigationContinuation?.resume(returning: ["url": url, "title": title])
            navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            handleNavigationError(error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            handleNavigationError(error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Only allow http/https/data/about schemes
        if let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" || scheme == "data" || scheme == "about" {
                return .allow
            }
            return .cancel
        }
        return .allow
    }

    nonisolated func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            let url = webView.url?.absoluteString ?? ""
            bridge?.pushEvent("browser.redirect", data: [
                "sessionId": id,
                "url": url
            ])
        }
    }

    // MARK: - Private

    private func handleNavigationError(_ error: Error) {
        isLoading = false
        let nsError = error as NSError
        // Cancelled navigations are not errors
        if nsError.code == NSURLErrorCancelled { return }

        let url = webView.url?.absoluteString ?? ""
        NSLog("[Port42] browser: session %@ navigation error: %@", id, error.localizedDescription)

        bridge?.pushEvent("browser.error", data: [
            "sessionId": id,
            "url": url,
            "error": error.localizedDescription
        ])

        navigationContinuation?.resume(returning: ["error": "navigation failed: \(error.localizedDescription)"])
        navigationContinuation = nil
    }
}
