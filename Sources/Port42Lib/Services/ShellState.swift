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

    /// The per-space accent palette (mirrors the prototype's space colors). A persisted, editable
    /// `spaces.accent` column is the later step (spec decision #1); for now each space gets a stable
    /// color derived from its id.
    static let palette: [Color] = [
        Color(red: 0.0,  green: 0.831, blue: 0.667),     // teal #00d4aa (prototype's base — softer glow)
        Color(red: 1.0,  green: 0.42,  blue: 0.70),      // pink
        Color(red: 1.0,  green: 0.74,  blue: 0.20),      // gold
        Color(red: 0.40, green: 0.78,  blue: 1.0),       // blue
        Color(red: 0.45, green: 0.90,  blue: 0.55),      // light green
        Color(red: 0.62, green: 0.28,  blue: 0.98),      // purple
        Color(red: 0.30, green: 0.85,  blue: 0.80),      // teal 2
    ]

    /// A per-space accent. Assigned by the space's POSITION (like the prototype's SpaceDef order) so
    /// the first N spaces are all visibly different; falls back to an id-hash for spaces not in the
    /// list. (A persisted, editable `spaces.accent` is the later step — spec decision #1.)
    public func accent(for space: Space) -> Color {
        if let idx = appState.spaces.firstIndex(where: { $0.id == space.id }) {
            return Self.palette[idx % Self.palette.count]
        }
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
}
