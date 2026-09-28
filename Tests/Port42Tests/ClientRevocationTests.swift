import Testing
import Foundation
@testable import Port42Lib

/// A revocation holds until the user restores the client (APP-12). Re-registering cleared it, so a
/// revoked companion terminal was back the next time it was spawned or renamed.
@Suite("Client revocation")
@MainActor
struct ClientRevocationTests {
    @Test("re-registering a revoked client keeps it revoked; restoring is the only way back")
    func reRegisterKeepsRevocation() throws {
        let db = try DatabaseService(inMemory: true)
        let registry = ClientRegistry(db: db, instance: "Port42Test")
        let id = "child-claude-space1"
        #expect(registry.register(id: id, name: "claude", kind: .child) != nil)
        registry.revoke(id: id)
        #expect(registry.client(id: id)?.isActive == false)

        registry.register(id: id, name: "claude", kind: .child)            // respawn
        registry.register(id: id, name: "claude-renamed", kind: .child)    // rename
        #expect(registry.client(id: id)?.isActive == false, "a respawn or rename un-revoked the client")

        try db.restoreClient(id: id)
        #expect(registry.client(id: id)?.isActive == true)
    }

    @Test("re-enrolling a revoked peer keeps it revoked")
    func peerUpsertKeepsRevocation() throws {
        let db = try DatabaseService(inMemory: true)
        try db.upsertPeerClient(id: "peer-ada", name: "Ada", peerKey: "ada-key")
        try db.revokeClient(id: "peer-ada")
        try db.upsertPeerClient(id: "peer-ada", name: "Ada", peerKey: "ada-key")
        #expect(try db.client(peerKey: "ada-key")?.revokedAt != nil)
    }
}
