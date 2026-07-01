import Foundation
import CoreGraphics
import SwiftUI

/// SHELL — S2 spine. The shell-only UI state (zoom ladder, selection, pinch latch) layered over
/// `AppState`. It READS `AppState` (spaces, ports, current space); it never owns or duplicates
/// ports/spaces/companions. Pure state so the S2 gate (`ShellStateTests`) runs headlessly — no
/// window, no webview. Mirrors the prototype's `Shell` zoom logic (`prototypes/p42shell`), the
/// canonical interaction reference (`spec-shell-reimplementation.md` §3.2 / §4 "Zoom ladder").
@MainActor
public final class ShellState: ObservableObject {

    /// The zoom ladder rungs: galaxy (all spaces) ↔ space (this desktop) ↔ focus (one port immersive).
    public enum Zoom: Equatable {
        case galaxy
        case space
        case focus(String)   // focused port udid
    }

    @Published public var zoom: Zoom = .space
    /// The highlighted tile zoom-in targets (hover/click); nil ⇒ fall back to the first port.
    @Published public var selectedPortId: String?
    /// The highlighted desktop tile (chat or a tiled port) — hover/click; what ⌘↓ focuses.
    @Published public var selectedTileId: String?
    /// Bumped to re-trigger the desktop grid layout (the Chrome "arrange" + every spawn).
    @Published public var arrangeBump: Int = 0
    /// Which space-world the mouse is over in galaxy (zoom-in dives into it).
    @Published public var galaxyHover: Int?
    /// Normalized cursor position (0…1) for the ambient background parallax (prototype's `mouse`).
    @Published public var mouse: CGPoint = CGPoint(x: 0.5, y: 0.5)

    private let appState: AppState
    public init(appState: AppState) { self.appState = appState }

    // MARK: Per-space accent theme (prototype's SpaceDef.accent)

    /// The per-space accent palette (mirrors the prototype's space colors), as hex. **Keep in sync
    /// with the v37 migration backfill in `DatabaseService`.** A space's color is assigned at
    /// creation (`createSpace`) and stored on `Space.accent` for life (spec decision #1) — the
    /// palette is only the source for *new* assignments and the legacy fallback.
    public static let paletteHex: [String] = [
        "#00D4AA",  // teal #00d4aa (prototype's base)
        "#FF6BB2",  // pink
        "#FFBD33",  // gold
        "#66C7FF",  // blue
        "#73E68C",  // light green
        "#9E47FA",  // purple
        "#4DD9CC",  // teal 2
    ]
    static let palette: [Color] = paletteHex.map { Color(shellHex: $0) ?? .teal }

    /// The color a *newly created* space at position `count` should get (before it's added). Stored
    /// permanently on the space, so it never shifts when other spaces come and go.
    public static func accentHex(forNewSpaceAt count: Int) -> String {
        paletteHex[count % paletteHex.count]
    }

    /// A per-space accent. Reads the space's **stored** hex (assigned for life at creation); for a
    /// space with no stored accent (predates v37 / remote) falls back to a **stable id-hash** — never
    /// list position, so colors never reshuffle when spaces are added or deleted.
    public func accent(for space: Space) -> Color {
        if let hex = space.accent, let c = Color(shellHex: hex) { return c }
        let h = space.id.utf8.reduce(0) { $0 &+ Int($1) }
        return Self.palette[h % Self.palette.count]
    }

    /// The current space's accent (falls back to the base accent).
    public var accent: Color {
        guard let s = appState.currentSpace else { return Self.palette[0] }
        return accent(for: s)
    }

    // MARK: Read-through helpers (never duplicate AppState)

    /// Non-background port udids on the current space, in panel order.
    public var currentSpacePortIds: [String] {
        guard let sid = appState.currentSpace?.id else { return [] }
        return appState.portWindows.panels
            .filter { $0.spaceId == sid && !$0.isBackground }
            .map { $0.udid }
    }

    /// What focus zooms into: the explicit selection (if still on this space) else the first port.
    public var selectedPort: String? {
        if let s = selectedPortId, currentSpacePortIds.contains(s) { return s }
        return currentSpacePortIds.first
    }

    // MARK: Zoom ladder (one rung per call; clamps at the ends)

    /// ⌘↑ / pinch-out — step UP toward the galaxy. Clamps at galaxy (the ceiling).
    public func zoomOut() {
        switch zoom {
        case .focus:  zoom = .space
        case .space:  zoom = .galaxy; galaxyHover = nil
        case .galaxy: break                       // ceiling — no wraparound
        }
    }

    /// ⌘↓ / pinch-in — step DOWN toward a single focused port. Clamps at focus (the floor).
    /// In galaxy, a hovered space-world dives straight into that space (hover-dive).
    public func zoomIn() {
        switch zoom {
        case .galaxy:
            if let h = galaxyHover, appState.spaces.indices.contains(h),
               appState.spaces[h].id != appState.currentSpace?.id {
                jumpToSpace(index: h)             // hover-dive: enter the hovered space
            } else {
                zoom = .space
            }
        case .space:
            // Focus the highlighted desktop tile (chat or a tiled port); else the first port.
            if let tid = selectedTileId ?? selectedPort { zoom = .focus(tid) }   // nothing ⇒ stay
        case .focus:
            break                                 // floor — no wraparound
        }
    }

    /// ⌘1…N — jump straight to the Nth space (0-based) and land on its desktop rung.
    public func jumpToSpace(index: Int) {
        guard appState.spaces.indices.contains(index) else { return }
        appState.selectSpace(appState.spaces[index])
        selectedPortId = nil
        galaxyHover = nil
        zoom = .space
    }

    // MARK: Pinch latch — ONE rung per gesture (prototype `Shell.pinch`)

    public var pinchAccum: CGFloat = 0
    public var pinchFired = false

    /// Trackpad magnify drives the same ladder: accumulate magnification, fire exactly one rung
    /// once past the threshold, then latch until the next gesture begins (`began`). Spread
    /// (delta > 0) zooms in; pinch (delta < 0) zooms out. Prevents a single squeeze rocketing
    /// through several rungs.
    public func pinch(delta: CGFloat, began: Bool) {
        if began { pinchAccum = 0; pinchFired = false }
        guard !pinchFired else { return }
        pinchAccum += delta
        let threshold: CGFloat = 0.32
        if pinchAccum > threshold { pinchFired = true; zoomIn() }
        else if pinchAccum < -threshold { pinchFired = true; zoomOut() }
    }

    // MARK: Key yield (§3.1) — pure decision, headless-tested

    /// Whether the shell should YIELD a key to a focused field/port instead of driving the zoom
    /// ladder. `isEditor` = a text editor / web view / terminal owns the keyboard (so any key it
    /// wants, including ⌘-combos while typing, passes through). **Esc** additionally yields whenever
    /// the focused port is a **terminal** — vim/less/any TUI needs its Esc (a non-terminal focused
    /// port still lets Esc peel back out of focus). Everything else drives the ladder.
    nonisolated public static func shouldYieldKey(isEditor: Bool, keyCode: UInt16,
                                                  focusedPortIsTerminal: Bool) -> Bool {
        if keyCode == 53 { return isEditor || focusedPortIsTerminal }   // 53 = Esc
        return isEditor
    }

    /// The port currently in focus is a terminal (its Esc must reach it, not the ladder).
    public var focusedPortIsTerminal: Bool {
        guard case .focus(let id) = zoom else { return false }
        return appState.portWindows.panels.first { $0.id == id }?.portType == "terminal"
    }

    // MARK: Z-order (prototype `Shell.zCounter` / `focus()`)

    /// Monotonic z-order source. Every focus bumps it and stamps the port, so the just-touched
    /// port is always frontmost. Persisted per-port via `PortPanel.z`.
    public private(set) var zCounter: Int = 0

    /// Next z value (frontmost). Call when a tile is focused/spawned, then stamp it on the panel.
    @discardableResult
    public func nextZ() -> Int { zCounter += 1; return zCounter }

    /// Keep the counter ahead of any restored `z` so freshly focused ports still land on top.
    public func seedZCounter(from panels: [PortPanel]) {
        zCounter = max(zCounter, panels.map(\.z).max() ?? 0)
    }

    // MARK: Tile geometry (S3 — movable tiles; positions live in state, not a render grid)

    /// A tile's default full size (titlebar + body) when a panel carries none yet.
    public static let defaultTileSize = CGSize(width: 460, height: 400)

    /// Minimum tile size (drag-resize floor).
    public static let minTileSize = CGSize(width: 220, height: 160)

    /// The right-edge rail's two drop zones: park (minimize to a chip) and close (delete the port).
    public enum ParkZone: Equatable { case park, close }

    /// Which rail zone the in-progress tile drag is currently over (drives the rail highlight); nil
    /// when the drag isn't over the rail.
    @Published public var draggingOverPark: ParkZone?

    /// The right rail's width (spec §4: `max(64, screenW·0.05)`).
    nonisolated public static func parkWidth(_ screenW: CGFloat) -> CGFloat { max(64, screenW * 0.05) }

    /// The close sub-zone's height — the bottom portion of the rail.
    nonisolated public static func closeZoneHeight(_ screenH: CGFloat) -> CGFloat { max(120, screenH * 0.2) }

    /// Classify a point (in desktop coordinates) against the right rail: the bottom portion of the
    /// strip is the **close** zone, the rest of the strip is **park**, everything left of the strip
    /// is nil. Pure → headless-testable.
    nonisolated public static func parkZone(at p: CGPoint, in area: CGSize) -> ParkZone? {
        guard p.x >= area.width - parkWidth(area.width) else { return nil }
        return p.y >= area.height - closeZoneHeight(area.height) ? .close : .park
    }

    /// Bring a tile to the front (focus/hover/drag-start): stamp it frontmost via `nextZ()` and
    /// select it. `setZ` no-ops if the id isn't a panel, so it's safe for any tile.
    public func bringToFront(_ tileId: String) {
        selectedTileId = tileId
        appState.portWindows.setZ(id: tileId, z: nextZ())
    }

    /// Re-grid the current space's tiled ports (the chat is one of them now) via the pure `arrange`
    /// and WRITE the resulting positions back — the layout authority (§4). Called on ⌘L and every
    /// user-initiated spawn/park; hand-drag positions survive a restart but a spawn re-grids them.
    public func applyArrange(area: CGSize) {
        guard let sid = appState.currentSpace?.id else { return }
        let panels = appState.portWindows.panels.filter { $0.spaceId == sid && $0.presentation == "tiled" }
        let tiles = panels.map { ArrangeTile(id: $0.id, size: $0.size, z: max($0.z, 1)) }
        let frames = Self.arrange(tiles, in: area)
        for p in panels {
            if let f = frames[p.id] { appState.portWindows.updateTileFrame(id: p.id, position: f.origin, size: f.size) }
        }
    }

    // MARK: Arrange (pure — prototype `arrange()`; the layout authority, §4)

    /// One tile's geometry input to `arrange` (id + current size + z). Pure so the grid is headless.
    public struct ArrangeTile: Equatable {
        public let id: String
        public let size: CGSize
        public let z: Int
        public init(id: String, size: CGSize, z: Int) { self.id = id; self.size = size; self.z = z }
    }

    /// Tidy tiles into a centered grid that always FITS the work area (so a spawn never pushes tiles
    /// off-screen). `cols = ceil(√n)`; the grid fills the space left by the Chrome (top), the dock
    /// (bottom) and the park rail (right); each tile is capped at its natural size but SHRUNK to fit
    /// its cell when the desktop gets crowded. Walks tiles in `z` order (stable). Returns each tile's
    /// full frame (origin + size); callers set `panel.position`/`.size`. Pure + deterministic → headless.
    nonisolated public static func arrange(_ tiles: [ArrangeTile], in area: CGSize) -> [String: CGRect] {
        let items = tiles.sorted { $0.z < $1.z }
        guard !items.isEmpty else { return [:] }
        let n = items.count
        let cols = max(1, Int(ceil(sqrt(Double(n)))))
        let rows = max(1, Int(ceil(Double(n) / Double(cols))))
        // Work area: clear the Chrome (top), the dock (bottom), the park rail + margins (sides).
        let top: CGFloat = 70, bottom: CGFloat = 100, side: CGFloat = 40, gap: CGFloat = 24
        let workX = side, workY = top
        let workW = max(240, area.width - side - parkWidth(area.width) - 20)
        let workH = max(200, area.height - top - bottom)
        let cellW = workW / Double(cols), cellH = workH / Double(rows)
        // Uniform tile size: capped at the largest natural size, shrunk to fit the cell when crowded.
        let maxW = items.map { $0.size.width }.max() ?? 300
        let maxH = items.map { $0.size.height }.max() ?? 200
        let tileW = max(80, min(maxW, cellW - gap))
        let tileH = max(60, min(maxH, cellH - gap))
        var out: [String: CGRect] = [:]
        for (i, item) in items.enumerated() {
            let cx = workX + (Double(i % cols) + 0.5) * cellW      // cell center
            let cy = workY + (Double(i / cols) + 0.5) * cellH
            out[item.id] = CGRect(x: cx - tileW / 2, y: cy - tileH / 2, width: tileW, height: tileH)
        }
        return out
    }
}

// MARK: - Hex color (shell accents)

extension Color {
    /// Parse "#RRGGBB" (or "RRGGBB") into a Color; nil on malformed input. Used for per-space accents.
    init?(shellHex: String) {
        var s = shellHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255.0,
            green: Double((v >> 8) & 0xFF) / 255.0,
            blue:  Double(v & 0xFF) / 255.0
        )
    }
}
