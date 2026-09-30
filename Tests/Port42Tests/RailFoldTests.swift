import Testing
import Foundation
@testable import Port42Lib

/// #192 (GM, 2026-09-29): a tile under the rail was lost behind it and could not be resized. The rail
/// folds to a thin edge, tiles are placed up to that edge, and it opens over them on hover and while a
/// tile is dragged, with a red dot on the edge when a running port needs you.
@Suite("Rail: folded out of the way, open when needed")
struct RailFoldTests {

    let area = CGSize(width: 1728, height: 1000)

    @Test("tiles are placed up to the folded edge, not the open rail")
    func workAreaReachesTheFoldedEdge() {
        let work = ShellPlacement.workArea(in: area)
        #expect(work.maxX == area.width - ShellState.railFoldedWidth - ShellPlacement.tileGap)
        #expect(work.maxX > area.width - ShellState.parkWidth(area.width), "tiles still stop at the open rail")
    }

    @Test("the rail is a thin edge folded and full width open")
    func widths() {
        #expect(ShellState.railWidth(open: false, screenW: area.width) == ShellState.railFoldedWidth)
        #expect(ShellState.railWidth(open: true, screenW: area.width) == ShellState.parkWidth(area.width))
        #expect(ShellState.railFoldedWidth <= 16)
    }

    @Test("dropping during a drag uses the open rail's zones")
    func dropZonesUseOpenWidth() {
        let x = area.width - ShellState.parkWidth(area.width) + 10     // inside the open rail, left of the edge
        #expect(ShellState.parkZone(at: CGPoint(x: x, y: 500), in: area) == .hide)
        #expect(ShellState.parkZone(at: CGPoint(x: x, y: 10), in: area) == .park)
        #expect(ShellState.parkZone(at: CGPoint(x: x, y: area.height - 10), in: area) == .close)
    }

    @Test("the rail opens on hover and for a whole move, and folds otherwise")
    @MainActor
    func openWhenNeeded() throws {
        let shell = ShellState(appState: AppState(db: try DatabaseService(inMemory: true)))
        #expect(!shell.railOpen)
        shell.railHovered = true
        #expect(shell.railOpen)
        shell.railHovered = false
        shell.tileMoving = true
        #expect(shell.railOpen, "a drag must find the drop zones open")
        shell.tileMoving = false
        #expect(!shell.railOpen)
    }

    @Test("the folded edge shows a dot only when a running port needs you")
    func edgeDot() {
        let quiet = PortCard(title: "a", lines: [.init(label: "cwd", value: "~")])
        let failing = PortCard(title: "b", lines: [.init(label: "exit", value: "1", tone: .alert)])
        #expect(!ShellState.railNeedsAttention([]))
        #expect(!ShellState.railNeedsAttention([quiet]))
        #expect(ShellState.railNeedsAttention([quiet, failing]))
    }
}

/// GM, trying it: "it needs to open instantly", "if I'm moving to that edge it should pre-emptively
/// open", and it should open on notifications.
@Suite("Rail: opens at once, ahead of a sweep, and for a new problem")
struct RailOpenTests {

    let w: CGFloat = 1728

    @Test("on the edge it opens at once, with no move needed")
    func edgeOpensAtOnce() {
        #expect(ShellState.railWantsOpen(isOpen: false, distance: 4, deltaX: 0, screenW: w))
    }

    @Test("a quick sweep toward the edge opens it before the pointer arrives")
    func sweepOpensEarly() {
        #expect(ShellState.railWantsOpen(isOpen: false, distance: 120, deltaX: 12, screenW: w))
        #expect(!ShellState.railWantsOpen(isOpen: false, distance: 400, deltaX: 30, screenW: w), "opened from across the screen")
    }

    @Test("a slow approach does not, so a tile's edge beside the rail can still be resized")
    func slowApproachLeavesItFolded() {
        #expect(!ShellState.railWantsOpen(isOpen: false, distance: 22, deltaX: 1, screenW: w))
        #expect(!ShellState.railWantsOpen(isOpen: false, distance: 60, deltaX: -8, screenW: w), "moving away opened it")
    }

    @Test("open, it stays open over itself and folds the moment the pointer is off it")
    func foldsWhenOff() {
        let open = ShellState.parkWidth(w)
        #expect(ShellState.railWantsOpen(isOpen: true, distance: open - 10, deltaX: -5, screenW: w))
        #expect(ShellState.railWantsOpen(isOpen: true, distance: open, deltaX: -5, screenW: w))
        #expect(!ShellState.railWantsOpen(isOpen: true, distance: open + 1, deltaX: -5, screenW: w))
    }

    @Test("the pointer opens it at once and folds it at once")
    @MainActor
    func pointerDrivesIt() throws {
        let shell = ShellState(appState: AppState(db: try DatabaseService(inMemory: true)))
        shell.pointerMoved(distanceFromRight: 3, deltaX: 0, screenW: w)
        #expect(shell.railOpen, "the edge did not open it at once")
        shell.pointerMoved(distanceFromRight: 100, deltaX: -10, screenW: w)
        #expect(shell.railOpen, "it folded while the pointer was still over it")
        shell.pointerMoved(distanceFromRight: ShellState.parkWidth(w) + 2, deltaX: -10, screenW: w)
        #expect(!shell.railOpen, "it stayed open with the pointer off it")
    }

    @Test("only a new problem opens it, and old news at launch does not")
    @MainActor
    func newProblemsOnly() throws {
        #expect(ShellState.newAlerts(previous: ["a"], current: ["a", "b"]) == ["b"])
        #expect(ShellState.newAlerts(previous: ["a", "b"], current: ["a"]).isEmpty)

        let shell = ShellState(appState: AppState(db: try DatabaseService(inMemory: true)))
        shell.noteRunningAlerts(["old"])
        #expect(!shell.railOpen, "a problem already there at launch threw the rail open")
        shell.noteRunningAlerts(["old"])
        #expect(!shell.railOpen)
        shell.noteRunningAlerts(["old", "new"])
        #expect(shell.railOpen, "a new problem did not open the rail")
    }
}
