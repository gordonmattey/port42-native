import Testing
import Foundation
@testable import Port42Lib

/// Nautilus Phase 4, 4.7b (Gordon: option A): a shared port's state lives in its storage, and every copy
/// of the port, on this machine or another, reads and writes that one port's storage, hearing each
/// change. First, each port has storage of its own: it was filed under who made the port, so two ports
/// one companion made in a space shared a bucket.
@Suite("Shared port storage (Phase 4, 4.7b)")
@MainActor
struct SharedStorageTests {

    static let peer = RemotePortTests.host

    struct World {
        let state: AppState
        let space: String
        let a: String   // port keys
        let b: String
        @MainActor func page(_ key: String) -> Principal { state.portWindows.panels.first { $0.udid == key }!.bridge.portPrincipal }
    }

    func world() throws -> World {
        let w = try makeParityWorld()
        for id in ["st-a", "st-b"] {
            _ = w.state.portWindows.registerTiledPort(id: id, html: "<p>\(id)</p>", spaceId: w.space.id,
                                                      createdBy: "companion-1", title: id, position: nil)
        }
        let a = w.state.portWindows.panels.first { $0.id == "st-a" }!.udid
        let b = w.state.portWindows.panels.first { $0.id == "st-b" }!.udid
        return World(state: w.state, space: w.space.id, a: a, b: b)
    }

    func call(_ w: World, _ p: Principal, _ method: String, _ args: [String: Any]) async throws -> Any? {
        try await w.state.runBridgeMethod(method, principal: p, args: BridgeArgs(args)).toJSONObject()
    }
    func value(_ out: Any?) -> Any? { (out as? [String: Any])?["value"] }

    @Test("two ports one companion made keep their own state under the same key")
    func perPort() async throws {
        let w = try world()
        _ = try await call(w, w.page(w.a), "storage.set", ["key": "state", "value": "from a"])
        _ = try await call(w, w.page(w.b), "storage.set", ["key": "state", "value": "from b"])
        #expect(value(try await call(w, w.page(w.a), "storage.get", ["key": "state"])) as? String == "from a",
                "a port read another port's state")
        #expect(value(try await call(w, w.page(w.b), "storage.get", ["key": "state"])) as? String == "from b")
    }

    @Test("a copy on another machine reads with see, writes with use, and reaches only that port's own bucket")
    func remoteReach() async throws {
        let w = try world()
        _ = try await call(w, w.page(w.a), "storage.set", ["key": "state", "value": ["n": 3]])
        _ = try await call(w, w.page(w.a), "storage.set", ["key": "space-wide", "value": "secret", "options": ["shared": true]])
        let guest = Principal.remote(peer: Self.peer, displayName: "Ada")
        func refused(_ method: String, _ args: [String: Any]) async -> String? {
            do { _ = try await call(w, guest, method, args); return nil } catch let e as BridgeError { return e.code } catch { return "?" }
        }
        #expect(await refused("storage.get", ["key": "state", "port": w.a]) == "not_granted", "read without being shared")

        w.state.grantRemoteRights([.see], to: Self.peer, onPort: w.a)
        let got = value(try await call(w, guest, "storage.get", ["key": "state", "port": w.a])) as? [String: Any]
        #expect(got?["n"] as? Int == 3, "the copy did not read its port's state")
        #expect(await refused("storage.set", ["key": "state", "value": 4, "port": w.a]) == "not_granted", "wrote with see only")
        #expect(await refused("storage.get", ["key": "space-wide", "port": w.a, "options": ["shared": true]]) == "not_granted",
                "reached the space's shared bucket")
        #expect(await refused("storage.get", ["key": "state", "port": w.a, "options": ["scope": "global"]]) == "not_granted",
                "reached global storage")
        #expect(await refused("storage.get", ["key": "state", "port": w.b]) == "not_granted", "reached a port not shared")

        w.state.grantRemoteRights([.see, .use], to: Self.peer, onPort: w.a)
        _ = try await call(w, guest, "storage.set", ["key": "state", "value": ["n": 4], "port": w.a])
        let seen = value(try await call(w, w.page(w.a), "storage.get", ["key": "state"])) as? [String: Any]
        #expect(seen?["n"] as? Int == 4, "the port's own page does not see the copy's write")
    }

    @Test("every change is announced on the port's topic, whoever made it")
    func announced() async throws {
        let w = try world()
        var got: [[String: Any]] = []
        let topic = PortNotify.topic(forPortKey: w.a)
        let id = w.state.notifyBus.subscribe(topic: topic) { json in
            if let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] { got.append(o) }
        }
        defer { w.state.notifyBus.unsubscribe(id: id, topic: topic) }
        _ = try await call(w, w.page(w.a), "storage.set", ["key": "state", "value": 1])
        w.state.grantRemoteRights([.see, .use], to: Self.peer, onPort: w.a)
        _ = try await call(w, .remote(peer: Self.peer, displayName: "Ada"), "storage.delete", ["key": "state", "port": w.a])
        let kinds = got.map { $0["kind"] as? String }
        #expect(kinds == ["storage", "storage"], "a change went unannounced: \(kinds)")
        #expect((got.first?["payload"] as? [String: Any])?["key"] as? String == "state")
    }
}
