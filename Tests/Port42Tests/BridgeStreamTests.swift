import Testing
import Foundation
@testable import Port42Lib

// Item 8 (streaming contract), first test: prove the BridgeStreamMethod shape headlessly — a stream
// yields intermediate tokens via `yield`, then returns the final value. This is the contract every
// adapter renders (port JS → _tokenCallback, gateway → chunked, tool-use → collect); wiring real
// ai.complete + the per-surface delivery comes next, verified live.

@Suite("Bridge — streaming contract")
struct BridgeStreamTests {

    @Test("a stream method delivers exactly N tokens, then the final value")
    @MainActor
    func tokensThenFinal() async throws {
        let method = BridgeStreamMethod(permission: nil) { _, _, yield in
            for t in ["Hel", "lo ", "world"] { yield(t) }
            return .object(["text": .string("Hello world"), "done": .bool(true)])
        }
        var tokens: [String] = []
        let p = Principal(id: "port-1", displayName: "a port", spaceId: nil, kind: .port)
        let final = try await method.run(p, BridgeArgs([:])) { tokens.append($0) }
        #expect(tokens == ["Hel", "lo ", "world"])
        #expect(final == .object(["text": .string("Hello world"), "done": .bool(true)]))
    }

    @Test("a thrown BridgeError propagates (the never-reject fix: a real reject, not a resolved {error})")
    @MainActor
    func throwsPropagate() async throws {
        let method = BridgeStreamMethod(permission: .ai) { _, _, yield in
            yield("partial")
            throw BridgeError(code: "ai_error", message: "model refused")
        }
        var tokens: [String] = []
        let p = Principal(id: "port-1", displayName: "a port", spaceId: nil, kind: .port)
        await #expect(throws: BridgeError.self) {
            _ = try await method.run(p, BridgeArgs([:])) { tokens.append($0) }
        }
        // tokens yielded before the throw are still delivered (a partial stream, then the reject)
        #expect(tokens == ["partial"])
    }

    @Test("carries permission + paramNames like a one-shot method")
    @MainActor
    func metadata() {
        let m = BridgeStreamMethod(permission: .ai, paramNames: ["prompt", "options"]) { _, _, _ in .null }
        #expect(m.permission == .ai)
        #expect(m.paramNames == ["prompt", "options"])
    }

    // MARK: dispatcher (step 2)

    @Test("runBridgeStream gates (pregrant), streams tokens, returns final")
    @MainActor
    func dispatchStreams() async throws {
        let w = try makeParityWorld()
        w.state.bridgeStreamRegistry = [
            "ai.complete": BridgeStreamMethod(permission: .ai, paramNames: ["prompt"]) { _, args, yield in
                let prompt = (try? args.requireString("prompt")) ?? ""
                for t in prompt.split(separator: " ") { yield(String(t)) }
                return .object(["text": .string(prompt)])
            }
        ]
        var tokens: [String] = []
        let p = Principal(id: "port-1", displayName: "port", spaceId: w.space.id, kind: .port)
        let final = try await w.state.runBridgeStream(
            "ai.complete", principal: p, args: BridgeArgs(["prompt": "a b c"]), pregrant: [.ai]
        ) { tokens.append($0) }
        #expect(tokens == ["a", "b", "c"])
        #expect(final == .object(["text": .string("a b c")]))
        #expect(w.state.bridgeStreamHandles("ai.complete"))
    }

    @Test("runBridgeStream throws unknown_method for an unregistered name")
    @MainActor
    func dispatchUnknown() async throws {
        let w = try makeParityWorld()
        let p = Principal(id: "x", displayName: "x", spaceId: nil, kind: .peer)
        await #expect(throws: BridgeError.self) {
            _ = try await w.state.runBridgeStream("nope.stream", principal: p, args: BridgeArgs([:])) { _ in }
        }
    }

    // MARK: LLMStreamCollector (step 3 building block — delegate → yield + final)

    @Test("collector: delegate tokens become yields, finish resolves the final value")
    @MainActor
    func collectorFinish() async throws {
        var tokens: [String] = []
        let final: BridgeValue = try await withCheckedThrowingContinuation { cont in
            let c = LLMStreamCollector(yield: { tokens.append($0) }, continuation: cont)
            c.llmDidReceiveToken("Hel")
            c.llmDidReceiveToken("lo")
            c.llmDidFinish(fullResponse: "Hello")
        }
        #expect(tokens == ["Hel", "lo"])
        #expect(final == .object(["text": .string("Hello")]))
    }

    @Test("collector: an engine error becomes a thrown BridgeError")
    @MainActor
    func collectorError() async throws {
        struct EngineFail: Error { let localizedDescription = "model down" }
        await #expect(throws: BridgeError.self) {
            _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<BridgeValue, Error>) in
                let c = LLMStreamCollector(yield: { _ in }, continuation: cont)
                c.llmDidError(EngineFail())
            }
        }
    }

    // MARK: registered ai.complete (step 3b — the self-describing spike)

    @Test("registered ai.complete streams tokens and resolves the final text")
    @MainActor
    func aiCompleteStreams() async throws {
        let w = try makeParityWorld()
        w.state.streamBackendOverride = { _ in StubStreamBackend(tokens: ["Hel", "lo"], finalText: "Hello") }
        var toks: [String] = []
        let p = Principal(id: "port-x", displayName: "a port", spaceId: w.space.id, kind: .port)
        let final = try await w.state.runBridgeStream(
            "ai.complete", principal: p, args: BridgeArgs(["prompt": "hi"]), pregrant: [.ai]
        ) { toks.append($0) }
        #expect(toks == ["Hel", "lo"])
        #expect(final == .object(["text": .string("Hello")]))
    }

    @Test("registered ai.complete: an engine error rejects (real throw, not resolved {error})")
    @MainActor
    func aiCompleteErrors() async throws {
        struct Boom: Error {}
        let w = try makeParityWorld()
        w.state.streamBackendOverride = { _ in StubStreamBackend(tokens: ["x"], finalText: "", failure: Boom()) }
        let p = Principal(id: "port-x", displayName: "a port", spaceId: w.space.id, kind: .port)
        await #expect(throws: BridgeError.self) {
            _ = try await w.state.runBridgeStream(
                "ai.complete", principal: p, args: BridgeArgs(["prompt": "hi"]), pregrant: [.ai]) { _ in }
        }
    }

    @Test("registered ai.complete: collector is retained during the call, released after (0 -> 0)")
    @MainActor
    func aiCompleteRetention() async throws {
        let w = try makeParityWorld()
        w.state.streamBackendOverride = { _ in StubStreamBackend(tokens: ["a", "b"], finalText: "ab") }
        #expect(w.state.activeStreamCollectorCount == 0)
        let p = Principal(id: "port-x", displayName: "a port", spaceId: w.space.id, kind: .port)
        // The call completing at all proves the collector was retained (a weak-only delegate would
        // dealloc mid-flight and the continuation would never resume); count back to 0 proves release.
        _ = try await w.state.runBridgeStream(
            "ai.complete", principal: p, args: BridgeArgs(["prompt": "hi"]), pregrant: [.ai]) { _ in }
        #expect(w.state.activeStreamCollectorCount == 0)
    }

    @Test("registered ai.complete: a suspended (paused) port is refused before reaching the model")
    @MainActor
    func aiCompleteSuspendGuard() async throws {
        let w = try makeParityWorld()
        let bridge = PortBridge(appState: w.state, spaceId: w.space.id,
                                messageId: "port-susp", createdBy: w.companion.id)
        bridge.aiPaused = true
        w.state.registerPortBridge(bridge)   // findInlineBridge resolves it by messageId
        // If the guard were skipped the stub would resolve; instead the call must throw first.
        var reached = false
        w.state.streamBackendOverride = { _ in reached = true; return StubStreamBackend(tokens: [], finalText: "") }
        let p = Principal(id: "port-susp", displayName: "a port", spaceId: w.space.id, kind: .port)
        await #expect(throws: BridgeError.self) {
            _ = try await w.state.runBridgeStream(
                "ai.complete", principal: p, args: BridgeArgs(["prompt": "hi"]), pregrant: [.ai]) { _ in }
        }
        #expect(reached == false)
        _ = bridge   // keep the bridge alive past the weak registration
    }

    @Test("generator: ai.complete's inline metadata produces its Anthropic tool schema")
    @MainActor
    func aiCompleteGeneratedSchema() throws {
        let w = try makeParityWorld()
        let method = try #require(w.state.bridgeStreamRegistry["ai.complete"])
        let schema = anthropicToolSchema(canonical: "ai.complete", method: method)
        #expect(schema["name"] as? String == "ai_complete")
        #expect((schema["description"] as? String)?.isEmpty == false)
        let input = schema["input_schema"] as? [String: Any]
        let props = input?["properties"] as? [String: Any]
        #expect(props?["prompt"] != nil)
        #expect(props?["options"] != nil)
        #expect(input?["required"] as? [String] == ["prompt"])
    }
}

// A hermetic LLM backend for streaming tests: yields the given tokens then finishes (or errors),
// synchronously through the delegate. No network.
final class StubStreamBackend: LLMBackend {
    var trackingSource = ""
    private let tokens: [String]
    private let finalText: String
    private let failure: Error?

    init(tokens: [String], finalText: String, failure: Error? = nil) {
        self.tokens = tokens
        self.finalText = finalText
        self.failure = failure
    }

    func send(messages: [[String: Any]], systemPrompt: String, model: String, maxTokens: Int,
              tools: [[String: Any]]?, thinkingEnabled: Bool, thinkingEffort: String,
              delegate: LLMStreamDelegate) throws {
        for t in tokens { delegate.llmDidReceiveToken(t) }
        if let failure { delegate.llmDidError(failure) } else { delegate.llmDidFinish(fullResponse: finalText) }
    }

    func continueWithToolResults(results: [(toolUseId: String, content: [[String: Any]])],
                                 messages: [[String: Any]], systemPrompt: String, model: String,
                                 maxTokens: Int, tools: [[String: Any]]?, thinkingEnabled: Bool,
                                 thinkingEffort: String) throws {}

    func cancel() {}
}
