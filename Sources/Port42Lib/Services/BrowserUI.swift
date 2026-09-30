import AppKit
import WebKit

/// A browser port's window-level behavior (docs/plan-browser-use.md, Phase 1): what happens when a page
/// opens a window, closes one, or asks the person something. Before this a browser port had no UI
/// delegate, so every new window (a "Sign in with Google" popup, a target=_blank link) did nothing and
/// every alert or confirm was silently dismissed.
@MainActor
final class PortBrowserUI: NSObject, WKUIDelegate {

    /// A page opened a sized window (an OAuth or payment popup). The popup must be built from the
    /// configuration WebKit hands over, or it loses its link to the page that opened it and the sign-in
    /// result never comes back.
    var onPopup: ((WKWebView) -> Void)?
    /// A popup closed itself (window.close), as an OAuth popup does when it is done.
    var onPopupClosed: ((WKWebView) -> Void)?

    /// Whether a new window is a popup to draw over the port, or a link to open in the port itself. A
    /// window asked for with a size is a popup (OAuth, payments); a plain target=_blank link is not, and
    /// with no tabs yet it opens where the person is looking. Pure.
    nonisolated static func opensAsPopup(width: Double?, height: Double?) -> Bool {
        width != nil || height != nil
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard Self.opensAsPopup(width: windowFeatures.width?.doubleValue, height: windowFeatures.height?.doubleValue) else {
            // No tabs yet: a new-window link opens in the port.
            if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self                      // its own window.close, dialogs and popups come here too
        popup.customUserAgent = webView.customUserAgent
        onPopup?(popup)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        onPopupClosed?(webView)
    }

    // MARK: - A page asking the person

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = Self.alert(message, host: frame.securityOrigin.host)
        alert.addButton(withTitle: "OK")
        present(alert, over: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = Self.alert(message, host: frame.securityOrigin.host)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, over: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = Self.alert(prompt, host: frame.securityOrigin.host)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, over: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = webView.window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    /// A page's own words, headed by the site that said them, so a page cannot pass itself off as Port42.
    private static func alert(_ message: String, host: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = host.isEmpty ? "This page says" : "\(host) says"
        alert.informativeText = message
        return alert
    }

    private func present(_ alert: NSAlert, over webView: WKWebView, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }
}

/// The user agent a browser port presents. WebKit's default names no browser, and Google's sign-in
/// refuses it as an embedded view ("this browser or app may not be secure"); naming Safari, which this
/// engine is, lets OAuth through. The version is the installed Safari's, so it stays current.
enum BrowserUserAgent {
    static let applicationName: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let version = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "18.0"
        return suffix(safariVersion: version)
    }()

    /// Pure, for the test.
    static func suffix(safariVersion: String) -> String { "Version/\(safariVersion) Safari/605.1.15" }
}
