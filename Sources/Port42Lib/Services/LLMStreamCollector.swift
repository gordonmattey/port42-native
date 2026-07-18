import Foundation

// MARK: - LLMStreamCollector (item 8, step 3 building block)
//
// Bridges the delegate-based LLM engine (`LLMStreamDelegate`: token / finish / error callbacks) to the
// `BridgeStreamMethod` shape (yield tokens via a closure, return a final `BridgeValue`, throw on error).
// `PortAIHandler` does the same but pushes into a specific `PortBridge`'s JS shim; this pushes into the
// unified `yield` + a continuation, so `ai.complete` can live in the registry and stream to ANY surface.
//
// Usage:
//   return try await withCheckedThrowingContinuation { cont in
//       let collector = LLMStreamCollector(yield: yield, continuation: cont)
//       try engine.send(..., delegate: collector)   // hold `collector` alive until finish/error
//   }
public final class LLMStreamCollector: NSObject, LLMStreamDelegate {
    private let yield: @MainActor (String) -> Void
    private var continuation: CheckedContinuation<BridgeValue, Error>?

    public init(yield: @escaping @MainActor (String) -> Void,
                continuation: CheckedContinuation<BridgeValue, Error>) {
        self.yield = yield
        self.continuation = continuation
        super.init()
    }

    /// Resume the continuation exactly once (a late finish racing an error is a no-op).
    @MainActor private func finish(_ result: Result<BridgeValue, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        switch result {
        case .success(let v): cont.resume(returning: v)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    // MARK: - LLMStreamDelegate

    nonisolated public func llmDidReceiveToken(_ token: String) {
        Task { @MainActor in self.yield(token) }
    }

    nonisolated public func llmDidFinish(fullResponse: String) {
        Task { @MainActor in self.finish(.success(.object(["text": .string(fullResponse)]))) }
    }

    nonisolated public func llmDidError(_ error: Error) {
        Task { @MainActor in
            let bridgeErr = (error as? BridgeError) ?? BridgeError(code: "ai_error", message: error.localizedDescription)
            self.finish(.failure(bridgeErr))
        }
    }
}
