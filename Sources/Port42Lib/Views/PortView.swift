import SwiftUI
import WebKit

// MARK: - Scroll-Passthrough WebView

/// WKWebView subclass that forwards scroll events to the parent view
/// so inline ports don't eat scroll gestures from the chat ScrollView.
private class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // Forward scroll events to the next responder (parent ScrollView)
        nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - Inline Port Renderer

/// Renders a port (companion-generated HTML/CSS/JS) in a sandboxed WKWebView.
public struct PortView: NSViewRepresentable {
    let html: String
    let bridge: PortBridge?
    @Binding var height: CGFloat

    public init(html: String, bridge: PortBridge? = nil, height: Binding<CGFloat>) {
        self.html = html
        self.bridge = bridge
        self._height = height
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Attach bridge if available (injects port42.* namespace)
        bridge?.attach(to: config)

        // Height reporting + viewport width tracking
        let heightScript = WKUserScript(
            source: """
            (function() {
                function reportHeight() {
                    const h = document.body.scrollHeight;
                    window.webkit.messageHandlers.portHeight.postMessage(h);
                }
                function updateViewport() {
                    const w = document.documentElement.clientWidth;
                    const h = document.documentElement.clientHeight;
                    document.documentElement.style.setProperty('--port-width', w + 'px');
                    document.documentElement.style.setProperty('--port-height', h + 'px');
                    if (window.port42) window.port42.viewport = { width: w, height: h };
                }
                window.addEventListener('load', function() {
                    reportHeight();
                    updateViewport();
                    new ResizeObserver(function() { reportHeight(); updateViewport(); }).observe(document.body);
                });
                window.addEventListener('resize', updateViewport);
                setTimeout(function() { reportHeight(); updateViewport(); }, 100);
                setTimeout(function() { reportHeight(); updateViewport(); }, 500);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(heightScript)
        config.userContentController.add(context.coordinator, name: "portHeight")

        // Forward JS console.log/error/warn to native NSLog for debugging
        let consoleScript = WKUserScript(
            source: """
            (function() {
                const orig = { log: console.log, error: console.error, warn: console.warn };
                function forward(level, args) {
                    try {
                        const msg = Array.from(args).map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');
                        window.webkit.messageHandlers.portConsole.postMessage({ level: level, message: msg });
                    } catch(e) {}
                }
                console.log = function() { forward('log', arguments); orig.log.apply(console, arguments); };
                console.error = function() { forward('error', arguments); orig.error.apply(console, arguments); };
                console.warn = function() { forward('warn', arguments); orig.warn.apply(console, arguments); };
                window.addEventListener('error', function(e) {
                    forward('error', [e.message + ' at ' + (e.filename || '') + ':' + (e.lineno || '')]);
                });
                window.addEventListener('unhandledrejection', function(e) {
                    forward('error', ['Unhandled promise rejection: ' + (e.reason || '')]);
                });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(consoleScript)
        config.userContentController.add(context.coordinator, name: "portConsole")

        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false

        // Give bridge a reference to the webview for callbacks
        bridge?.setWebView(webView)

        loadContent(webView)
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            loadContent(webView)
        }
    }

    private func loadContent(_ webView: WKWebView) {
        let document = wrapHTML(html)
        webView.loadHTMLString(document, baseURL: nil)
    }

    /// Wrap port content in a full HTML document with port42 theme and CSP
    private func wrapHTML(_ body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:;">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                background: #111;
                color: #e0e0e0;
                font-family: "SF Mono", "Fira Code", "Cascadia Code", monospace;
                font-size: 13px;
                line-height: 1.5;
                padding: 12px;
                overflow: hidden;
            }
            a { color: #00ff41; }
            button, input, select, textarea {
                font-family: inherit;
                font-size: inherit;
                color: #e0e0e0;
                background: #1a1a1a;
                border: 1px solid #333;
                border-radius: 4px;
                padding: 6px 10px;
                outline: none;
            }
            button {
                cursor: pointer;
                background: #00ff41;
                color: #0a0a0a;
                border: none;
                font-weight: 600;
                padding: 6px 14px;
            }
            button:hover { opacity: 0.85; }
            input:focus, textarea:focus { border-color: #00ff41; }
            ::-webkit-scrollbar { width: 6px; }
            ::-webkit-scrollbar-track { background: transparent; }
            ::-webkit-scrollbar-thumb { background: #333; border-radius: 3px; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    // MARK: - Coordinator

    public class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: PortView
        var lastHTML: String

        init(_ parent: PortView) {
            self.parent = parent
            self.lastHTML = parent.html
        }

        // Block all navigation (sandbox)
        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        // Receive messages from JS (height updates + console forwarding)
        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "portHeight", let h = message.body as? CGFloat {
                DispatchQueue.main.async {
                    let clamped = min(max(h, 40), 600)
                    if abs(self.parent.height - clamped) > 1 {
                        self.parent.height = clamped
                    }
                }
            } else if message.name == "portConsole",
                      let body = message.body as? [String: Any],
                      let level = body["level"] as? String,
                      let msg = body["message"] as? String {
                NSLog("[Port42:port:%@] %@", level, msg)
            }
        }
    }
}
