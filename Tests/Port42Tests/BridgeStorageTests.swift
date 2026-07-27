import Testing
import Foundation
@testable import Port42Lib

// Phase 1, batch 2: storage. GM chose the clean contract over preserving either old path, so these
// test the intended behavior directly (not parity): principal-derived scope, JSON round-trip,
// {value}/{keys}/{ok} shapes, and scope isolation.

@Suite("Bridge — storage")
struct BridgeStorageTests {

    @MainActor
    func value(_ blocks: [[String: Any]]) -> Any? {
        guard let text = blocks.first?["text"] as? String,
              let d = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) as? [String: Any]
        else { return nil }
        return obj
    }

    @MainActor
    func call(_ w: ParityWorld, _ canonical: String, _ input: [String: Any], principal: Principal? = nil) async throws -> BridgeValue {
        let method = try #require(w.registry[canonical])
        return try await method.run(principal ?? w.principal, BridgeArgs(input))
    }

    @Test("set then get round-trips a string, scoped to the space")
    @MainActor
    func setGetString() async throws {
        let w = try makeParityWorld()
        _ = try await call(w, "storage.set", ["key": "note", "value": "hello"])
        let got = try await call(w, "storage.get", ["key": "note"])
        #expect(got == .object(["value": .string("hello")]))
    }

    @Test("set then get round-trips a JSON object (parsed back, not a string)")
    @MainActor
    func setGetJSON() async throws {
        let w = try makeParityWorld()
        _ = try await call(w, "storage.set", ["key": "cfg", "value": ["n": 3, "on": true]])
        let got = try await call(w, "storage.get", ["key": "cfg"])
        #expect(got == .object(["value": .object(["n": .int(3), "on": .bool(true)])]))
    }

    @Test("missing key returns { value: null }")
    @MainActor
    func missingIsNull() async throws {
        let w = try makeParityWorld()
        #expect(try await call(w, "storage.get", ["key": "nope"]) == .object(["value": .null]))
    }

    @Test("list returns { keys: [...] } for what was set")
    @MainActor
    func list() async throws {
        let w = try makeParityWorld()
        _ = try await call(w, "storage.set", ["key": "a", "value": "1"])
        _ = try await call(w, "storage.set", ["key": "b", "value": "2"])
        let listed = try await call(w, "storage.list", [:])
        guard case let .object(o) = listed, case let .array(keys) = o["keys"] else {
            Issue.record("expected { keys: [...] }"); return
        }
        let names = keys.compactMap { if case let .string(s) = $0 { return s } else { return nil } }.sorted()
        #expect(names == ["a", "b"])
    }

    @Test("delete removes the key")
    @MainActor
    func delete() async throws {
        let w = try makeParityWorld()
        _ = try await call(w, "storage.set", ["key": "x", "value": "1"])
        _ = try await call(w, "storage.delete", ["key": "x"])
        #expect(try await call(w, "storage.get", ["key": "x"]) == .object(["value": .null]))
    }

    @Test("scope is principal-derived: a different principal id can't see the value")
    @MainActor
    func scopeByPrincipal() async throws {
        let w = try makeParityWorld()
        _ = try await call(w, "storage.set", ["key": "secret", "value": "mine"])
        // same space, different caller id → different creator scope → not visible
        let other = Principal.companion(id: "someone-else", displayName: "Other", spaceId: w.space.id)
        let got = try await call(w, "storage.get", ["key": "secret"], principal: other)
        #expect(got == .object(["value": .null]))
    }

    @Test("global scope is shared across spaces; space scope is not")
    @MainActor
    func globalVsSpace() async throws {
        let w = try makeParityWorld()
        _ = try await call(w, "storage.set", ["key": "g", "value": "gv", "options": ["scope": "global"]])
        // a caller in a different space, same id, reads the global value
        let elsewhere = Principal.companion(id: w.companion.id, displayName: w.companion.displayName, spaceId: "other-space")
        let g = try await call(w, "storage.get", ["key": "g", "options": ["scope": "global"]], principal: elsewhere)
        #expect(g == .object(["value": .string("gv")]))
        // but a space-scoped read from the other space sees nothing
        let s = try await call(w, "storage.get", ["key": "g"], principal: elsewhere)
        #expect(s == .object(["value": .null]))
    }

    @Test("space-scoped storage with no space context errors")
    @MainActor
    func noSpaceErrors() async throws {
        let w = try makeParityWorld()
        let spaceless = Principal.peer(id: "peer-1", displayName: "curl")
        await #expect(throws: BridgeError.self) {
            _ = try await call(w, "storage.set", ["key": "k", "value": "v"], principal: spaceless)
        }
    }

    @Test("positional args (the JS surface) map through paramNames")
    @MainActor
    func positional() async throws {
        let w = try makeParityWorld()
        let setMethod = try #require(w.registry["storage.set"])
        _ = try await setMethod.run(w.principal, BridgeArgs(positional: ["pk", "pv"], names: setMethod.paramNames))
        let getMethod = try #require(w.registry["storage.get"])
        let got = try await getMethod.run(w.principal, BridgeArgs(positional: ["pk"], names: getMethod.paramNames))
        #expect(got == .object(["value": .string("pv")]))
    }
}
