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

    // MARK: - Permission State

    /// Permissions granted during this port session. Resets when bridge is deallocated.
    public var grantedPermissions: Set<PortPermission> = []

    /// Active AI streams keyed by callId.
    /// In-flight streaming-registry calls (ai.complete, companions.invoke), keyed by the JS callId so
    /// `ai.cancel(callId)` and `suspendAI()` (park/background) can cancel the running Task. This is the
    /// only in-flight-AI bookkeeping — the old PortAIHandler/activeStreams path is gone.
    public var streamTasks: [Int: Task<Void, Never>] = [:]

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
        // the awaiter — the caller's `await` must always return. Cancels by the PRINCIPAL id (the
        // companion for a companion-created port), so the ask this port queued is actually found.
        // Trade-off, accepted: if a sibling port of the same companion is riding the same coalesced
        // card, its await resolves false too — it re-asks on the next call (a deny is never
        // persisted), which beats a zombie card for a dead port.
        if let state = appState as? AppState, messageId != nil || createdBy != nil {
            let pid = createdBy ?? messageId ?? ""
            Task { @MainActor in state.permissions.cancelRequests(from: pid) }
        }
        // The mic-leak teardown backstop (backlog 0.5): device resources release on the close path
        // (PortWindowManager.close/stop -> releaseAcquisitions). This deinit covers the non-close
        // death paths (quit, sign-out, restore-replace), funneling to the SAME AppState entry point,
        // keyed on the port's stable id. Captured as a plain value; deinit adds no retain. A port
        // with no messageId started no captures. The in-flight AI loop is cancelled at close; any
        // stream Task that outlives this bridge holds [weak self] and no-ops.
        if let state = appState as? AppState, let mid = messageId {
            Task { @MainActor in state.releaseAcquisitions(portId: mid) }
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
    //
    // There is no per-bridge permission machinery any more: the dispatcher gates every method
    // against the registry's declared permission, keyed on portPrincipal, and persists grants
    // itself. The old checkPermission/recordGrant pair died in the Phase 3 sweep — its only
    // caller gated fs.drop, which needs no permission (an explicit user gesture).

    /// WHO this port is, for authorization: the ONE identity every dispatch and permission ask uses.
    /// A companion-created port acts as its creator (GM decision 2026-07-19) — one grant bucket per
    /// author per space (P-260 in both directions) and one storage namespace with its companion
    /// (todo #6). A human-created port keys on its own message id. The space scope rides in
    /// `spaceId`, so a grant never leaks across spaces.
    var portPrincipal: Principal {
        Principal(
            id: createdBy ?? messageId ?? ObjectIdentifier(self).debugDescription,
            displayName: createdBy ?? title ?? "a port",
            spaceId: spaceId, kind: .port,
            // The port's OWN id, carried separately from the authz `id` (which is the creator for a
            // companion-made port). Owner resolution keys on this so event routing and teardown find
            // THIS port, not the creator's shared bucket (backlog 0.5).
            portId: messageId)
    }

    // MARK: - File Drop

    /// Handle files dropped onto the port window.
    /// Ports: triggers filesystem permission, then dispatches `port42:filedrop` to JS.
    @MainActor
    /// Dispatch dropped file paths to the port's JS as `port42:filedrop` (an array of path
    /// strings). Reading a file's contents still goes through `fs.read` (.filesystem permission).
    public func handleFileDrop(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        // A drop is user consent, same as a pick: grant the dropped paths to THIS port's principal
        // so the fs.read the JS is about to make actually succeeds. (Pre-close-out this grant was
        // never recorded anywhere — registerDroppedPath had no callers — so dropped paths were
        // announced to JS but unreadable.) Keyed on portPrincipal.id, the SAME identity the read
        // will dispatch as — a messageId-keyed grant is invisible to a companion-created port
        // since the creator resolution.
        if let state {
            let principalId = portPrincipal.id
            for path in paths { state.grantPickedPath(path, to: principalId) }
        }
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
        // Re-keyed to presentation visibility (backlog 1.1, decision 1): an off-desktop or galaxy-hidden
        // tile also stops billing the model, from the ONE computation shared with 0.3. This gates NEW
        // model calls only; in-flight streams are still cancelled solely on the park/background
        // transition (suspendAI), so glancing at the galaxy does not kill a running generation. Falls
        // back to the panel-mode keying when no shell is wired (headless / tests).
        if let shell = state.shell { return !shell.isVisible(panel) }
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

    /// Release every ongoing resource this port acquired (backlog 0.5): the device captures, streams,
    /// and browser sessions on the shared bridges (via AppState.releaseAcquisitions, keyed on this
    /// port's stable id), plus any in-flight generation (suspendAI). The ONE funnel the close path
    /// (PortWindowManager.close/stop) calls before tearing down the webview; the deinit backstop
    /// funnels to the same AppState entry point for the non-close death paths.
    @MainActor
    public func releaseAcquisitions() {
        if let state, let mid = messageId {
            state.releaseAcquisitions(portId: mid)
        }
        suspendAI()
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

    /// What to do with a handled call's result. ONE triage (pinned by PortCallDispositionTests) so
    /// the never-rejecting-bridge fix (1635d93) cannot silently regress: an {error: String}
    /// envelope REJECTS the JS promise — the caller's catch runs — everything else resolves, and a
    /// streaming handler's deferred marker means the stream settles the promise itself.
    enum CallDisposition {
        case deferred
        case reject(String)
        case resolve(Any)
    }

    static func disposition(for result: Any) -> CallDisposition {
        if let dict = result as? [String: Any] {
            if dict["__deferred__"] as? Bool == true { return .deferred }
            // Only the adapter's own {error: String} envelope rejects; a payload whose "error"
            // happens to hold data (non-string) is a success value the caller must receive.
            if let errMsg = dict["error"] as? String { return .reject(errMsg) }
        }
        return .resolve(result)
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "port42",
              let body = message.body as? [String: Any],
              let method = body["method"] as? String,
              let callId = body["callId"] as? Int else { return }

        let args = body["args"] as? [Any] ?? []

        Task { @MainActor in
            let result = await handleMethod(method, args: args, callId: callId)

            switch Self.disposition(for: result) {
            case .deferred:
                return
            case .reject(let errMsg):
                rejectCall(callId, errMsg)
            case .resolve(let value):
                // .fragmentsAllowed: registry methods can return a bare string/number (e.g.
                // crease.read's "No creases yet" text). Without it, a fragment top level makes
                // JSONSerialization raise an ObjC NSException that `try?` cannot catch; it unwinds
                // through the main-queue drain and permanently wedges the main queue (no dispatch
                // block or main-actor task runs again) while the run loop keeps pumping — the app
                // looks alive but every queued action is dead. Same option as the streaming
                // resolve path above.
                let jsonData = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
                let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                _ = try? await webView?.evaluateJavaScript("port42._resolve(\(callId), \(jsonString))")
            }
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
            let principal = portPrincipal
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
            let principal = portPrincipal
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

        // ai.cancel: the one machinery branch that outlives the old switch (the documented
        // transport shim). It cancels a stream by JS callId (streamTasks), which is
        // transport-coupled state on THIS bridge instance, not a service method.
        if method == "ai.cancel" {
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
        }

        // The old switch is GONE (the close-out): every other method is served registry-first
        // above. Nothing falls through.
        NSLog("[Port42] Unknown bridge method: %@", method)
        return ["error": "unknown method: \(method)"]
    }

    // postCapture (capture-to-disk + inline system message) left with the deleted screen/camera
    // cases — the registry image path returns `.data` directly. ToolExecutor still carries its own
    // copy on the old switch until the close-out.

    // ai.complete and companions.invoke moved to the streaming registry (item 8):
    // buildBridgeStreamRegistry, dispatched by the stream branch in handleMethod. The old
    // handleAIComplete / handleCompanionInvoke and their helpers (resolveDefaultModel,
    // cleanAlternation) are deleted; the message-building lives on AppState now.

    // MARK: - Event Pushing

    /// Push an event to the port's JS context
    @MainActor
    public func pushEvent(_ event: String, data: Any) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed]),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("port42._emit('\(event)', \(jsonString))") { _, _ in }
        // Phase L1: mirror the event on the port's Notify topic so subscribers see it too — this is the
        // browser attach point (browser.load/redirect/error push to the owner port), and also covers
        // filedrop / presentation. Cheap no-op when nobody subscribes.
        (appState as? AppState)?.notifyBus.publish(topic: "port:\(messageId)", kind: event, payload: data)
    }

    /// Send heartbeat to keep connection status alive
    @MainActor
    public func pushHeartbeat() {
        webView?.evaluateJavaScript("port42._heartbeat()") { _, _ in }
    }

    /// Push this port's CURRENT presentation once its webview finishes loading (backlog 1.1, Step 3):
    /// covers a port that only uses `on('presentation')` and would otherwise miss the state at birth.
    /// The getter `port42.presentation()` is the robust initial-read path; this is the belt-and-braces
    /// for on-only ports. No-ops for a port with no id or before the shell exists.
    @MainActor
    public func emitCurrentPresentation() {
        guard let mid = messageId, let snap = state?.shell?.presentation(forPortId: mid) else { return }
        pushEvent("presentation", data: snap.jsonObject)
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
                // The proxy target is a FUNCTION so a dotless method is callable directly:
                // port42.help() dispatches call('help'). Namespaced calls are unchanged.
                var f = function() { return call(namespace, Array.prototype.slice.call(arguments)); };
                if (carveouts) { for (var k in carveouts) { f[k] = carveouts[k]; } }
                return new Proxy(f, { get: function(t, m) {
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
                    // Presentation also fires a DOM CustomEvent, parity with port42:filedrop (backlog 1.1),
                    // so a port may listen via window.addEventListener('port42:presentation', ...) too.
                    if (event === 'presentation') {
                        try { window.dispatchEvent(new CustomEvent('port42:presentation', { detail: data })); } catch(e) {}
                    }
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
