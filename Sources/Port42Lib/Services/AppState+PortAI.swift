import Foundation

// MARK: - Port AI resolution (item 8: registry-owned, off PortBridge)
//
// `ai.complete` used to resolve its backend / model / token budget from methods that lived on a
// specific `PortBridge` instance (they read `self.createdBy`). The streaming registry entry has no
// PortBridge, so the resolution moves here, parameterized on the caller's `createdBy` (the creating
// companion id, when there is one). PortBridge's own helpers now delegate to these, so the port path
// and the registry path resolve identically.

@MainActor
public extension AppState {

    /// Default max tokens for port AI calls (`ai.complete` and port generation).
    var portAIMaxTokens: Int { 16384 }

    /// Resolve the LLM backend for an `ai.complete` call. Prefers the designated Port AI companion
    /// (`portAICompanionId`), then the caller's creating companion, then a bare `LLMEngine`.
    func resolvePortAIBackend(createdBy: String?) -> LLMBackend {
        let savedId = UserDefaults.standard.string(forKey: "portAICompanionId") ?? ""
        if !savedId.isEmpty,
           let companion = companions.first(where: { $0.id == savedId }) {
            return makeLLMBackend(for: companion)
        }
        if let createdBy,
           let companion = companions.first(where: { $0.id == createdBy }) {
            return makeLLMBackend(for: companion)
        }
        return LLMEngine()
    }

    /// Resolve the default model for an `ai.complete` call. Same precedence as the backend: designated
    /// Port AI companion's model, then the caller's creating companion, then the system default.
    func resolvePortAIModel(createdBy: String?) -> String {
        let savedId = UserDefaults.standard.string(forKey: "portAICompanionId") ?? ""
        if !savedId.isEmpty,
           let companion = companions.first(where: { $0.id == savedId }),
           let model = companion.model {
            return model
        }
        if let createdBy,
           let companion = companions.first(where: { $0.id == createdBy }),
           let model = companion.model {
            return model
        }
        return "claude-sonnet-4-6"
    }

    // MARK: - Streaming (ai.complete) support

    /// Test seam: when set, `resolveStreamBackend` returns this instead of a real engine, so streaming
    /// tests run hermetically (no network). Nil in production.
    var streamBackendOverride: ((String?) -> LLMBackend)? {
        get { _streamBackendOverride }
        set { _streamBackendOverride = newValue }
    }

    /// Backend for a streaming `ai.complete` call, honoring the test override.
    func resolveStreamBackend(createdBy: String?) -> LLMBackend {
        _streamBackendOverride?(createdBy) ?? resolvePortAIBackend(createdBy: createdBy)
    }

    /// The port bridge behind a `.port` principal, for the suspend guard and `createdBy` resolution.
    /// nil for non-port principals (gateway / companion callers are never suspendable).
    func streamPortBridge(for principal: Principal) -> PortBridge? {
        guard principal.kind == .port else { return nil }
        // The port's OWN id, not the authz id (a companion-created port authorizes as its creator, so
        // principal.id would miss the specific port — same fix as owningPortBridge, backlog 0.5).
        let key = principal.portId ?? principal.id
        if let inline = findInlineBridge(by: key) { return inline }
        return portWindows.panels.first(where: { $0.messageId == key })?.bridge
    }

    /// The creating-companion id used to resolve backend/model, per principal kind: a port's is its
    /// bridge's `createdBy`; a companion's IS its own id; a gateway peer has none.
    func createdBy(for principal: Principal, bridge: PortBridge?) -> String? {
        switch principal.kind {
        case .port: return bridge?.createdBy
        case .companion: return principal.id
        // Neither a gateway caller nor the human IS a companion, so neither resolves a
        // creating-companion: they fall back to the app default like any uncredited caller.
        case .peer, .human: return nil
        }
    }

    /// Retain a live stream collector for the call's lifetime (see `LLMStreamCollector`: the engine's
    /// delegate is weak, so nothing else keeps it alive between `send` and finish).
    func retainStreamCollector(_ c: LLMStreamCollector) {
        _activeStreamCollectors.append(c)
    }

    /// Drop retention once the collector has finished or errored (idempotent).
    func releaseStreamCollector(_ c: LLMStreamCollector) {
        _activeStreamCollectors.removeAll { $0 === c }
    }

    /// In-flight collector count (for tests: 0 -> 1 -> 0 across a call).
    var activeStreamCollectorCount: Int { _activeStreamCollectors.count }

    /// The streaming core shared by every registry stream method (ai.complete, companions.invoke):
    /// send `messages` to `backend`, stream tokens via `yield`, return the final `{text: ...}`.
    /// Settlement is core-owned — cancel settles the continuation directly (see the cancel-hang RCA),
    /// not via an engine callback. Retains the collector for the call's lifetime (delegate is weak).
    func runLLMStream(backend: LLMBackend, messages: [[String: Any]], systemPrompt: String,
                      model: String, maxTokens: Int,
                      yield: @escaping @MainActor (String) -> Void) async throws -> BridgeValue {
        var collector: LLMStreamCollector?
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<BridgeValue, Error>) in
                let c = LLMStreamCollector(
                    yield: yield, continuation: cont, engine: backend,
                    onDone: { [weak self] done in self?.releaseStreamCollector(done) })
                collector = c
                self.retainStreamCollector(c)
                do {
                    try backend.send(messages: messages, systemPrompt: systemPrompt, model: model,
                                     maxTokens: maxTokens, tools: nil, thinkingEnabled: false,
                                     thinkingEffort: "low", delegate: c)
                } catch {
                    self.releaseStreamCollector(c)
                    cont.resume(throwing: (error as? BridgeError)
                        ?? BridgeError(code: "ai_error", message: error.localizedDescription))
                }
            }
        } onCancel: {
            Task { @MainActor in
                backend.cancel()
                collector?.cancelIfPending()
            }
        }
    }

    // MARK: - companions.invoke support (moved off PortBridge for the streaming registry)

    /// Identity + space-context system prompt for a port-invoked companion.
    func companionInvokeSystemPrompt(companion: AgentConfig, spaceId: String?) -> String {
        let userName = currentUser?.displayName ?? "someone"
        let contextDescription: String
        if let ch = currentSpace, ch.type == "direct", let c = spaceCompanions.first {
            contextDescription = "You are in a private 1:1 space (DM) with \(userName) and \(c.displayName)."
        } else if let cid = spaceId, let ch = spaces.first(where: { $0.id == cid }) {
            contextDescription = "You are in the #\(ch.name) space."
        } else if let ch = currentSpace {
            contextDescription = "You are in the #\(ch.name) space."
        } else {
            contextDescription = "You are in a Port42 conversation."
        }
        let basePrompt = companion.systemPrompt ?? "You are a helpful companion."
        return """
            IDENTITY: You are \(companion.displayName).

            CONTEXT: You are an AI companion in Port42. \(contextDescription) \
            The user is \(userName). You were invoked by a port (an interactive UI surface) to provide analysis or answers. \
            Your response goes back to the port, not to the chat. Be helpful and concise.

            INSTRUCTIONS: \(basePrompt)
            """
    }

    /// Recent space conversation (last 20) plus the port's prompt, alternated user/assistant.
    func companionInvokeMessages(companion: AgentConfig, prompt: String) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for msg in self.messages.suffix(20) {
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
        if !prompt.isEmpty {
            messages.append(["role": "user", "content": prompt])
        }
        return cleanAlternation(messages)
    }

    /// Ensure messages alternate user/assistant and start with user; merge consecutive same-role.
    private func cleanAlternation(_ messages: [[String: Any]]) -> [[String: Any]] {
        guard !messages.isEmpty else { return [] }
        var result: [[String: Any]] = []
        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            if let last = result.last, last["role"] as? String == role {
                let merged = (last["content"] as? String ?? "") + "\n" + (msg["content"] as? String ?? "")
                result[result.count - 1] = ["role": role, "content": merged]
            } else {
                result.append(msg)
            }
        }
        // Must start with user.
        if result.first?["role"] as? String == "assistant" {
            result.insert(["role": "user", "content": "(context)"], at: 0)
        }
        return result
    }
}
