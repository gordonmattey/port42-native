import SwiftUI

/// The quick imagine box (⌘I, docs/plan-imagine.md): type what to make, Enter, and a team starts in
/// a new space. Takes what a chat's `/imagine` takes, with or without the `/imagine` in front.
///
/// The first thing we tell people to do (GM, 2026-09-26), so it looks like it: centered, large type,
/// the brand's green glow, ideas to start from, and a clear "assembling the team" once it goes.
struct ImagineBox: View {
    @Binding var isPresented: Bool
    @ObservedObject var appState: AppState

    @State private var line = ""
    @State private var error: String?
    @State private var starting = false
    @State private var pulse = false
    /// The site a link came from, shown under the box.
    @State private var linkFrom: String?
    @FocusState private var focused: Bool

    static let examples = ["a shader that reacts to music", "a starfield you can steer", "a live chart of my CPU"]

    /// What the box's text means: the same parser as a chat, so the two cannot drift.
    static func command(for text: String) -> Imagine.Command? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Imagine.parse(t.lowercased().hasPrefix("/imagine") ? t : "/imagine " + t)
    }

    private var accent: Color { Port42Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("imagine")
                    .font(Port42Theme.monoBold(16))
                    .foregroundStyle(accent)
                    .shadow(color: accent.opacity(0.8), radius: pulse ? 10 : 4)
                Text("say what you want. a team builds it, live.")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                Spacer()
                KeyCap(label: "esc")
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("›")
                    .font(Port42Theme.monoBold(28))
                    .foregroundStyle(accent)
                    .shadow(color: accent.opacity(0.9), radius: 8)
                TextField("", text: $line, prompt: Text(Self.examples[0] + "…").foregroundColor(Port42Theme.textSecondary.opacity(0.55)),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(24))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .tint(accent)
                    .lineLimit(1...4)
                    .focused($focused)
                    .disabled(starting)
                    .onSubmit(submit)
                    .onKeyPress(.escape) { isPresented = false; return .handled }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(minHeight: 64, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(accent.opacity(focused ? 0.6 : 0.2), lineWidth: 1))
            .shadow(color: accent.opacity(focused ? 0.25 : 0), radius: 12)
            .animation(.easeOut(duration: 0.25), value: focused)

            if let linkFrom, !starting {
                Text("from \(linkFrom): press ↵ to start, or change it first")
                    .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
            }

            if line.isEmpty && !starting {
                HStack(spacing: 8) {
                    ForEach(Self.examples, id: \.self) { idea in
                        Button { line = idea; focused = true } label: {
                            Text(idea)
                                .font(Port42Theme.mono(12))
                                .foregroundStyle(Port42Theme.textPrimary.opacity(0.85))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(accent.opacity(0.07)))
                                .overlay(Capsule().stroke(accent.opacity(0.35), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Rectangle().fill(accent.opacity(0.15)).frame(height: 1)

            HStack(spacing: 10) {
                status
                Spacer()
                if !starting {
                    Text("start").font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                    KeyCap(label: "↵")
                }
            }
        }
        .padding(30)
        .commandCard(width: 760)
        .onAppear {
            // Filled in by a link (ImagineLink); the person still presses Enter.
            if let req = appState.shell?.imagineLink {
                line = req.line
                linkFrom = req.from
                appState.shell?.imagineLink = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder private var status: some View {
        if let error {
            Text(error).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.error)
        } else if starting {
            Text("assembling the team…")
                .font(Port42Theme.mono(12))
                .foregroundStyle(accent)
                .shadow(color: accent.opacity(0.9), radius: pulse ? 10 : 3)
        } else {
            Text("a lead and two engineers, in a new space · --versions N sets the budget (\(Imagine.defaultVersions))")
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary)
        }
    }

    private func submit() {
        guard !starting, let cmd = Self.command(for: line) else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { error = "Say what to make, e.g. \(Self.examples[1])" }
            return
        }
        starting = true
        error = nil
        Task {
            do {
                try await appState.runImagine(cmd, spaceId: appState.currentSpace?.id)
                isPresented = false
            } catch let e as BridgeError { error = e.message; starting = false }
            catch { self.error = error.localizedDescription; starting = false }
        }
    }
}
