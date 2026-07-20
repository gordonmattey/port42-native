import Foundation
import AppKit
import WebKit

/// Executes tool calls from LLM companions against port42 bridge APIs.
/// One instance per conversation (space or swim space).
@MainActor
public final class ToolExecutor {
    private weak var appState: AppState?
    private let spaceId: String?
    let createdBy: String?
    /// Display name of the caller (for message attribution); nil for anonymous/remote callers.
    let createdByName: String?
    /// True when this executor runs an in-app companion composing a chat reply. Routes
    /// `port_create({type:"web"})` to an inline port; external/remote executors (inChat=false) open a
    /// desktop tile instead. See AppState.createPort.
    let inChat: Bool

    /// Granted permissions for this conversation (per-companion, per-space). Passed to the
    /// registry dispatch as a same-call pregrant.
    private var grantedPermissions: Set<PortPermission> = []

    /// Pre-grant a permission without prompting the user (tests, and "Always Allow" style callers).
    func pregrant(_ perm: PortPermission) {
        grantedPermissions.insert(perm)
    }

    init(appState: AppState, spaceId: String?, createdBy: String? = nil,
         createdByName: String? = nil, inChat: Bool = false) {
        self.appState = appState
        self.spaceId = spaceId
        self.createdBy = createdBy
        self.createdByName = createdByName
        self.inChat = inChat
        // Restore previously granted permissions so the user isn't re-prompted. spaceId nil = a
        // spaceless caller (the gateway) → its global grant, which never restored before.
        if let by = createdBy {
            self.grantedPermissions = appState.companionPermissions(createdBy: by, spaceId: spaceId)
        }
    }

    /// Execute a tool and return the result as content blocks for the Anthropic API.
    /// Returns an array of content blocks (text or image).
    func execute(name: String, input: [String: Any]) async -> [[String: Any]] {
        NSLog("[Port42] ToolExecutor: executing %@", name)

        // Registry-first (Phase 2): the in-app companion path dispatches extracted methods through the
        // one shared impl, then renders the BridgeValue as tool-use content blocks. Unextracted
        // (live-only) methods fall through to the old switch below. The dispatcher reads the persisted
        // grants fresh, so `grantedPermissions` is passed only as a same-call pregrant.
        let canonical = name.contains(".") ? name : (appState?.canonicalFromTool(name) ?? name)
        if let appState, appState.bridgeHandles(canonical) {
            let principal = Principal(id: createdBy ?? "anonymous-tool-caller",
                                      displayName: createdByName ?? createdBy ?? "a companion",
                                      spaceId: spaceId, kind: .companion)
            do {
                let value = try await appState.runBridgeMethod(canonical, principal: principal,
                                                               args: BridgeArgs(input), pregrant: grantedPermissions)
                return value.toToolBlocks()
            } catch let e as BridgeError {
                return e.toToolBlocks()
            } catch {
                return [["type": "text", "text": "Error: \(error.localizedDescription)"]]
            }
        }

        // Streaming registry (item 8): tool-use is one-shot, so collect-into-final — ignore tokens,
        // render the accumulated result as tool blocks.
        if let appState, appState.bridgeStreamHandles(canonical) {
            let principal = Principal(id: createdBy ?? "anonymous-tool-caller",
                                      displayName: createdByName ?? createdBy ?? "a companion",
                                      spaceId: spaceId, kind: .companion)
            do {
                let value = try await appState.runBridgeStream(canonical, principal: principal,
                                                               args: BridgeArgs(input), pregrant: grantedPermissions,
                                                               yield: { _ in })
                return value.toToolBlocks()
            } catch let e as BridgeError {
                return e.toToolBlocks()
            } catch {
                return [["type": "text", "text": "Error: \(error.localizedDescription)"]]
            }
        }

        // The old switch is GONE (the close-out): every tool is served registry-first above.
        // Nothing falls through.
        NSLog("[Port42] ToolExecutor: unknown tool %@", name)
        return [["type": "text", "text": "Unknown tool: \(name)"]]
    }
}

// MARK: - Remote Tool Executor

/// Specialized executor for remote RPC calls (CLIs, OpenClaw).
/// Includes "Always Allow" permission bypasses from global settings.
@MainActor
public final class RemoteToolExecutor: ObservableObject {
    private weak var appState: AppState?
    private let senderId: String
    private let senderName: String
    
    public init(appState: AppState, senderId: String, senderName: String) {
        self.appState = appState
        self.senderId = senderId
        self.senderName = senderName
    }

    public func execute(method: String, input: [String: Any]) async -> Any {
        // Resolve the incoming name to canonical: a dotted name IS canonical (`port.getHtml`,
        // `ports.list`); a snake tool name maps through ToolNaming. This is what makes both spellings
        // reach the same method and kills the `port.getHtml` → Unknown-tool class.
        let canonical = method.contains(".") ? method : (appState?.canonicalFromTool(method) ?? method)

        // "Always Allow" settings become pre-grants for the registry path (and the old path below).
        var pregrant: Set<PortPermission> = []
        for (key, perm): (String, PortPermission) in [("remoteAllowTerminal", .terminal),
                                                       ("remoteAllowFS", .filesystem),
                                                       ("remoteAllowScreen", .screen)] {
            if UserDefaults.standard.bool(forKey: key) { pregrant.insert(perm) }
        }

        // Registry-first (Phase 2): the unified path serves every extracted method, identically for
        // JS / tool-use / gateway. Anything not yet extracted (the live-only families) falls through
        // to the old switch below, unchanged.
        if let appState, appState.bridgeHandles(canonical) {
            let principal = Principal(id: senderId, displayName: senderName, spaceId: nil, kind: .peer)
            do {
                let value = try await appState.runBridgeMethod(canonical, principal: principal,
                                                               args: BridgeArgs(input), pregrant: pregrant)
                return value.toJSONObject()
            } catch let e as BridgeError {
                return e.toJSONObject()
            } catch {
                return ["error": error.localizedDescription]
            }
        }

        // Streaming registry (item 8): HTTP/RPC is one-shot, so collect-into-final — the tokens are
        // ignored and the accumulated result is returned. A failed call returns {error} in the body
        // (correct for a request/response transport; not the never-reject shim).
        if let appState, appState.bridgeStreamHandles(canonical) {
            let principal = Principal(id: senderId, displayName: senderName, spaceId: nil, kind: .peer)
            do {
                let value = try await appState.runBridgeStream(canonical, principal: principal,
                                                               args: BridgeArgs(input), pregrant: pregrant,
                                                               yield: { _ in })
                return value.toJSONObject()
            } catch let e as BridgeError {
                return e.toJSONObject()
            } catch {
                return ["error": error.localizedDescription]
            }
        }

        // The old switch is GONE (the close-out): nothing falls through.
        return ["error": "unknown method: \(method)"]
    }
}
