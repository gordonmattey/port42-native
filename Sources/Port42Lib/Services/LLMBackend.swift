import Foundation

// MARK: - LLM Backend Protocol

/// Common interface for all LLM provider engines.
/// Each engine owns its own streaming parser, tool schema format, and auth.
/// SpaceAgentHandler talks only to this protocol — it doesn't know which provider is running.
public protocol LLMBackend: AnyObject {
    /// Label for token tracking (e.g. companion name, "router", "port:MyPort")
    var trackingSource: String { get set }

    func send(
        messages: [[String: Any]],
        systemPrompt: String,
        model: String,
        maxTokens: Int,
        tools: [[String: Any]]?,
        thinkingEnabled: Bool,
        thinkingEffort: String,
        delegate: LLMStreamDelegate
    ) throws

    func continueWithToolResults(
        results: [(toolUseId: String, content: [[String: Any]])],
        messages: [[String: Any]],
        systemPrompt: String,
        model: String,
        maxTokens: Int,
        tools: [[String: Any]]?,
        thinkingEnabled: Bool,
        thinkingEffort: String
    ) throws

    /// Stop the in-flight request. A backend need NOT emit a terminal delegate event in response to
    /// cancel (the real `LLMEngine` swallows `NSURLErrorCancelled` and emits nothing) — cancellation
    /// settlement is owned by the core (`runBridgeStream`'s cancel handler settles the continuation),
    /// not by the plug. cancel() is "stop the network", not "please settle my continuation".
    func cancel()
}

// MARK: - Factory

/// Create the right backend for a given companion config.
public func makeLLMBackend(for agent: AgentConfig) -> LLMBackend {
    switch agent.provider {
    case .gemini:
        return GeminiEngine()
    case .compatibleEndpoint:
        // Phase 2: CompatibleEngine (OpenAI protocol). Falls back to Anthropic for now.
        return LLMEngine()
    case .anthropic, nil:
        return LLMEngine()
    }
}
