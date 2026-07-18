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
}
