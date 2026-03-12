import Foundation
import WebKit

// MARK: - Port Bridge

/// Bridges port42.* JS calls from a port's WKWebView to native Swift services.
/// Handles request/response matching via callId, and pushes live events to JS.
public final class PortBridge: NSObject, WKScriptMessageHandler {

    private weak var webView: WKWebView?
    private weak var appState: AnyObject?  // AppState, weakly held to avoid import cycle
    private let channelId: String?
    private let messageId: String?
    private let createdBy: String?

    /// Accessor for AppState (cast from AnyObject to avoid circular dependency)
    private var state: AppState? { appState as? AppState }

    public init(appState: AnyObject, channelId: String?, messageId: String? = nil, createdBy: String? = nil) {
        self.appState = appState
        self.channelId = channelId
        self.messageId = messageId
        self.createdBy = createdBy
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
            _ = try? await webView?.evaluateJavaScript("port42._resolve(\(callId), \(jsonString))")
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

        // port42.channel.current()
        case "channel.current":
            // Check if we're in a swim
            if let swim = state.activeSwimSession {
                return [
                    "id": "swim-\(swim.companion.id)",
                    "name": swim.companion.displayName,
                    "type": "swim",
                    "members": [
                        ["name": state.currentUser?.displayName ?? "you", "type": "human"],
                        ["name": swim.companion.displayName, "type": "companion"]
                    ]
                ] as [String: Any]
            }
            // Otherwise return current channel
            if let channel = state.currentChannel {
                let channelMembers = (try? state.db.getChannelMembers(channelId: channel.id)) ?? []
                let members: [[String: String]] = channelMembers.map {
                    ["name": $0.name, "type": $0.type]
                }
                return [
                    "id": channel.id,
                    "name": channel.name,
                    "type": channel.type,
                    "members": members
                ] as [String: Any]
            }
            return NSNull()

        // port42.channel.list()
        case "channel.list":
            return state.channels.map { ch -> [String: Any] in
                [
                    "id": ch.id,
                    "name": ch.name,
                    "type": ch.type,
                    "isCurrent": ch.id == state.currentChannel?.id
                ]
            }

        // port42.channel.switchTo(id)
        case "channel.switchTo":
            guard let id = args.first as? String else {
                return ["error": "channel.switchTo requires a channel id"]
            }
            if let channel = state.channels.first(where: { $0.id == id }) {
                state.selectChannel(channel)
                return ["ok": true]
            }
            return ["error": "channel not found"]

        // port42.messages.send(text)
        case "messages.send":
            guard let text = args.first as? String, !text.isEmpty else {
                return ["error": "messages.send requires a non-empty text argument"]
            }
            state.sendMessage(content: text)
            return ["ok": true]

        // port42.port.info()
        case "port.info":
            var info: [String: Any] = [:]
            if let mid = messageId { info["messageId"] = mid }
            if let creator = createdBy { info["createdBy"] = creator }
            if let cid = channelId { info["channelId"] = cid }
            return info

        // port42.storage.set(key, value, options?)
        // options: { scope: 'global', shared: true }
        case "storage.set":
            guard let key = args.first as? String else {
                return ["error": "storage.set requires a key"]
            }
            let opts = args.count > 2 ? args[2] as? [String: Any] : nil
            guard let resolved = storageScope(opts: opts) else {
                return ["error": "storage.set requires channel context for channel-scoped storage"]
            }
            let value: String
            if args.count > 1 {
                if let str = args[1] as? String {
                    value = str
                } else if let data = try? JSONSerialization.data(withJSONObject: args[1]),
                          let json = String(data: data, encoding: .utf8) {
                    value = json
                } else {
                    return ["error": "storage.set value must be serializable"]
                }
            } else {
                return ["error": "storage.set requires a value"]
            }
            do {
                try state.db.setPortStorage(key: key, value: value, scope: resolved.scope, creatorId: resolved.creator)
                return ["ok": true]
            } catch {
                return ["error": error.localizedDescription]
            }

        // port42.storage.get(key, options?)
        case "storage.get":
            guard let key = args.first as? String else {
                return ["error": "storage.get requires a key"]
            }
            let opts = args.count > 1 ? args[1] as? [String: Any] : nil
            guard let resolved = storageScope(opts: opts) else {
                return ["error": "storage.get requires channel context for channel-scoped storage"]
            }
            do {
                if let value = try state.db.getPortStorage(key: key, scope: resolved.scope, creatorId: resolved.creator) {
                    if let data = value.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) {
                        return ["value": parsed]
                    }
                    return ["value": value]
                }
                return ["value": NSNull()]
            } catch {
                return ["error": error.localizedDescription]
            }

        // port42.storage.delete(key, options?)
        case "storage.delete":
            guard let key = args.first as? String else {
                return ["error": "storage.delete requires a key"]
            }
            let opts = args.count > 1 ? args[1] as? [String: Any] : nil
            guard let resolved = storageScope(opts: opts) else {
                return ["error": "storage.delete requires channel context for channel-scoped storage"]
            }
            do {
                try state.db.deletePortStorage(key: key, scope: resolved.scope, creatorId: resolved.creator)
                return ["ok": true]
            } catch {
                return ["error": error.localizedDescription]
            }

        // port42.storage.list(options?)
        case "storage.list":
            let opts = args.first as? [String: Any]
            guard let resolved = storageScope(opts: opts) else {
                return ["error": "storage.list requires channel context for channel-scoped storage"]
            }
            do {
                let keys = try state.db.listPortStorageKeys(scope: resolved.scope, creatorId: resolved.creator)
                return ["keys": keys]
            } catch {
                return ["error": error.localizedDescription]
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

    // MARK: - Storage Helpers

    /// Resolve storage scope and creator from JS options.
    /// scope: channelId or "__global__", creator: createdBy or "__shared__"
    private func storageScope(opts: [String: Any]?) -> (scope: String, creator: String)? {
        let scope: String
        if let s = opts?["scope"] as? String, s == "global" {
            scope = "__global__"
        } else {
            guard let cid = channelId else { return nil }
            scope = cid
        }
        let shared = opts?["shared"] as? Bool ?? false
        let creator = shared ? "__shared__" : (createdBy ?? "__unknown__")
        return (scope, creator)
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
                recent: (n) => call('messages.recent', [n || 20]),
                send: (text) => call('messages.send', [text])
            },
            user: {
                get: () => call('user.get')
            },
            channel: {
                current: () => call('channel.current'),
                list: () => call('channel.list'),
                switchTo: (id) => call('channel.switchTo', [id])
            },
            on: function(event, callback) {
                if (!_listeners[event]) _listeners[event] = [];
                _listeners[event].push(callback);
            },
            connection: {
                status: () => _connected ? 'connected' : 'disconnected',
                onStatusChange: (callback) => _statusCallbacks.push(callback)
            },
            storage: {
                set: (key, value, opts) => call('storage.set', [key, value, opts || {}]).then(r => r && r.ok),
                get: (key, opts) => call('storage.get', [key, opts || {}]).then(r => r ? r.value : null),
                delete: (key, opts) => call('storage.delete', [key, opts || {}]).then(r => r && r.ok),
                list: (opts) => call('storage.list', [opts || {}]).then(r => r ? r.keys : [])
            },
            port: {
                info: () => call('port.info'),
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
