import Testing
import Foundation
@testable import Port42Lib

/// Backlog 3.6, Step 1: the persistent space sort order that drives the galaxy front and ⌘1–9
/// (distinct from the ⌘K recency axis, 0.6). The pure `nextSortIndex` and the `getRegularSpaces`
/// ordering; the drag gesture is Step 2.
@Suite("Space sort order (3.6)")
struct SpaceSortIndexTests {

    @Test("nextSortIndex is max+1, and 0 for an empty set")
    func nextSortIndexIsMaxPlusOne() {
        #expect(Space.nextSortIndex(after: []) == 0)
        var a = Space.create(name: "a"); a.sortIndex = 5
        var b = Space.create(name: "b"); b.sortIndex = 2
        #expect(Space.nextSortIndex(after: [a, b]) == 6)
    }

    @Test("getRegularSpaces orders by sortIndex, createdAt as the tiebreak")
    func ordersBySortIndex() throws {
        let db = try DatabaseService(inMemory: true)
        var a = Space.create(name: "a"); a.sortIndex = 2
        var b = Space.create(name: "b"); b.sortIndex = 0
        var c = Space.create(name: "c"); c.sortIndex = 1
        try db.saveSpace(a); try db.saveSpace(b); try db.saveSpace(c)
        #expect(try db.getRegularSpaces().map(\.name) == ["b", "c", "a"])
    }

    @Test("sortIndex round-trips through save/fetch")
    func sortIndexPersists() throws {
        let db = try DatabaseService(inMemory: true)
        var s = Space.create(name: "s"); s.sortIndex = 7
        try db.saveSpace(s)
        #expect(try db.getRegularSpaces().first?.sortIndex == 7)
    }
}
