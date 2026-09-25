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
        let p = Principal.port(id: "port-1", displayName: "a port", spaceId: nil)
        let final = try await method.run(p, BridgeArgs([:])) { tokens.append($0) }
        #expect(tokens == ["Hel", "lo ", "world"])
        #expect(final == .object(["text": .string("Hello world"), "done": .bool(true)]))
    }

    @Test("a thrown BridgeError propagates (the never-reject fix: a real reject, not a resolved {error})")
    @MainActor
    func throwsPropagate() async throws {
        let method = BridgeStreamMethod(permission: .ai) { _, _, yield in
            yield("partial")
            throw BridgeError(code: .aiError, message: "model refused")
        }
        var tokens: [String] = []
        let p = Principal.port(id: "port-1", displayName: "a port", spaceId: nil)
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


    @Test("runBridgeStream throws unknown_method for an unregistered name")
    @MainActor
    func dispatchUnknown() async throws {
        let w = try makeParityWorld()
        let p = Principal.peer(id: "x", displayName: "x")
        await #expect(throws: BridgeError.self) {
            _ = try await w.state.runBridgeStream("nope.stream", principal: p, args: BridgeArgs([:])) { _ in }
        }
    }

    // MARK: LLMStreamCollector (step 3 building block — delegate → yield + final)



    // MARK: registered ai.complete (step 3b — the self-describing spike)








    // MARK: companions.invoke (folded into the streaming registry)


}
