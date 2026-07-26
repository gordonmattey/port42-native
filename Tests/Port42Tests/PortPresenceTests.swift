import Testing
import Foundation
@testable import Port42Lib

/// L2.a — presence, the pure layer (docs/plan-port42-protocol-local-bus.md §"Phase L2 REVISED").
///
/// Headless by construction: `DriverRegistry` takes `now` as a parameter, so staleness — the
/// behaviour most likely to be wrong — is tested by arithmetic instead of by sleeping.
@Suite("PortLease — presence (L2.a)")
struct PortLeaseTests {

    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let human = ActorRef(principal: "user-gordon")
    let echo = ActorRef(principal: "companion-echo")

    // MARK: - The holder table

    @Test("whoever writes first is the driver, with no ceremony")
    func acquiresWhenFree() {
        var r = DriverRegistry()
        let d = r.record(port: "P", actor: human, name: "gordon", now: t0)
        guard case .changed(let lease) = d else { Issue.record("expected .changed, got \(d)"); return }
        #expect(lease.ref == human)
        #expect(lease.expires == t0.addingTimeInterval(DriverRegistry.defaultTTL))
        #expect(r.driver(of: "P", now: t0)?.ref == human)
    }

    @Test("the driver's own writes move the window forward, and are NOT a change")
    func holderRefreshes() {
        var r = DriverRegistry()
        r.record(port: "P", actor: human, name: "gordon", now: t0)
        let d = r.record(port: "P", actor: human, name: "gordon", now: t0.addingTimeInterval(5))
        guard case .refreshed(let lease) = d else { Issue.record("expected .refreshed, got \(d)"); return }
        // Distinct from .granted so the Notify broadcast can fire on CHANGE only (§L2.5).
        #expect(lease.expires == t0.addingTimeInterval(5 + DriverRegistry.defaultTTL))
    }

    @Test("the LAST driver wins — presence never refuses to move (R1)")
    func lastDriverWins() {
        var r = DriverRegistry()
        r.record(port: "P", actor: human, name: "gordon", now: t0)
        let d = r.record(port: "P", actor: echo, name: "echo", now: t0.addingTimeInterval(1))
        // A different actor while the record is still fresh is a CHANGE, not a refusal. Holding the
        // driver still would leave the chrome naming someone who has stopped, which is the failure
        // this replaced: a human typing into a port a companion had been writing to stayed invisible.
        guard case .changed(let lease) = d else { Issue.record("expected .changed, got \(d)"); return }
        #expect(lease.ref == echo)
        #expect(r.driver(of: "P", now: t0.addingTimeInterval(1))?.name == "echo")
    }

    @Test("a stale record stops naming anyone — a crashed writer is not still driving")
    func expiryFrees() {
        var r = DriverRegistry()
        r.record(port: "P", actor: human, name: "gordon", now: t0)
        let later = t0.addingTimeInterval(DriverRegistry.defaultTTL + 1)
        #expect(r.driver(of: "P", now: later) == nil)
        let d = r.record(port: "P", actor: echo, name: "echo", now: later)
        guard case .changed(let lease) = d else { Issue.record("expected .changed, got \(d)"); return }
        #expect(lease.ref == echo)
    }

    @Test("ports are independent — driving one says nothing about another")
    func perPort() {
        var r = DriverRegistry()
        r.record(port: "A", actor: human, name: "gordon", now: t0)
        let d = r.record(port: "B", actor: echo, name: "echo", now: t0)
        guard case .changed = d else { Issue.record("expected .changed on a different port"); return }
        #expect(r.driver(of: "A", now: t0)?.ref == human)
        #expect(r.driver(of: "B", now: t0)?.ref == echo)
    }

    // MARK: - Giving it up

    @Test("only the driver can release; a stray release is a no-op, not a way to clear someone else")
    func releaseIsHolderOnly() {
        var r = DriverRegistry()
        r.record(port: "P", actor: human, name: "gordon", now: t0)
        #expect(r.release(port: "P", actor: echo, now: t0) == false)
        #expect(r.driver(of: "P", now: t0)?.ref == human)
        #expect(r.release(port: "P", actor: human, now: t0) == true)
        #expect(r.driver(of: "P", now: t0) == nil)
    }

    @Test("handoff moves presence, and only the current driver may do it")
    func handoff() {
        var r = DriverRegistry()
        r.record(port: "P", actor: human, name: "gordon", now: t0)
        // Not the driver → refused, so a knock cannot become a seizure.
        #expect(r.handoff(port: "P", from: echo, to: echo, toName: "echo", now: t0) == false)
        #expect(r.handoff(port: "P", from: human, to: echo, toName: "echo", now: t0) == true)
        #expect(r.driver(of: "P", now: t0)?.ref == echo)
        #expect(r.driver(of: "P", now: t0)?.name == "echo")
    }

    @Test("handing off a port nobody drives is refused — no assigning it behind someone's back")
    func handoffNeedsAHolder() {
        var r = DriverRegistry()
        #expect(r.handoff(port: "P", from: human, to: echo, toName: "echo", now: t0) == false)
        #expect(r.driver(of: "P", now: t0) == nil)
    }

    @Test("forget drops presence with the port (a close, not a release)")
    func forget() {
        var r = DriverRegistry()
        r.record(port: "P", actor: human, name: "gordon", now: t0)
        r.forget(port: "P")
        #expect(r.driver(of: "P", now: t0) == nil)
    }

    // MARK: - L2.d.2: the interaction throttle

    // (`allow` is mutating, so each call is hoisted out of the #expect macro.)

    @Test("the FIRST interaction always claims — that is the moment it matters")
    func throttleAllowsFirst() {
        var t = PresenceThrottle(interval: 5)
        let first = t.allow(port: "P", now: t0)
        #expect(first)
    }

    @Test("a burst of keystrokes claims once, not per character")
    func throttleCollapsesABurst() {
        var t = PresenceThrottle(interval: 5)
        let first = t.allow(port: "P", now: t0)
        #expect(first)
        // Typing at ~10 chars/sec for two seconds: 20 keystrokes, no further claims.
        var extra = 0
        for i in 1...20 where t.allow(port: "P", now: t0.addingTimeInterval(Double(i) * 0.1)) { extra += 1 }
        #expect(extra == 0)
        // Past the interval, a continuing session re-claims so the lease never lapses under use.
        let later = t.allow(port: "P", now: t0.addingTimeInterval(6))
        #expect(later)
    }

    @Test("ports throttle independently — typing in one does not mute a claim in another")
    func throttleIsPerPort() {
        var t = PresenceThrottle(interval: 5)
        let a = t.allow(port: "A", now: t0)
        let b = t.allow(port: "B", now: t0)
        #expect(a && b)
    }

    @Test("forget resets a port's throttle, so a reused id claims immediately")
    func throttleForget() {
        var t = PresenceThrottle(interval: 5)
        _ = t.allow(port: "P", now: t0)
        t.forget(port: "P")
        let again = t.allow(port: "P", now: t0.addingTimeInterval(0.1))
        #expect(again)
    }

    // MARK: - The peer-qualified holder (decision-identity-model.md)

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
        var r = DriverRegistry()
        let localGordon = ActorRef(principal: "user-gordon")
        let remoteGordon = ActorRef(peer: "12D3KooW", principal: "user-gordon")
        r.record(port: "P", actor: localGordon, name: "gordon", now: t0)
        // Same person, other machine: still a CHANGE of driver, not a refresh. A bare principal id
        // would have called it the same actor, so the chrome would never have said which device is
        // driving — and R6's turn-scoped release would clear the wrong one.
        guard case .changed = r.record(port: "P", actor: remoteGordon, name: "gordon@laptop", now: t0) else {
            Issue.record("a remote instance must not be mistaken for the local driver"); return
        }
        #expect(r.driver(of: "P", now: t0)?.ref == remoteGordon)
    }
}
