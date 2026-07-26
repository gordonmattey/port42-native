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
        Principal(id: id, displayName: id, spaceId: nil, kind: .companion)
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
        #expect(state.portActivity.seq(for: udid) == 1)
    }

    @Test("a CURRENT token succeeds")
    func currentTokenSucceeds() async throws {
        let (state, id, udid) = try makeWorld()
        try await rename(state, id, "first", expect: state.portActivity.token(for: udid))
        #expect(state.portWindows.panels.first(where: { $0.id == id })?.userTitle == "first")
    }

    @Test("a STALE token is refused, and the port is left alone")
    func staleTokenRefused() async throws {
        let (state, id, udid) = try makeWorld()
        let composed = state.portActivity.token(for: udid)   // what a slow writer read
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
        let composed = state.portActivity.token(for: udid)
        try await rename(state, id, "moved", by: "bob")

        do {
            try await rename(state, id, "stale", by: "alice", expect: composed)
            Issue.record("expected the stale write to be refused")
        } catch let e as BridgeError {
            #expect(e.code == PortActivity.staleCode)
            #expect(e.details["current"] == state.portActivity.token(for: udid))
            // And it reaches the caller in BOTH renderings: JSON for code, prose for a companion.
            let json = e.toJSONObject() as? [String: Any]
            #expect(json?["current"] as? String == state.portActivity.token(for: udid))
            let text = (e.toToolBlocks().first?["text"] as? String) ?? ""
            #expect(text.contains("current:"))
        }
    }

    @Test("conflict → retry with the returned token → success, in ONE extra round trip")
    func selfCorrectsInOneRetry() async throws {
        let (state, id, udid) = try makeWorld()
        let composed = state.portActivity.token(for: udid)
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
        let composed = state.portActivity.token(for: udid)
        try await rename(state, id, "moved", by: "bob")
        let afterBob = state.portActivity.seq(for: udid)

        try? await rename(state, id, "stale", by: "alice", expect: composed)
        #expect(state.portActivity.seq(for: udid) == afterBob,
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
        #expect(mine?["token"] as? String == state.portActivity.token(for: udid))
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
