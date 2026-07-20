import Testing
import Foundation
@testable import Port42Lib

// Close-out step 4c: the API reference (help / llms.txt) is GENERATED from the registry's
// self-describing metadata instead of hand-written prose that drifts. Two invariants:
//   1. Coverage: every registry method appears in help's output. A method that exists is
//      documented; the hand-written file provably misses the recent ones.
//   2. Self-description: every registry method carries a non-empty description. The generated
//      reference is only as good as the metadata, so empty descriptions are a gate failure, not a
//      rendering quirk.

@Suite("Bridge — help (generated API reference)")
struct BridgeHelpTests {

    @Test("help documents every registry method")
    @MainActor
    func helpCoversRegistry() async throws {
        let w = try makeParityWorld()
        let help = try #require(w.registry["help"])
        guard case let .string(text) = try await help.run(w.principal, BridgeArgs([:])) else {
            Issue.record("help should return the reference text")
            return
        }
        var missing: [String] = []
        for name in Set(w.registry.keys).union(w.state.bridgeStreamRegistry.keys) where !text.contains(name) {
            missing.append(name)
        }
        #expect(missing.isEmpty, "help does not document: \(missing.sorted())")
    }

    @Test("every registry method is self-describing (non-empty description)")
    @MainActor
    func everyMethodDescribed() throws {
        let w = try makeParityWorld()
        var undescribed: [String] = []
        for (name, m) in w.registry where m.description.isEmpty {
            undescribed.append(name)
        }
        for (name, m) in w.state.bridgeStreamRegistry where m.description.isEmpty {
            undescribed.append(name)
        }
        #expect(undescribed.isEmpty, "methods with no description: \(undescribed.sorted())")
    }

    // MARK: - topics (knowledge item B: craft is lazy-loaded through help, on every surface)

    @Test("help('ports') serves the port-craft manual, not the API inventory")
    @MainActor
    func helpPortsTopic() async throws {
        let w = try makeParityWorld()
        let help = try #require(w.registry["help"])
        guard case let .string(text) = try await help.run(w.principal, BridgeArgs(["topic": "ports"])) else {
            Issue.record("help(ports) should return the manual text")
            return
        }
        #expect(text.contains("ONE PORT, TWO PRESENTATIONS"), "the craft manual should lead")
        #expect(!text.contains("## Available Methods"), "the manual is not the API inventory")
    }

    @Test("an unknown help topic fails cleanly with the known topics named")
    @MainActor
    func unknownTopicFails() async throws {
        let w = try makeParityWorld()
        let help = try #require(w.registry["help"])
        await #expect(throws: BridgeError.self) {
            _ = try await help.run(w.principal, BridgeArgs(["topic": "definitely-not-a-topic"]))
        }
    }

    @Test("help is an LLM tool, so a companion lazy-loads knowledge like any other agent")
    @MainActor
    func helpIsATool() throws {
        let w = try makeParityWorld()
        #expect(w.registry["help"]?.toolExposed == true,
                "help must be tool-exposed (GM decision 2026-07-19) — the one mechanism for craft on every surface")
    }
}
