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
    }
}

public enum ShellPlacement {

    /// z of a focused unit — above the rails (10_000 / 10_500) and the focus backdrop.
    public static let focusZ: Double = 12_000
    /// z of the dim backdrop behind a focused unit (covers tiles + rails, below the unit).
    public static let backdropZ: Double = 11_900
    public static let tileCorner: CGFloat = 10
    public static let focusCorner: CGFloat = 16

    /// The focus card: 0.78×0.8 of the desktop area, centered — the same proportions
    /// `ShellFocusContent` used, but derived from the AREA (headless, no NSScreen).
    nonisolated public static func focusRect(in area: CGSize) -> CGRect {
        let w = area.width * 0.78, h = area.height * 0.8
        return CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
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
    /// (a member of `desktopTilePanels`); off-desktop ports are invisible, never unmounted.
    nonisolated public static func placement(id: String,
                                             position: CGPoint?,
                                             size: CGSize,
                                             z: Int,
                                             zoom: ShellState.Zoom,
                                             onDesktop: Bool,
                                             fallbackIndex: Int,
                                             area: CGSize) -> PortPlacement {
        guard onDesktop else {
            return PortPlacement(rect: .zero, corner: tileCorner, z: 0, chrome: .tile, visible: false)
        }
        if case .focus(let fid) = zoom, fid == id {
            return PortPlacement(rect: focusRect(in: area), corner: focusCorner,
                                 z: focusZ, chrome: .focus, visible: true)
        }
        let rect = resolvedTileFrame(position: position, size: size, fallbackIndex: fallbackIndex)
        return PortPlacement(rect: rect, corner: tileCorner,
                             z: Double(max(z, 1)), chrome: .tile, visible: true)
    }
}
