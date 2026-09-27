import SwiftUI

/// The hold-to-talk indicator. It lives in the shell's overlay stack rather than in a port, so a
/// port cannot draw a fake one and cannot hide the real one.
struct VoiceIndicator: View {
    let accent: Color
    @State private var pulse = false

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.5 : 0.9)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                Text("listening")
                    .font(Port42Theme.mono(11))
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.75))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.5), lineWidth: 1))
            .padding(.bottom, 120)                    // clear of the dock
        }
        .onAppear { pulse = true }
    }
}
