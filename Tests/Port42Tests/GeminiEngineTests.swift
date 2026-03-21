import Testing
import Foundation
@testable import Port42Lib

// MARK: - Helpers

/// Collects delegate callbacks from GeminiEngine.
private final class GeminiTestDelegate: LLMStreamDelegate, @unchecked Sendable {
    var tokens: [String] = []
    var finishedResponse: String?
    var toolCalls: [(id: String, name: String, input: [String: Any])]?
    var error: Error?

    func llmDidReceiveToken(_ token: String) { tokens.append(token) }
    func llmDidFinish(fullResponse: String) { finishedResponse = fullResponse }
    func llmDidRequestToolUse(calls: [(id: String, name: String, input: [String: Any])]) { toolCalls = calls }
    func llmDidError(_ error: Error) { self.error = error }
}

// SSE event helper — ensures proper \n\n termination
private func sseEvent(_ json: String) -> String { "data: \(json)\n\n" }

@Suite("GeminiEngine", .serialized)
struct GeminiEngineTests {

    // MARK: - Text Parsing

    @Test("Single text part produces token")
    func singleTextPart() {
        let engine = GeminiEngine()
        let delegate = GeminiTestDelegate()

        let sse = sseEvent(#"{"candidates":[{"content":{"parts":[{"text":"Hello world"}],"role":"model"}}]}"#)
        engine.injectSSEForTesting(sse, delegate: delegate)

        #expect(delegate.tokens == ["Hello world"])
        #expect(engine.fullResponse == "Hello world")
    }

    @Test("Multi-part text response accumulates")
    func multiPartText() {
        let engine = GeminiEngine()
        let delegate = GeminiTestDelegate()

        let sse = sseEvent(#"{"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"}}]}"#)
              + sseEvent(#"{"candidates":[{"content":{"parts":[{"text":" world"}],"role":"model"}}]}"#)
        engine.injectSSEForTesting(sse, delegate: delegate)

        #expect(delegate.tokens == ["Hello", " world"])
        #expect(engine.fullResponse == "Hello world")
    }

    // MARK: - Function Call Parsing

    @Test("Single function call is parsed")
    func singleFunctionCall() {
        let engine = GeminiEngine()
        let delegate = GeminiTestDelegate()

        let sse = sseEvent(#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"crease_write","args":{"content":"something reformed"}}}],"role":"model"}}]}"#)
        engine.injectSSEForTesting(sse, delegate: delegate)

        #expect(engine.lastFunctionCallParts.count == 1)
        let callPart = engine.lastFunctionCallParts[0]
        let fc = callPart["functionCall"] as? [String: Any]
        #expect(fc?["name"] as? String == "crease_write")
        let args = fc?["args"] as? [String: Any]
        #expect(args?["content"] as? String == "something reformed")
    }

    @Test("Multiple function calls in one response")
    func multipleFunctionCalls() {
        let engine = GeminiEngine()
        let delegate = GeminiTestDelegate()

        let sse = sseEvent(#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"crease_read","args":{}}},{"functionCall":{"name":"position_read","args":{}}}],"role":"model"}}]}"#)
        engine.injectSSEForTesting(sse, delegate: delegate)

        #expect(engine.lastFunctionCallParts.count == 2)
    }

    @Test("Mixed text and function call in same SSE event")
    func mixedChunk() {
        let engine = GeminiEngine()
        let delegate = GeminiTestDelegate()

        let sse = sseEvent(#"{"candidates":[{"content":{"parts":[{"text":"Let me check"},{"functionCall":{"name":"crease_read","args":{}}}],"role":"model"}}]}"#)
        engine.injectSSEForTesting(sse, delegate: delegate)

        #expect(delegate.tokens == ["Let me check"])
        #expect(engine.lastFunctionCallParts.count == 1)
    }

    // MARK: - continueWithToolResults message format

    @Test("continueWithToolResults builds functionResponse message format")
    func continueWithToolResultsFormat() throws {
        let store = Port42AuthStore()
        store.saveCredential("test-gemini-key", provider: "gemini")
        defer { store.deleteCredential(provider: "gemini") }

        let engine = GeminiEngine(store: store)
        let delegate = GeminiTestDelegate()

        // Simulate receiving a function call
        let sse = sseEvent(#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"crease_write","args":{"content":"test"}}}],"role":"model"}}]}"#)
        engine.injectSSEForTesting(sse, delegate: delegate)

        // lastFunctionCallParts should be populated and contain the function call
        #expect(engine.lastFunctionCallParts.count == 1)
        let callPart = engine.lastFunctionCallParts[0]
        let fc = callPart["functionCall"] as? [String: Any]
        #expect(fc?["name"] as? String == "crease_write")
    }

    @Test("Tool ID encodes tool name")
    func toolIdEncoding() {
        let engine = GeminiEngine()
        let delegate = GeminiTestDelegate()

        let sse = sseEvent(#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"crease_write","args":{"content":"x"}}}],"role":"model"}}]}"#)
        engine.injectSSEForTesting(sse, delegate: delegate)

        // ID should be "gemini-crease_write-0"
        let id = engine.toolIdForTesting(0)
        #expect(id == "gemini-crease_write-0")
    }

    // MARK: - Auth: no key → noAuth error

    @Test("No Gemini key throws noAuth")
    func noGeminiKeyThrows() {
        let store = Port42AuthStore()
        store.deleteCredential(provider: "gemini")

        let engine = GeminiEngine(store: store)
        let delegate = GeminiTestDelegate()

        var threw = false
        do {
            try engine.send(
                messages: [],
                systemPrompt: "",
                model: "gemini-2.0-flash",
                maxTokens: 1024,
                tools: nil,
                thinkingEnabled: false,
                thinkingEffort: "low",
                delegate: delegate
            )
        } catch LLMEngineError.noAuth {
            threw = true
        } catch {}
        #expect(threw)
    }

    // MARK: - Error Translation

    @Test("401 → authExpired error")
    func errorTranslation401() {
        let engine = GeminiEngine()
        let delegate = GeminiTestDelegate()

        engine.injectHTTPErrorForTesting(statusCode: 401, body: #"{"error":{"message":"API key invalid"}}"#, delegate: delegate)

        guard case .authExpired(let msg) = delegate.error as? LLMEngineError else {
            Issue.record("Expected authExpired, got \(String(describing: delegate.error))")
            return
        }
        #expect(msg.contains("401"))
    }

    @Test("429 → httpError rate limit")
    func errorTranslation429() {
        let engine = GeminiEngine()
        let delegate = GeminiTestDelegate()

        engine.injectHTTPErrorForTesting(statusCode: 429, body: #"{"error":{"message":"quota exceeded"}}"#, delegate: delegate)

        guard case .httpError(let code, _) = delegate.error as? LLMEngineError else {
            Issue.record("Expected httpError, got \(String(describing: delegate.error))")
            return
        }
        #expect(code == 429)
    }

    @Test("Malformed SSE body is gracefully ignored")
    func malformedSSE() {
        let engine = GeminiEngine()
        let delegate = GeminiTestDelegate()

        engine.injectSSEForTesting("data: not-valid-json\n\n", delegate: delegate)

        #expect(delegate.tokens.isEmpty)
        #expect(delegate.error == nil)
    }

    @Test("Empty candidates array is gracefully ignored")
    func emptyCandidates() {
        let engine = GeminiEngine()
        let delegate = GeminiTestDelegate()

        engine.injectSSEForTesting(sseEvent(#"{"candidates":[]}"#), delegate: delegate)

        #expect(delegate.tokens.isEmpty)
        #expect(delegate.error == nil)
    }

    @Test("Top-level error in SSE payload is reported")
    func topLevelError() {
        let engine = GeminiEngine()
        let delegate = GeminiTestDelegate()

        engine.injectSSEForTesting(sseEvent(#"{"error":{"message":"model not found"}}"#), delegate: delegate)

        guard case .streamingError(let msg) = delegate.error as? LLMEngineError else {
            Issue.record("Expected streamingError, got \(String(describing: delegate.error))")
            return
        }
        #expect(msg.contains("model not found"))
    }
}
