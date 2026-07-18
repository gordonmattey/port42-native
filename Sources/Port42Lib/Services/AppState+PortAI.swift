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
        if let inline = findInlineBridge(by: principal.id) { return inline }
        return portWindows.panels.first(where: { $0.messageId == principal.id })?.bridge
    }

    /// The creating-companion id used to resolve backend/model, per principal kind: a port's is its
    /// bridge's `createdBy`; a companion's IS its own id; a gateway peer has none.
    func createdBy(for principal: Principal, bridge: PortBridge?) -> String? {
        switch principal.kind {
        case .port: return bridge?.createdBy
        case .companion: return principal.id
        case .peer: return nil
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
}
