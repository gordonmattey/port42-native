import Testing
import Foundation
@testable import Port42Lib

// APP-20: storage {scope:'global', shared:true} is one cell every local caller reads and writes,
// ungated. It stays open, since cross-space collaboration between ports needs it, and the fix is
// that an author is told so before storing anything there. These tests hold the documentation to
// the behavior: the descriptions and the port manual say "public board", a caller in one space
// reads what another space's caller wrote, and a caller on another machine never reaches it.

@Suite("Storage public board (APP-20)")
@MainActor
struct StoragePublicBoardTests {

    func run(_ w: ParityWorld, _ method: String, as p: Principal, _ args: [String: Any]) async throws -> BridgeValue {
        let m = try #require(w.registry[method])
        return try await m.run(p, BridgeArgs(args))
    }

    @Test("storage.get and storage.set say the global shared cell is a public board")
    func descriptionsSaySo() throws {
        let w = try makeParityWorld()
        for method in ["storage.get", "storage.set"] {
            let d = try #require(w.registry[method]).description
            #expect(d.contains("PUBLIC board"), "\(method) does not warn that global+shared is public")
        }
    }

    @Test("the port manual says so too")
    func manualSaysSo() throws {
        let url = try #require(Bundle.module.url(forResource: "ports-context", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("IS A PUBLIC BOARD"))
    }

    @Test("what one space's caller writes there, another space's caller reads: as documented")
    func boardIsShared() async throws {
        let w = try makeParityWorld()
        let writer = Principal.companion(id: "c-a", displayName: "a", spaceId: "space-a")
        let reader = Principal.companion(id: "c-b", displayName: "b", spaceId: "space-b")
        let board: [String: Any] = ["scope": "global", "shared": true]
        _ = try await run(w, "storage.set", as: writer, ["key": "note", "value": "hello"].merging(board) { $1 })
        let got = try await run(w, "storage.get", as: reader, ["key": "note"].merging(board) { $1 })
        #expect((got.toJSONObject() as? [String: Any])?["value"] as? String == "hello")
    }

    @Test("a caller on another machine cannot reach the board")
    func remoteRefused() async throws {
        let w = try makeParityWorld()
        let remote = Principal.remote(peer: "peer-x", displayName: "x")
        await #expect(throws: BridgeError.self) {
            _ = try await run(w, "storage.get", as: remote, ["key": "note", "scope": "global", "shared": true])
        }
    }
}
