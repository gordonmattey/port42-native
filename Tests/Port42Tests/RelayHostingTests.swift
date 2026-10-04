import Testing
import Foundation
@testable import Port42Lib

/// An instance is reachable through the relays only while it shares something (GW-16, GM 2026-09-28).
/// Every install used to register on the public relay at launch and stay registered.
@Suite("Relay hosting follows sharing")
@MainActor
struct RelayHostingTests {

    @Test("off at rest; on with an invite out; off when the last is withdrawn")
    func followsInvites() async throws {
        let t = InviteTests()
        let w = try t.world()
        var sent: [Bool] = []
        w.state.relayLeaveDelay = 0          // leaving the relays at once, as before the access notice
        w.state.onRelayHosting = { sent.append($0) }
        w.state.refreshSharing()
        #expect(!w.state.relayHosting && sent.isEmpty, "an instance sharing nothing asked to be reachable")

        let made = try await t.create(w)
        #expect(w.state.relayHosting && sent == [true], "an invite went out and the instance is not reachable")
        w.state.withdrawInvite(id: try #require(made["id"] as? String))
        #expect(!w.state.relayHosting && sent == [true, false], "withdrawn, it stayed reachable")
    }

    @Test("someone joined keeps it on after the link is used up; stopping sharing turns it off")
    func followsPeople() async throws {
        let t = InviteTests()
        let w = try t.world()
        var sent: [Bool] = []
        w.state.relayLeaveDelay = 0          // leaving the relays at once, as before the access notice
        w.state.onRelayHosting = { sent.append($0) }
        let made = try await t.create(w)
        let nonce = try t.coupon(made).nonce
        _ = try await t.remote(w, as: InviteTests.ada, "invite.redeem", ["nonce": nonce, "name": "Ada"])
        _ = try await t.remote(w, as: InviteTests.eve, "invite.redeem", ["nonce": nonce, "name": "Eve"])
        #expect(w.state.openInvites().isEmpty, "the link should be used up")
        #expect(w.state.relayHosting, "two people are in, and the instance stopped being reachable")
        w.state.stopSharing(peer: InviteTests.ada, port: w.p)
        #expect(w.state.relayHosting, "one person is still in")
        w.state.stopSharing(peer: InviteTests.eve, port: w.p)
        #expect(!w.state.relayHosting && sent.last == false, "nothing is shared and it is still reachable")
    }

    @Test("the gateway is told on its private pipe, one line each way, in words the gateway reads")
    func pipeLine() throws {
        #expect(GatewayProcess.relayHostLine(true) == "relay-host on\n")
        #expect(GatewayProcess.relayHostLine(false) == "relay-host off\n")
        // The Go side reads these exact words; if the two ever differ, no install would host again.
        let go = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("gateway/relayhost.go"), encoding: .utf8)
        for on in [true, false] {
            let word = GatewayProcess.relayHostLine(on).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(go.contains("case \"\(word)\":"), "the gateway does not read \"\(word)\"")
        }
    }
}
