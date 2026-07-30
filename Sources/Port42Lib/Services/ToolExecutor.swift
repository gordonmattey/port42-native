import Foundation
import AppKit
import WebKit

/// Executes tool calls from LLM companions against port42 bridge APIs.
/// One instance per conversation (space or swim space).
@MainActor
public final class ToolExecutor {
    private weak var appState: AppState?
    private let spaceId: String?
    /// The companion this executor acts for. NON-OPTIONAL since I1.5: an optional here is what made
    /// a shared `"anonymous-tool-caller"` identity expressible, and the one production construction
    /// site has always passed a real `AgentConfig.id`. A caller that cannot name its companion now
    /// fails to compile instead of pooling grants with every other unnamed caller.
    let createdBy: String
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

    init(appState: AppState, spaceId: String?, createdBy: String,
         createdByName: String? = nil, inChat: Bool = false) {
        self.appState = appState
        self.spaceId = spaceId
        self.createdBy = createdBy
        self.createdByName = createdByName
        self.inChat = inChat
        // Restore previously granted permissions so the user isn't re-prompted. The OBJECT is
        // port 0 (machine capabilities); spaceId nil = a zoneless caller (the gateway) → its global
        // grant, which never restored before.
        self.grantedPermissions = appState.grants(grantee: createdBy, on: .machine, zone: spaceId)
    }

    /// A single tool result over this many UTF-8 bytes is truncated before it reaches the model — a
    /// safety valve so one pathological result (a huge file cat, a giant API dump) can't blow the
    /// request's context. The FULL result still reaches ports and the gateway (uncapped); only this
    /// path, the in-app LLM tool-result, is bounded — it is the only caller that pays tokens per byte —
    /// and it is told in-band that truncation happened so it can narrow and retry. ~200KB ≈ ~50K tokens.
    static let maxToolResultBytes = 200_000

    /// Cap oversized text blocks for the model, in-band. Non-text blocks (images) and small blocks
    /// pass through untouched. Pure, so it is unit-testable without an AppState.
    nonisolated static func capForModel(_ blocks: [[String: Any]],
                                        max: Int = ToolExecutor.maxToolResultBytes) -> [[String: Any]] {
        blocks.map { block in
            guard (block["type"] as? String) == "text", let text = block["text"] as? String else { return block }
            let bytes = text.utf8.count
            guard bytes > max else { return block }
            let kept = String(decoding: Array(text.utf8.prefix(max)), as: UTF8.self)
            var out = block
            out["text"] = kept + "\n… (truncated: showing \(max) of \(bytes) bytes — narrow the command/query or fetch in ranges)"
            return out
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
            let principal = Principal.forCompanionTool(createdBy: createdBy,
                                                       createdByName: createdByName,
                                                       spaceId: spaceId)
            do {
                let value = try await appState.runBridgeMethod(canonical, principal: principal,
                                                               args: BridgeArgs(input), pregrant: grantedPermissions)
                return Self.capForModel(value.toToolBlocks())
            } catch let e as BridgeError {
                return e.toToolBlocks()
            } catch {
                return [["type": "text", "text": "Error: \(error.localizedDescription)"]]
            }
        }

        // Streaming registry (item 8): tool-use is one-shot, so collect-into-final — ignore tokens,
        // render the accumulated result as tool blocks.
        if let appState, appState.bridgeStreamHandles(canonical) {
            let principal = Principal.forCompanionTool(createdBy: createdBy,
                                                       createdByName: createdByName,
                                                       spaceId: spaceId)
            do {
                let value = try await appState.runBridgeStream(canonical, principal: principal,
                                                               args: BridgeArgs(input), pregrant: grantedPermissions,
                                                               yield: { _ in })
                return Self.capForModel(value.toToolBlocks())
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

        // THE BLANKET PRE-GRANT IS GONE (D12, GM 2026-07-28; deleted at A.3).
        //
        // Three UserDefaults flags used to union terminal, filesystem and screen into EVERY gateway
        // call, before the principal was constructed — the one thing in the system that could hand
        // out authority without naming anybody, and all three were ON in production. It made sense
        // only while callers were anonymous, when the choice was prompt-on-every-call or trust
        // everything, because there was nothing to attach a grant TO. Per-grantee grants are that
        // missing third thing, so the flags became redundant rather than merely unsafe.
        //
        // Every capability now goes through the permission request path, and what it costs is one
        // ask per capability per caller, once — cushioned by the manager, where a grant can now be
        // seen and withdrawn.
        let pregrant: Set<PortPermission> = []

        // Registry-first (Phase 2): the unified path serves every extracted method, identically for
        // JS / tool-use / gateway. Anything not yet extracted (the live-only families) falls through
        // to the old switch below, unchanged.
        if let appState, appState.bridgeHandles(canonical) {
            let principal = Principal.peer(id: senderId, displayName: senderName)
            #if DEBUG
            // The `local-http` counter is GONE with the bucket it measured (5b). It existed to size
            // how much traffic rode the shared principal before deciding what to do about it; the
            // answer was to delete it, so counting it is counting nothing. A gateway caller now
            // arrives verified and named, or does not arrive.
            ActorProbe.minted(id: principal.id, surface: "gateway", rung: "verified-client")
            #endif
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
            let principal = Principal.peer(id: senderId, displayName: senderName)
            #if DEBUG
            ActorProbe.minted(id: principal.id, surface: "gateway-stream", rung: "verified-client")
            #endif
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
        // Coded, like every other refusal. This is a dict rather than a throw because the caller is
        // tool use, whose transport is a result object — but a caller still has to be able to
        // branch on it, and this one answered with prose alone.
        return ["error": "unknown method: \(method)", "code": BridgeErrorCode.unknownMethod.wire]
    }
}
