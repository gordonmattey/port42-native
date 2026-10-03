import Testing
import Foundation
@testable import Port42Lib

// The remote port links are kept in memory (the 20 s freezes on Dev6, 2026-10-02): every write must be seen
// by the next read, or a tile would answer as the wrong port.
@Suite("remote port cache")
struct RemotePortCacheTests {
    @Test("each write to remote_ports is seen by the next read")
    func writesAreSeen() throws {
        let db = try DatabaseService(inMemory: true)
        #expect(try db.remotePorts().isEmpty && db.remotePortTiles().isEmpty)
        try db.upsertRemotePort(.init(peerKey: "H", portKey: "P", title: "board", rights: [.see], relays: ["r"], hostName: "Gordon"))
        #expect(try db.remotePorts().map(\.portKey) == ["P"], "an upsert was not seen")
        _ = try (db.remotePorts(), db.remotePortTiles())   // warm the cache, so a write that does not forget it shows
        try db.setRemotePortTile(peerKey: "H", portKey: "P", localPort: "T")
        #expect(try db.remotePortTiles()["T"]?.portKey == "P", "a tile link was not seen")
        _ = try (db.remotePorts(), db.remotePortTiles())
        try db.setRemotePortWakes(peerKey: "H", portKey: "P", wakes: true)
        #expect(try db.remotePorts().first?.wakes == true, "a wake change was not seen")
        _ = try (db.remotePorts(), db.remotePortTiles())
        try db.setRemotePortKnownAs(peerKey: "H", portKey: "P", knownAs: "gordon11")
        #expect(try db.remotePorts().first?.knownAs == "gordon11", "a name change was not seen")
        _ = try (db.remotePorts(), db.remotePortTiles())
        try db.upsertRemotePort(.init(peerKey: "H", portKey: "P", title: "board", rights: [.see, .edit], relays: ["r"], hostName: "Gordon"))
        #expect(try db.remotePorts().first?.rights == [.see, .edit], "a rights change was not seen")
        _ = try (db.remotePorts(), db.remotePortTiles())
        try db.deleteRemotePort(peerKey: "H", portKey: "P")
        #expect(try db.remotePorts().isEmpty && db.remotePortTiles().isEmpty, "a delete was not seen")
    }
}
