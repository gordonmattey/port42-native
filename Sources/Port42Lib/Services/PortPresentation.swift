import Foundation
import CoreGraphics

/// Ports must know their presentation state (backlog 1.1, `docs/plan-port-presentation-state.md`).
///
/// The port-facing value the shell delivers so a well-behaved port can idle when it is not visible
/// and drop fidelity when it is small. A DERIVED view-model value, a sibling of `PortPlacement`, not
/// a stored fact: it is computed from the SAME desktop-membership + peek-index decision `contextItems`
/// makes, with the richer visibility gates layered on top (Step 1). Two axes, deliberately separate:
///
/// - `state` is the placement/mode a port scales fidelity to (focused = full, tiled = normal,
///   peek = thumbnail).
/// - `visible` is the single authoritative "render your pixels now" bool a port gates its rAF on.
///   It is STRICTLY RICHER than `PortPlacement.visible`: on top of "has a rect on the desktop" it
///   also requires the desktop is shown (`zoom != .galaxy`) and nothing covers the port (not behind
///   another port's focus backdrop, `ShellPlacement.backdropZ`).
public struct PortPresentation: Equatable {

    public enum State: String, Equatable, CaseIterable {
        case focused, tiled, peek, parked, background, inline
    }

    /// The placement/mode.
    public let state: State
    /// The authoritative "on screen right now" bool — what a port gates its animation loop on.
    public let visible: Bool
    /// On-screen content size in points for the resolved state; `0` when not visible.
    public let w: Int
    public let h: Int
    /// Optional transition cause, attached at diff time (Step 3). The pure mapping leaves it nil —
    /// a cause is about the prev→next edge, which the per-snapshot mapping cannot see.
    public let reason: String?

    public init(state: State, visible: Bool, w: Int, h: Int, reason: String? = nil) {
        self.state = state
        self.visible = visible
        self.w = w
        self.h = h
        self.reason = reason
    }

    /// Build from a content size. Rounds to points and enforces the invariant structurally:
    /// `w,h` are `0,0` whenever `!visible`, whatever size is passed.
    public init(state: State, visible: Bool, size: CGSize = .zero, reason: String? = nil) {
        self.init(state: state, visible: visible,
                  w: visible ? Int(size.width.rounded()) : 0,
                  h: visible ? Int(size.height.rounded()) : 0,
                  reason: reason)
    }

    /// The wire shape the port receives (`pushEvent` payload / the `presentation()` getter).
    public var jsonObject: [String: Any] {
        var o: [String: Any] = ["state": state.rawValue, "visible": visible, "w": w, "h": h]
        if let reason { o["reason"] = reason }
        return o
    }

    /// The same value with a transition cause attached (Step 3 diff site).
    public func with(reason: String?) -> PortPresentation {
        PortPresentation(state: state, visible: visible, w: w, h: h, reason: reason)
    }
}

extension ShellState {

    /// THE pure presentation mapping (Step 1). Fully primitive so it is headless-testable exactly like
    /// `ShellPlacement.placement` — no window, no AppState. `onDesktop` / `isPeeking` ARE the shared
    /// membership + peek-index decision `contextItems` already made (see the `for panel:` overload);
    /// this function only layers the visibility gates. Precedence, first match wins:
    ///   background > parked > inline > off-desktop > (zoom occlusion) > peek/tiled.
    nonisolated public static func presentation(id: String,
                                                isBackground: Bool,
                                                mode: String,
                                                size: CGSize,
                                                zoom: Zoom,
                                                onDesktop: Bool,
                                                isPeeking: Bool,
                                                area: CGSize) -> PortPresentation {
        // Panel-mode gates first — these hold regardless of the current desktop or zoom.
        if isBackground { return PortPresentation(state: .background, visible: false) }
        if mode == "parked" { return PortPresentation(state: .parked, visible: false) }
        if mode == "inline" {
            // v1 conservative: an inline card reports visible; true chat-scroll visibility is a
            // scoped follow-up (never wrongly idles a visible port).
            return PortPresentation(state: .inline, visible: true, size: size)
        }
        // A "tiled" panel that is not staged on the current desktop (another space) — not visible.
        guard onDesktop else { return PortPresentation(state: .tiled, visible: false) }
        // On the current desktop: the zoom rung decides occlusion for BOTH tiles and peeks, because
        // the focus backdrop (backdropZ) sits above the peek rail (peekZ) and every tile.
        switch zoom {
        case .galaxy:
            // The desktop itself is not shown — report the placement mode, invisible.
            return PortPresentation(state: isPeeking ? .peek : .tiled, visible: false)
        case .focus(let fid):
            if fid == id {
                return PortPresentation(state: .focused, visible: true,
                                        size: ShellPlacement.focusRect(in: area).size)
            }
            // Another port is focused — its backdrop covers every other tile and peek.
            return PortPresentation(state: isPeeking ? .peek : .tiled, visible: false)
        case .space:
            if isPeeking {
                return PortPresentation(state: .peek, visible: true, size: ShellPlacement.peekSize)
            }
            return PortPresentation(state: .tiled, visible: true, size: size)
        }
    }

    /// Ergonomic overload for the call site (Step 3): consume this panel's entry in `contextItems`
    /// (`item == nil` ⇒ not staged on the current desktop; `item.peek != nil` ⇒ peeking). The ONE
    /// membership decision the desktop render, arrange, and focus paths already share.
    nonisolated public static func presentation(for panel: PortPanel,
                                                zoom: Zoom,
                                                item: PortContextItem?,
                                                area: CGSize) -> PortPresentation {
        presentation(id: panel.id,
                     isBackground: panel.isBackground,
                     mode: panel.presentation,
                     size: panel.size,
                     zoom: zoom,
                     onDesktop: item != nil,
                     isPeeking: item?.peek != nil,
                     area: area)
    }

    /// The pure diff (Step 3): the ports whose presentation changed, each carrying a coarse transition
    /// `reason`. `prev`/`next` are reason-nil snapshots (the mapping never sets reason), so `!=` compares
    /// only state/visible/w/h. A port absent from `next` (closed) is simply dropped — no push needed.
    /// Sorted by id so the result is deterministic for tests. This is the tested unit of the funnel:
    /// the debounced trigger and the real `pushEvent` delivery are verified live (Step 5).
    nonisolated public static func presentationDeltas(
        prev: [String: PortPresentation],
        next: [String: PortPresentation]) -> [(id: String, presentation: PortPresentation)] {
        var out: [(id: String, presentation: PortPresentation)] = []
        for id in next.keys.sorted() {
            let n = next[id]!
            let p = prev[id]
            if p != n {
                out.append((id: id, presentation: n.with(reason: transitionReason(from: p, to: n))))
            }
        }
        return out
    }

    /// A coarse cause for a transition, derived purely from the delta (the merged pipeline erases the
    /// specific trigger, so this describes the change, not what caused it). Only called when `prev != next`.
    nonisolated public static func transitionReason(from prev: PortPresentation?,
                                                    to next: PortPresentation) -> String? {
        guard let prev else { return "appear" }
        if prev.state != next.state { return next.state.rawValue }        // e.g. "focused", "parked"
        if prev.visible != next.visible { return next.visible ? "shown" : "hidden" }
        return "resize"                                                    // state+visible equal ⇒ size changed
    }

    /// Heartbeat defense (backlog 1.1, Step 4): a not-visible port is skipped so its JS is not woken.
    /// A port with no resolvable presentation defaults to being kept alive.
    nonisolated public static func shouldHeartbeat(_ p: PortPresentation?) -> Bool {
        p?.visible ?? true
    }
}
