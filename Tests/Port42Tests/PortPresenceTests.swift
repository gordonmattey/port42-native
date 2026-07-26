import Testing
import Foundation
@testable import Port42Lib

/// L2.a — right-of-way, the pure layer (docs/plan-port42-protocol-local-bus.md §L2).
///
/// Headless by construction: `LeaseRegistry` takes `now` as a parameter, so expiry — the behaviour
/// most likely to be wrong — is tested by arithmetic instead of by sleeping.
@Suite("PortLease — right-of-way (L2.a)")
struct PortLeaseTests {

    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let human = ActorRef(principal: "user-gordon")
    let echo = ActorRef(principal: "companion-echo")

    // MARK: - The holder table

    @Test("a free port is acquired implicitly by whoever writes first")
    func acquiresWhenFree() {
        var r = LeaseRegistry()
        let d = r.check(port: "P", actor: human, name: "gordon", now: t0)
        guard case .granted(let lease) = d else { Issue.record("expected .granted, got \(d)"); return }
        #expect(lease.holder == human)
        #expect(lease.expires == t0.addingTimeInterval(LeaseRegistry.defaultTTL))
        #expect(r.holder(of: "P", now: t0)?.holder == human)
    }

    @Test("the holder's own writes refresh the TTL, and are NOT a change")
    func holderRefreshes() {
        var r = LeaseRegistry()
        r.check(port: "P", actor: human, name: "gordon", now: t0)
        let d = r.check(port: "P", actor: human, name: "gordon", now: t0.addingTimeInterval(5))
        guard case .refreshed(let lease) = d else { Issue.record("expected .refreshed, got \(d)"); return }
        // Distinct from .granted so the Notify broadcast can fire on CHANGE only (§L2.5).
        #expect(lease.expires == t0.addingTimeInterval(5 + LeaseRegistry.defaultTTL))
    }

    @Test("a second actor is denied, and the denial names the holder")
    func deniesOthers() {
        var r = LeaseRegistry()
        r.check(port: "P", actor: human, name: "gordon", now: t0)
        let d = r.check(port: "P", actor: echo, name: "echo", now: t0.addingTimeInterval(1))
        guard case .denied(let held) = d else { Issue.record("expected .denied, got \(d)"); return }
        #expect(held.holder == human)
        #expect(held.holderName == "gordon")     // the error can say WHO, not just "denied"
        #expect(r.holder(of: "P", now: t0.addingTimeInterval(1))?.holder == human)
    }

    @Test("an expired lease frees the port — a crashed holder cannot hold the pen forever")
    func expiryFrees() {
        var r = LeaseRegistry()
        r.check(port: "P", actor: human, name: "gordon", now: t0)
        let later = t0.addingTimeInterval(LeaseRegistry.defaultTTL + 1)
        #expect(r.holder(of: "P", now: later) == nil)
        let d = r.check(port: "P", actor: echo, name: "echo", now: later)
        guard case .granted(let lease) = d else { Issue.record("expected .granted, got \(d)"); return }
        #expect(lease.holder == echo)
    }

    @Test("ports are independent — holding one says nothing about another")
    func perPort() {
        var r = LeaseRegistry()
        r.check(port: "A", actor: human, name: "gordon", now: t0)
        let d = r.check(port: "B", actor: echo, name: "echo", now: t0)
        guard case .granted = d else { Issue.record("expected .granted on a different port"); return }
        #expect(r.holder(of: "A", now: t0)?.holder == human)
        #expect(r.holder(of: "B", now: t0)?.holder == echo)
    }

    // MARK: - Giving it up

    @Test("only the holder can release; a stray release is a no-op, not a way to knock them off")
    func releaseIsHolderOnly() {
        var r = LeaseRegistry()
        r.check(port: "P", actor: human, name: "gordon", now: t0)
        #expect(r.release(port: "P", actor: echo, now: t0) == false)
        #expect(r.holder(of: "P", now: t0)?.holder == human)
        #expect(r.release(port: "P", actor: human, now: t0) == true)
        #expect(r.holder(of: "P", now: t0) == nil)
    }

    @Test("handoff moves the pen, and only the holder may do it")
    func handoff() {
        var r = LeaseRegistry()
        r.check(port: "P", actor: human, name: "gordon", now: t0)
        // Not the holder → refused, so a knock cannot become a seizure.
        #expect(r.handoff(port: "P", from: echo, to: echo, toName: "echo", now: t0) == false)
        #expect(r.handoff(port: "P", from: human, to: echo, toName: "echo", now: t0) == true)
        #expect(r.holder(of: "P", now: t0)?.holder == echo)
        #expect(r.holder(of: "P", now: t0)?.holderName == "echo")
    }

    @Test("handing off a FREE port is refused — no assigning the pen behind someone's back")
    func handoffNeedsAHolder() {
        var r = LeaseRegistry()
        #expect(r.handoff(port: "P", from: human, to: echo, toName: "echo", now: t0) == false)
        #expect(r.holder(of: "P", now: t0) == nil)
    }

    @Test("forget drops the lease with the port (a close, not a release)")
    func forget() {
        var r = LeaseRegistry()
        r.check(port: "P", actor: human, name: "gordon", now: t0)
        r.forget(port: "P")
        #expect(r.holder(of: "P", now: t0) == nil)
    }

    // MARK: - L2.d.2: the interaction throttle

    // (`allow` is mutating, so each call is hoisted out of the #expect macro.)

    @Test("the FIRST interaction always claims — that is the moment it matters")
    func throttleAllowsFirst() {
        var t = ClaimThrottle(interval: 5)
        let first = t.allow(port: "P", now: t0)
        #expect(first)
    }

    @Test("a burst of keystrokes claims once, not per character")
    func throttleCollapsesABurst() {
        var t = ClaimThrottle(interval: 5)
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
        var t = ClaimThrottle(interval: 5)
        let a = t.allow(port: "A", now: t0)
        let b = t.allow(port: "B", now: t0)
        #expect(a && b)
    }

    @Test("forget resets a port's throttle, so a reused id claims immediately")
    func throttleForget() {
        var t = ClaimThrottle(interval: 5)
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

    @Test("the same principal at a DIFFERENT instance is a different holder")
    func peerQualificationMatters() {
        var r = LeaseRegistry()
        let localGordon = ActorRef(principal: "user-gordon")
        let remoteGordon = ActorRef(peer: "12D3KooW", principal: "user-gordon")
        r.check(port: "P", actor: localGordon, name: "gordon", now: t0)
        // Same person, other machine: still contention. Two devices must not silently co-write,
        // which is exactly what a bare principal id would have allowed.
        guard case .denied = r.check(port: "P", actor: remoteGordon, name: "gordon@laptop", now: t0) else {
            Issue.record("a remote instance must not inherit the local holder's pen"); return
        }
    }
}
