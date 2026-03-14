import Foundation
import WebKit

// MARK: - Port Bridge

/// Bridges port42.* JS calls from a port's WKWebView to native Swift services.
/// Handles request/response matching via callId, and pushes live events to JS.
public final class PortBridge: NSObject, WKScriptMessageHandler, ObservableObject {

    private weak var webView: WKWebView?
    private weak var appState: AnyObject?  // AppState, weakly held to avoid import cycle
    private let channelId: String?
    public let messageId: String?
    private let createdBy: String?

    /// Accessor for AppState (cast from AnyObject to avoid circular dependency)
    private var state: AppState? { appState as? AppState }

    // MARK: - Permission State

    /// Permissions granted during this port session. Resets when bridge is deallocated.
    public var grantedPermissions: Set<PortPermission> = []

    /// Active AI streams keyed by callId.
    public var activeStreams: [Int: PortAIHandler] = [:]

    /// The permission currently awaiting user approval, if any.
    @Published public var pendingPermission: PortPermission?

    /// Continuation for the pending permission prompt.
    private var permissionContinuation: CheckedContinuation<Bool, Never>?

    /// Terminal sessions owned by this port. Created lazily on first terminal.spawn call.
    private var terminalBridge: TerminalBridge?

    /// Clipboard bridge. Created lazily on first clipboard call.
    private var clipboardBridge: ClipboardBridge?

    /// File bridge. Created lazily on first fs call.
    private var fileBridge: FileBridge?

    /// Notification bridge. Created lazily on first notify call.
    private var notificationBridge: NotificationBridge?

    /// Audio bridge. Created lazily on first audio call.
    private var audioBridge: AudioBridge?

    /// Screen capture bridge. Created lazily on first screen call.
    private var screenBridge: ScreenBridge?

    /// Browser bridge. Created lazily on first browser call.
    private var browserBridge: BrowserBridge?

    /// Automation bridge. Created lazily on first automation call.
    private var automationBridge: AutomationBridge?

    /// Camera bridge. Created lazily on first camera call.
    private var cameraBridge: CameraBridge?

    public init(appState: AnyObject, channelId: String?, messageId: String? = nil, createdBy: String? = nil) {
        self.appState = appState
        self.channelId = channelId
        self.messageId = messageId
        self.createdBy = createdBy
        super.init()

        // Restore cached permissions immediately so they're in place before the webview
        // loads and JS executes. This prevents permission prompts from re-firing when
        // LazyVStack recycles inline port views.
        if let mid = messageId {
            if let state = appState as? AppState,
               let cached = state.cachedPortPermissions[mid] {
                grantedPermissions = cached
                NSLog("[Port42] Bridge init: restored %d cached permissions for %@", cached.count, mid)
            } else {
                NSLog("[Port42] Bridge init: no cached permissions for %@ (state=%@)", mid, appState == nil ? "nil" : "present")
            }
        } else {
            NSLog("[Port42] Bridge init: no messageId")
        }
    }

    deinit {
        let tb = terminalBridge
        if let tb {
            Task { @MainActor in tb.killAll() }
        }
        let ab = audioBridge
        if let ab {
            Task { @MainActor in ab.cleanup() }
        }
        let bb = browserBridge
        if let bb {
            Task { @MainActor in bb.cleanup() }
        }
        let cb = cameraBridge
        if let cb {
            Task { @MainActor in cb.cleanup() }
        }
        let sb = screenBridge
        if let sb {
            Task { @MainActor in sb.cleanup() }
        }
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

    // MARK: - Permission Management

    /// Grant the pending permission and resume the waiting method.
    @MainActor
    public func grantPermission() {
        guard let perm = pendingPermission else { return }
        grantedPermissions.insert(perm)
        pendingPermission = nil
        permissionContinuation?.resume(returning: true)
        permissionContinuation = nil

        // Cache on AppState so permission survives LazyVStack view recycling
        if let mid = messageId {
            NSLog("[Port42] grantPermission: caching %d permissions for %@: %@", grantedPermissions.count, mid, grantedPermissions.map { $0.rawValue }.joined(separator: ","))
            state?.cachePortPermissions(messageId: mid, permissions: grantedPermissions)
        } else {
            NSLog("[Port42] grantPermission: no messageId, cannot cache")
        }
        // Persist to DB so permissions survive app restart
        state?.portWindows.persistPermissions(for: self)
    }

    /// Deny the pending permission and resume the waiting method with false.
    @MainActor
    public func denyPermission() {
        pendingPermission = nil
        permissionContinuation?.resume(returning: false)
        permissionContinuation = nil
    }

    /// Check and request permission for a method. Returns true if allowed.
    @MainActor
    private func checkPermission(for method: String) async -> Bool {
        guard let perm = PortPermission.permissionForMethod(method) else { return true }
        if grantedPermissions.contains(perm) {
            NSLog("[Port42] checkPermission: %@ already granted (msg=%@)", perm.rawValue, messageId ?? "nil")
            return true
        }

        NSLog("[Port42] checkPermission: PROMPTING for %@ (msg=%@, granted=%@)", perm.rawValue, messageId ?? "nil", grantedPermissions.map { $0.rawValue }.joined(separator: ","))
        // Deny any previous pending permission to avoid leaking its continuation
        if let prev = permissionContinuation {
            prev.resume(returning: false)
            permissionContinuation = nil
        }
        // Ask the user
        return await withCheckedContinuation { continuation in
            permissionContinuation = continuation
            pendingPermission = perm
        }
    }

    // MARK: - Streaming Support

    /// Push a token to the port's JS context for streaming.
    @MainActor
    public func pushToken(_ callId: Int, _ token: String) {
        let escaped = escapeJSString(token)
        webView?.evaluateJavaScript("port42._tokenCallback(\(callId), \"\(escaped)\")") { _, _ in }
    }

    /// Resolve a deferred call with a string result.
    @MainActor
    public func resolveCall(_ callId: Int, _ result: String) {
        let escaped = escapeJSString(result)
        webView?.evaluateJavaScript("port42._resolve(\(callId), \"\(escaped)\")") { _, _ in }
    }

    /// Reject a deferred call with an error message.
    @MainActor
    public func rejectCall(_ callId: Int, _ error: String) {
        let escaped = escapeJSString(error)
        webView?.evaluateJavaScript("port42._reject(\(callId), \"\(escaped)\")") { _, _ in }
    }

    /// Remove a completed stream handler.
    @MainActor
    public func removeStream(_ callId: Int) {
        activeStreams.removeValue(forKey: callId)
    }

    /// Escape a string for safe embedding in JS string literals.
    private func escapeJSString(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
           .replacingOccurrences(of: "\r", with: "\\r")
           .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "port42",
              let body = message.body as? [String: Any],
              let method = body["method"] as? String,
              let callId = body["callId"] as? Int else { return }

        let args = body["args"] as? [Any] ?? []

        Task { @MainActor in
            let result = await handleMethod(method, args: args, callId: callId)

            // Deferred results (streaming) are resolved by the handler, not here
            if let dict = result as? [String: Any], dict["__deferred__"] as? Bool == true {
                return
            }

            let jsonData = try? JSONSerialization.data(withJSONObject: result)
            let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            _ = try? await webView?.evaluateJavaScript("port42._resolve(\(callId), \(jsonString))")
        }
    }

    // MARK: - Method Routing

    @MainActor
    private func handleMethod(_ method: String, args: [Any], callId: Int = 0) async -> Any {
        // Permission guard
        let allowed = await checkPermission(for: method)
        if !allowed {
            return ["error": "permission denied"]
        }

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

        // port42.companions.invoke(id, prompt)
        case "companions.invoke":
            return await handleCompanionInvoke(args: args, callId: callId, state: state)

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

        // port42.ai.models()
        case "ai.models":
            return [
                ["id": "claude-opus-4-6", "name": "Opus 4.6", "tier": "flagship"],
                ["id": "claude-sonnet-4-6", "name": "Sonnet 4.6", "tier": "balanced"],
                ["id": "claude-haiku-4-5-20251001", "name": "Haiku 4.5", "tier": "fast"]
            ]

        // port42.ai.complete(prompt, options?)
        case "ai.complete":
            return await handleAIComplete(args: args, callId: callId, state: state)

        // port42.ai.cancel(callId)
        case "ai.cancel":
            guard let targetId = args.first as? Int else {
                return ["error": "ai.cancel requires a callId"]
            }
            if let handler = activeStreams[targetId] {
                handler.engine.cancel()
                removeStream(targetId)
                return ["ok": true]
            }
            return ["error": "no active stream for callId \(targetId)"]

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

        // MARK: Resources

        case "terminal.xtermjs":
            // Serve bundled xterm.js + CSS for terminal ports
            let js = PortBridge.bundledXtermJS ?? ""
            let css = PortBridge.bundledXtermCSS ?? ""
            return ["js": js, "css": css]

        // MARK: Terminal

        case "terminal.spawn":
            let opts = args.first as? [String: Any] ?? [:]
            let shell = opts["shell"] as? String ?? "/bin/zsh"
            let cwd = opts["cwd"] as? String
            let cols = UInt16(opts["cols"] as? Int ?? 80)
            let rows = UInt16(opts["rows"] as? Int ?? 24)
            let env = opts["env"] as? [String: String]
            NSLog("[Port42] terminal.spawn requested: shell=%@, cols=%d, rows=%d", shell, cols, rows)

            if terminalBridge == nil {
                terminalBridge = TerminalBridge(bridge: self)
            }
            if let sessionId = terminalBridge?.spawn(shell: shell, cwd: cwd, cols: cols, rows: rows, env: env) {
                NSLog("[Port42] terminal.spawn succeeded: %@", sessionId)
                return ["sessionId": sessionId]
            } else {
                NSLog("[Port42] terminal.spawn failed")
                return ["error": "failed to spawn terminal"]
            }

        case "terminal.send":
            guard let sessionId = args.first as? String,
                  let data = args.count > 1 ? args[1] as? String : nil else {
                return ["error": "terminal.send requires sessionId and data"]
            }
            let ok = terminalBridge?.send(sessionId: sessionId, data: data) ?? false
            if ok {
                return ["ok": true]
            } else {
                return ["error": "session not found or not running"]
            }

        case "terminal.resize":
            guard let sessionId = args.first as? String,
                  let cols = args.count > 1 ? args[1] as? Int : nil,
                  let rows = args.count > 2 ? args[2] as? Int : nil else {
                return ["error": "terminal.resize requires sessionId, cols, rows"]
            }
            let ok = terminalBridge?.resize(sessionId: sessionId, cols: UInt16(cols), rows: UInt16(rows)) ?? false
            if ok {
                return ["ok": true]
            } else {
                return ["error": "session not found or not running"]
            }

        case "terminal.kill":
            guard let sessionId = args.first as? String else {
                return ["error": "terminal.kill requires sessionId"]
            }
            let ok = terminalBridge?.kill(sessionId: sessionId) ?? false
            if ok {
                return ["ok": true]
            } else {
                return ["error": "session not found"]
            }

        // MARK: Clipboard

        case "clipboard.read":
            if clipboardBridge == nil { clipboardBridge = ClipboardBridge() }
            return clipboardBridge!.read()

        case "clipboard.write":
            if clipboardBridge == nil { clipboardBridge = ClipboardBridge() }
            return clipboardBridge!.write(args)

        // MARK: File System

        case "fs.pick":
            if fileBridge == nil { fileBridge = FileBridge() }
            let opts = args.first as? [String: Any] ?? [:]
            // H1: Check if key window exists before presenting panel
            NSLog("[Port42] fs.pick: keyWindow=%@, callId=%d", NSApp.keyWindow?.description ?? "nil", callId)
            let pickResult = await fileBridge!.pick(opts: opts)
            // H3: Check if webview is still alive after picker
            NSLog("[Port42] fs.pick: result=%@, webView=%@", String(describing: pickResult), webView == nil ? "GONE" : "alive")
            return pickResult

        case "fs.read":
            guard let path = args.first as? String else {
                return ["error": "fs.read requires a path"]
            }
            // H2: Check if fileBridge survived LazyVStack recycling
            NSLog("[Port42] fs.read: fileBridge=%@, path=%@", fileBridge == nil ? "NIL" : "exists(\(fileBridge!.allowedPathCount) paths)", path)
            if fileBridge == nil { return ["error": "no file has been picked yet"] }
            let opts = args.count > 1 ? args[1] as? [String: Any] : nil
            return fileBridge!.read(path: path, opts: opts)

        case "fs.write":
            guard let path = args.first as? String,
                  let data = args.count > 1 ? args[1] as? String : nil else {
                return ["error": "fs.write requires path and data"]
            }
            // H2: Check if fileBridge survived
            NSLog("[Port42] fs.write: fileBridge=%@, path=%@", fileBridge == nil ? "NIL" : "exists(\(fileBridge!.allowedPathCount) paths)", path)
            if fileBridge == nil { return ["error": "no file has been picked yet"] }
            let opts = args.count > 2 ? args[2] as? [String: Any] : nil
            return fileBridge!.write(path: path, data: data, opts: opts)

        // MARK: Notifications

        case "notify.send":
            guard let title = args.first as? String else {
                return ["error": "notify.send requires a title"]
            }
            let body = args.count > 1 ? args[1] as? String ?? "" : ""
            let opts = args.count > 2 ? args[2] as? [String: Any] : nil
            if notificationBridge == nil { notificationBridge = NotificationBridge() }
            return await notificationBridge!.send(title: title, body: body, opts: opts)

        // MARK: Audio

        case "audio.capture":
            let opts = args.first as? [String: Any] ?? [:]
            if audioBridge == nil { audioBridge = AudioBridge(bridge: self) }
            return await audioBridge!.capture(opts: opts)

        case "audio.stopCapture":
            return audioBridge?.stopCapture() ?? ["error": "no active capture"]

        case "audio.speak":
            guard let text = args.first as? String, !text.isEmpty else {
                return ["error": "audio.speak requires non-empty text"]
            }
            let opts = args.count > 1 ? args[1] as? [String: Any] : nil
            if audioBridge == nil { audioBridge = AudioBridge(bridge: self) }
            return await audioBridge!.speak(text: text, opts: opts)

        case "audio.play":
            guard let data = args.first as? String, !data.isEmpty else {
                return ["error": "audio.play requires base64 audio data"]
            }
            let opts = args.count > 1 ? args[1] as? [String: Any] : nil
            if audioBridge == nil { audioBridge = AudioBridge(bridge: self) }
            return audioBridge!.play(data: data, opts: opts)

        case "audio.stop":
            return audioBridge?.stop() ?? ["ok": true]

        // MARK: Screen Capture

        case "screen.windows":
            if screenBridge == nil { screenBridge = ScreenBridge(bridge: self) }
            return await screenBridge!.windows()

        case "screen.capture":
            let opts = args.first as? [String: Any] ?? [:]
            if screenBridge == nil { screenBridge = ScreenBridge(bridge: self) }
            return await screenBridge!.capture(opts: opts)

        case "screen.stream":
            let opts = args.first as? [String: Any] ?? [:]
            if screenBridge == nil { screenBridge = ScreenBridge(bridge: self) }
            return await screenBridge!.stream(opts: opts)

        case "screen.stopStream":
            if screenBridge == nil { return ["error": "Not streaming"] }
            return await screenBridge!.stopStream()

        // MARK: Camera

        case "camera.capture":
            let opts = args.first as? [String: Any] ?? [:]
            if cameraBridge == nil { cameraBridge = CameraBridge(bridge: self) }
            return await cameraBridge!.capture(opts: opts)

        case "camera.stream":
            let opts = args.first as? [String: Any] ?? [:]
            if cameraBridge == nil { cameraBridge = CameraBridge(bridge: self) }
            return await cameraBridge!.stream(opts: opts)

        case "camera.stopStream":
            return cameraBridge?.stopStream() ?? ["error": "no active camera"]

        // MARK: Browser

        case "browser.open":
            guard let url = args.first as? String, !url.isEmpty else {
                return ["error": "browser.open requires a URL"]
            }
            let opts = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            if browserBridge == nil { browserBridge = BrowserBridge(bridge: self) }
            return await browserBridge!.open(url: url, opts: opts)

        case "browser.navigate":
            guard let sessionId = args.first as? String,
                  let url = args.count > 1 ? args[1] as? String : nil else {
                return ["error": "browser.navigate requires sessionId and url"]
            }
            guard let bb = browserBridge else { return ["error": "no browser sessions"] }
            return await bb.navigate(sessionId: sessionId, url: url)

        case "browser.capture":
            guard let sessionId = args.first as? String else {
                return ["error": "browser.capture requires sessionId"]
            }
            let opts = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            guard let bb = browserBridge else { return ["error": "no browser sessions"] }
            return await bb.capture(sessionId: sessionId, opts: opts)

        case "browser.text":
            guard let sessionId = args.first as? String else {
                return ["error": "browser.text requires sessionId"]
            }
            let opts = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            guard let bb = browserBridge else { return ["error": "no browser sessions"] }
            return await bb.text(sessionId: sessionId, opts: opts)

        case "browser.html":
            guard let sessionId = args.first as? String else {
                return ["error": "browser.html requires sessionId"]
            }
            let opts = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            guard let bb = browserBridge else { return ["error": "no browser sessions"] }
            return await bb.html(sessionId: sessionId, opts: opts)

        case "browser.execute":
            guard let sessionId = args.first as? String,
                  let js = args.count > 1 ? args[1] as? String : nil else {
                return ["error": "browser.execute requires sessionId and JavaScript code"]
            }
            guard let bb = browserBridge else { return ["error": "no browser sessions"] }
            return await bb.execute(sessionId: sessionId, js: js)

        case "browser.close":
            guard let sessionId = args.first as? String else {
                return ["error": "browser.close requires sessionId"]
            }
            guard let bb = browserBridge else { return ["error": "no browser sessions"] }
            return bb.close(sessionId: sessionId)

        // MARK: Automation

        case "automation.runAppleScript":
            guard let source = args.first as? String, !source.isEmpty else {
                return ["error": "automation.runAppleScript requires source code"]
            }
            if automationBridge == nil { automationBridge = AutomationBridge() }
            let opts = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            return await automationBridge!.runAppleScript(source: source, opts: opts)

        case "automation.runJXA":
            guard let source = args.first as? String, !source.isEmpty else {
                return ["error": "automation.runJXA requires source code"]
            }
            if automationBridge == nil { automationBridge = AutomationBridge() }
            let opts = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            return await automationBridge!.runJXA(source: source, opts: opts)

        default:
            NSLog("[Port42] Unknown bridge method: %@", method)
            return ["error": "unknown method: \(method)"]
        }
    }

    // MARK: - AI Complete

    @MainActor
    private func handleAIComplete(args: [Any], callId: Int, state: AppState) async -> Any {
        guard let prompt = args.first as? String, !prompt.isEmpty else {
            return ["error": "ai.complete requires a prompt"]
        }

        let opts = args.count > 1 ? args[1] as? [String: Any] : nil
        let model = opts?["model"] as? String ?? resolveDefaultModel(state: state)
        let systemPrompt = opts?["systemPrompt"] as? String ?? "You are a helpful assistant."
        let maxTokens = opts?["maxTokens"] as? Int ?? 4096
        let images = opts?["images"] as? [String]

        let handler = PortAIHandler(callId: callId, bridge: self)
        activeStreams[callId] = handler

        // Build user message content (multimodal if images provided)
        let content: Any
        if let images, !images.isEmpty {
            var blocks: [[String: Any]] = images.map { base64 in
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/png",
                        "data": base64
                    ] as [String: String]
                ]
            }
            blocks.append(["type": "text", "text": prompt])
            content = blocks
        } else {
            content = prompt
        }

        let messages: [[String: Any]] = [
            ["role": "user", "content": content]
        ]

        do {
            try handler.engine.send(
                messages: messages,
                systemPrompt: systemPrompt,
                model: model,
                maxTokens: maxTokens,
                delegate: handler
            )
        } catch {
            removeStream(callId)
            return ["error": error.localizedDescription]
        }

        return ["__deferred__": true]
    }

    // MARK: - Companion Invoke

    @MainActor
    private func handleCompanionInvoke(args: [Any], callId: Int, state: AppState) async -> Any {
        guard let identifier = args.first as? String, !identifier.isEmpty else {
            return ["error": "companions.invoke requires a companion id or name"]
        }
        let prompt = (args.count > 1 ? args[1] as? String : nil) ?? ""

        // Resolve companion by ID or by name (case-insensitive)
        let companion = state.companions.first(where: { $0.id == identifier })
            ?? state.companions.first(where: { $0.displayName.lowercased() == identifier.lowercased() })

        guard let companion else {
            return ["error": "companion not found: \(identifier)"]
        }

        guard companion.mode == .llm else {
            return ["error": "companion '\(companion.displayName)' is not an LLM companion"]
        }

        // Model resolution: explicit option (not used for invoke) -> companion config -> creating companion -> system default
        let model = companion.model ?? resolveDefaultModel(state: state)
        let basePrompt = companion.systemPrompt ?? "You are a helpful companion."

        // Build system prompt with identity and channel context
        let userName = state.currentUser?.displayName ?? "someone"
        let contextDescription: String
        if let swim = state.activeSwimSession {
            contextDescription = "You are in a private swim (1:1 session) with \(userName) and \(swim.companion.displayName)."
        } else if let cid = channelId, let ch = state.channels.first(where: { $0.id == cid }) {
            contextDescription = "You are in the #\(ch.name) channel."
        } else if let ch = state.currentChannel {
            contextDescription = "You are in the #\(ch.name) channel."
        } else {
            contextDescription = "You are in a Port42 conversation."
        }
        let companionSystemPrompt = """
            IDENTITY: You are \(companion.displayName).

            CONTEXT: You are an AI companion in Port42. \(contextDescription) \
            The user is \(userName). You were invoked by a port (an interactive UI surface) to provide analysis or answers. \
            Your response goes back to the port, not to the chat. Be helpful and concise.

            INSTRUCTIONS: \(basePrompt)
            """

        // Build channel context messages (recent conversation)
        var messages: [[String: Any]] = []
        let recent = state.messages.suffix(20)
        for msg in recent {
            if msg.isSystem { continue }
            if msg.content.isEmpty || msg.content.hasPrefix("[error:") { continue }
            if msg.senderId == companion.id {
                messages.append(["role": "assistant", "content": msg.content])
            } else if msg.isAgent {
                let ownerNote = msg.senderOwner.map { " (belonging to \($0))" } ?? ""
                messages.append(["role": "user", "content": "(companion \(msg.senderName)\(ownerNote) said): \(msg.content)"])
            } else {
                messages.append(["role": "user", "content": "[\(msg.senderName)]: \(msg.content)"])
            }
        }

        // Append the port's prompt as the final user message
        if !prompt.isEmpty {
            messages.append(["role": "user", "content": prompt])
        }

        // Ensure messages alternate and start with user
        messages = cleanAlternation(messages)
        guard !messages.isEmpty else {
            return ["error": "no messages to send"]
        }

        let handler = PortAIHandler(callId: callId, bridge: self)
        activeStreams[callId] = handler

        do {
            try handler.engine.send(
                messages: messages,
                systemPrompt: companionSystemPrompt,
                model: model,
                maxTokens: 4096,
                delegate: handler
            )
        } catch {
            removeStream(callId)
            return ["error": error.localizedDescription]
        }

        return ["__deferred__": true]
    }

    // MARK: - Helpers

    /// Resolve the default model from the creating companion or system default.
    private func resolveDefaultModel(state: AppState) -> String {
        // Try the creating companion's model
        if let creator = createdBy,
           let companion = state.companions.first(where: { $0.displayName.lowercased() == creator.lowercased() }),
           let model = companion.model {
            return model
        }
        return "claude-sonnet-4-6"
    }

    /// Ensure messages alternate user/assistant and start with user.
    /// Merges consecutive same-role messages.
    private func cleanAlternation(_ messages: [[String: Any]]) -> [[String: Any]] {
        guard !messages.isEmpty else { return [] }
        var result: [[String: Any]] = []
        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            if let last = result.last, last["role"] as? String == role {
                // Merge consecutive same-role messages (text content only)
                let lastContent = last["content"] as? String ?? ""
                let thisContent = msg["content"] as? String ?? ""
                let merged = lastContent + "\n" + thisContent
                result[result.count - 1] = ["role": role, "content": merged]
            } else {
                result.append(msg)
            }
        }
        // Must start with user
        if result.first?["role"] as? String == "assistant" {
            result.insert(["role": "user", "content": "(context)"], at: 0)
        }
        return result
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

    // MARK: - Bundled Resources

    /// Bundled xterm.js library for terminal ports
    static let bundledXtermJS: String? = {
        guard let url = Bundle.module.url(forResource: "xterm", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// Bundled xterm.css for terminal ports
    static let bundledXtermCSS: String? = {
        guard let url = Bundle.module.url(forResource: "xterm", withExtension: "css") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    // MARK: - Injected JavaScript

    /// The port42.* namespace injected into every port webview
    static let bridgeJS: String = """
    (function() {
        let _callId = 0;
        const _pending = {};
        const _listeners = {};
        const _tokenCallbacks = {};

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
            _reject: function(callId, error) {
                const resolve = _pending[callId];
                if (resolve) {
                    delete _pending[callId];
                    delete _tokenCallbacks[callId];
                    resolve({"error": error});
                }
            },
            _tokenCallback: function(callId, token) {
                const cb = _tokenCallbacks[callId];
                if (cb) try { cb(token); } catch(e) { console.error(e); }
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

            ai: {
                models: () => call('ai.models'),
                complete: function(prompt, opts) {
                    opts = opts || {};
                    const id = _callId + 1;
                    if (opts.onToken) _tokenCallbacks[id] = opts.onToken;
                    return call('ai.complete', [prompt, {
                        model: opts.model,
                        systemPrompt: opts.systemPrompt,
                        maxTokens: opts.maxTokens,
                        images: opts.images
                    }]).then(function(r) {
                        delete _tokenCallbacks[id];
                        if (r && r.error) throw new Error(r.error);
                        if (opts.onDone) opts.onDone(r);
                        return r;
                    });
                },
                cancel: function(callId) { return call('ai.cancel', [callId]); }
            },
            companions: {
                list: () => call('companions.list'),
                get: (id) => call('companions.get', [id]),
                invoke: function(id, prompt, opts) {
                    opts = opts || {};
                    const cid = _callId + 1;
                    if (opts.onToken) _tokenCallbacks[cid] = opts.onToken;
                    return call('companions.invoke', [id, prompt]).then(function(r) {
                        delete _tokenCallbacks[cid];
                        if (r && r.error) throw new Error(r.error);
                        if (opts.onDone) opts.onDone(r);
                        return r;
                    });
                }
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
            },
            terminal: {
                spawn: (opts) => call('terminal.spawn', [opts || {}]),
                send: (sessionId, data) => call('terminal.send', [sessionId, data]),
                resize: (sessionId, cols, rows) => call('terminal.resize', [sessionId, cols, rows]),
                kill: (sessionId) => call('terminal.kill', [sessionId]),
                on: function(event, callback) {
                    const fullEvent = 'terminal.' + event;
                    if (!_listeners[fullEvent]) _listeners[fullEvent] = [];
                    _listeners[fullEvent].push(callback);
                },
                loadXterm: async function() {
                    const res = await call('terminal.xtermjs');
                    if (res && res.js) {
                        const style = document.createElement('style');
                        style.textContent = res.css || '';
                        document.head.appendChild(style);
                        const script = document.createElement('script');
                        script.textContent = res.js;
                        document.head.appendChild(script);
                        // xterm.js exports to window.Terminal
                        return window.Terminal;
                    }
                    return null;
                }
            },
            clipboard: {
                read: () => call('clipboard.read'),
                write: (data) => call('clipboard.write', [data])
            },
            fs: {
                pick: (opts) => call('fs.pick', [opts || {}]),
                read: (path, opts) => call('fs.read', [path, opts || {}]),
                write: (path, data, opts) => call('fs.write', [path, data, opts || {}])
            },
            notify: {
                send: (title, body, opts) => call('notify.send', [title, body || '', opts || {}])
            },
            audio: {
                capture: (opts) => call('audio.capture', [opts || {}]),
                stopCapture: () => call('audio.stopCapture'),
                speak: (text, opts) => call('audio.speak', [text, opts || {}]),
                play: (data, opts) => call('audio.play', [data, opts || {}]),
                stop: () => call('audio.stop'),
                on: function(event, callback) {
                    var fullEvent = 'audio.' + event;
                    if (!_listeners[fullEvent]) _listeners[fullEvent] = [];
                    _listeners[fullEvent].push(callback);
                }
            },
            screen: {
                windows: () => call('screen.windows'),
                capture: (opts) => call('screen.capture', [opts || {}]),
                stream: (opts) => call('screen.stream', [opts || {}]),
                stopStream: () => call('screen.stopStream'),
                on: function(event, callback) {
                    if (event === 'frame') {
                        window.__port42_listeners = window.__port42_listeners || {};
                        window.__port42_listeners['screen.frame'] = callback;
                    }
                }
            },
            camera: {
                capture: (opts) => call('camera.capture', [opts || {}]),
                stream: (opts) => call('camera.stream', [opts || {}]),
                stopStream: () => call('camera.stopStream'),
                on: function(event, callback) {
                    var fullEvent = 'camera.' + event;
                    if (!_listeners[fullEvent]) _listeners[fullEvent] = [];
                    _listeners[fullEvent].push(callback);
                }
            },
            browser: {
                open: (url, opts) => call('browser.open', [url, opts || {}]),
                navigate: (sessionId, url) => call('browser.navigate', [sessionId, url]),
                capture: (sessionId, opts) => call('browser.capture', [sessionId, opts || {}]),
                text: (sessionId, opts) => call('browser.text', [sessionId, opts || {}]),
                html: (sessionId, opts) => call('browser.html', [sessionId, opts || {}]),
                execute: (sessionId, js) => call('browser.execute', [sessionId, js]),
                close: (sessionId) => call('browser.close', [sessionId]),
                on: function(event, callback) {
                    var fullEvent = 'browser.' + event;
                    if (!_listeners[fullEvent]) _listeners[fullEvent] = [];
                    _listeners[fullEvent].push(callback);
                }
            },
            automation: {
                runAppleScript: (source, opts) => call('automation.runAppleScript', [source, opts || {}]),
                runJXA: (source, opts) => call('automation.runJXA', [source, opts || {}])
            },
            viewport: {
                width: window.innerWidth || 600,
                height: window.innerHeight || 400,
                on: function(event, callback) {
                    if (event === 'resize') {
                        window.__port42_listeners = window.__port42_listeners || {};
                        window.__port42_listeners['viewport.resize'] = callback;
                    }
                }
            }
        };
    })();
    """
}
