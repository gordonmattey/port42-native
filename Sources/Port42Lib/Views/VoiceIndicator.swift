import SwiftUI

/// The hold-to-talk indicator, at the bottom of the shell. Used when the words are going to something
/// the shell itself owns; a port being dictated into gets the same pill over its own tile.
///
/// Either way the SHELL draws it, never the port, so a port cannot draw a fake one and cannot hide the
/// real one.
struct VoiceIndicator: View {
    let accent: Color
    let label: String
    let live: Bool

    var body: some View {
        VStack {
            Spacer()
            VoicePill(accent: accent, label: label, live: live)
                .padding(.bottom, 120)                    // clear of the dock
        }
    }
}

/// The pill itself, so the shell and a tile can show the same thing in two places.
struct VoicePill: View {
    let accent: Color
    let label: String
    let live: Bool                  // true while the microphone is open
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
                Circle()
                    .fill(live ? accent : Color.white.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse && live ? 1.5 : 0.9)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                Text(label)
                    .font(Port42Theme.mono(11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.75))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(accent.opacity(live ? 0.5 : 0.25), lineWidth: 1))
        .onAppear { pulse = true }
    }
}
