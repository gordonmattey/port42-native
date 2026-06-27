import Testing
import Foundation
@testable import Port42Lib

/// Step 3 of first-class terminal ports: `terminal_send`/`terminal_list` resolve a caller's
/// id-or-name onto a native Ghostty controller. Controllers need a live surface to construct, so
/// the resolution rule is split into a pure matcher (`AppState.resolveTerminalId`) tested here.
@Suite("Terminal resolver — id/name → controller id")
struct TerminalResolverTests {

    private let candidates: [(id: String, name: String)] = [
        (id: "AAAA-1111", name: "claude9"),
        (id: "BBBB-2222", name: "bash-build"),
        (id: "CCCC-3333", name: "htop monitor")
    ]

    @Test("exact id hit wins even when the query also matches a name")
    func idHitWins() {
        // A query equal to an id resolves to that id, never falling through to a name scan.
        #expect(AppState.resolveTerminalId("BBBB-2222", candidates: candidates) == "BBBB-2222")
    }

    @Test("exact name match (case-insensitive) resolves to its id")
    func exactName() {
        #expect(AppState.resolveTerminalId("Claude9", candidates: candidates) == "AAAA-1111")
    }

    @Test("substring name match resolves to its id")
    func containsName() {
        #expect(AppState.resolveTerminalId("htop", candidates: candidates) == "CCCC-3333")
    }

    @Test("exact name is preferred over a substring match")
    func exactBeatsContains() {
        let cands = [(id: "X", name: "build"), (id: "Y", name: "build-step-2")]
        #expect(AppState.resolveTerminalId("build", candidates: cands) == "X")
    }

    @Test("no match returns nil")
    func notFound() {
        #expect(AppState.resolveTerminalId("nope", candidates: candidates) == nil)
    }

    @Test("empty candidates returns nil")
    func emptyCandidates() {
        #expect(AppState.resolveTerminalId("claude9", candidates: []) == nil)
    }
}
