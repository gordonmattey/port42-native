import Testing
import Foundation
@testable import Port42Lib

/// SHELL — S2 test gate: the zoom ladder (galaxy ↔ space ↔ focus).
///
/// `ShellState` (the shell-only UI `ObservableObject` — zoom level, idle, parallax, pinch latch) does
/// not exist yet; it lands in S2 (`spec-shell-reimplementation.md` §3.2). These tests are stubbed
/// `.disabled` so the suite compiles and the gate is visible in the test list — fill in each body and
/// drop the trait as `ShellState` comes online. The zoom ladder is *pure state* (no window, no webview),
/// so it is fully unit-testable headlessly, same harness as `RegisteredInlinePortTests`
/// (`DatabaseService(inMemory: true)` → `AppState`).
@Suite("Shell zoom ladder")
struct ShellStateTests {

    @Test("⌘↑/pinch-out steps focus → space → galaxy, one rung per gesture",
          .disabled("S2 — ShellState not implemented yet"))
    @MainActor
    func zoomsOutOneRungPerStep() throws {
        // TODO(S2): from .focus(id), one zoom-out → .space; again → .galaxy; the pinch latch fires
        // exactly once per gesture (no multi-rung jumps).
    }

    @Test("⌘↓/pinch-in steps galaxy → space → focus(selected)",
          .disabled("S2 — ShellState not implemented yet"))
    @MainActor
    func zoomsInOneRungPerStep() throws {
        // TODO(S2): from .galaxy, zoom-in → .space; again → .focus(selectedPort). Hover-dive in galaxy
        // enters the hovered space.
    }

    @Test("zoom clamps at the ends (galaxy is the ceiling, focus is the floor)",
          .disabled("S2 — ShellState not implemented yet"))
    @MainActor
    func clampsAtBounds() throws {
        // TODO(S2): zoom-out at .galaxy stays .galaxy; zoom-in at .focus stays .focus. No wraparound.
    }

    @Test("⌘1…N jumps directly to the Nth space and lands on its desktop rung",
          .disabled("S2 — ShellState not implemented yet"))
    @MainActor
    func numberKeyJumpsSpace() throws {
        // TODO(S2): ⌘k selects appState.spaces[k-1] (switchToSpace) and sets zoom == .space, regardless
        // of the current rung.
    }
}
