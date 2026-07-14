import SwiftUI
import AppKit

// Shared helpers that survived the classic-mode retirement: these were defined in
// ContentView/NewCompanionSheet (deleted) but are load-bearing for the shell.

// MARK: - Companion type presets (identity + constitution per type)

enum CompanionTypePreset: String, CaseIterable {
    case architect, compiler, operatorType, echo

    var displayName: String {
        switch self {
        case .architect: return "architect"
        case .compiler: return "compiler"
        case .operatorType: return "operator"
        case .echo: return "echo"
        }
    }

    var label: String {
        switch self {
        case .architect: return "decides what to build"
        case .compiler: return "builds it correctly"
        case .operatorType: return "keeps it running"
        case .echo: return "holds context"
        }
    }

    var defaultKBPath: String {
        switch self {
        case .architect: return "scopes/architect"
        case .compiler: return "scopes/compiler"
        case .operatorType: return "scopes/operator"
        case .echo: return "scopes/echo"
        }
    }

    var constitutionFile: String {
        switch self {
        case .architect: return "architect-constitution"
        case .compiler: return "compiler-constitution"
        case .operatorType: return "operator-constitution"
        case .echo: return "echo-constitution"
        }
    }
}

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
