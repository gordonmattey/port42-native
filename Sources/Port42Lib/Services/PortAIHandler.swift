import Foundation

// MARK: - Port AI Handler

/// Bridges a single LLM stream to a port's JS context via PortBridge.
/// Each ai.complete or companions.invoke call creates its own handler + engine.
@MainActor
public final class PortAIHandler: NSObject, LLMStreamDelegate {

    public let callId: Int
    public let engine: LLMBackend
    private weak var bridge: PortBridge?

    public init(callId: Int, bridge: PortBridge, engine: LLMBackend = LLMEngine()) {
        self.callId = callId
        self.bridge = bridge
        self.engine = engine
        super.init()
    }

    // MARK: - LLMStreamDelegate

    nonisolated public func llmDidReceiveToken(_ token: String) {
        Task { @MainActor in
            self.bridge?.pushToken(self.callId, token)
        }
    }

    nonisolated public func llmDidFinish(fullResponse: String) {
        Task { @MainActor in
            self.bridge?.resolveCall(self.callId, fullResponse)
            self.bridge?.removeStream(self.callId)
        }
    }

    nonisolated public func llmDidError(_ error: Error) {
        Task { @MainActor in
            self.bridge?.rejectCall(self.callId, error.localizedDescription)
            self.bridge?.removeStream(self.callId)
        }
    }
}
