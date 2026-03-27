import Foundation
import WebKit

// MARK: - Port Bridge

/// Bridges port42.* JS calls from a port's WKWebView to native Swift services.
/// Handles request/response matching via callId, and pushes live events to JS.
public final class PortBridge: NSObject, WKScriptMessageHandler, ObservableObject {

    private weak var webView: WKWebView?
    private weak var appState: AnyObject?  // AppState, weakly held to avoid import cycle
    public let channelId: String?
    public let messageId: String?
    public let createdBy: String?

    /// Explicit title set at creation or updated by the port via port42.port.setTitle().
    /// Takes priority over HTML <title> extraction.
    @Published public var title: String?

    /// Capabilities declared by the port via port42.port.setCapabilities([...]).
    @Published public var storedCapabilities: [String] = []

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
    private(set) var terminalBridge: TerminalBridge?

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

    public init(appState: AnyObject, channelId: String?, messageId: String? = nil, createdBy: String? = nil, title: String? = nil) {
        self.appState = appState
        self.channelId = channelId
        self.messageId = messageId
        self.createdBy = createdBy
        self.title = title
        super.init()

        // Restore cached permissions immediately so they're in place before the webview
        // loads and JS executes. This prevents permission prompts from re-firing when
        // LazyVStack recycles inline port views.
        if let state = appState as? AppState {
            // 1. Message-level cache (survives view recycling within session)
            if let mid = messageId, let cached = state.cachedPortPermissions[mid] {
                grantedPermissions = cached
            }
            // 2. Companion-level persistence (P-260): auto-restore permissions for same companion+channel
            if let by = createdBy, let cid = channelId {
                let companionPerms = state.companionPermissions(createdBy: by, channelId: cid)
                if !companionPerms.isEmpty {
                    grantedPermissions.formUnion(companionPerms)
                }
            }
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
            state?.cachePortPermissions(messageId: mid, permissions: grantedPermissions)
        }
        // Persist to DB so permissions survive app restart
        state?.portWindows.persistPermissions(for: self)
        // Companion-level persistence (P-260): save so future ports by same companion auto-grant
        if let by = createdBy, let cid = channelId {
            state?.saveCompanionPermissions(grantedPermissions, createdBy: by, channelId: cid)
        }
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
            return true
        }
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

    // MARK: - File Drop

    /// Handle files dropped onto the port window.
    /// Terminal ports: pastes escaped paths into the terminal (requires terminal permission).
    /// Other ports: triggers filesystem permission, then dispatches `port42:filedrop` to JS.
    @MainActor
    public func handleFileDrop(_ files: [[String: Any]]) async {
        // Terminal ports: paste file paths directly into the terminal
        if let tb = terminalBridge, tb.firstActiveSessionId != nil {
            guard await checkPermission(for: "terminal.send") else { return }
            let paths = files.compactMap { $0["path"] as? String }
            let escaped = paths.map { path -> String in
                // Shell-escape: wrap in single quotes, escape existing single quotes
                "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            tb.sendToFirst(data: escaped.joined(separator: " "))
            return
        }

        // Regular ports: dispatch JS event
        guard await checkPermission(for: "fs.drop") else { return }
        guard let json = try? JSONSerialization.data(withJSONObject: files),
              let jsonStr = String(data: json, encoding: .utf8) else { return }
        webView?.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('port42:filedrop', {detail: \(jsonStr)}))"
        ) { _, _ in }
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

        // port42.help() — returns the full API reference
        case "help", "-h":
            if let url = Bundle.port42.url(forResource: "cli-context", withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
            return "API reference unavailable"

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
            if let companion = state.activeSwimCompanion,
               let channel = state.currentChannel, channel.isSwim {
                return [
                    "id": channel.id,
                    "name": companion.displayName,
                    "type": "swim",
                    "members": [
                        ["name": state.currentUser?.displayName ?? "you", "type": "human"],
                        ["name": companion.displayName, "type": "companion"]
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
        // Always sends as the current user — ports are interactive surfaces
        // used by the human, so user-initiated sends must not inherit the
        // companion identity of whoever created the port.
        case "messages.send":
            guard let text = args.first as? String, !text.isEmpty else {
                return ["error": "messages.send requires a non-empty text argument"]
            }
            let targetChannelId = (args.count > 1 ? args[1] as? String : nil) ?? channelId
            state.sendMessage(content: text, toChannelId: targetChannelId)
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
            // Return models for the designated Port AI companion's provider
            let portProvider: AgentProvider? = {
                let savedId = UserDefaults.standard.string(forKey: "portAICompanionId") ?? ""
                if !savedId.isEmpty,
                   let companion = state.companions.first(where: { $0.id == savedId }) {
                    return companion.provider
                }
                return nil
            }()
            switch portProvider {
            case .gemini:
                return [
                    ["id": "gemini-2.5-pro", "name": "Gemini 2.5 Pro", "tier": "flagship"],
                    ["id": "gemini-2.5-flash", "name": "Gemini 2.5 Flash", "tier": "balanced"],
                    ["id": "gemini-2.0-flash", "name": "Gemini 2.0 Flash", "tier": "fast"]
                ]
            default:
                return [
                    ["id": "claude-opus-4-6", "name": "Opus 4.6", "tier": "flagship"],
                    ["id": "claude-sonnet-4-6", "name": "Sonnet 4.6", "tier": "balanced"],
                    ["id": "claude-haiku-4-5-20251001", "name": "Haiku 4.5", "tier": "fast"]
                ]
            }

        // port42.ai.status() — check if AI calls are available
        case "ai.status":
            return ["paused": LLMEngine.paused]

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

        // port42.port.setTitle(title) — set explicit title on self, overrides HTML <title> extraction
        case "port.setTitle":
            guard let newTitle = args.first as? String, !newTitle.isEmpty else {
                return ["error": "title required"]
            }
            self.title = newTitle
            if let mid = messageId {
                state.portWindows.renamePort(byMessageId: mid, title: newTitle)
            }
            return ["ok": true]

        // port42.port.setCapabilities(caps) — declare this port's capabilities
        case "port.setCapabilities":
            guard let caps = args.first as? [String] else {
                return ["error": "setCapabilities requires an array of strings"]
            }
            self.storedCapabilities = caps
            if let udid = messageId.flatMap({ mid in state.portWindows.panels.first(where: { $0.messageId == mid })?.udid }) {
                state.portWindows.setCapabilities(id: udid, capabilities: caps)
            }
            return ["ok": true]

        // port42.port.rename(id, title) — rename another port by UDID
        case "port.rename":
            guard let id = args.first as? String,
                  let newTitle = args.count > 1 ? args[1] as? String : nil,
                  !newTitle.isEmpty else {
                return ["error": "port.rename requires id and title"]
            }
            state.portWindows.renamePort(id: id, title: newTitle)
            // Also update inline bridge if it's an inline port
            if let bridge = state.findInlineBridge(by: id) {
                bridge.title = newTitle
            }
            return ["ok": true]

        // port42.port.resize(w, h) — height change handled by JS postMessage
        case "port.resize":
            return ["ok": true]

        // port42.ports.list(opts?) — list all active ports
        case "ports.list":
            let opts = args.first as? [String: Any]
            let filterCaps = opts?["capabilities"] as? [String] ?? []
            let floating = state.portWindows.allPorts()
            let inline = state.inlinePorts().filter { $0.channelId == channelId || channelId == nil }.suffix(5)
            typealias PortInfo = (id: String, title: String, createdBy: String?, capabilities: [String], cwd: String?, status: String, x: CGFloat?, y: CGFloat?)
            let all: [PortInfo] = floating.map { (id: $0.udid, title: $0.title, createdBy: $0.createdBy, capabilities: $0.capabilities, cwd: $0.cwd, status: $0.isBackground ? "docked" : "floating", x: $0.x, y: $0.y) }
                + inline.map { (id: $0.id, title: $0.title, createdBy: $0.createdBy, capabilities: $0.capabilities, cwd: $0.cwd, status: "inline", x: CGFloat?.none, y: CGFloat?.none) }
            let filtered = filterCaps.isEmpty ? all : all.filter { p in
                filterCaps.allSatisfy { cap in p.capabilities.contains(cap) }
            }
            return filtered.map { p -> [String: Any] in
                var entry: [String: Any] = ["id": p.id, "title": p.title, "capabilities": p.capabilities, "status": p.status]
                if let cb = p.createdBy { entry["createdBy"] = cb }
                if let cwd = p.cwd { entry["cwd"] = cwd }
                if let x = p.x { entry["x"] = x }
                if let y = p.y { entry["y"] = y }
                return entry
            }

        // port42.port.update(id, html) — update another port's HTML
        case "port.update":
            guard let id = args.first as? String,
                  let html = args.count > 1 ? args[1] as? String : nil else {
                return ["error": "port.update requires id and html"]
            }
            let updated = state.portWindows.updatePort(idOrTitle: id, html: html)
            return ["ok": updated]

        // port42.port.getHtml(id, version?) — read a port's current or versioned HTML
        case "port.getHtml":
            guard let id = args.first as? String else {
                return ["error": "port.getHtml requires id"]
            }
            if let version = args.count > 1 ? args[1] as? Int : nil {
                if let html = try? state.db.fetchPortVersionHtml(udid: id, version: version) {
                    return ["html": html]
                }
                return ["error": "no version \(version) for port '\(id)'"]
            }
            if let html = try? state.db.fetchPortHtml(udid: id) {
                return ["html": html]
            }
            return ["error": "no port found for id '\(id)'"]

        // port42.port.patch(id, search, replace) — targeted string replacement
        case "port.patch":
            guard let id = args.first as? String,
                  let search = args.count > 1 ? args[1] as? String : nil,
                  let replace = args.count > 2 ? args[2] as? String : nil else {
                return ["error": "port.patch requires id, search, and replace"]
            }
            guard let currentHtml = try? state.db.fetchPortHtml(udid: id) else {
                return ["error": "no port found for id '\(id)'"]
            }
            guard currentHtml.contains(search) else {
                return ["error": "search string not found in port '\(id)'"]
            }
            let patched = currentHtml.replacingOccurrences(of: search, with: replace)
            let applied = state.portWindows.updatePort(idOrTitle: id, html: patched)
            return ["ok": applied]

        // port42.port.history(id) — version history for a port
        case "port.history":
            guard let id = args.first as? String else {
                return ["error": "port.history requires id"]
            }
            let versions = (try? state.db.fetchPortVersions(portUdid: id)) ?? []
            return versions.map { v -> [String: Any] in
                var entry: [String: Any] = [
                    "version": v.version,
                    "createdAt": ISO8601DateFormatter().string(from: v.createdAt)
                ]
                if let cb = v.createdBy { entry["createdBy"] = cb }
                return entry
            }

        // port42.port.manage(id, action) — focus/close/dock/undock another port
        case "port.manage":
            guard let id = args.first as? String,
                  let action = args.count > 1 ? args[1] as? String : nil else {
                return ["error": "port.manage requires id and action"]
            }
            guard let panel = state.portWindows.findPort(by: id) else {
                return ["error": "no port found for '\(id)'"]
            }
            switch action {
            case "focus":
                state.portWindows.bringToFront(panel.id)
                return ["ok": true]
            case "close":
                state.portWindows.close(panel.id)
                return ["ok": true]
            case "minimize", "dock":
                state.portWindows.minimize(panel.id)
                return ["ok": true]
            case "restore", "undock":
                return ["ok": state.portWindows.restore(panel.id)]
            default:
                return ["error": "unknown action '\(action)'. Use: focus, close, dock, undock"]
            }

        // port42.port.move(id, x, y) — move a floating port to screen coordinates
        case "port.move":
            guard let id = args.first as? String,
                  let xd = (args.count > 1 ? args[1] as? Double : nil),
                  let yd = (args.count > 2 ? args[2] as? Double : nil) else {
                return ["error": "port.move requires id, x, y"]
            }
            let x = CGFloat(xd), y = CGFloat(yd)
            state.portWindows.movePort(id: id, x: x, y: y)
            return ["ok": true]

        // port42.port.position(id) — get current position and size of a port window
        case "port.position":
            guard let id = args.first as? String else {
                return ["error": "port.position requires id"]
            }
            if let frame = state.portWindows.portFrame(by: id) {
                return ["x": frame.origin.x, "y": frame.origin.y, "width": frame.size.width, "height": frame.size.height]
            }
            return ["error": "port not found or not floating: '\(id)'"]

        // port42.screen.displays() — list all displays with bounds (no permissions needed)
        case "screen.displays":
            return NSScreen.screens.map { screen -> [String: Any] in
                let f = screen.frame
                let v = screen.visibleFrame
                return [
                    "width": f.width, "height": f.height,
                    "x": f.origin.x, "y": f.origin.y,
                    "visibleWidth": v.width, "visibleHeight": v.height,
                    "visibleX": v.origin.x, "visibleY": v.origin.y,
                    "isMain": screen == NSScreen.main
                ]
            }

        // port42.port.restore(id, version) — restore a port to a previous version
        case "port.restore":
            guard let id = args.first as? String,
                  let version = args.count > 1 ? args[1] as? Int : nil else {
                return ["error": "port.restore requires id and version"]
            }
            guard let html = try? state.db.fetchPortVersionHtml(udid: id, version: version) else {
                return ["error": "no version \(version) for port '\(id)'"]
            }
            let restored = state.portWindows.updatePort(idOrTitle: id, html: html)
            return ["ok": restored]

        // port42.crease.write(content, opts?) — write a new crease
        case "crease.write":
            guard let companionId = createdBy,
                  let content = args.first as? String, !content.isEmpty else {
                return ["error": "crease.write requires content and companion context"]
            }
            let opts = args.count > 1 ? args[1] as? [String: Any] : nil
            let crease = CompanionCrease(
                companionId: companionId,
                channelId: opts?["channelId"] as? String ?? channelId,
                content: content,
                prediction: opts?["prediction"] as? String,
                actual: opts?["actual"] as? String
            )
            try? state.db.saveCrease(crease)
            return ["id": crease.id, "ok": true]

        // port42.crease.touch(id) — mark a crease as active
        case "crease.touch":
            guard let id = args.first as? String else {
                return ["error": "crease.touch requires id"]
            }
            try? state.db.touchCrease(id: id)
            return ["ok": true]

        // port42.crease.forget(id) — remove a crease
        case "crease.forget":
            guard let id = args.first as? String else {
                return ["error": "crease.forget requires id"]
            }
            try? state.db.deleteCrease(id: id)
            return ["ok": true]

        // port42.fold.update(opts) — update fold state (writes to swim channel)
        case "fold.update":
            guard let companionId = createdBy else {
                return ["error": "fold.update requires companion context"]
            }
            let opts = args.first as? [String: Any] ?? [:]
            let swimId = "swim-\(companionId)"
            var fold = (try? state.db.fetchFold(companionId: companionId, channelId: swimId))
                ?? CompanionFold(companionId: companionId, channelId: swimId)
            if let est = opts["established"] as? [String] { fold.established = est }
            if let ten = opts["tensions"] as? [String] { fold.tensions = ten }
            if let h = opts["holding"] as? String { fold.holding = h.isEmpty ? nil : h }
            if let delta = opts["depthDelta"] as? Int { fold.depth = max(0, fold.depth + delta) }
            fold.updatedAt = Date()
            try? state.db.saveFold(fold)
            return ["ok": true]

        // port42.position.set(read, opts?) — set position state (writes to swim channel)
        case "position.set":
            guard let companionId = createdBy else {
                return ["error": "position.set requires companion context"]
            }
            guard let read = args.first as? String, !read.isEmpty else {
                return ["error": "position.set requires read"]
            }
            let opts = args.count > 1 ? args[1] as? [String: Any] : nil
            let swimId = "swim-\(companionId)"
            var pos = (try? state.db.fetchPosition(companionId: companionId, channelId: swimId))
                ?? CompanionPosition(companionId: companionId, channelId: swimId)
            pos.read = read
            if let stance = opts?["stance"] as? String { pos.stance = stance.isEmpty ? nil : stance }
            if let watching = opts?["watching"] as? [String] { pos.watching = watching.isEmpty ? nil : watching }
            pos.updatedAt = Date()
            try? state.db.savePosition(pos)
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
            if terminalBridge == nil {
                terminalBridge = TerminalBridge(bridge: self)
            }
            if let sessionId = terminalBridge?.spawn(shell: shell, cwd: cwd, cols: cols, rows: rows, env: env) {
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

        case "terminal.cwd":
            guard let sessionId = args.first as? String else {
                return ["error": "terminal.cwd requires sessionId"]
            }
            if let cwd = terminalBridge?.cwd(sessionId: sessionId) {
                return ["cwd": cwd]
            }
            return ["cwd": NSNull()]

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
            let pickResult = await fileBridge!.pick(opts: opts)
            return pickResult

        case "fs.read":
            guard let path = args.first as? String else {
                return ["error": "fs.read requires a path"]
            }
            if fileBridge == nil { return ["error": "no file has been picked yet"] }
            let opts = args.count > 1 ? args[1] as? [String: Any] : nil
            return fileBridge!.read(path: path, opts: opts)

        case "fs.write":
            guard let path = args.first as? String,
                  let data = args.count > 1 ? args[1] as? String : nil else {
                return ["error": "fs.write requires path and data"]
            }
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
            let screenResult = await screenBridge!.capture(opts: opts)
            if let dict = screenResult as? [String: Any], let b64 = dict["image"] as? String {
                postCapture(base64PNG: b64, type: "screen")
            }
            return screenResult

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
            let cameraResult = await cameraBridge!.capture(opts: opts)
            if let dict = cameraResult as? [String: Any], let b64 = dict["image"] as? String {
                postCapture(base64PNG: b64, type: "camera")
            }
            return cameraResult

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

        // MARK: - Relationship state (swim-scoped read-only)

        // port42.creases.read(opts?)
        case "creases.read":
            guard let cid = channelId, cid.hasPrefix("swim-") else {
                return ["error": "creases.read is only available in a swim"]
            }
            let companionId = String(cid.dropFirst("swim-".count))
            let opts = args.first as? [String: Any]
            let limit = opts?["limit"] as? Int ?? 8
            let creases = (try? state.db.fetchCreases(companionId: companionId, channelId: cid, limit: limit)) ?? []
            return creases.map { c -> [String: Any] in
                var entry: [String: Any] = [
                    "id": c.id,
                    "content": c.content,
                    "weight": c.weight,
                    "createdAt": ISO8601DateFormatter().string(from: c.createdAt)
                ]
                if let pred = c.prediction { entry["prediction"] = pred }
                if let act = c.actual { entry["actual"] = act }
                return entry
            }

        // port42.fold.read()
        case "fold.read":
            guard let cid = channelId, cid.hasPrefix("swim-") else {
                return ["error": "fold.read is only available in a swim"]
            }
            let companionId = String(cid.dropFirst("swim-".count))
            guard let fold = try? state.db.fetchFold(companionId: companionId, channelId: cid) else {
                return ["depth": 0, "established": [], "tensions": [], "holding": NSNull()] as [String: Any]
            }
            return [
                "depth": fold.depth,
                "established": fold.established ?? [],
                "tensions": fold.tensions ?? [],
                "holding": fold.holding as Any
            ] as [String: Any]

        // port42.position.read()
        case "position.read":
            guard let cid = channelId, cid.hasPrefix("swim-") else {
                return ["error": "position.read is only available in a swim"]
            }
            let companionId = String(cid.dropFirst("swim-".count))
            guard let pos = try? state.db.fetchPosition(companionId: companionId, channelId: cid), !pos.isEmpty else {
                return ["read": NSNull(), "stance": NSNull(), "watching": []] as [String: Any]
            }
            return [
                "read": pos.read as Any,
                "stance": pos.stance as Any,
                "watching": pos.watching ?? []
            ] as [String: Any]

        default:
            NSLog("[Port42] Unknown bridge method: %@", method)
            return ["error": "unknown method: \(method)"]
        }
    }

    // MARK: - Capture Persistence

    /// Save a captured PNG to disk and post an inline system message to the channel.
    @MainActor
    private func postCapture(base64PNG: String, type: String) {
        guard let state = state, let channelId = channelId else { return }

        // Resolve captures directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let capturesDir = appSupport.appendingPathComponent("Port42/captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let stamp = fmt.string(from: Date())
        let companion = (createdBy ?? "port")
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let filename = "\(stamp)-\(companion)-\(type).png"
        let fileURL = capturesDir.appendingPathComponent(filename)

        if let data = Data(base64Encoded: base64PNG) {
            try? data.write(to: fileURL)
        }

        let msg = Message.create(
            channelId: channelId,
            senderId: createdBy ?? "system",
            senderName: createdBy ?? "system",
            content: "[capture:\(type):\(fileURL.path)]",
            senderType: "system"
        )
        do {
            try state.db.saveMessage(msg)
        } catch {
            NSLog("[Port42] Failed to save capture message: %@", error.localizedDescription)
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

        let backend = resolvePortAIBackend(state: state)
        backend.trackingSource = "port:\(title ?? createdBy ?? "unknown")"
        let handler = PortAIHandler(callId: callId, bridge: self, engine: backend)
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
                tools: nil,
                thinkingEnabled: false,
                thinkingEffort: "low",
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
        if let companion = state.activeSwimCompanion,
           let ch = state.currentChannel, ch.isSwim {
            contextDescription = "You are in a private swim (1:1 session) with \(userName) and \(companion.displayName)."
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
                tools: nil,
                thinkingEnabled: false,
                thinkingEffort: "low",
                delegate: handler
            )
        } catch {
            removeStream(callId)
            return ["error": error.localizedDescription]
        }

        return ["__deferred__": true]
    }

    // MARK: - Helpers

    /// Resolve the LLM backend for port42.ai.complete() calls.
    /// Uses the designated Port AI companion (portAICompanionId UserDefaults key) if set,
    /// otherwise falls back to the creating companion's backend, then LLMEngine.
    private func resolvePortAIBackend(state: AppState) -> LLMBackend {
        let savedId = UserDefaults.standard.string(forKey: "portAICompanionId") ?? ""
        if !savedId.isEmpty,
           let companion = state.companions.first(where: { $0.id == savedId }) {
            return makeLLMBackend(for: companion)
        }
        if let creator = createdBy,
           let companion = state.companions.first(where: { $0.id == creator }) {
            return makeLLMBackend(for: companion)
        }
        return LLMEngine()
    }

    /// Resolve the default model for port42.ai.complete() calls.
    /// Prefers the designated Port AI companion's model, then creating companion, then system default.
    private func resolvePortAIModel(state: AppState) -> String {
        let savedId = UserDefaults.standard.string(forKey: "portAICompanionId") ?? ""
        if !savedId.isEmpty,
           let companion = state.companions.first(where: { $0.id == savedId }),
           let model = companion.model {
            return model
        }
        if let creator = createdBy,
           let companion = state.companions.first(where: { $0.id == creator }),
           let model = companion.model {
            return model
        }
        return "claude-sonnet-4-6"
    }

    /// Resolve the default model from the creating companion or system default.
    private func resolveDefaultModel(state: AppState) -> String {
        resolvePortAIModel(state: state)
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
                status: () => call('ai.status'),
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
                },
                update: (id, html) => call('port.update', [id, html]).then(r => r && r.ok),
                getHtml: (id, version) => call('port.getHtml', version != null ? [id, version] : [id]).then(r => r ? r.html : null),
                patch: (id, search, replace) => call('port.patch', [id, search, replace]).then(r => r && r.ok),
                history: (id) => call('port.history', [id]),
                manage: (id, action) => call('port.manage', [id, action]),
                restore: (id, version) => call('port.restore', [id, version]).then(r => r && r.ok),
                move: (id, x, y) => call('port.move', [id, x, y]).then(r => r && r.ok),
                position: (id) => call('port.position', [id])
            },
            ports: {
                list: (opts) => call('ports.list', opts ? [opts] : [])
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
                write: (path, data, opts) => call('fs.write', [path, data, opts || {}]),
                onFileDrop: function(callback) {
                    window.addEventListener('port42:filedrop', (e) => callback(e.detail));
                }
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
                displays: () => call('screen.displays'),
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
            },
            creases: {
                read: (opts) => call('creases.read', opts ? [opts] : []),
                write: (content, opts) => call('crease.write', opts ? [content, opts] : [content]),
                touch: (id) => call('crease.touch', [id]).then(r => r && r.ok),
                forget: (id) => call('crease.forget', [id]).then(r => r && r.ok)
            },
            fold: {
                read: () => call('fold.read'),
                update: (opts) => call('fold.update', [opts || {}]).then(r => r && r.ok)
            },
            position: {
                read: () => call('position.read'),
                set: (read, opts) => call('position.set', opts ? [read, opts] : [read]).then(r => r && r.ok)
            }
        };
    })();
    """
}
