import Foundation

// MARK: - AI service (the reference plug-in service)
//
// The first service extracted as its own module, and the template for the rest (Keeper, storage, and
// eventually external MCP servers). See `docs/bridge-architecture-and-mcp.md` §6.
//
// The registry has two kinds of tenant: platform/device built-ins, and SERVICES that own state and a
// domain contract and could just as well run outside the app. `ai` is the clearest service — its
// backend is genuinely external (Anthropic / Gemini) — so it exercises every facet of the pattern at
// once and is where we nail the shape:
//
//   - a streaming method   → `ai.complete`  (BridgeStreamMethod, registered into the stream registry)
//   - plain reads          → `ai.models`, `ai.status`  (BridgeMethod, one-shot registry)
//   - an external backend   → `resolveStreamBackend` / `makeLLMBackend` (the provider abstraction; the
//                            part Keeper and storage each supply their own version of)
//   - a transport shim it EXCLUDES → `ai.cancel` stays at the port-JS adapter, because it cancels a
//                            stream by JS `callId` (`streamTasks`), which is transport-coupled, not a
//                            service method. A documented carve-out, same class as `port.resize`.
//
// A service is just a module that registers its namespace's methods (one-shot and/or streaming) into
// the one registry, each self-describing and gated, owning its backend dependency. No `BridgeService`
// protocol yet: the convention (one register-module per service) is formalized only once a second
// service (Keeper) confirms it earns the abstraction.
//
// `companions.invoke` is also an agent-runtime faculty, but it lives in the `companions` namespace
// (platform roster + one runtime verb), so it stays with the comms methods rather than moving here.

// MARK: One-shot methods (ai.models, ai.status)

@MainActor
func registerAIService(into r: inout BridgeRegistry, appState: AppState) {

    r["ai.models"] = BridgeMethod(
        permission: nil,
        toolExposed: false,
        description: "List the available models for the current Port AI provider, each with id, name, and tier.",
        inputSchema: ["type": "object", "properties": [String: Any]()]
    ) { _, _ in
        // Models follow the provider of the designated Port AI companion (else the Anthropic default).
        let provider: AgentProvider? = {
            let savedId = UserDefaults.standard.string(forKey: "portAICompanionId") ?? ""
            if !savedId.isEmpty, let c = appState.companions.first(where: { $0.id == savedId }) {
                return c.provider
            }
            return nil
        }()
        let models: [(id: String, name: String, tier: String)]
        switch provider {
        case .gemini:
            models = [
                ("gemini-2.5-pro", "Gemini 2.5 Pro", "flagship"),
                ("gemini-2.5-flash", "Gemini 2.5 Flash", "balanced"),
                ("gemini-2.0-flash", "Gemini 2.0 Flash", "fast"),
            ]
        default:
            models = [
                ("claude-opus-4-6", "Opus 4.6", "flagship"),
                ("claude-sonnet-4-6", "Sonnet 4.6", "balanced"),
                ("claude-haiku-4-5-20251001", "Haiku 4.5", "fast"),
            ]
        }
        return .array(models.map { .object(["id": .string($0.id), "name": .string($0.name), "tier": .string($0.tier)]) })
    }

    r["ai.status"] = BridgeMethod(
        permission: nil,
        toolExposed: false,
        description: "Whether AI calls are currently paused (the token-burn guard).",
        inputSchema: ["type": "object", "properties": [String: Any]()]
    ) { _, _ in
        .object(["paused": .bool(LLMEngine.paused)])
    }
}

// MARK: Streaming method (ai.complete)

@MainActor
func registerAIServiceStream(into r: inout BridgeStreamRegistry, appState: AppState) {

    r["ai.complete"] = BridgeStreamMethod(
        permission: .ai,
        paramNames: ["prompt", "options"],
        toolExposed: false,
        description: "Complete a prompt with an LLM, streaming tokens back. Returns the full text.",
        inputSchema: [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "The prompt to complete."] as [String: Any],
                "options": [
                    "type": "object",
                    "description": "Optional: model, systemPrompt, maxTokens, images (base64 PNG).",
                    "properties": [
                        "model": ["type": "string"] as [String: Any],
                        "systemPrompt": ["type": "string"] as [String: Any],
                        "maxTokens": ["type": "integer"] as [String: Any],
                        "images": ["type": "array", "items": ["type": "string"] as [String: Any]] as [String: Any]
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any],
            "required": ["prompt"]
        ]
    ) { principal, args, yield in
        // A parked/backgrounded/paused port must not reach the model (the token-burn guard). Only a
        // port principal maps to a suspendable surface; gateway/companion callers are never suspended.
        let bridge = appState.streamPortBridge(for: principal)
        if let bridge, bridge.isSuspended {
            throw BridgeError(code: "port_paused",
                              message: "port is paused (parked or backgrounded). Bring it to the desktop to use AI.")
        }

        let prompt = try args.requireString("prompt")
        guard !prompt.isEmpty else {
            throw BridgeError(code: "bad_args", message: "ai.complete requires a prompt")
        }
        let opts = args.object("options")
        let createdBy = appState.createdBy(for: principal, bridge: bridge)
        let model = opts?["model"] as? String ?? appState.resolvePortAIModel(createdBy: createdBy)
        let systemPrompt = opts?["systemPrompt"] as? String ?? "You are a helpful assistant."
        let maxTokens = opts?["maxTokens"] as? Int ?? appState.portAIMaxTokens
        let images = opts?["images"] as? [String]

        let backend = appState.resolveStreamBackend(createdBy: createdBy)
        backend.trackingSource = "port:\(principal.displayName)"

        // Build the user message (multimodal if images provided).
        let content: Any
        if let images, !images.isEmpty {
            var blocks: [[String: Any]] = images.map { base64 in
                ["type": "image",
                 "source": ["type": "base64", "media_type": "image/png", "data": base64] as [String: String]]
            }
            blocks.append(["type": "text", "text": prompt])
            content = blocks
        } else {
            content = prompt
        }
        let messages: [[String: Any]] = [["role": "user", "content": content]]

        return try await appState.runLLMStream(
            backend: backend, messages: messages, systemPrompt: systemPrompt,
            model: model, maxTokens: maxTokens, yield: yield)
    }
}
