import SwiftUI
import AppKit

// Shared helpers that survived the classic-mode retirement: these were defined in
// ContentView/NewCompanionSheet (deleted) but are load-bearing for the shell.

// MARK: - AppKit tooltip (works in the borderless shell window)

final class PassthroughTooltipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct TooltipHost: NSViewRepresentable {
    let tooltip: String
    func makeNSView(context: Context) -> PassthroughTooltipView {
        let v = PassthroughTooltipView()
        v.toolTip = tooltip
        return v
    }
    func updateNSView(_ nsView: PassthroughTooltipView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    /// AppKit tooltip that fires even in a borderless/hiddenTitleBar window (where SwiftUI `.help()`
    /// silently doesn't) — the shell's Chrome relies on this. Overlay (not background) so it's the
    /// topmost NSView under the cursor; hitTest returns nil so clicks fall through.
    func appKitTooltip(_ text: String) -> some View {
        self.overlay(TooltipHost(tooltip: text))
    }
}
