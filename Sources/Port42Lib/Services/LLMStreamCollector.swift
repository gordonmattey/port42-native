import Foundation

// MARK: - LLMStreamCollector (item 8, step 3 building block)
//
// Bridges the delegate-based LLM engine (`LLMStreamDelegate`: token / finish / error callbacks) to the
// `BridgeStreamMethod` shape (yield tokens via a closure, return a final `BridgeValue`, throw on error).
// It pushes into the unified `yield` + a continuation, so ai.complete / companions.invoke live in the
// registry and stream to ANY surface (port JS, gateway, tool-use) instead of a per-surface handler.
//
// Usage:
//   return try await withCheckedThrowingContinuation { cont in
//       let collector = LLMStreamCollector(yield: yield, continuation: cont)
//       try engine.send(..., delegate: collector)   // hold `collector` alive until finish/error
//   }
public final class LLMStreamCollector: NSObject, LLMStreamDelegate {
    private let yield: @MainActor (String) -> Void
    private var continuation: CheckedContinuation<BridgeValue, Error>?
    /// Strong ref to the engine so it outlives the local scope of the registry body: `LLMEngine.delegate`
    /// is weak, so without holding both the collector AND its engine alive, the stream would dealloc
    /// mid-flight and no callback would ever fire. The owner (AppState) retains the collector; the
    /// collector retains the engine.
    private let engine: LLMBackend
    /// Called once, on finish or error, so the owner can drop its retention. Passes `self` so the
    /// closure does not have to capture (and cycle with) the collector.
    private let onDone: ((LLMStreamCollector) -> Void)?

    /// Last-resort safety net (2.7 hardening): if no terminal callback and no cancel ever arrives, the
    /// collector would sit in the owner's strong `_activeStreamCollectors` forever (so a `deinit` guard
    /// alone never fires) and the awaiting JS promise would hang. This watchdog settles the call as an
    /// error after `timeout`, which also drops the retention. Cancelled on a normal finish.
    private var watchdog: Task<Void, Never>?

    public init(yield: @escaping @MainActor (String) -> Void,
                continuation: CheckedContinuation<BridgeValue, Error>,
                engine: LLMBackend = LLMEngine(),
                onDone: ((LLMStreamCollector) -> Void)? = nil,
                timeout: TimeInterval = 300) {
        self.yield = yield
        self.continuation = continuation
        self.engine = engine
        self.onDone = onDone
        super.init()
        if timeout > 0 {
            watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(BridgeError(code: "ai_timeout",
                    message: "stream settled by watchdog: no terminal response within \(Int(timeout))s")))
            }
        }
    }

    /// Resume the continuation exactly once (a late finish racing an error is a no-op), then release.
    @MainActor private func finish(_ result: Result<BridgeValue, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        watchdog?.cancel(); watchdog = nil
        switch result {
        case .success(let v): cont.resume(returning: v)
        case .failure(let e): cont.resume(throwing: e)
        }
        onDone?(self)
    }

    deinit {
        watchdog?.cancel()
        // Cheap net for the case the collector IS deallocated while still pending (no owner retain):
        // settle so the awaiting call can never hang. resume() is safe to call from any thread.
        if let cont = continuation {
            continuation = nil
            cont.resume(throwing: CancellationError())
        }
    }

    /// Settle the call as cancelled if it has not already settled. The core calls this from a stream's
    /// cancellation handler so cancellation does not depend on the engine emitting a terminal callback
    /// (the real `LLMEngine` swallows `NSURLErrorCancelled`). Idempotent: a later engine callback no-ops.
    @MainActor public func cancelIfPending() {
        finish(.failure(CancellationError()))
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
