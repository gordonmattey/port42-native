import SwiftUI

/// A port drawn at card size shows this instead of a miniature of its content: its state, from what it
/// declared and what Port42 knows (docs/plan-port-state-v1.md). A peek is card-sized, so a peek shows
/// it. Port42 always draws the card (GM, 2026-09-29). A wide card runs its lines as one strip; a tall
/// or square one stacks them.
struct PortStateCard: View {
    @ObservedObject var appState: AppState
    @ObservedObject var states: PortStateStore
    @ObservedObject var presence: ChatPresenceStore
    @ObservedObject var console = PortConsole.shared
    @ObservedObject var chats: PortChatStore
    let panel: PortPanel
    let size: CGSize
    let accent: Color

    var body: some View {
        // Re-read every few seconds so "2m ago" stays true; state changes redraw at once.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let card = appState.portCard(panel)
            let wide = PortPresentation.orientation(size) == .wide
            VStack(alignment: .leading, spacing: 5) {
                if card.lines.isEmpty {
                    Spacer(minLength: 0)
                    Text(kindLabel)
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
                    Spacer(minLength: 0)
                } else if wide {
                    strip(card.lines)
                        .font(Port42Theme.mono(10))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                } else {
                    ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                        row(line)
                    }
                    Spacer(minLength: 0)
                }
                if let p = card.progress { bar(p, failed: card.progressFailed) }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.black)
        }
    }

    private var kindLabel: String {
        switch panel.portType {
        case "terminal": return "terminal"
        case "browser": return "browser"
        default: return "port"
        }
    }

    /// A wide card's lines as one run of text, each label dim and each value in its tone, so a failure
    /// still stands out.
    private func strip(_ lines: [PortCard.Line]) -> Text {
        lines.enumerated().reduce(Text("")) { text, item in
            let (i, line) = item
            let sep = i == 0 ? Text("") : Text(" · ").foregroundColor(Port42Theme.textSecondary.opacity(0.5))
            return text + sep
                + Text(line.label + " ").foregroundColor(Port42Theme.textSecondary.opacity(0.7))
                + Text(line.value).foregroundColor(color(line.tone))
        }
    }

    private func row(_ line: PortCard.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line.label)
                .font(Port42Theme.mono(9))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                .frame(width: 50, alignment: .leading)
            Text(line.value)
                .font(Port42Theme.mono(10))
                .foregroundStyle(color(line.tone))
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func color(_ tone: PortCard.Tone) -> Color {
        switch tone {
        case .normal: return Port42Theme.textPrimary.opacity(0.9)
        case .alert: return Color(red: 1, green: 0.45, blue: 0.4)
        case .quiet: return Port42Theme.textSecondary
        }
    }

    private func bar(_ p: Double, failed: Bool) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(failed ? Color.red.opacity(0.8) : accent)
                    .frame(width: max(3, g.size.width * min(1, max(0, p))))
            }
        }
        .frame(height: 3)
    }
}
