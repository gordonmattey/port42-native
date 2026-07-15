import Testing
import Foundation
@testable import Port42Lib

/// ⌘` port cycling + shell-global chords (docs/plan-working-set.md §B) Tier A gate.
///
/// Same headless harness as `ShellStateTests`. The cycle core is MRU-by-z over the desktop's
/// tiles with a BURST: chords < 1s apart walk an order snapshotted at the first tap, and the
/// burst commits exactly ONE MRU update (z stamp) when it ends.
@Suite("⌘` port cycling")
struct PortCycleTests {

    @MainActor
    private func makeState() throws -> (ShellState, AppState) {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        return (ShellState(appState: state), state)
    }

    /// Three tiles on one space with ascending z (c is frontmost → MRU order [c, b, a]).
    @MainActor
    private func seedTiles(_ shell: ShellState, _ state: AppState) -> Space {
        let space = Space.create(name: "main")
        state.spaces = [space]; state.currentSpace = space
        for (i, id) in ["a", "b", "c"].enumerated() {
            _ = state.portWindows.registerTiledPort(id: id, html: "<title>\(id)</title><div/>",
                                                    spaceId: space.id, createdBy: nil, title: nil,
                                                    position: nil)
            state.portWindows.setZ(id: id, z: i + 1)
        }
        shell.seedZCounter(from: state.portWindows.panels)
        return space
    }

    // MARK: pure math

    @Test("cycleNext wraps in both directions")
    func cycleNextWraps() {
        #expect(ShellState.cycleNext(count: 3, index: 0, forward: true) == 1)
        #expect(ShellState.cycleNext(count: 3, index: 2, forward: true) == 0)    // wrap down
        #expect(ShellState.cycleNext(count: 3, index: 0, forward: false) == 2)   // wrap up
        #expect(ShellState.cycleNext(count: 2, index: 1, forward: true) == 0)    // 2-tile bounce
        #expect(ShellState.cycleNext(count: 0, index: 0, forward: true) == 0)    // empty → safe
    }

    // MARK: chord classification (the yield bypass — pure)

    @Test("⌘`/⇧⌘`/⌘1…9/⌘K classify as shell-global; everything else stays yielded")
    func chordClassification() {
        typealias S = ShellState
        // Backtick by keyCode (ANSI 50) and by character (layout-proof), shift = reverse.
        #expect(S.shellGlobalChord(keyCode: 50, characters: "`", command: true, shift: false, option: false, control: false) == .cycleForward)
        #expect(S.shellGlobalChord(keyCode: 50, characters: "~", command: true, shift: true, option: false, control: false) == .cycleBackward)
        #expect(S.shellGlobalChord(keyCode: 10, characters: "`", command: true, shift: false, option: false, control: false) == .cycleForward)   // ISO key
        // ⌘digits → working-space jump, 0-based.
        #expect(S.shellGlobalChord(keyCode: 18, characters: "1", command: true, shift: false, option: false, control: false) == .jumpSpace(0))
        #expect(S.shellGlobalChord(keyCode: 25, characters: "9", command: true, shift: false, option: false, control: false) == .jumpSpace(8))
        // ⌘K → switcher.
        #expect(S.shellGlobalChord(keyCode: 40, characters: "k", command: true, shift: false, option: false, control: false) == .quickSwitcher)
        // NOT chords: no ⌘; ⌘0; ⇧⌘K; ⌘⌥1 (option combos belong to apps); plain backtick; ⌘V; Esc.
        #expect(S.shellGlobalChord(keyCode: 50, characters: "`", command: false, shift: false, option: false, control: false) == nil)
        #expect(S.shellGlobalChord(keyCode: 29, characters: "0", command: true, shift: false, option: false, control: false) == nil)
        #expect(S.shellGlobalChord(keyCode: 40, characters: "k", command: true, shift: true, option: false, control: false) == nil)
        #expect(S.shellGlobalChord(keyCode: 18, characters: "1", command: true, shift: false, option: true, control: false) == nil)
        #expect(S.shellGlobalChord(keyCode: 9, characters: "v", command: true, shift: false, option: false, control: false) == nil)
        #expect(S.shellGlobalChord(keyCode: 53, characters: nil, command: false, shift: false, option: false, control: false) == nil)
    }

    // MARK: the burst

    @Test("a burst snapshots the order at the first tap: the third tap reaches the third tile")
    @MainActor
    func burstReachesThirdTile() throws {
        let (shell, state) = try makeState()
        _ = seedTiles(shell, state)                      // MRU [c, b, a]
        let t0 = Date()

        shell.cycleStep(forward: true, now: t0)                          // → b
        #expect(shell.selectedTileId == "b")
        shell.cycleStep(forward: true, now: t0.addingTimeInterval(0.4))  // → a (snapshot walk)
        #expect(shell.selectedTileId == "a")
        shell.cycleStep(forward: true, now: t0.addingTimeInterval(0.8))  // → wraps to c
        #expect(shell.selectedTileId == "c")

        // No z stamps yet — intermediates never pollute the MRU order.
        let zc = state.portWindows.panels.first { $0.id == "c" }!.z
        #expect(zc == 3)
    }

    @Test("the burst commits ONE MRU update: only the final landing gets the top z stamp")
    @MainActor
    func burstCommitsOnce() throws {
        let (shell, state) = try makeState()
        _ = seedTiles(shell, state)                      // z: a=1 b=2 c=3
        let t0 = Date()

        shell.cycleStep(forward: true, now: t0)                          // → b
        shell.cycleStep(forward: true, now: t0.addingTimeInterval(0.5))  // → a
        shell.commitCycleBurst()                                          // burst ends

        let z = { (id: String) in state.portWindows.panels.first { $0.id == id }!.z }
        #expect(z("a") > z("c"))                          // final landing stamped frontmost
        #expect(z("b") == 2)                              // intermediate untouched
        #expect(shell.cycleBoostId == nil)                // transient boost cleared

        // Next tap = a NEW burst over the committed order [a, c, b]: one tap bounces to c.
        shell.cycleStep(forward: true, now: t0.addingTimeInterval(10))
        #expect(shell.selectedTileId == "c")
    }

    @Test("separated taps bounce between the two hot ports (macOS ⌘` feel)")
    @MainActor
    func separatedTapsBounce() throws {
        let (shell, state) = try makeState()
        _ = seedTiles(shell, state)                      // MRU [c, b, a]
        var t = Date()

        shell.cycleStep(forward: true, now: t); shell.commitCycleBurst() // → b, committed
        #expect(shell.selectedTileId == "b")
        t = t.addingTimeInterval(10)
        shell.cycleStep(forward: true, now: t); shell.commitCycleBurst() // → back to c
        #expect(shell.selectedTileId == "c")
        t = t.addingTimeInterval(10)
        shell.cycleStep(forward: true, now: t); shell.commitCycleBurst() // → b again: the bounce
        #expect(shell.selectedTileId == "b")
        _ = state                                          // keep state alive through the run
    }

    @Test("⇧⌘` walks the snapshot the other way")
    @MainActor
    func backwardReverses() throws {
        let (shell, state) = try makeState()
        _ = seedTiles(shell, state)                      // snapshot [c, b, a], start at c
        let t0 = Date()
        shell.cycleStep(forward: false, now: t0)                          // backward wraps → a
        #expect(shell.selectedTileId == "a")
        shell.cycleStep(forward: false, now: t0.addingTimeInterval(0.4))  // → b
        #expect(shell.selectedTileId == "b")
    }

    @Test("a tile closed mid-burst is skipped, not landed on")
    @MainActor
    func deadIdSkipped() throws {
        let (shell, state) = try makeState()
        _ = seedTiles(shell, state)                      // snapshot [c, b, a]
        let t0 = Date()
        shell.cycleStep(forward: true, now: t0)                          // → b
        state.portWindows.close("a")                                      // a dies mid-burst
        shell.cycleStep(forward: true, now: t0.addingTimeInterval(0.4))  // a skipped → wraps to c
        #expect(shell.selectedTileId == "c")
    }

    // MARK: the two rungs

    @Test("at .focus a step swaps the focused unit in place — never bounces out to .space")
    @MainActor
    func focusSwapsInPlace() throws {
        let (shell, state) = try makeState()
        _ = seedTiles(shell, state)
        shell.zoom = .focus("c")
        shell.cycleStep(forward: true, now: Date())
        #expect(shell.zoom == .focus("b"))               // swapped, still on the focus rung
        _ = state
    }

    @Test("cycling starts from the unit you're ON (focused), not the frontmost z")
    @MainActor
    func startsFromCurrentUnit() throws {
        let (shell, state) = try makeState()
        _ = seedTiles(shell, state)                      // MRU [c, b, a]
        shell.zoom = .focus("b")                          // focused ≠ frontmost
        shell.cycleStep(forward: true, now: Date())      // next after b in [c,b,a] is a
        #expect(shell.zoom == .focus("a"))
        _ = state
    }

    @Test("cycling is a desktop gesture: no-op at .galaxy; no-op with fewer than two tiles")
    @MainActor
    func guardsRungsAndCount() throws {
        let (shell, state) = try makeState()
        _ = seedTiles(shell, state)
        shell.zoom = .galaxy
        shell.cycleStep(forward: true, now: Date())
        #expect(shell.selectedTileId == nil)

        let (shell2, state2) = try makeState()
        let space = Space.create(name: "solo")
        state2.spaces = [space]; state2.currentSpace = space
        _ = state2.portWindows.registerTiledPort(id: "only", html: "<div/>", spaceId: space.id,
                                                 createdBy: nil, title: nil, position: nil)
        shell2.zoom = .space
        shell2.cycleStep(forward: true, now: Date())
        #expect(shell2.selectedTileId == nil)             // one tile → nothing to cycle
    }
}
