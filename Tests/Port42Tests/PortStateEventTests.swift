import Testing
import Foundation
@testable import Port42Lib

/// G1 · a subscriber is told when a port's STATE changed.
///
/// **The gap, measured 2026-08-01.** `port.subscribe` exists so something can WATCH a port, and
/// `PortEventKind` had sixteen cases — console, push, presentation, driver, filedrop,
/// terminal.output, browser.*, screen.frame, camera.frame, audio.*, message, companion.activity —
/// and not one meaning "this port's state was replaced". The only publish on the write path was
/// `broadcastDriverChange`, which returns early for a refresh **on purpose**: "publishing per
/// keystroke would drown the topic in non-news".
///
/// So a host patching their own port twice emitted one driver event at most, and possibly none. A
/// watcher saw console output, pushes and device frames, and could not see the port's content
/// change. That undercuts the reason OUTPUT was built at all (§10c: "an agent cannot watch a port
/// was a hole in the product regardless of libp2p").
///
/// **THE TRAP this suite exists to hold:** the driver rule's suppression must NOT be inherited. A
/// refresh is non-news for a driver chip and is exactly the news for a subscriber. The two live one
/// line apart, which is what makes copying the wrong one easy.
@Suite("A port's state change is observable (G1)")
@MainActor
struct PortStateEventTests {

    func makeWorld() throws -> (AppState, String, String) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let id = "state-target-1"
        _ = state.portWindows.registerTiledPort(
            id: id, html: "<html><body>hi</body></html>",
            spaceId: nil, createdBy: nil, title: "t", position: nil)
        let udid = state.portWindows.panels.first(where: { $0.id == id })!.udid
        return (state, id, udid)
    }

    func principal(_ id: String = "alice") -> Principal {
        Principal.companion(id: id, displayName: id, spaceId: nil)
    }

    /// Everything that lands on the port's topic, decoded far enough to see kind and token.
    final class Collector {
        var kinds: [String] = []
        var tokens: [String?] = []
        var states: Int { kinds.filter { $0 == PortEventKind.state.wire }.count }
    }

    @discardableResult
    func collect(_ state: AppState, key: String, into c: Collector) -> Int {
        state.notifyBus.subscribe(topic: PortNotify.topic(forPortKey: key)) { json in
            guard let d = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let kind = obj["kind"] as? String else { return }
            c.kinds.append(kind)
            c.tokens.append(obj["token"] as? String)
        }
    }

    func rename(_ state: AppState, _ id: String, _ title: String,
                by who: String = "alice", expect: String?? = nil) async throws {
        var a: [String: Any] = ["id": id, "title": title]
        let key = state.portWindows.panels.first(where: { $0.id == id })?.udid ?? id
        let resolved: String? = expect ?? state.portInput.token(for: key)
        if let resolved { a[PortActivity.expectParam] = resolved }
        _ = try await state.runBridgeMethod("port.rename", principal: principal(who), args: BridgeArgs(a))
    }

    @Test("a state kind exists, declared rather than spelled at a publish site")
    func stateKindExists() {
        #expect(PortEventKind.state.wire == "state")
        #expect(PortEventKind.allCases.contains(.state))
    }

    @Test("a write publishes a state event carrying the port's token")
    func writePublishesState() async throws {
        let (state, id, udid) = try makeWorld()
        let c = Collector()
        collect(state, key: udid, into: c)

        try await rename(state, id, "renamed once")

        #expect(c.states == 1, "a state write must announce itself once; saw \(c.kinds)")
        // The token on the event is what a subscriber re-reads against, so it must be the state
        // AFTER the write, not the one it composed against.
        let after = state.portInput.token(for: udid)
        let stateTokens = zip(c.kinds, c.tokens).filter { $0.0 == PortEventKind.state.wire }.map(\.1)
        #expect(stateTokens.first ?? nil == after)
    }

    @Test("TWO writes by the SAME actor both publish — the driver rule is not inherited")
    func consecutiveWritesBothPublish() async throws {
        // The trap. `broadcastDriverChange` says nothing on a refresh because a driver chip does not
        // want per-keystroke news. A subscriber does: the second write is the change it watches for.
        let (state, id, udid) = try makeWorld()
        let c = Collector()
        collect(state, key: udid, into: c)

        try await rename(state, id, "first")
        try await rename(state, id, "second")

        #expect(c.states == 2,
                "the second write by the same actor was suppressed — the driver rule leaked in")
    }

    @Test("a READ publishes nothing")
    func readPublishesNothing() async throws {
        let (state, id, udid) = try makeWorld()
        let c = Collector()
        collect(state, key: udid, into: c)

        // Any read will do; `ports.list` needs no live DB row, and what is under test is that a
        // method with no `writesTarget` reaches the guard and announces nothing.
        _ = try await state.runBridgeMethod("ports.list", principal: principal(), args: BridgeArgs([:]))
        _ = id

        #expect(c.states == 0, "a read announced a state change")
    }

    @Test("a REFUSED write announces nothing")
    func refusedWriteAnnouncesNothing() async throws {
        // A refused write never landed. Announcing it would send every subscriber to re-read for a
        // change that did not happen, and would make the token they see disagree with the port.
        let (state, id, udid) = try makeWorld()
        let c = Collector()
        collect(state, key: udid, into: c)

        await #expect(throws: BridgeError.self) {
            try await rename(state, id, "refused", expect: "0:0")   // stale on purpose
        }
        #expect(c.states == 0, "a refused write announced a change that never happened")
    }
}
