import Foundation

// MARK: - LLM Backend Protocol

/// Common interface for all LLM provider engines.
/// Each engine owns its own streaming parser, tool schema format, and auth.
/// ChannelAgentHandler talks only to this protocol — it doesn't know which provider is running.
public protocol LLMBackend: AnyObject {
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
