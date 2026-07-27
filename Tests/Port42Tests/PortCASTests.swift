import Testing
import Foundation
@testable import Port42Lib

/// R3 — compare-and-swap at the dispatch seam.
///
/// The first step in this phase that REFUSES anything, and the replacement for the lock R1 removed.
/// A writer may declare the state it composed against; if the port has moved since, the write is
/// refused and told what the current state IS, so the retry is a fact rather than a guess.
@Suite("Port CAS (R3)")
@MainActor
struct PortCASTests {

    func makeWorld() throws -> (AppState, String, String) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let id = "cas-target-1"
        _ = state.portWindows.registerInlinePort(
            id: id, html: "<html><body>hi</body></html>",
            spaceId: nil, createdBy: nil, title: "t", anchorMessageId: nil)
        let udid = state.portWindows.panels.first(where: { $0.id == id })!.udid
        return (state, id, udid)
    }

    func principal(_ id: String) -> Principal {
        Principal.companion(id: id, displayName: id, spaceId: nil)
    }

    func rename(_ state: AppState, _ id: String, _ title: String,
                by who: String = "alice", expect: String? = nil) async throws {
        var a: [String: Any] = ["id": id, "title": title]
        if let expect { a[PortActivity.expectParam] = expect }
        _ = try await state.runBridgeMethod("port.rename", principal: principal(who), args: BridgeArgs(a))
    }

    // MARK: - The three behaviours the gate names

    @Test("an ABSENT token still succeeds — nothing that works today breaks")
    func absentTokenIsAllowed() async throws {
        let (state, id, udid) = try makeWorld()
        try await rename(state, id, "no token")
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "no token")
        #expect(state.portInput.seq(for: udid) == 1)
    }

    @Test("a CURRENT token succeeds")
    func currentTokenSucceeds() async throws {
        let (state, id, udid) = try makeWorld()
        try await rename(state, id, "first", expect: state.portInput.token(for: udid))
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "first")
    }

    @Test("a STALE token is refused, and the port is left alone")
    func staleTokenRefused() async throws {
        let (state, id, udid) = try makeWorld()
        let composed = state.portInput.token(for: udid)   // what a slow writer read
        try await rename(state, id, "someone else got there", by: "bob")   // the port moves

        await #expect(throws: BridgeError.self) {
            try await rename(state, id, "stale write", by: "alice", expect: composed)
        }
        // Refused means REFUSED: the body never ran.
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "someone else got there")
    }

    @Test("the refusal CARRIES current — without it the caller cannot converge")
    func refusalCarriesCurrent() async throws {
        let (state, id, udid) = try makeWorld()
        let composed = state.portInput.token(for: udid)
        try await rename(state, id, "moved", by: "bob")

        do {
            try await rename(state, id, "stale", by: "alice", expect: composed)
            Issue.record("expected the stale write to be refused")
        } catch let e as BridgeError {
            #expect(e.code == PortActivity.staleCode)
            #expect(e.details["current"] == state.portInput.token(for: udid))
            // And it reaches the caller in BOTH renderings: JSON for code, prose for a companion.
            let json = e.toJSONObject() as? [String: Any]
            #expect(json?["current"] as? String == state.portInput.token(for: udid))
            let text = (e.toToolBlocks().first?["text"] as? String) ?? ""
            #expect(text.contains("current:"))
        }
    }

    @Test("conflict → retry with the returned token → success, in ONE extra round trip")
    func selfCorrectsInOneRetry() async throws {
        let (state, id, udid) = try makeWorld()
        let composed = state.portInput.token(for: udid)
        try await rename(state, id, "moved", by: "bob")

        var recovered = false
        do {
            try await rename(state, id, "mine", by: "alice", expect: composed)
        } catch let e as BridgeError {
            // The whole point of carrying `current`: a naive caller retries with what it was handed
            // and does NOT need to re-read the port.
            try await rename(state, id, "mine", by: "alice", expect: e.details["current"])
            recovered = true
        }
        #expect(recovered)
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "mine")
    }

    @Test("a refused write does NOT bump — a rejection must not invalidate the next writer")
    func refusalDoesNotBump() async throws {
        let (state, id, udid) = try makeWorld()
        let composed = state.portInput.token(for: udid)
        try await rename(state, id, "moved", by: "bob")
        let afterBob = state.portInput.seq(for: udid)

        try? await rename(state, id, "stale", by: "alice", expect: composed)
        #expect(state.portInput.seq(for: udid) == afterBob,
                "a refused write bumped the token, so every other writer was invalidated by a write that never happened")
    }

    // MARK: - The token has to be readable, or none of the above is usable

    @Test("ports.list carries each port's token — read and write in one round trip")
    func listCarriesToken() async throws {
        let (state, id, udid) = try makeWorld()
        try await rename(state, id, "x")
        let out = try await state.runBridgeMethod("ports.list", principal: principal("alice"),
                                                  args: BridgeArgs([:]))
        let arr = (out.toJSONObject() as? [[String: Any]]) ?? []
        let mine = arr.first { ($0["id"] as? String) == udid || ($0["id"] as? String) == id }
        #expect(mine?["token"] as? String == state.portInput.token(for: udid))
    }

    // MARK: - The key (review finding, 2026-07-26)

    @Test("an INLINE-only port is CAS-protected too — nil id and nil udid is not 'no port'")
    func inlinePortsHaveAKey() {
        // A `port` fence before adoption resolves with id AND udid nil, only messageId set. The key
        // was `udid ?? id`, so it came out nil — and the dispatcher's whole write block (token bump,
        // presence, CAS) is `if let key`, so ALL of it was skipped for a real, writable surface.
        let inline = PortRef(kind: .web, spaceId: nil, id: nil, udid: nil, messageId: "msg-1")
        #expect(PortRef.key(inline) == "msg-1")
        // The ordinary shapes are unchanged: udid wins, then id.
        #expect(PortRef.key(PortRef(kind: .web, spaceId: nil, id: "i", udid: "u", messageId: "m")) == "u")
        #expect(PortRef.key(PortRef(kind: .terminal, spaceId: nil, id: "t", udid: nil, messageId: nil)) == "t")
    }

    @Test("no Notify topic hand-rolls the port key from a resolved ref")
    func notifyTopicsUseTheOneKey() throws {
        // A first version of this test banned `udid ?? ` everywhere and turned up ten hits — which
        // proved the finding was imprecise, not that the codebase was ten times worse. That
        // expression serves TWO different jobs:
        //
        //   the per-port KEY  (Notify topic / activity token / presence) = udid ?? id ?? messageId
        //   the DB udid       (fetchPortHtml, port_versions, restore)    = udid, aliased ?? id
        //
        // They are not the same and must not be unified: a DB read keyed on a messageId would miss,
        // and a topic keyed on the caller's raw alias splits publisher from subscriber. So this
        // pins only the one that has to agree with the token — the Notify topic.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") where line.contains("\"port:\\(") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") || t.hasPrefix("///") { continue }
                // A ref in scope must go through `.key`; a topic built from a plain local id is
                // fine (the caller already resolved it).
                if t.contains("ref") && !t.contains(".key") {
                    offenders.append("\(url.lastPathComponent): \(t)")
                }
            }
        }
        #expect(offenders.isEmpty, "Notify topics not using PortRef.key: \(offenders.joined(separator: " | "))")
    }

    // MARK: - The declaration cannot rot

    @Test("EVERY write verb accepts expect, and no read verb does")
    func expectIsUniversalOnWrites() throws {
        let db = try DatabaseService(inMemory: true)
        let registry = buildBridgeRegistry(AppState(db: db))
        for (name, m) in registry {
            let hasExpect = m.paramNames.contains(PortActivity.expectParam)
            if m.writesTarget != nil {
                #expect(hasExpect, "\(name) writes but cannot be given a token")
                // Appended, never inserted: `BridgeArgs(positional:names:)` maps in order, so any
                // other position would silently reassign an existing positional JS caller's args.
                #expect(m.paramNames.last == PortActivity.expectParam,
                        "\(name) must take expect LAST or it breaks positional callers")
            } else {
                #expect(!hasExpect, "\(name) is a read and must not advertise a write token")
            }
        }
    }
}
