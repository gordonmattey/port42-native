import Testing
import Foundation
@testable import Port42Lib

// I1.6 — the last step of the ACTOR noun (plan-port42-protocol-local-bus.md §B).
//
// I1.3 and I1.4 changed WHICH identity a write carries. This suite pins what that identity is
// CALLED, because the driver chip renders `principal.displayName` and a name nobody recognizes is
// the same failure as no attribution at all: the human sees contention and cannot act on it.
//
// Pinned rather than eyeballed on purpose. "I looked at the chip once" is the weakest evidence in
// this thread's vocabulary, and the identities feeding it now come from four different factories.
@Suite("Driver attribution (I1.6)")
struct DriverAttributionTests {

    // MARK: - every surface names something a human can act on

    @Test("a companion names itself, not its internal id, when it has a display name")
    func companionNamesItself() {
        let p = Principal.forCompanionTool(createdBy: "agent-7f3a", createdByName: "echo",
                                           spaceId: "space-1")
        #expect(p.displayName == "echo")
        // The id remains the grant key; the label never is (Phase 3).
        #expect(p.id == "agent-7f3a")
    }

    @Test("a companion with no display name falls back to its id, never to an empty chip")
    func companionWithoutDisplayNameStillNamesSomething() {
        let p = Principal.forCompanionTool(createdBy: "agent-7f3a", createdByName: nil, spaceId: nil)
        #expect(p.displayName == "agent-7f3a")
        #expect(!p.displayName.isEmpty)
    }

    @Test("the local gateway reads as a place, not as a raw token")
    func gatewayNamesAPlace() {
        let p = Principal.peer(id: Principal.localGatewayID,
                               displayName: Principal.gatewayDisplayName(for: Principal.localGatewayID))
        #expect(p.displayName == "Local (gateway)")
        #expect(p.displayName != Principal.localGatewayID)
    }

    @Test("a gateway-created port names ITSELF, which is the visible half of I1.3")
    func gatewayCreatedPortNamesItself() {
        let p = Principal.forPortBridge(createdBy: Principal.localGatewayID, messageId: "port-a",
                                        instanceFallback: "unused", title: "weather", spaceId: "s")
        // Before I1.3 this chip read "local-http" while the grant covered every gateway-made port in
        // the space. Now the name and the grant describe the same single thing.
        #expect(p.displayName == "weather")
        #expect(p.id == "port-a")
    }

    @Test("a companion-created port names its author, so P-260 stays legible in the chrome")
    func companionCreatedPortNamesItsAuthor() {
        let p = Principal.forPortBridge(createdBy: "echo", messageId: "port-a",
                                        instanceFallback: "unused", title: "weather", spaceId: "s")
        #expect(p.displayName == "echo")
    }

    @Test("no surface can produce an empty or heap-address driver name")
    func noSurfaceProducesAnUnreadableName() {
        let all: [Principal] = [
            .forCompanionTool(createdBy: "a", createdByName: nil, spaceId: nil),
            .peer(id: Principal.localGatewayID,
                  displayName: Principal.gatewayDisplayName(for: Principal.localGatewayID)),
            .human(id: "u1", displayName: "Gordon", spaceId: "s"),
            // A port with nothing at all: no creator, no title. The last-resort label.
            .forPortBridge(createdBy: nil, messageId: nil, instanceFallback: "panel-1",
                           title: nil, spaceId: nil),
        ]
        for p in all {
            #expect(!p.displayName.isEmpty)
            #expect(!p.displayName.contains("ObjectIdentifier"))
        }
    }

    // MARK: - the chrome does not promise a refusal that R1 removed

    @Test("no in-product copy claims presence blocks a write")
    func presenceCopyDoesNotPromiseRefusal() throws {
        // R1 demoted the lease to presence: it refuses NOTHING, last driver wins. The chip's tooltip
        // said "your writes are refused until they finish" for three steps after that stopped being
        // true. What refuses is CAS, and only against stale state.
        //
        // Scanned rather than asserted on one string, because the claim can reappear in any view.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let claims = ["writes are refused until", "take the pen", "takes the pen", "port_busy"]
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            // Only user-facing strings count. A comment explaining the removed claim is the record
            // of the fix, not a reoccurrence of it.
            for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                if claims.contains(where: { t.contains($0) }) {
                    offenders.append("\(f.lastPathComponent): \(t.prefix(80))")
                }
            }
        }
        #expect(offenders.isEmpty, """
            Copy promises a refusal presence does not perform: \(offenders).
            Presence reports who drove last and blocks nothing (R1). CAS refuses a write composed \
            against stale state (R3). Say that instead.
            """)
    }
}
