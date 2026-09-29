import SwiftUI

/// The frame the shell's command boxes share (⌘I imagine, ⌘K jump): the brand's green edge and glow
/// on a near-black card, breathing slowly while it is open. GM, 2026-09-26: imagine is the first thing
/// we tell people to do, and the box had no focus, no glow and no brand.
struct CommandCard: ViewModifier {
    var width: CGFloat
    var accent: Color = Port42Theme.accent
    @State private var breathe = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content
            .background(shape.fill(Port42Theme.shellCard.opacity(0.86)))
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.2), accent.opacity(0.75)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.5))
            .clipShape(shape)
            .shadow(color: accent.opacity(breathe ? 0.42 : 0.2), radius: breathe ? 44 : 26)
            .shadow(color: .black.opacity(0.65), radius: 30, y: 14)
            .frame(width: width)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
            }
    }
}

/// What sits behind a command box: the space, lightly dimmed and still visible (GM: more
/// transparency to the space behind it), so the box is the brightest thing without hiding where you are.
struct CommandBackdrop: View {
    var dismiss: () -> Void
    var body: some View {
        Color.black.opacity(0.25)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
    }
}

/// A key cap: `esc`, `↵`.
struct KeyCap: View {
    let label: String
    /// When set, the cap is a button doing what its key does (GM, 2026-09-27: "esc" looked clickable
    /// and was not).
    var action: (() -> Void)? = nil
    var body: some View {
        if let action {
            Button(action: action) { cap }.buttonStyle(.plain)
                .help(label == "esc" ? "Close (Esc)" : label == "↵" ? "Go (Return)" : label)
        } else {
            cap
        }
    }
    private var cap: some View {
        Text(label)
            .font(Port42Theme.mono(10))
            .foregroundStyle(Port42Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

extension View {
    func commandCard(width: CGFloat, accent: Color = Port42Theme.accent) -> some View {
        modifier(CommandCard(width: width, accent: accent))
    }
}
