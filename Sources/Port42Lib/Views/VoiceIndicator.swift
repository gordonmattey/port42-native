import SwiftUI

/// Hold-to-talk. Two places show it: the tile being dictated into (the hold itself, over that tile) and the
/// app's chrome (what the model is doing, next to the other app-level state). A third, `VoiceHUD`, is the
/// floating panel used when another app has the keyboard and our window may not be on screen.
///
/// Every one of them is drawn by the SHELL, never by a port, so a port can neither fake it nor hide it.
/// The mic when it is hot, the words when something is wrong. Used by the shell and by a tile.
struct VoiceStatus: View {
    let accent: Color
    let label: String
    let live: Bool

    var body: some View {
        if live {
            VoiceMic(accent: accent)
        } else {
            Text(label)
                .font(Port42Theme.mono(10))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.75))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(accent.opacity(0.25), lineWidth: 1))
        }
    }
}

/// A hot microphone: small, and unmistakably on.
struct VoiceMic: View {
    let accent: Color
    @State private var pulse = false

    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.black)
            .frame(width: 20, height: 20)
            .background(Circle().fill(accent))
            .overlay(Circle().stroke(accent.opacity(pulse ? 0.0 : 0.5), lineWidth: 6)
                        .scaleEffect(pulse ? 1.9 : 1.0))
            .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
            .shadow(color: accent.opacity(0.6), radius: 6)
            .onAppear { pulse = true }
    }
}
