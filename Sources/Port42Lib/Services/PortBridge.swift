import Foundation
import WebKit

// MARK: - Port Bridge

/// Bridges port42.* JS calls from a port's WKWebView to native Swift services.
/// Handles request/response matching via callId, and pushes live events to JS.
public final class PortBridge: NSObject, WKScriptMessageHandler, ObservableObject {

    private(set) weak var webView: WKWebView?
    private weak var appState: AnyObject?  // AppState, weakly held to avoid import cycle
    /// The port's home space. Updated by `PortWindowManager.move` when a port is re-homed, so
    /// API calls / permissions keep attributing to the space the port actually lives in.
    public internal(set) var spaceId: String?
    public let messageId: String?
    public let createdBy: String?

    /// Explicit title set at creation or updated by the port via port42.port.setTitle().
    /// Takes priority over HTML <title> extraction.
    @Published public var title: String?

    /// Capabilities declared by the port via port42.port.setCapabilities([...]).
    @Published public var storedCapabilities: [String] = []

    /// Accessor for AppState (cast from AnyObject to avoid circular dependency)
    private var state: AppState? { appState as? AppState }

    // MARK: - Relationship-memory space resolution (D4: memory is space-scoped)

    /// The space relationship memory READS from for this call: the current space, or the
    /// companion's DM when headless. nil if neither resolves.
    private func memReadSpaceId(_ companionId: String) -> String? {
        if let sid = spaceId { return sid }
        return (try? state?.db.directSpaceId(companionId: companionId)) ?? nil
    }

    /// Write variant: ensure the companion's DM exists when there's no current space.
    private func memWriteSpaceId(_ companionId: String) -> String? {
        if let sid = spaceId { return sid }
        return (try? state?.db.getOrCreateDirectSpaceId(companionId: companionId)) ?? nil
    }

    // MARK: - Permission State

    /// Permissions granted during this port session. Resets when bridge is deallocated.
    public var grantedPermissions: Set<PortPermission> = []

    /// Active AI streams keyed by callId.
    /// In-flight streaming-registry calls (ai.complete, companions.invoke), keyed by the JS callId so
    /// `ai.cancel(callId)` and `suspendAI()` (park/background) can cancel the running Task. This is the
    /// only in-flight-AI bookkeeping — the old PortAIHandler/activeStreams path is gone.
    public var streamTasks: [Int: Task<Void, Never>] = [:]


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

    /// Automation bridge. Created lazily on first automation call.
    private var automationBridge: AutomationBridge?

    /// Camera bridge. Created lazily on first camera call.
    private var cameraBridge: CameraBridge?

    public init(appState: AnyObject, spaceId: String?, messageId: String? = nil, createdBy: String? = nil, title: String? = nil) {
        self.appState = appState
        self.spaceId = spaceId
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
            // 2. Companion-level persistence (P-260): auto-restore permissions for same companion+space
            //    (spaceId nil = a spaceless caller's global grant — see AppState.companionPermKey)
            if let by = createdBy {
                let companionPerms = state.companionPermissions(createdBy: by, spaceId: spaceId)
                if !companionPerms.isEmpty {
                    grantedPermissions.formUnion(companionPerms)
                }
            }
        }
    }

    deinit {
        // A port can die with a card still queued (closed while waiting). Deny it rather than leak
        // the awaiter — the caller's `await` must always return.
        if let mid = messageId, let state = appState as? AppState {
            Task { @MainActor in state.permissions.cancelRequests(from: mid) }
        }
        let ab = audioBridge
        if let ab {
            Task { @MainActor in ab.cleanup() }
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

    /// Record a granted permission: in-memory, view-recycling cache, DB, and the companion-level
    /// grant. Called by the coordinator's answer path, never by a view.
    @MainActor
    private func recordGrant(_ perm: PortPermission) {
        grantedPermissions.insert(perm)
        // Cache on AppState so permission survives LazyVStack view recycling
        if let mid = messageId {
            state?.cachePortPermissions(messageId: mid, permissions: grantedPermissions)
        }
        // Persist to DB so permissions survive app restart
        state?.portWindows.persistPermissions(for: self)
        // Companion-level persistence (P-260): save so future ports by same companion auto-grant
        if let by = createdBy {
            state?.saveCompanionPermissions(grantedPermissions, createdBy: by, spaceId: spaceId)
        }
    }

    /// How this port identifies itself on the permission card.
    private var requester: PermissionRequester {
        PermissionRequester(
            id: messageId ?? ObjectIdentifier(self).debugDescription,
            displayName: createdBy ?? title ?? "a port",
            spaceId: spaceId,
            createdBy: createdBy
        )
    }

    /// Check and request permission for a method. Returns true if allowed.
    ///
    /// The ask now goes to `AppState.permissions` — one queue, rendered once by the shell. This
    /// bridge owns no continuation, so a second concurrent ask can't clobber the first (it
    /// coalesces), and there is no render site here to go missing.
    @MainActor
    private func checkPermission(for method: String) async -> Bool {
        guard let perm = PortPermission.permissionForMethod(method) else { return true }
        if grantedPermissions.contains(perm) { return true }
        guard let state = self.state else { return false }
        let granted = await state.permissions.request(perm, from: requester)
        if granted { recordGrant(perm) }
        return granted
    }

    // MARK: - File Drop

    /// Handle files dropped onto the port window.
    /// Ports: triggers filesystem permission, then dispatches `port42:filedrop` to JS.
    @MainActor
    /// Dispatch dropped file paths to the port's JS as `port42:filedrop` (an array of path
    /// strings). Reading a file's contents still goes through `fs.read` (.filesystem permission).
    public func handleFileDrop(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        guard await checkPermission(for: "fs.drop") else { return }
        guard let json = try? JSONSerialization.data(withJSONObject: paths),
              let jsonStr = String(data: json, encoding: .utf8) else { return }
        NSLog("[Port42] handleFileDrop: dispatching port42:filedrop for %d path(s)", paths.count)
        _ = try? await webView?.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('port42:filedrop', {detail: \(jsonStr)}))"
        )
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

    /// Resolve a deferred call with a structured `BridgeValue` (a streaming method's final value, e.g.
    /// ai.complete's `{text: ...}`). The JS promise resolves with the JSON object as-is; there is no
    /// bare-string unwrap. Uses `_resolve` with a JSON value, mirroring the synchronous result path.
    @MainActor
    public func resolveValue(_ callId: Int, _ value: BridgeValue) {
        let json = value.toJSONObject()
        let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
        let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        webView?.evaluateJavaScript("port42._resolve(\(callId), \(jsonString))") { _, _ in }
    }

    /// Manual per-port AI pause (the pause.circle button in the port's chrome). Distinct from
    /// park/background: the port stays on the desktop and keeps animating (a shader's rAF loop is
    /// GPU, not AI) — only its model calls are blocked. GM: "pause the ai but keep the shader going."
    @Published public var aiPaused: Bool = false

    /// True when model calls must be refused: parked, backgrounded, or manually AI-paused. Off-screen
    /// ports can't burn the subscription while nobody's looking; the manual pause lets a visible port
    /// keep running without reaching the model.
    @MainActor
    var isSuspended: Bool {
        if aiPaused { return true }
        guard let state = self.state,
              let panel = state.portWindows.panels.first(where: { $0.bridge === self }) else { return false }
        return panel.isBackground || panel.presentation == "parked"
    }

    /// Cancel every in-flight AI stream — called when the port is parked/backgrounded so a running
    /// generation stops immediately, not just the next one. Gating new calls (the `isSuspended` guard
    /// in the registry stream methods) stops the loop; this stops the current spend. Cancelling the
    /// Task trips runBridgeStream's cancel handler (backend.cancel + core-owned settlement).
    @MainActor
    public func suspendAI() {
        for (_, task) in streamTasks { task.cancel() }
        streamTasks.removeAll()
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

            // A failed call rejects the JS promise (no resolve({error}) convention). One place, so every
            // method's error is a real rejection the caller catches, not a value it must inspect.
            if let dict = result as? [String: Any], let errMsg = dict["error"] as? String {
                rejectCall(callId, errMsg)
                return
            }

            // .fragmentsAllowed: registry methods can return a bare string/number (e.g. crease.read's
            // "No creases yet" text). Without it, a fragment top level makes JSONSerialization raise an
            // ObjC NSException that `try?` cannot catch; it unwinds through the main-queue drain and
            // permanently wedges the main queue (no dispatch block or main-actor task runs again) while
            // the run loop keeps pumping — the app looks alive but every queued action is dead. Same
            // option as the streaming resolve path above.
            let jsonData = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
            let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            _ = try? await webView?.evaluateJavaScript("port42._resolve(\(callId), \(jsonString))")
        }
    }

    // MARK: - Method Routing

    @MainActor
    private func handleMethod(_ method: String, args: [Any], callId: Int = 0) async -> Any {
        // Registry-first (Phase 2): port JS dispatches extracted+wired methods through the shared impl.
        // JS calls positionally, so the positional args map to named via the method's paramNames; the
        // native JSON value is returned (a BridgeError becomes {error}, the shape JS already handles).
        // Resolve via the instance alias map (service name-maps like creases.* -> crease.* plus the
        // files.* base), not the static ToolNaming.resolveAlias which only knows files.*.
        let canonical = state?.resolveBridgeAlias(method) ?? ToolNaming.resolveAlias(method)
        if let state, let bridgeMethod = state.bridgeRegistry[canonical], bridgeMethod.wired {
            let principal = Principal(
                id: messageId ?? ObjectIdentifier(self).debugDescription,
                displayName: createdBy ?? title ?? "a port",
                spaceId: spaceId, kind: .port)
            do {
                let value = try await state.runBridgeMethod(
                    canonical, principal: principal,
                    args: BridgeArgs(positional: args, names: bridgeMethod.paramNames),
                    pregrant: grantedPermissions)
                return value.toJSONObject()
            } catch let e as BridgeError {
                return ["error": e.message]
            } catch {
                return ["error": error.localizedDescription]
            }
        }

        // Streaming registry (item 8): ai.complete streams tokens, then resolves. Runs in a tracked
        // Task so ai.cancel(callId) can cancel it. yield → _tokenCallback, final text → _resolve, a
        // thrown BridgeError → _reject (the never-reject fix: the port's catch runs instead of the
        // promise silently resolving a value). Permission is gated inside runBridgeStream.
        if let state, state.bridgeStreamHandles(canonical) {
            let principal = Principal(
                id: messageId ?? ObjectIdentifier(self).debugDescription,
                displayName: createdBy ?? title ?? "a port",
                spaceId: spaceId, kind: .port)
            let names = state.bridgeStreamRegistry[canonical]?.paramNames ?? []
            let grants = grantedPermissions
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let value = try await state.runBridgeStream(
                        canonical, principal: principal,
                        args: BridgeArgs(positional: args, names: names),
                        pregrant: grants,
                        yield: { [weak self] token in self?.pushToken(callId, token) })
                    self.resolveValue(callId, value)
                } catch let e as BridgeError {
                    self.rejectCall(callId, e.message)
                } catch is CancellationError {
                    // Core settles the stream as cancelled (the engine emits no terminal event on
                    // cancel); reject the JS promise so it does not dangle. See the cancel-hang RCA.
                    self.rejectCall(callId, "cancelled")
                } catch {
                    self.rejectCall(callId, error.localizedDescription)
                }
                self.streamTasks.removeValue(forKey: callId)
            }
            streamTasks[callId] = task
            return ["__deferred__": true]
        }

        // Permission guard (old path — live-only / unwired methods)
        let allowed = await checkPermission(for: method)
        if !allowed {
            return ["error": "permission denied"]
        }

        guard let state = state else { return ["error": "no app state"] }

        switch method {

        // port42.help() — returns the full API reference
        case "help", "-h":
            if let url = Bundle.port42.url(forResource: "llms", withExtension: "txt"),
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
            // Optional space_id (positional) filters the global roster to that space's companions.
            let roster = Port42Members.companions(appState: state, spaceId: args.first as? String)
            return roster.map { agent -> [String: Any] in
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

        // port42.companions.invoke moved to the streaming registry (item 8) — handled by the stream
        // branch above, before this switch. No longer a case here.

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

        // port42.space.current()
        case "space.current":
            // Check if we're in a DM (a `direct` space with a sole companion)
            if let space = state.currentSpace, space.type == "direct",
               let companion = state.spaceCompanions.first {
                let members: [[String: Any]] = [
                    ["name": state.currentUser?.displayName ?? "you", "type": "human"],
                    ["name": companion.displayName, "type": "agent"]
                ]
                return [
                    "id": space.id,
                    "name": companion.displayName,
                    "type": space.type,   // "direct" — the "swim" type no longer exists (swim→space)
                    "memberCount": members.count,
                    "members": members
                ] as [String: Any]
            }
            // Optional space_id (positional) — inspect any space, default to current. Lets a
            // terminal companion query its OWN space (PORT42_SPACE_ID), not just the UI's current.
            let sid = args.first as? String
            if let space = (sid.flatMap { id in state.spaces.first(where: { $0.id == id }) } ?? state.currentSpace) {
                let list = (try? state.db.getSpaceMembers(spaceId: space.id)) ?? []
                return [
                    "id": space.id,
                    "name": space.name,
                    "type": space.type,
                    "memberCount": list.count,
                    "members": list.map { Port42Members.dict($0) }
                ] as [String: Any]
            }
            return NSNull()

        // port42.space.list()
        case "space.list":
            return state.spaces.map { sp -> [String: Any] in
                [
                    "id": sp.id,
                    "name": sp.name,
                    "type": sp.type,
                    "isCurrent": sp.id == state.currentSpace?.id
                ]
            }

        // space.switchTo: extracted to the registry (tail item 2).

        // port42.messages.send(text)
        // Sends as current user, UNLESS called from a companion terminal port (createdBy set),
        // in which case it's redirected to sendAsCreator so CLI agents that call curl
        // get the correct identity and typing indicator clearing.
        case "messages.send":
            guard let text = args.first as? String, !text.isEmpty else {
                return ["error": "messages.send requires a non-empty text argument"]
            }
            let targetSpaceId = (args.count > 1 ? args[1] as? String : nil) ?? spaceId
            if let senderName = createdBy, !senderName.isEmpty {
                NSLog("[p42-bridge] messages.send from companion port '%@' — redirecting to sendAsCreator", senderName)
                state.sendMessageAsNamedAgent(content: text, senderName: senderName, toSpaceId: targetSpaceId)
                if let sid = targetSpaceId {
                    state.typingAgentNamesBySpace[sid, default: []].remove(senderName)
                    state.sync.sendTyping(spaceId: sid, senderName: senderName, isTyping: false, senderOwner: state.currentUser?.displayName)
                }
            } else {
                state.sendMessage(content: text, toSpaceId: targetSpaceId)
            }
            return ["ok": true]

        // messages.sendAsCreator: extracted to the registry (tail item 1). The principal's
        // displayName carries this port's createdBy (falling back to title).

        // port42.terminal.exec(command, {cwd?, timeout?}) — headless run-and-capture.
        // The ONLY terminal bridge method: spawn/send/list moved to port.create / port.push /
        // ports.list. Gated by .terminal (PortPermission). Shares ShellExec with terminal_exec.
        case "terminal.exec":
            guard let command = args.first as? String, !command.isEmpty else {
                return ["error": "terminal.exec requires a command string"]
            }
            let execOpts = args.count > 1 ? args[1] as? [String: Any] : nil
            let execCwd = execOpts?["cwd"] as? String
            let execTimeout = min((execOpts?["timeout"] as? Int) ?? 30, 120)
            let execOutput = await ShellExec.run(command, cwd: execCwd, timeout: execTimeout)
            return ["output": execOutput]

        // port.info: extracted to the registry (tail item 9) — served from the caller's principal.

        // port42.ai.models / ai.status / ai.complete are all served by the registry now: models and
        // status are the `ai` service module (BridgeServiceAI.swift, registry-first), complete streams
        // via the stream registry. Only ai.cancel remains here — it cancels a stream by JS callId
        // (streamTasks), which is transport-coupled, not a service method.

        // port42.ai.cancel(callId)
        case "ai.cancel":
            guard let targetId = args.first as? Int else {
                return ["error": "ai.cancel requires a callId"]
            }
            // ai.complete / companions.invoke run as tracked Tasks (streaming registry); cancel the
            // Task, which trips runBridgeStream's cancel handler (backend.cancel + core settlement).
            if let task = streamTasks[targetId] {
                task.cancel()
                streamTasks.removeValue(forKey: targetId)
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
                return ["error": "storage.set requires space context for space-scoped storage"]
            }
            let value: String
            if args.count > 1 {
                if let str = args[1] as? String {
                    value = str
                } else if let data = try? JSONSerialization.data(withJSONObject: args[1], options: [.fragmentsAllowed]),
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
                return ["error": "storage.get requires space context for space-scoped storage"]
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
                return ["error": "storage.delete requires space context for space-scoped storage"]
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
                return ["error": "storage.list requires space context for space-scoped storage"]
            }
            do {
                let keys = try state.db.listPortStorageKeys(scope: resolved.scope, creatorId: resolved.creator)
                return ["keys": keys]
            } catch {
                return ["error": error.localizedDescription]
            }

        // port.close / port.setTitle / port.setCapabilities: extracted to the registry (tail item 9),
        // keyed on the caller's own principal. close is now a REAL self-close (the old case was a
        // no-op returning ok).

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

        // port.resize: a pure JS carve-out (manipulates the DOM + postMessage); it never dispatches
        // to native, so no case is needed here or in the registry.

        // port42.ports.list(opts?) — list all active ports
        case "ports.list":
            let opts = args.first as? [String: Any]
            let filterCaps = opts?["capabilities"] as? [String] ?? []
            let floating = state.portWindows.allPorts()
            let inline = state.inlinePorts().filter { $0.spaceId == spaceId || spaceId == nil }.suffix(5)
            typealias PortInfo = (id: String, title: String, createdBy: String?, capabilities: [String], cwd: String?, status: String, x: CGFloat?, y: CGFloat?, surfaceBound: Bool?)
            // surfaceBound (what terminal_list used to report) comes from the live controller; only
            // terminal ports have one, so non-terminals carry nil and omit the field.
            // Status mirrors presentation ('tiled' | 'parked' | 'inline'); a backgrounded
            // port reports "docked" (off the desktop, still running).
            let all: [PortInfo] = floating.map { (id: $0.udid, title: $0.title, createdBy: $0.createdBy, capabilities: $0.capabilities, cwd: $0.cwd, status: $0.isBackground ? "docked" : $0.presentation, x: $0.x, y: $0.y, surfaceBound: state.terminalControllers[$0.udid]?.isSurfaceBound) }
                + inline.map { (id: $0.id, title: $0.title, createdBy: $0.createdBy, capabilities: $0.capabilities, cwd: $0.cwd, status: "inline", x: CGFloat?.none, y: CGFloat?.none, surfaceBound: Bool?.none) }
            let filtered = filterCaps.isEmpty ? all : all.filter { p in
                filterCaps.allSatisfy { cap in p.capabilities.contains(cap) }
            }
            return filtered.map { p -> [String: Any] in
                var entry: [String: Any] = ["id": p.id, "title": p.title, "capabilities": p.capabilities, "status": p.status]
                if let cb = p.createdBy { entry["createdBy"] = cb }
                if let cwd = p.cwd { entry["cwd"] = cwd }
                if let surfaceBound = p.surfaceBound { entry["surfaceBound"] = surfaceBound }
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

        // port42.port.push(id, data) — one type-dispatched verb: a terminal id gets a RAW,
        // non-arming inject (the caller supplies its own newline); a web id gets a port42:data
        // CustomEvent. Ungated.
        case "port.push":
            guard let id = args.first as? String,
                  args.count > 1 else {
                return ["error": "port.push requires id and data"]
            }
            let data = args[1]
            let controller = state.resolveTerminalController(idOrName: id)
            let webView = state.portWindows.webViews[id]
            switch PortPushRoute.classify(isTerminal: controller != nil, isWeb: webView != nil) {
            case .terminal:
                // Raw, non-arming: drives the terminal directly without arming the post gate.
                let str = (data as? String) ?? (try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard controller!.sendRaw(str) else {
                    return ["error": "terminal '\(id)' has no live surface"]
                }
                return ["ok": true]
            case .web:
                guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed]),
                      let jsonStr = String(data: jsonData, encoding: .utf8) else {
                    return ["error": "could not serialize data"]
                }
                _ = try? await webView!.evaluateJavaScript(
                    "window.dispatchEvent(new CustomEvent('port42:data', {detail: \(jsonStr)}))"
                )
                return ["ok": true]
            case .notFound:
                return ["error": "port '\(id)' not found or not active"]
            }

        // port42.port.create({type, title?, html?, command?, args?, cwd?, systemPrompt?, env?, space_id?})
        // Uniform creation primitive. A web port's own JS is an EXTERNAL caller, so web ports open as a
        // floating window (inline:false). Ungated (no permission). Returns {id, title} or {error}.
        case "port.create":
            let opts = args.first as? [String: Any] ?? [:]
            let sid = (opts["space_id"] as? String) ?? spaceId ?? state.currentSpace?.id ?? ""
            return state.createPort(
                type: opts["type"] as? String,
                title: opts["title"] as? String,
                html: opts["html"] as? String,
                command: opts["command"] as? String,
                args: opts["args"] as? [String] ?? [],
                cwd: opts["cwd"] as? String,
                systemPrompt: opts["systemPrompt"] as? String,
                env: opts["env"] as? [String: String] ?? [:],
                spaceId: sid, createdBy: createdBy, createdByName: createdBy,
                presentation: opts["presentation"] as? String)   // nil → mode default (shell: tiled)

        // port42.port.exec(id, js) — execute JS on a live port
        case "port.exec":
            guard let id = args.first as? String,
                  let js = args.count > 1 ? args[1] as? String : nil else {
                return ["error": "port.exec requires id and js"]
            }
            guard let webView = state.portWindows.webViews[id] else {
                return ["error": "port '\(id)' not found or not active"]
            }
            do {
                // #5: callAsyncJavaScript — awaits promises, yields JSON-serializable values (so an
                // object result no longer marshals as "unsupported type").
                guard let result = try await PortExecJS.run(webView, js) else { return ["ok": true] }
                return ["result": result]
            } catch {
                return ["error": error.localizedDescription]
            }

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
            case "background":
                // Set this port as the shell background (Layer 0), full-bleed and ambient.
                await state.shell?.setBackgroundPort(id: panel.udid)
                return ["ok": true]
            case "unbackground":
                await state.shell?.setBackgroundPort(id: nil)     // clear → ambient Canvas returns
                return ["ok": true]
            case "close":
                state.portWindows.close(panel.id)
                return ["ok": true]
            case "minimize", "dock":
                state.portWindows.minimize(panel.id)
                return ["ok": true]
            case "restore", "undock":
                // Step 8: undock on an inline port pops it out (re-parents its live webview, no reload).
                if panel.presentation == "inline" {
                    state.portWindows.undockInline(id: panel.id, in: CGSize(width: 800, height: 600))
                    return ["ok": true]
                }
                return ["ok": state.portWindows.restore(panel.id)]
            default:
                return ["error": "unknown action '\(action)'. Use: focus, close, dock, undock, background, unbackground"]
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

        // port.position: extracted to the registry (tail item 9).

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
                spaceId: opts?["spaceId"] as? String ?? spaceId,
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

        // port42.fold.update(opts) — update fold state (writes to swim space)
        case "fold.update":
            guard let companionId = createdBy else {
                return ["error": "fold.update requires companion context"]
            }
            let opts = args.first as? [String: Any] ?? [:]
            guard let foldSpaceId = memWriteSpaceId(companionId) else {
                return ["error": "no space context for fold"]
            }
            var fold = (try? state.db.fetchFold(companionId: companionId, spaceId: foldSpaceId))
                ?? CompanionFold(companionId: companionId, spaceId: foldSpaceId)
            if let est = opts["established"] as? [String] { fold.established = est }
            if let ten = opts["tensions"] as? [String] { fold.tensions = ten }
            if let h = opts["holding"] as? String { fold.holding = h.isEmpty ? nil : h }
            if let delta = opts["depthDelta"] as? Int { fold.depth = max(0, fold.depth + delta) }
            fold.updatedAt = Date()
            try? state.db.saveFold(fold)
            return ["ok": true]

        // port42.position.set(read, opts?) — set position state (writes to swim space)
        case "position.set":
            guard let companionId = createdBy else {
                return ["error": "position.set requires companion context"]
            }
            guard let read = args.first as? String, !read.isEmpty else {
                return ["error": "position.set requires read"]
            }
            let opts = args.count > 1 ? args[1] as? [String: Any] : nil
            guard let posSpaceId = memWriteSpaceId(companionId) else {
                return ["error": "no space context for position"]
            }
            var pos = (try? state.db.fetchPosition(companionId: companionId, spaceId: posSpaceId))
                ?? CompanionPosition(companionId: companionId, spaceId: posSpaceId)
            pos.read = read
            if let stance = opts?["stance"] as? String { pos.stance = stance.isEmpty ? nil : stance }
            if let watching = opts?["watching"] as? [String] { pos.watching = watching.isEmpty ? nil : watching }
            pos.updatedAt = Date()
            try? state.db.savePosition(pos)
            return ["ok": true]

        // MARK: Clipboard

        case "clipboard.read":
            if clipboardBridge == nil { clipboardBridge = ClipboardBridge() }
            return clipboardBridge!.read()

        case "clipboard.write":
            if clipboardBridge == nil { clipboardBridge = ClipboardBridge() }
            return clipboardBridge!.write(args)

        // MARK: File System

        // fs.* is the canonical file surface; files.* are thin aliases (D4) so ports written against
        // the documented files.* names work too. Same handlers, same .filesystem permission.
        case "fs.pick", "files.pick":
            if fileBridge == nil { fileBridge = FileBridge() }
            let opts = args.first as? [String: Any] ?? [:]
            let pickResult = await fileBridge!.pick(opts: opts)
            return pickResult

        case "fs.read", "files.read":
            guard let path = args.first as? String else {
                return ["error": "fs.read requires a path"]
            }
            if fileBridge == nil { return ["error": "no file has been picked yet"] }
            let opts = args.count > 1 ? args[1] as? [String: Any] : nil
            return fileBridge!.read(path: path, opts: opts)

        case "fs.write", "files.write":
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
            if let b64 = screenResult["image"] as? String {
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
            if let b64 = cameraResult["image"] as? String {
                postCapture(base64PNG: b64, type: "camera")
            }
            return cameraResult

        case "camera.stream":
            let opts = args.first as? [String: Any] ?? [:]
            if cameraBridge == nil { cameraBridge = CameraBridge(bridge: self) }
            return await cameraBridge!.stream(opts: opts)

        case "camera.stopStream":
            return cameraBridge?.stopStream() ?? ["error": "no active camera"]

        // browser.*: extracted to the registry (tail item 5) — one shared session store, sessions
        // remember their creating port for event routing.

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

        // rest.call: extracted to the registry (tail item 4) — permission .rest, unified body with
        // the per-companion secret grant and filtered response headers.

        // MARK: - Relationship state (space-scoped, companion = createdBy — D4)

        // port42.creases.read(opts?)
        case "creases.read":
            guard let companionId = createdBy else {
                return ["error": "creases.read requires companion context"]
            }
            let opts = args.first as? [String: Any]
            let limit = opts?["limit"] as? Int ?? 8
            let creases = (try? state.db.fetchCreases(companionId: companionId, spaceId: memReadSpaceId(companionId), limit: limit)) ?? []
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

        // port42.engravings.read(opts?)
        case "engravings.read":
            guard let companionId = createdBy else {
                return ["error": "engravings.read requires companion context"]
            }
            let opts = args.first as? [String: Any]
            let limit = opts?["limit"] as? Int ?? 8
            let engravings = (try? state.db.fetchEngravings(companionId: companionId, spaceId: memReadSpaceId(companionId), limit: limit)) ?? []
            return engravings.map { e -> [String: Any] in
                var entry: [String: Any] = [
                    "id": e.id,
                    "content": e.content,
                    "weight": e.weight,
                    "createdAt": ISO8601DateFormatter().string(from: e.createdAt)
                ]
                if let cat = e.category { entry["category"] = cat }
                return entry
            }

        // port42.engraving.write(content, opts?) — write a new engraving
        case "engraving.write":
            guard let companionId = createdBy,
                  let content = args.first as? String, !content.isEmpty else {
                return ["error": "engraving.write requires content and companion context"]
            }
            let opts = args.count > 1 ? args[1] as? [String: Any] : nil
            let engraving = CompanionEngraving(
                companionId: companionId,
                spaceId: opts?["spaceId"] as? String ?? spaceId,
                content: content,
                category: opts?["category"] as? String
            )
            try? state.db.saveEngraving(engraving)
            return ["id": engraving.id, "ok": true]

        // port42.engraving.touch(id) — mark an engraving as active
        case "engraving.touch":
            guard let id = args.first as? String else {
                return ["error": "engraving.touch requires id"]
            }
            try? state.db.touchEngraving(id: id)
            return ["ok": true]

        // port42.engraving.forget(id) — remove an engraving
        case "engraving.forget":
            guard let id = args.first as? String else {
                return ["error": "engraving.forget requires id"]
            }
            try? state.db.deleteEngraving(id: id)
            return ["ok": true]

        // port42.fold.read()
        case "fold.read":
            guard let companionId = createdBy else {
                return ["error": "fold.read requires companion context"]
            }
            guard let foldSpaceId = memReadSpaceId(companionId),
                  let fold = try? state.db.fetchFold(companionId: companionId, spaceId: foldSpaceId) else {
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
            guard let companionId = createdBy else {
                return ["error": "position.read requires companion context"]
            }
            guard let posSpaceId = memReadSpaceId(companionId),
                  let pos = try? state.db.fetchPosition(companionId: companionId, spaceId: posSpaceId), !pos.isEmpty else {
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

    /// Save a captured PNG to disk and post an inline system message to the space.
    @MainActor
    private func postCapture(base64PNG: String, type: String) {
        guard let state = state, let spaceId = spaceId else { return }

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
            spaceId: spaceId,
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

    // ai.complete and companions.invoke moved to the streaming registry (item 8):
    // buildBridgeStreamRegistry, dispatched by the stream branch in handleMethod. The old
    // handleAIComplete / handleCompanionInvoke and their helpers (resolveDefaultModel,
    // cleanAlternation) are deleted; the message-building lives on AppState now.

    // MARK: - Storage Helpers

    /// Resolve storage scope and creator from JS options.
    /// scope: spaceId or "__global__", creator: createdBy or "__shared__"
    private func storageScope(opts: [String: Any]?) -> (scope: String, creator: String)? {
        let scope: String
        if let s = opts?["scope"] as? String, s == "global" {
            scope = "__global__"
        } else {
            guard let cid = spaceId else { return nil }
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
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed]),
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
            return new Promise((resolve, reject) => {
                const id = ++_callId;
                _pending[id] = { resolve: resolve, reject: reject };
                window.webkit.messageHandlers.port42.postMessage({
                    method: method,
                    args: args || [],
                    callId: id
                });
            });
        }

        window.port42 = (function() {
            // GENERIC DISPATCH replaces ~240 lines of hand-written per-method bindings. Any
            // port42.a.b(...args) posts call('a.b', args); the host resolves the name (canonical, or a
            // service surface alias like creases.* -> crease.*) and the permission, and returns the
            // structured BridgeValue. No per-method result unwrapping any more: read .value / .html /
            // .ok / .result / .output off the result (same shape every surface now returns).
            //
            // The explicit members below are the only exceptions, because they are NOT request/response
            // dispatch: bridge machinery, event listeners, the two streaming shims (ai.complete /
            // companions.invoke, which wire a token callback), and the one client-only method
            // (port.resize, which manipulates the DOM).
            function __ns(namespace, carveouts) {
                return new Proxy(carveouts || {}, { get: function(t, m) {
                    if (typeof m !== 'string') return undefined;
                    if (Object.prototype.hasOwnProperty.call(t, m)) return t[m];
                    return function() { return call(namespace + '.' + m, Array.prototype.slice.call(arguments)); };
                }});
            }
            var impl = {
                _resolve: function(callId, data) {
                    const p = _pending[callId];
                    if (p) { delete _pending[callId]; delete _tokenCallbacks[callId]; p.resolve(data); }
                },
                _reject: function(callId, error) {
                    const p = _pending[callId];
                    if (p) { delete _pending[callId]; delete _tokenCallbacks[callId]; p.reject(new Error(error)); }
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
                    if (!wasConnected) { _statusCallbacks.forEach(cb => { try { cb('connected'); } catch(e) { console.error(e); } }); }
                },
                on: function(event, callback) {
                    if (!_listeners[event]) _listeners[event] = [];
                    _listeners[event].push(callback);
                },
                connection: {
                    status: () => _connected ? 'connected' : 'disconnected',
                    onStatusChange: (callback) => _statusCallbacks.push(callback)
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
                ai: __ns('ai', {
                    complete: function(prompt, opts) {
                        opts = opts || {};
                        const id = _callId + 1;
                        if (opts.onToken) _tokenCallbacks[id] = opts.onToken;
                        const p = call('ai.complete', [prompt, {
                            model: opts.model,
                            systemPrompt: opts.systemPrompt,
                            maxTokens: opts.maxTokens,
                            images: opts.images
                        }]).then(function(r) { if (opts.onDone) opts.onDone(r); return r; });
                        p.callId = id;
                        p.cancel = function() { return port42.ai.cancel(id); };
                        return p;
                    },
                    cancel: function(callId) { return call('ai.cancel', [callId]); }
                }),
                companions: __ns('companions', {
                    invoke: function(id, prompt, opts) {
                        opts = opts || {};
                        const cid = _callId + 1;
                        if (opts.onToken) _tokenCallbacks[cid] = opts.onToken;
                        return call('companions.invoke', [id, prompt]).then(function(r) { if (opts.onDone) opts.onDone(r); return r; });
                    }
                }),
                port: __ns('port', {
                    resize: (w, h) => {
                        document.body.style.width = w + 'px';
                        document.body.style.height = h + 'px';
                        window.webkit.messageHandlers.portHeight.postMessage(h);
                    }
                }),
                fs: __ns('fs', {
                    onFileDrop: function(callback) {
                        window.addEventListener('port42:filedrop', (e) => callback(e.detail));
                    }
                }),
                audio: __ns('audio', {
                    on: function(event, callback) {
                        var fullEvent = 'audio.' + event;
                        if (!_listeners[fullEvent]) _listeners[fullEvent] = [];
                        _listeners[fullEvent].push(callback);
                    }
                }),
                screen: __ns('screen', {
                    on: function(event, callback) {
                        if (event === 'frame') {
                            window.__port42_listeners = window.__port42_listeners || {};
                            window.__port42_listeners['screen.frame'] = callback;
                        }
                    }
                }),
                camera: __ns('camera', {
                    on: function(event, callback) {
                        var fullEvent = 'camera.' + event;
                        if (!_listeners[fullEvent]) _listeners[fullEvent] = [];
                        _listeners[fullEvent].push(callback);
                    }
                }),
                browser: __ns('browser', {
                    on: function(event, callback) {
                        var fullEvent = 'browser.' + event;
                        if (!_listeners[fullEvent]) _listeners[fullEvent] = [];
                        _listeners[fullEvent].push(callback);
                    }
                })
            };
            return new Proxy(impl, {
                get: function(target, ns) {
                    if (typeof ns !== 'string') return undefined;
                    if (Object.prototype.hasOwnProperty.call(target, ns)) return target[ns];
                    return __ns(ns, {});
                }
            });
        })();
    })();
    """
}
