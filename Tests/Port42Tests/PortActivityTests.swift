import Testing
import Foundation
@testable import Port42Lib

/// R2 — the activity token, pure layer (docs/plan-port42-protocol-local-bus.md §"Phase L2 REVISED").
///
/// This is the CORRECTNESS half of what the lease used to do badly. `PortLeaseTests` covers the
/// presence half; R3 wires the comparison into the dispatch seam.
@Suite("PortActivity — the state token (R2)")
struct PortActivityTests {

    @Test("a port nobody has touched is 0 — 'nothing has happened here' is a real answer")
    func unknownPortStartsAtZero() {
        let a = PortActivity(epoch: "e1")
        #expect(a.seq(for: "P") == 0)
        #expect(a.token(for: "P") == "e1:0")
    }

    @Test("bumping is monotonic per port")
    func monotonic() {
        var a = PortActivity(epoch: "e1")
        #expect(a.bump("P") == "e1:1")
        #expect(a.bump("P") == "e1:2")
        #expect(a.bump("P") == "e1:3")
        #expect(a.seq(for: "P") == 3)
    }

    @Test("ports are independent — a write to one does not invalidate a token for another")
    func perPort() {
        var a = PortActivity(epoch: "e1")
        a.bump("A"); a.bump("A")
        a.bump("B")
        #expect(a.seq(for: "A") == 2)
        #expect(a.seq(for: "B") == 1)
        #expect(a.seq(for: "C") == 0)
    }

    // MARK: - The epoch (Spike A finding A4)

    @Test("two launches never share a token, even for the same port at the same count")
    func epochsDoNotCollide() {
        var before = PortActivity(epoch: "aaaa1111")
        var after = PortActivity(epoch: "bbbb2222")
        before.bump("P")
        after.bump("P")
        // Same port, same count, different run. Without the epoch these compare EQUAL, and a token
        // composed before a restart would pass CAS against a port whose live state was wiped by it.
        #expect(before.token(for: "P") != after.token(for: "P"))
        #expect(before.seq(for: "P") == after.seq(for: "P"))
    }

    @Test("a fresh epoch is generated per instance, and is not the empty string")
    func epochIsGenerated() {
        let a = PortActivity(), b = PortActivity()
        #expect(a.epoch != b.epoch)
        #expect(!a.epoch.isEmpty)
        // Compared for equality only, never ordered or parsed for meaning.
        #expect(a.token(for: "P") == "\(a.epoch):0")
    }

    // MARK: - The lifecycle rule that is the OPPOSITE of presence

    @Test("a counter is never reset — a reused port id must not let a dead port's token pass")
    func neverResets() {
        var a = PortActivity(epoch: "e1")
        a.bump("P"); a.bump("P")
        // A close drops PRESENCE (`DriverRegistry.forget`) because a dead port has no driver. There
        // is deliberately no counterpart here: if a closed id is reused and the count restarted, a
        // token composed against the DEAD port would match the new one. Monotonic-and-never-reset
        // means a stale token mismatches by construction. This asserts the type offers no way back.
        #expect(a.seq(for: "P") == 2)
        #expect(a.bump("P") == "e1:3")
    }
}
