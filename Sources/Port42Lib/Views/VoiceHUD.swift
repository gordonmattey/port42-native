import AppKit
import SwiftUI

/// The hot microphone when Port42 is not the app on screen.
///
/// A panel rather than a window: borderless, non-activating, ignoring the mouse, at status-bar level. It
/// cannot take focus, so it cannot change where the words land, and it shows on every space and over a full
/// screen app, which is where dictation into another app is most likely to be used.
@MainActor
public final class VoiceHUD {

    private var panel: NSPanel?

    public init() {}

    public func show(accent: Color, label: String?) {
        let content = HStack(spacing: 8) {
            VoiceMic(accent: accent)
            if let label {
                Text(label)
                    .font(Port42Theme.mono(10))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.8))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(accent.opacity(0.4), lineWidth: 1))
        .fixedSize()

        let host = NSHostingView(rootView: content)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let panel = self.panel ?? makePanel()
        panel.setContentSize(size)
        panel.contentView = host
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: frame.maxX - size.width - 24, y: frame.minY + 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    public func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NonActivatingPanel(contentRect: .zero,
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.worksWhenModal = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}

/// A panel that can never take the keyboard or become the app's main window.
///
/// Showing and hiding an ordinary panel from an app that is not active bounces activation: the app comes
/// forward when the panel is ordered in and the previous app comes back when it is ordered out, which looked
/// like focus jumping away a few seconds after clicking on Port42 (GM, Dev7, 2026-09-27). The indicator must be
/// visible without ever being a participant in focus, or it changes where the words land.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
