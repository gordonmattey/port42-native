import Testing
import Foundation
@testable import Port42Lib

/// Presence, the pure layer — DERIVED from the activity record since step 3
/// (docs/plan-port42-protocol-local-bus.md §F).
///
/// These properties used to belong to `DriverRegistry`, a second table storing who acted on a port
/// beside a counter that already moved when someone did. The table is gone; every property below is
/// now read off the same record the token comes from, which is what makes "who is driving" checkable
/// from the token itself rather than asserted next to it.
///
/// Headless by construction: `PortActivity` takes `now` as a parameter, so staleness — the behaviour
/// most likely to be wrong — is tested by arithmetic instead of by sleeping.
@Suite("PortPresence — the driver, derived (step 3)")
struct PortPresenceTests {

    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let human = ActorRef(principal: "user-gordon")
    let echo = ActorRef(principal: "companion-echo")

    // MARK: - Who is driving

    @Test("whoever writes first is the driver, with no ceremony")
    func firstWriterDrives() throws {
        var a = PortActivity(epoch: "e1")
        let b = a.bump("P", by: human, named: "gordon", at: t0)
        let d = try #require(b.driverChanged)
        #expect(d.ref == human)
        #expect(d.expires == t0.addingTimeInterval(PortActivity.driverTTL))
        #expect(a.driver(of: "P", now: t0)?.ref == human)
    }

    @Test("the driver's own next write moves the window forward, and is NOT a change")
    func ownWriteRefreshes() {
        var a = PortActivity(epoch: "e1")
        a.bump("P", by: human, named: "gordon", at: t0)
        let b = a.bump("P", by: human, named: "gordon", at: t0.addingTimeInterval(5))
        // nil is what keeps the Notify broadcast quiet: a refresh fires per keystroke, and
        // publishing it would drown the port's topic in non-news.
        #expect(b.driverChanged == nil)
        #expect(a.driver(of: "P", now: t0.addingTimeInterval(5))?.expires
                == t0.addingTimeInterval(5 + PortActivity.driverTTL))
    }

    @Test("the LAST driver wins — presence never refuses to move (R1)")
    func lastDriverWins() {
        var a = PortActivity(epoch: "e1")
        a.bump("P", by: human, named: "gordon", at: t0)
        let b = a.bump("P", by: echo, named: "echo", at: t0.addingTimeInterval(1))
        // A different actor while the record is still fresh is a CHANGE, not a refusal. Holding the
        // driver still would leave the chrome naming someone who has stopped, which is the failure
        // this replaced: a human typing into a port a companion had been writing to stayed invisible.
        #expect(b.driverChanged?.ref == echo)
        #expect(a.driver(of: "P", now: t0.addingTimeInterval(1))?.name == "echo")
    }

    @Test("a stale record stops naming anyone — a crashed writer is not still driving")
    func expiryStopsNamingAnyone() {
        var a = PortActivity(epoch: "e1")
        a.bump("P", by: human, named: "gordon", at: t0)
        let later = t0.addingTimeInterval(PortActivity.driverTTL + 1)
        #expect(a.driver(of: "P", now: later) == nil)
        // The same actor after the window lapsed is a CHANGE, because the chip had faded and has to
        // relight. Only a live record makes a repeat a refresh.
        let b = a.bump("P", by: human, named: "gordon", at: later)
        #expect(b.driverChanged?.ref == human)
    }

    @Test("ports are independent — driving one says nothing about another")
    func perPort() {
        var a = PortActivity(epoch: "e1")
        a.bump("A", by: human, named: "gordon", at: t0)
        let b = a.bump("B", by: echo, named: "echo", at: t0)
        #expect(b.driverChanged?.ref == echo)
        #expect(a.driver(of: "A", now: t0)?.ref == human)
        #expect(a.driver(of: "B", now: t0)?.ref == echo)
    }

    @Test("no actor, no driver — the port changed and we do not know who")
    func unattributedNamesNobody() {
        var a = PortActivity(epoch: "e1")
        let b = a.bump("P", at: t0)
        #expect(b.driverChanged == nil)
        #expect(a.driver(of: "P", now: t0) == nil)
        #expect(a.seq(for: "P") == 1, "it still counts: the port DID change")
    }

    @Test("an unattributed write does NOT clear the driver — this one is load-bearing")
    func unattributedDoesNotClear() {
        // A companion's `port.push` to a terminal counts TWICE: once attributed at the dispatch seam,
        // and once unattributed at the pty funnel (R2b), because the funnel sees text entering the
        // surface and not who sent it. If a nil actor cleared the attribution, every companion would
        // blank its own chip the instant it wrote — green in every unit test, visibly broken live.
        var a = PortActivity(epoch: "e1")
        a.bump("P", by: echo, named: "echo", at: t0)
        a.bump("P", at: t0.addingTimeInterval(0.01))
        #expect(a.driver(of: "P", now: t0.addingTimeInterval(0.01))?.ref == echo)
        #expect(a.seq(for: "P") == 2)
    }

    @Test("an unattributed write does not extend the window either")
    func unattributedDoesNotRefresh() {
        // The timestamp belongs to the ATTRIBUTION, not to the port. A redrawing TUI writing every
        // second would otherwise keep a human's name lit forever after they walked away.
        var a = PortActivity(epoch: "e1")
        a.bump("P", by: human, named: "gordon", at: t0)
        a.bump("P", at: t0.addingTimeInterval(PortActivity.driverTTL - 1))
        #expect(a.driver(of: "P", now: t0.addingTimeInterval(PortActivity.driverTTL + 1)) == nil)
    }

    // MARK: - The close: attribution lapses, the count does not

    @Test("a close drops the driver and KEEPS the count")
    func portClosedDropsOnlyAttribution() {
        var a = PortActivity(epoch: "e1")
        a.bump("P", by: human, named: "gordon", at: t0)
        a.portClosed("P")
        // A dead port has no driver, and a reused id must not inherit the last one's name.
        #expect(a.driver(of: "P", now: t0) == nil)
        // But the counter must not rewind, or a token composed against the DEAD port passes CAS
        // against the live one that took its id (Spike A's fourth correction).
        #expect(a.seq(for: "P") == 1)
        #expect(a.bump("P", at: t0).token == "e1:2")
    }

    // MARK: - The peer-qualified driver (decision-identity-model.md)

    @Test("local is the DEGENERATE form of remote, so today's strings need no migration")
    func actorRefWireForm() {
        #expect(ActorRef(principal: "u1").description == "u1")
        #expect(ActorRef(peer: "12D3KooW", principal: "u1").description == "12D3KooW/u1")
        #expect(ActorRef.parse("u1") == ActorRef(principal: "u1"))
        #expect(ActorRef.parse("12D3KooW/u1") == ActorRef(peer: "12D3KooW", principal: "u1"))
        // Round trip both ways.
        let remote = ActorRef(peer: "12D3KooW", principal: "u1")
        #expect(ActorRef.parse(remote.description) == remote)
    }

    @Test("the same principal at a DIFFERENT instance is a different driver")
    func peerQualificationMatters() {
        var a = PortActivity(epoch: "e1")
        let localGordon = ActorRef(principal: "user-gordon")
        let remoteGordon = ActorRef(peer: "12D3KooW", principal: "user-gordon")
        a.bump("P", by: localGordon, named: "gordon", at: t0)
        // Same person, other machine: still a CHANGE of driver, not a refresh. A bare principal id
        // would have called it the same actor, so the chrome would never have said which device is
        // driving.
        let b = a.bump("P", by: remoteGordon, named: "gordon@laptop", at: t0)
        #expect(b.driverChanged?.ref == remoteGordon)
        #expect(a.driver(of: "P", now: t0)?.ref == remoteGordon)
    }

    // MARK: - What step 3 deleted

    @Test("presence has ONE home: no table stores a driver beside the counter")
    func noSecondDriverTable() throws {
        // The register's test: one concept, one definition. `DriverRegistry` and `PresenceThrottle`
        // were the last instance inside the seam, and `release`/`handoff` were lease-era verbs with
        // no production callers at all. Tree-wide, because a gate scoped to named files is not a gate.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in src.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                for dead in ["DriverRegistry", "PresenceThrottle", "presenceClaimed"] where t.contains(dead) {
                    found.append("\(url.lastPathComponent): \(t.prefix(60))")
                }
            }
        }
        #expect(found.isEmpty, """
            A second home for presence is back: \(found).
            The driver is whoever moved the token last, derived from one record. A stored copy can \
            only ever disagree with it, and it is what focus used to write into without proving \
            anything (§F).
            """)
    }
}
