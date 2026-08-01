import Testing
import Foundation
@testable import Port42Lib

/// SPIKE · a shared port's bridge call, and who holds the grant.
///
/// **The question.** CR1 says ports call `window.port42` in-process and never traverse the gateway,
/// which is why ports were exempt from the entire authentication story of half two. A SHARED port
/// breaks that: the JS runs on the guest's machine, so its bridge call has to reach the host and
/// therefore crosses a transport. When the guest clicks and the port calls `fs.read` on my machine,
/// **who is the grantee?**
///
/// - the PORT, and every future guest inherits whatever I granted it once — the pooling disease
///   that `local-http` was
/// - the GUEST, and the same port behaves differently depending on who clicked
/// - the PAIR, which is the only honest answer
///
/// **The falsifier.** If the store can only express "the port is the grantee", sharing a
/// host-reaching port pools authority across every guest, and the sharing design needs rethinking
/// before step 2 starts. No transport is needed to answer this: the principal and grant shape is
/// decidable on one machine today.
@Suite("SPIKE · a shared port's actor is a pair")
struct SharedPortActorSpikeTests {

    static let peerB = "12D3KooWA1b2c3d4e5f6g7h8i9j0kLmNoPqRsTuVwXyZaBcDeFgH"
    static let peerC = "12D3KooWZ9y8x7w6v5u4t3s2r1q0pOnMlKjIhGfEdCbAzYxWvUtS"
    static let portX = "PANEL-UDID-1"

    /// `ActorRef` has been `<peerID>/<principal>` since day one, peer-qualified deliberately. If the
    /// compound actor is already expressible, the model needs no new noun for this.
    static func actor(peer: String, port: String) -> String {
        ActorRef(peer: peer, principal: port).description
    }

    @Test("the compound actor already has a representation")
    func actorRefIsAlreadyPeerQualified() {
        let a = Self.actor(peer: Self.peerB, port: Self.portX)
        #expect(a.contains(Self.peerB))
        #expect(a.contains(Self.portX))
        // And it round-trips, so it is an identity rather than a display string.
        #expect(ActorRef.parse(a) == ActorRef(peer: Self.peerB, principal: Self.portX))
    }

    @Test("a grant to <peer>/<port> does NOT leak to another peer driving the same port")
    @MainActor
    func grantsDoNotPoolAcrossGuests() throws {
        let db = try DatabaseService(inMemory: true)
        let object = PortObject.machine.keySegment      // the host's port 0: what fs.read acts on

        // I grant filesystem to peer B driving port X.
        try db.saveGrants([.filesystem], grantee: Self.actor(peer: Self.peerB, port: Self.portX),
                          object: object, zone: "")

        // Peer C drives the SAME port. They must get nothing.
        let forC = try db.grants(grantee: Self.actor(peer: Self.peerC, port: Self.portX),
                                 object: object, zone: "")
        #expect(forC.isEmpty, "a second guest inherited the first guest's grant")

        // And the port ALONE holds nothing, so a local call by the same port is not covered either.
        let forPortAlone = try db.grants(grantee: Self.portX, object: object, zone: "")
        #expect(forPortAlone.isEmpty, "the grant leaked onto the port itself")

        // The pair I actually granted still works.
        let forB = try db.grants(grantee: Self.actor(peer: Self.peerB, port: Self.portX),
                                 object: object, zone: "")
        #expect(forB == [.filesystem])
    }

    @Test("THE FAILURE MODE, demonstrated: grant to the port alone and every guest inherits it")
    @MainActor
    func grantingToThePortPools() throws {
        let db = try DatabaseService(inMemory: true)
        let object = PortObject.machine.keySegment

        // The tempting shape, because it is what a port's principal is today.
        try db.saveGrants([.filesystem], grantee: Self.portX, object: object, zone: "")

        // Any guest driving that port reads the same row. This is `local-http` again, one level in.
        for guest in [Self.peerB, Self.peerC] {
            let asPort = try db.grants(grantee: Self.portX, object: object, zone: "")
            #expect(asPort == [.filesystem],
                    "guest \(guest.prefix(12)) inherits authority nobody granted them")
        }
    }

    @Test("both slots can be peer-qualified at once without colliding")
    @MainActor
    func compoundActorAndRemoteObjectCoexist() throws {
        let db = try DatabaseService(inMemory: true)
        // Peer B, driving port X, acting on peer A's port 0. Grantee and object BOTH contain `/`.
        let remoteObject = PortObject.remoteMachine(peerID: Self.peerC).keySegment
        let grantee = Self.actor(peer: Self.peerB, port: Self.portX)

        try db.saveGrants([.terminal], grantee: grantee, object: remoteObject, zone: "")

        #expect(try db.grants(grantee: grantee, object: remoteObject, zone: "") == [.terminal])
        // The same actor on the LOCAL object is a different row, so the object still discriminates.
        #expect(try db.grants(grantee: grantee, object: PortObject.machine.keySegment,
                              zone: "").isEmpty)
    }

    @Test("the permission card can name both, which is what makes it consentable")
    func theCardCanNameTheGuestAndThePort() {
        // A card saying only "Pricing Calculator wants filesystem access" hides that a person on
        // another machine is asking. The display name has to carry both halves.
        let p = Principal.peer(id: Self.actor(peer: Self.peerB, port: Self.portX),
                               displayName: "Ada's Pricing Calculator", spaceId: nil)
        #expect(p.id.contains(Self.peerB), "the grant key must carry the guest")
        #expect(p.scopeDescription.contains("Ada's"), "the human must see whose it is")
    }
}
