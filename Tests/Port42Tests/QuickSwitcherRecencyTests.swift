import Testing
import Foundation
@testable import Port42Lib

// Backlog 0.6: the ⌘K empty-query list opens on where you were (most-recently-visited first), and
// the recency survives restart. The ordering is a pure function, tested decisively here; the
// UserDefaults persistence is exercised by markSpaceRead.

@Suite("Quick switcher recency")
struct QuickSwitcherRecencyTests {

    private func space(_ id: String) -> Space {
        Space(id: id, name: id.uppercased(), type: "team", createdAt: Date(timeIntervalSince1970: 1_000_000))
    }

    @Test("most-recently-visited first, unvisited keep their original order")
    @MainActor
    func recencyOrder() {
        let spaces = ["a", "b", "c", "d"].map(space)
        let lastRead: [String: Date] = [
            "a": Date(timeIntervalSince1970: 100),   // visited, older
            "c": Date(timeIntervalSince1970: 200),   // visited, newer
        ]
        let ordered = AppState.spacesByRecency(spaces, lastRead: lastRead).map(\.id)
        // c (newest visit), a (older visit), then the unvisited b, d in their incoming order.
        #expect(ordered == ["c", "a", "b", "d"])
    }

    @Test("all unvisited preserves the incoming (createdAt) order")
    @MainActor
    func allUnvisited() {
        let spaces = ["a", "b", "c"].map(space)
        let ordered = AppState.spacesByRecency(spaces, lastRead: [:]).map(\.id)
        #expect(ordered == ["a", "b", "c"])
    }

    @Test("a newly visited space jumps to the front")
    @MainActor
    func newVisitJumpsToFront() {
        let spaces = ["a", "b", "c"].map(space)
        let lastRead: [String: Date] = [
            "a": Date(timeIntervalSince1970: 100),
            "b": Date(timeIntervalSince1970: 300),   // most recent
            "c": Date(timeIntervalSince1970: 200),
        ]
        let ordered = AppState.spacesByRecency(spaces, lastRead: lastRead).map(\.id)
        #expect(ordered == ["b", "c", "a"])
    }

    @Test("markSpaceRead records the visit time")
    @MainActor
    func markRecordsVisit() throws {
        // Hermetic: markSpaceRead persists to the test process's UserDefaults, so a fresh AppState
        // loads whatever a prior run left. Clear the key, then assert the delta (the visit is set).
        UserDefaults.standard.removeObject(forKey: "spaceLastReadDates")
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let id = "recency-test-space"
        #expect(state.lastReadDates[id] == nil)
        state.markSpaceRead(id)
        #expect(state.lastReadDates[id] != nil, "the visit is recorded for MRU sorting")
        UserDefaults.standard.removeObject(forKey: "spaceLastReadDates")
    }
}
