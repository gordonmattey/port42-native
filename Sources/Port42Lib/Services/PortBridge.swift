import Foundation
import WebKit

// MARK: - Port Bridge

/// Bridges port42.* JS calls from a port's WKWebView to native Swift services.
/// Handles request/response matching via callId, and pushes live events to JS.
public final class PortBridge: NSObject, WKScriptMessageHandler {

    private weak var webView: WKWebView?
    private weak var appState: AnyObject?  // AppState, weakly held to avoid import cycle
    private let channelId: String?

    /// Accessor for AppState (cast from AnyObject to avoid circular dependency)
    private var state: AppState? { appState as? AppState }

    public init(appState: AnyObject, channelId: String?) {
        self.appState = appState
        self.channelId = channelId
        super.init()
    }

    /// Attach this bridge to a WKWebView configuration before content loads
    public func attach(to config: WKWebViewConfiguration) {
        // Inject the port42 JS namespace
        let bridgeScript = WKUserScript(
            source: PortBridge.bridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(bridgeScript)
        config.userContentController.add(self, name: "port42")
    }

    /// Set the webview reference for callbacks
    public func setWebView(_ webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "port42",
              let body = message.body as? [String: Any],
              let method = body["method"] as? String,
              let callId = body["callId"] as? Int else { return }

        let args = body["args"] as? [Any] ?? []

        Task { @MainActor in
            let result = await handleMethod(method, args: args)
            let jsonData = try? JSONSerialization.data(withJSONObject: result)
            let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            try? await webView?.evaluateJavaScript("port42._resolve(\(callId), \(jsonString))")
        }
    }

    // MARK: - Method Routing

    @MainActor
    private func handleMethod(_ method: String, args: [Any]) async -> Any {
        guard let state = state else { return ["error": "no app state"] }

        switch method {

        // port42.user.get()
        case "user.get":
            if let user = state.currentUser {
                return ["id": user.id, "name": user.displayName]
            }
            return NSNull()

        // port42.companions.list()
        case "companions.list":
            let typingNames = state.typingAgentNames
            return state.companions.map { agent -> [String: Any] in
                [
                    "id": agent.id,
                    "name": agent.displayName,
                    "model": agent.model ?? "",
                    "isActive": typingNames.contains(agent.displayName)
                ]
            }

        // port42.companions.get(id)
        case "companions.get":
            guard let id = args.first as? String else { return NSNull() }
            if let agent = state.companions.first(where: { $0.id == id }) {
                let typingNames = state.typingAgentNames
                return [
                    "id": agent.id,
                    "name": agent.displayName,
                    "model": agent.model ?? "",
                    "isActive": typingNames.contains(agent.displayName)
                ]
            }
            return NSNull()

        // port42.messages.recent(n)
        case "messages.recent":
            let limit = (args.first as? Int) ?? 20
            let messages = Array(state.messages.suffix(limit))
            return messages.map { msg -> [String: Any] in
                [
                    "id": msg.id,
                    "sender": msg.senderName,
                    "content": msg.content,
                    "timestamp": ISO8601DateFormatter().string(from: msg.timestamp),
                    "isCompanion": msg.isAgent
                ]
            }

        // port42.port.close() — handled by JS side for now
        case "port.close":
            return ["ok": true]

        // port42.port.resize(w, h) — height change handled by JS postMessage
        case "port.resize":
            return ["ok": true]

        default:
            NSLog("[Port42] Unknown bridge method: %@", method)
            return ["error": "unknown method: \(method)"]
        }
    }

    // MARK: - Event Pushing

    /// Push an event to the port's JS context
    @MainActor
    public func pushEvent(_ event: String, data: Any) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("port42._emit('\(event)', \(jsonString))") { _, _ in }
    }

    /// Send heartbeat to keep connection status alive
    @MainActor
    public func pushHeartbeat() {
        webView?.evaluateJavaScript("port42._heartbeat()") { _, _ in }
    }

    // MARK: - Injected JavaScript

    /// The port42.* namespace injected into every port webview
    static let bridgeJS: String = """
    (function() {
        let _callId = 0;
        const _pending = {};
        const _listeners = {};

        // Connection health tracking
        let _lastHeartbeat = Date.now();
        let _connected = true;
        const _statusCallbacks = [];
        const _HEARTBEAT_TIMEOUT = 10000; // 10s without heartbeat = disconnected

        function _checkConnection() {
            const now = Date.now();
            const wasConnected = _connected;
            _connected = (now - _lastHeartbeat) < _HEARTBEAT_TIMEOUT;
            if (wasConnected !== _connected) {
                const status = _connected ? 'connected' : 'disconnected';
                _statusCallbacks.forEach(cb => { try { cb(status); } catch(e) { console.error(e); } });
            }
        }
        // Check connection status every 3s
        setInterval(_checkConnection, 3000);

        function call(method, args) {
            return new Promise((resolve) => {
                const id = ++_callId;
                _pending[id] = resolve;
                window.webkit.messageHandlers.port42.postMessage({
                    method: method,
                    args: args || [],
                    callId: id
                });
            });
        }

        window.port42 = {
            _resolve: function(callId, data) {
                const resolve = _pending[callId];
                if (resolve) {
                    delete _pending[callId];
                    resolve(data);
                }
            },
            _emit: function(event, data) {
                const cbs = _listeners[event] || [];
                cbs.forEach(cb => { try { cb(data); } catch(e) { console.error(e); } });
            },
            _heartbeat: function() {
                _lastHeartbeat = Date.now();
                const wasConnected = _connected;
                _connected = true;
                if (!wasConnected) {
                    _statusCallbacks.forEach(cb => { try { cb('connected'); } catch(e) { console.error(e); } });
                }
            },

            companions: {
                list: () => call('companions.list'),
                get: (id) => call('companions.get', [id])
            },
            messages: {
                recent: (n) => call('messages.recent', [n || 20])
            },
            user: {
                get: () => call('user.get')
            },
            on: function(event, callback) {
                if (!_listeners[event]) _listeners[event] = [];
                _listeners[event].push(callback);
            },
            connection: {
                status: () => _connected ? 'connected' : 'disconnected',
                onStatusChange: (callback) => _statusCallbacks.push(callback)
            },
            port: {
                close: () => call('port.close'),
                resize: (w, h) => {
                    document.body.style.width = w + 'px';
                    document.body.style.height = h + 'px';
                    window.webkit.messageHandlers.portHeight.postMessage(h);
                }
            }
        };
    })();
    """
}
