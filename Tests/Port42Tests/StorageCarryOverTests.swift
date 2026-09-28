import Testing
import Foundation
@testable import Port42Lib

/// A port's storage from 0.5.x is still there after the upgrade (GM, 2026-09-27: the Drafts port opened
/// empty in v1). 0.5.x kept a port's data under its creator's id; v1 gives each port its own bucket.
@Suite("Port storage carries over from 0.5.x")
@MainActor
struct StorageCarryOverTests {
    func get(_ s: AppState, _ p: Principal, _ key: String) async throws -> Any? {
        let v = try await s.runBridgeMethod("storage.get", principal: p, args: BridgeArgs(["key": key]))
        return (v.toJSONObject() as? [String: Any])?["value"].flatMap { $0 is NSNull ? nil : $0 }
    }

    @Test("a port reads what its creator stored in 0.5.x; a delete stays deleted; the marker is not listed")
    func carriedOnce() async throws {
        let w = try makeParityWorld()
        let space = w.space.id
        // What 0.5.x left: the draft under the port's creator, a terminal client.
        try w.state.db.setPortStorage(key: "drafts-published", value: "[\"post one\"]", scope: space, creatorId: "terminal-abc")
        w.state.portWindows.registerTiledPort(id: "drafts", html: "<title>Drafts</title>", spaceId: space,
                                              createdBy: "terminal-abc", title: "Drafts", position: nil)
        let panel = try #require(w.state.portWindows.panels.first { $0.id == "drafts" })
        let me = panel.bridge.portPrincipal
        #expect(try await get(w.state, me, "drafts-published") as? [String] == ["post one"], "the draft did not come across")
        // Deleted in v1: it must not come back from the old bucket.
        _ = try await w.state.runBridgeMethod("storage.delete", principal: me, args: BridgeArgs(["key": "drafts-published"]))
        #expect(try await get(w.state, me, "drafts-published") == nil, "a deleted key came back from 0.5.x's bucket")
        let list = try await w.state.runBridgeMethod("storage.list", principal: me, args: BridgeArgs([:]))
        #expect(((list.toJSONObject() as? [String: Any])?["keys"] as? [String]) == [], "the marker is listed")
        // The old bucket is untouched, for any other port of the same creator.
        #expect(try w.state.db.getPortStorage(key: "drafts-published", scope: space, creatorId: "terminal-abc") != nil)
        withExtendedLifetime(w.state) {}
    }

    @Test("what a port already stored in v1 wins over the old copy")
    func ownDataWins() async throws {
        let w = try makeParityWorld()
        let space = w.space.id
        w.state.portWindows.registerTiledPort(id: "p", html: "<title>p</title>", spaceId: space,
                                              createdBy: "terminal-xyz", title: "p", position: nil)
        let panel = try #require(w.state.portWindows.panels.first { $0.id == "p" })
        try w.state.db.setPortStorage(key: "k", value: "\"new\"", scope: space, creatorId: "port:" + panel.udid)
        try w.state.db.setPortStorage(key: "k", value: "\"old\"", scope: space, creatorId: "terminal-xyz")
        #expect(try await get(w.state, panel.bridge.portPrincipal, "k") as? String == "new")
        withExtendedLifetime(w.state) {}
    }
}
