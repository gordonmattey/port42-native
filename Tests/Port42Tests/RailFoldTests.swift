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
