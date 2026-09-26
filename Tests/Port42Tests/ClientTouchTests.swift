import Testing
import Foundation
@testable import Port42Lib

// Recording a client as seen is a database commit, and it ran on every gateway call on the main
// thread; with several agents calling at once, calls timed out behind those commits (Dev4,
// 2026-09-26). It is written at most once a minute per client, off the main thread.
@Suite("A client's last-seen is written at most once a minute")
@MainActor
struct ClientTouchTests {
    @Test("repeated calls within a minute write once; after a minute, again; each client on its own")
    func throttled() throws {
        let state = AppState(db: try DatabaseService(inMemory: true))
        let t = Date()
        #expect(state.touchClientIfDue("a", now: t))
        for i in 1...50 { #expect(!state.touchClientIfDue("a", now: t.addingTimeInterval(Double(i))), "wrote again at +\(i)s") }
        #expect(state.touchClientIfDue("b", now: t.addingTimeInterval(5)))
        #expect(state.touchClientIfDue("a", now: t.addingTimeInterval(61)))
    }
}
