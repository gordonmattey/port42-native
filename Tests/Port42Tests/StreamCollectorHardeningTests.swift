import Testing
import Foundation
@testable import Port42Lib

/// 2.7 hardening: a streaming call must never leak a pending JS promise on a SILENT engine death — a
/// backend that emits no terminal callback and does not throw. The collector is strongly retained by
/// the owner until settlement, so a `deinit` guard alone can't fire; the watchdog settles (and releases)
/// after its timeout. This asserts the call ERRORS rather than hangs.
@Suite("Stream collector hardening (2.7)")
struct StreamCollectorHardeningTests {

    /// A backend that never calls its delegate and never throws — the silent-death case.
    final class SilentBackend: LLMBackend, @unchecked Sendable {
        var trackingSource = ""
        func send(messages: [[String: Any]], systemPrompt: String, model: String, maxTokens: Int,
                  tools: [[String: Any]]?, thinkingEnabled: Bool, thinkingEffort: String,
                  delegate: LLMStreamDelegate) throws { /* emits nothing, ever */ }
        func continueWithToolResults(results: [(toolUseId: String, content: [[String: Any]])],
                                     messages: [[String: Any]], systemPrompt: String, model: String,
                                     maxTokens: Int, tools: [[String: Any]]?, thinkingEnabled: Bool,
                                     thinkingEffort: String) throws {}
        func cancel() {}
    }

    @Test("a silent backend settles the stream via the watchdog instead of hanging")
    func watchdogSettlesSilentStream() async throws {
        let backend = SilentBackend()
        var keepAlive: [LLMStreamCollector] = []          // retain → exercises the WATCHDOG (not deinit)
        var settledWithError = false
        do {
            _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<BridgeValue, Error>) in
                let c = LLMStreamCollector(yield: { _ in }, continuation: cont,
                                           engine: backend, onDone: { _ in }, timeout: 0.2)
                keepAlive.append(c)
                try? backend.send(messages: [], systemPrompt: "", model: "m", maxTokens: 1,
                                  tools: nil, thinkingEnabled: false, thinkingEffort: "low", delegate: c)
            }
        } catch {
            settledWithError = true                       // watchdog fired → error, not a permanent hang
        }
        #expect(settledWithError)
        _ = keepAlive
    }
}
