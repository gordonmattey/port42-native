import Testing
import Foundation
@testable import Port42Lib

// MARK: - BridgeAIServiceTests
//
// Behavioral cover for the `ai` service module extraction (BridgeServiceAI.swift): ai.models and
// ai.status moved off the old PortBridge switch into the registry. These assert the extracted bodies
// run through the registry and keep their shape, so deleting the old switch cases is safe.
// (ai.complete's streaming behavior is covered by the streaming-contract suites.)

@Suite("Bridge — ai service")
@MainActor
struct BridgeAIServiceTests {

    @Test("ai.models is registered, ungated, and returns id/name/tier objects")
    func aiModels() async throws {
        let w = try makeParityWorld()
        let r = buildBridgeRegistry(w.state)
        let method = try #require(r["ai.models"], "ai.models should be in the registry")
        #expect(method.permission == nil)

        let value = try await method.run(w.principal, BridgeArgs([:]))
        guard case let .array(items) = value else {
            Issue.record("ai.models should return an array, got \(value)"); return
        }
        #expect(items.count == 3)
        guard case let .object(first) = items.first else {
            Issue.record("ai.models items should be objects"); return
        }
        #expect(first["id"] != nil && first["name"] != nil && first["tier"] != nil)
        // No companion designated → Anthropic default.
        if case let .string(id) = first["id"] { #expect(id.hasPrefix("claude")) }
    }

    @Test("ai.status is registered, ungated, and returns a paused flag")
    func aiStatus() async throws {
        let w = try makeParityWorld()
        let r = buildBridgeRegistry(w.state)
        let method = try #require(r["ai.status"], "ai.status should be in the registry")
        #expect(method.permission == nil)

        let value = try await method.run(w.principal, BridgeArgs([:]))
        guard case let .object(o) = value, case .bool = o["paused"] else {
            Issue.record("ai.status should return { paused: Bool }, got \(value)"); return
        }
    }

    @Test("ai.complete is in the stream registry, gated .ai")
    func aiCompleteStream() throws {
        let w = try makeParityWorld()
        let sr = buildBridgeStreamRegistry(w.state)
        let method = try #require(sr["ai.complete"], "ai.complete should be in the stream registry")
        #expect(method.permission == .ai)
        #expect(method.paramNames == ["prompt", "options"])
    }
}
