import Foundation
import CoreGraphics

/// Port Units — the pure placement layer (plan-port-units-render-refactor.md §3, Phase 0).
///
/// Tile / focus stop being separate MOUNTS and become GEOMETRY STATES of one persistent
/// per-port view: `placement()` maps (panel geometry, zoom, area) → the rect/z/chrome that
/// view should have right now. The view never leaves the window; zoom just animates these
/// values. Pure + nonisolated so the whole decision is headless-testable (`PortUnitTests`).
/// `.peek` joins the Chrome enum in Phase 1 (rail slots replace the peek VStack).
public struct PortPlacement: Equatable {
    public var rect: CGRect
    public var corner: CGFloat
    public var z: Double
    public var chrome: Chrome
    public var visible: Bool

    public enum Chrome: Equatable {
        case tile
        case focus
        case peek
    }
}

public enum ShellPlacement {

    /// z of a focused unit — above the rails (10_000 / 10_500) and the focus backdrop.
    public static let focusZ: Double = 12_000
    /// z of the dim backdrop behind a focused unit (covers tiles + rails, below the unit).
    public static let backdropZ: Double = 11_900
    /// Base z of peeking units — above the park rail (10_000), below the backdrop/focus.
    public static let peekZ: Double = 10_500
    public static let tileCorner: CGFloat = 10
    public static let focusCorner: CGFloat = 16
    public static let peekCorner: CGFloat = 11
    /// A peek unit's footprint (Phase 1): the old rail tile — 24pt header + 116pt live content.
    public static let peekSize = CGSize(width: 210, height: 140)
    /// A browser unit's address bar height (Phase 2): the page rect is the unit's content
    /// rect minus this bar — the bar is chrome, part of the unit, never a second mount.
    public static let browserBarH: CGFloat = 34

    /// The rail slot for the Nth peek (Phase 1): stacked from the top-left, under the Chrome,
    /// replacing the old rail `VStack`. Pure so peeks are absolutely positioned like any unit.
    nonisolated public static func railSlot(_ index: Int, in area: CGSize) -> CGRect {
        CGRect(x: 12, y: 60 + Double(index) * (peekSize.height + 12),
               width: peekSize.width, height: peekSize.height)
    }

    /// The focus card: 0.78×0.8 of the desktop area, centered — the old focus overlay's
    /// proportions, but derived from the AREA (headless, no NSScreen).
    nonisolated public static func focusRect(in area: CGSize) -> CGRect {
        let w = area.width * 0.78, h = area.height * 0.8
        return CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
    }

    // MARK: - The work area (ONE definition, docs/design-shell-layout.md §9.2)

    /// The gap held between tiles, and between a tile and the desktop edge (GM: "5–10px, no more").
    public static let tileGap: CGFloat = 8
    /// Clearance for the dock, which is a real overlay: a tile behind it cannot be clicked. Its pill
    /// is ~64pt tall and sits 24pt off the bottom, so 96 leaves a small gap above it.
    public static let dockClearance: CGFloat = 96
    /// The birth size of EVERY port, whatever its type (GM 2026-08-03: "ports should just have one
    /// default size, browser html or chat whatever"). Two fit across a 1728pt desktop with the gaps.
    public static let defaultTileSize = CGSize(width: 620, height: 440)

    /// The region a tile may occupy, in DESKTOP coordinates (y = 0 is the first pixel under the
    /// Chrome — the desktop's own `GeometryReader` already excludes the bar).
    ///
    /// This is the single definition. `arrange` used to inset 70 from the top and 40 at the sides
    /// while the drag clamp allowed y ≥ 0, so the two disagreed by 70pt of usable desktop.
    nonisolated public static func workArea(in area: CGSize) -> CGRect {
        let right = ShellState.parkWidth(area.width) + tileGap    // the park rail is a live drop target
        let w = max(ShellState.minTileSize.width, area.width - tileGap - right)
        let h = max(ShellState.minTileSize.height, area.height - tileGap - dockClearance)
        return CGRect(x: tileGap, y: tileGap, width: w, height: h)
    }

    // MARK: - place (Phase 1: a birth places, it does not re-grid)

    /// Where to put ONE new tile, moving nothing that already exists.
    ///
    /// Largest gap, per GM: the maximal empty rectangles of the work area minus the occupied tiles
    /// (each inflated by `tileGap`, which is what makes the spacing rule fall out of the geometry
    /// rather than being a second rule). The largest one that can hold `size` wins, the tile is
    /// centered in it, and ties break topmost-then-leftmost so the function is deterministic.
    ///
    /// When nothing fits the tile goes ON TOP of the others, cascaded from the frontmost — GM:
    /// "it just needs to go on top of the tiles rather than pushing in, because everything moves at
    /// that point and it could have moved something I placed intentionally".
    ///
    /// `occupied` is in z order, back to front, so `last` is the frontmost tile.
    nonisolated public static func place(_ size: CGSize, among occupied: [CGRect], in area: CGSize) -> CGPoint {
        let bounds = workArea(in: area)
        let blockers = occupied.map { $0.insetBy(dx: -tileGap, dy: -tileGap) }

        // Anchors: the work area's top-left, plus the far corners of every blocker. Sweeping the
        // largest rect anchored at each is the standard enumeration of maximal empty rectangles.
        var xs: [CGFloat] = [bounds.minX], ys: [CGFloat] = [bounds.minY]
        for b in blockers {
            if b.maxX > bounds.minX && b.maxX < bounds.maxX { xs.append(b.maxX) }
            if b.maxY > bounds.minY && b.maxY < bounds.maxY { ys.append(b.maxY) }
        }
        xs = Array(Set(xs)).sorted(); ys = Array(Set(ys)).sorted()

        var best: CGRect? = nil
        for y in ys {
            for x in xs {
                let origin = CGPoint(x: x, y: y)
                guard !blockers.contains(where: { $0.contains(origin) }) else { continue }
                let gap = maximalRect(at: origin, blockers: blockers, bounds: bounds)
                guard gap.width >= size.width, gap.height >= size.height else { continue }
                guard let b = best else { best = gap; continue }
                // Largest area wins; ties go to the topmost, then the leftmost.
                let a1 = gap.width * gap.height, a0 = b.width * b.height
                if a1 > a0 || (a1 == a0 && (gap.minY < b.minY || (gap.minY == b.minY && gap.minX < b.minX))) {
                    best = gap
                }
            }
        }

        // Anchored at the gap's top-left, never centered in it. Centering reads better for ONE tile
        // and packs terribly: a centered 620x440 splits a 1634x939 work area into four strips, none
        // of them wide enough for the next tile, so every later birth would cascade on top of
        // something. Anchoring keeps the free space in one piece, and four tiles fit where centering
        // fits one. (A test pins it: four consecutive births must not land on each other.)
        if let gap = best { return gap.origin }
        return cascade(size, after: occupied.last, step: occupied.count, in: bounds)
    }

    /// The largest empty rect whose TOP-LEFT is `origin`. Sweeps right, letting each blocker either
    /// cut the width short (it starts at or above the origin) or lower the ceiling (it starts below).
    nonisolated static func maximalRect(at origin: CGPoint, blockers: [CGRect], bounds: CGRect) -> CGRect {
        var limitX = bounds.maxX
        var height = bounds.maxY - origin.y
        var best = CGRect(origin: origin, size: .zero)
        func consider(_ w: CGFloat, _ h: CGFloat) {
            guard w > 0, h > 0 else { return }
            if w * h > best.width * best.height { best = CGRect(x: origin.x, y: origin.y, width: w, height: h) }
        }
        let relevant = blockers
            .filter { $0.maxX > origin.x && $0.maxY > origin.y && $0.minY < bounds.maxY }
            .sorted { $0.minX < $1.minX }
        for b in relevant {
            if b.minX >= limitX { break }
            consider(max(0, min(b.minX, limitX) - origin.x), height)
            if b.minY <= origin.y {
                limitX = min(limitX, max(origin.x, b.minX))     // blocks the whole height from here on
            } else {
                height = min(height, b.minY - origin.y)         // only lowers the ceiling
            }
            if height <= 0 { break }
        }
        consider(max(0, limitX - origin.x), height)
        return best
    }

    /// Nothing fits: stagger on top of the frontmost tile, wrapping back into the work area rather
    /// than running off it. Nothing existing moves.
    ///
    /// The wrap staggers rather than returning to the corner. Measured on Dev2: three births in a row
    /// on a full desktop each landed at exactly (8,8), stacked precisely on the tile already there,
    /// with their title bars coincident and so ungrabbable. `nth` (the tile count at the time) walks
    /// the wrapped origin diagonally instead, which is the whole point of a cascade.
    nonisolated static func cascade(_ size: CGSize, after front: CGRect?, step nth: Int, in bounds: CGRect) -> CGPoint {
        let step: CGFloat = 30
        let from = front?.origin ?? CGPoint(x: bounds.minX - step, y: bounds.minY - step)
        var p = CGPoint(x: from.x + step, y: from.y + step)
        if p.x + size.width > bounds.maxX || p.y + size.height > bounds.maxY {
            let n = CGFloat(max(0, nth) % 6)                     // wrapped, but not back onto the corner
            p = CGPoint(x: bounds.minX + n * step, y: bounds.minY + n * step)
        }
        return clamped(p, size: size, in: bounds)
    }

    /// Keep a tile inside the work area. Used by placement, by the resize/restore rescue, and by
    /// nothing else — a hand drag has its own (looser) clamp, which lets a tile hang off an edge.
    nonisolated public static func clamped(_ origin: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
                y: min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height)))
    }

    /// A tile's frame: its committed position/size, or the cheap cascade seed until
    /// arrange runs (hoisted verbatim from `ShellDesktopView.resolvedPortFrame`).
    nonisolated public static func resolvedTileFrame(position: CGPoint?, size: CGSize,
                                                     fallbackIndex: Int) -> CGRect {
        if let position { return CGRect(origin: position, size: size) }
        let i = max(0, fallbackIndex)
        return CGRect(x: 330 + Double(i % 4) * 90, y: 200 + Double(i % 3) * 80,
                      width: size.width, height: size.height)
    }

    /// State → geometry for one port. `onDesktop` = the port is staged on this desktop
    /// (a member of `contextItems`); off-desktop ports are invisible, never unmounted.
    /// Precedence: focused > peeking > tiled — a previewed peek resizes railSlot → focusRect
    /// IN PLACE (the same view), exactly like tile focus.
    nonisolated public static func placement(id: String,
                                             position: CGPoint?,
                                             size: CGSize,
                                             z: Int,
                                             zoom: ShellState.Zoom,
                                             onDesktop: Bool,
                                             peekIndex: Int? = nil,
                                             fallbackIndex: Int,
                                             area: CGSize) -> PortPlacement {
        guard onDesktop else {
            return PortPlacement(rect: .zero, corner: tileCorner, z: 0, chrome: .tile, visible: false)
        }
        if case .focus(let fid) = zoom, fid == id {
            return PortPlacement(rect: focusRect(in: area), corner: focusCorner,
                                 z: focusZ, chrome: .focus, visible: true)
        }
        if let i = peekIndex {
            return PortPlacement(rect: railSlot(i, in: area), corner: peekCorner,
                                 z: peekZ + Double(i), chrome: .peek, visible: true)
        }
        let rect = resolvedTileFrame(position: position, size: size, fallbackIndex: fallbackIndex)
        return PortPlacement(rect: rect, corner: tileCorner,
                             z: Double(max(z, 1)), chrome: .tile, visible: true)
    }
}
