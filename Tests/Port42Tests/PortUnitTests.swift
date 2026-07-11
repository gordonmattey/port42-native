import Testing
import CoreGraphics
@testable import Port42Lib

/// Tier A for the Port Units refactor, Phase 0 (plan-port-units-render-refactor.md §9):
/// the pure `placement()` — state, not geometry, drives where a port's one persistent
/// view sits. Headless; the mount/window half is Tier B (`PortRenderProbe` + the
/// "Port Units — cycle" harness).
@Suite("Port Units — placement (Phase 0)")
struct PortUnitTests {

    private let area = CGSize(width: 1000, height: 800)
    private let size = CGSize(width: 460, height: 400)

    private func place(id: String = "p1",
                       position: CGPoint? = CGPoint(x: 100, y: 120),
                       z: Int = 3,
                       zoom: ShellState.Zoom = .space,
                       onDesktop: Bool = true,
                       fallbackIndex: Int = 0) -> PortPlacement {
        ShellPlacement.placement(id: id, position: position, size: size, z: z,
                                 zoom: zoom, onDesktop: onDesktop,
                                 fallbackIndex: fallbackIndex, area: area)
    }

    @Test("focusRect is 0.78×0.8 of the area, centered")
    func focusRectCentered() {
        let r = ShellPlacement.focusRect(in: area)
        #expect(r.width == 780)
        #expect(r.height == 640)
        #expect(r.midX == 500)
        #expect(r.midY == 400)
    }

    @Test("tiled placement uses the committed position/size (== resolvedTileFrame)")
    func tiledUsesCommittedFrame() {
        let p = place()
        #expect(p.rect == CGRect(x: 100, y: 120, width: 460, height: 400))
        #expect(p.rect == ShellPlacement.resolvedTileFrame(position: CGPoint(x: 100, y: 120),
                                                           size: size, fallbackIndex: 0))
        #expect(p.chrome == .tile)
        #expect(p.corner == ShellPlacement.tileCorner)
        #expect(p.z == 3)
        #expect(p.visible)
    }

    @Test("tiled placement falls back to the cascade when never positioned")
    func tiledFallbackCascade() {
        let p0 = place(position: nil, fallbackIndex: 0)
        let p5 = place(position: nil, fallbackIndex: 5)
        #expect(p0.rect.origin == CGPoint(x: 330, y: 200))
        #expect(p5.rect.origin == CGPoint(x: 330 + 90, y: 200 + 2 * 80))   // 5%4=1, 5%3=2
        #expect(p0.rect.size == size)
    }

    @Test("legacy z 0 paints at zIndex 1 (never under the desktop floor)")
    func legacyZeroZClamps() {
        #expect(place(z: 0).z == 1)
    }

    @Test("focused placement = focusRect + focus z/chrome/corner")
    func focusedPlacement() {
        let p = place(zoom: .focus("p1"))
        #expect(p.rect == ShellPlacement.focusRect(in: area))
        #expect(p.z == ShellPlacement.focusZ)
        #expect(p.chrome == .focus)
        #expect(p.corner == ShellPlacement.focusCorner)
        #expect(p.visible)
    }

    @Test("another port's focus leaves this tile placed as a tile (stays staged)")
    func otherPortsFocusLeavesTileAlone() {
        let p = place(zoom: .focus("someone-else"))
        #expect(p.chrome == .tile)
        #expect(p.rect == CGRect(x: 100, y: 120, width: 460, height: 400))
        #expect(p.visible)
    }

    @Test("off-desktop → invisible, never a different mount")
    func offDesktopInvisible() {
        let p = place(onDesktop: false)
        #expect(!p.visible)
    }

    @Test("zoom round trip returns the identical tile rect (state drives geometry)")
    func zoomRoundTrip() {
        let before = place(zoom: .space)
        let during = place(zoom: .focus("p1"))
        let after = place(zoom: .space)
        #expect(before == after)
        #expect(during.rect != before.rect)
    }

    @Test("focus z sits above the rails and the backdrop; backdrop above the rails")
    func zLayering() {
        #expect(ShellPlacement.focusZ > ShellPlacement.backdropZ)
        #expect(ShellPlacement.backdropZ > 10_500)   // notification rail
    }
}
