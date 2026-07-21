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

    // MARK: - reorder (Step 2)

    private func ordered(_ names: [String]) -> [Space] {
        names.enumerated().map { i, n in var s = Space.create(name: n); s.sortIndex = i; return s }
    }

    @Test("insert into the gap before the target (a before c → 2nd)")
    func reorderInsertBefore() {
        let s = ordered(["a", "b", "c", "d"])
        let out = Space.reorder(s, moving: s[0].id, to: s[2].id)   // a into the gap before c
        #expect(out.map(\.name) == ["b", "a", "c", "d"])
        #expect(out.map(\.sortIndex) == [0, 1, 2, 3])
    }

    @Test("gap before a LATER tile lands further right (a before d → 3rd)")
    func reorderInsertBeforeLater() {
        let s = ordered(["a", "b", "c", "d"])
        let out = Space.reorder(s, moving: s[0].id, to: s[3].id)   // a into the gap before d
        #expect(out.map(\.name) == ["b", "c", "a", "d"])
    }

    @Test("the end sentinel (target matches no space) appends")
    func reorderAppendEnd() {
        let s = ordered(["a", "b", "c", "d"])
        let out = Space.reorder(s, moving: s[0].id, to: "__reorder_end__")
        #expect(out.map(\.name) == ["b", "c", "d", "a"])
    }

    @Test("backward: c into the gap before a → first")
    func reorderBackward() {
        let s = ordered(["a", "b", "c", "d"])
        let out = Space.reorder(s, moving: s[2].id, to: s[0].id)
        #expect(out.map(\.name) == ["c", "a", "b", "d"])
        #expect(out.map(\.sortIndex) == [0, 1, 2, 3])
    }

    @Test("reorder is a no-op for equal or unknown ids")
    func reorderNoOp() {
        let s = ordered(["a", "b"])
        #expect(Space.reorder(s, moving: s[0].id, to: s[0].id).map(\.name) == ["a", "b"])
        #expect(Space.reorder(s, moving: "ghost", to: s[0].id).map(\.name) == ["a", "b"])
    }

    @Test("reorderSpaces persists the new order to the DB")
    @MainActor
    func reorderPersists() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        for sp in ordered(["a", "b", "c"]) { try db.saveSpace(sp) }
        state.spaces = try db.getRegularSpaces()                  // [a, b, c]
        let c = state.spaces[2], a = state.spaces[0]
        state.reorderSpaces(moving: c.id, to: a.id)               // c in front of a
        #expect(state.spaces.map(\.name) == ["c", "a", "b"])
        #expect(state.spaces.map(\.sortIndex) == [0, 1, 2])
        #expect(try db.getRegularSpaces().map(\.name) == ["c", "a", "b"])   // survives a reload
    }

}
