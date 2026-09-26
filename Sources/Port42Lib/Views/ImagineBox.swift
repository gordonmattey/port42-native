import SwiftUI

/// The quick imagine box (⌘I, docs/plan-imagine.md): type what to make, Enter, and a team starts in
/// a new space. Takes what a chat's `/imagine` takes, with or without the `/imagine` in front.
struct ImagineBox: View {
    @Binding var isPresented: Bool
    @ObservedObject var appState: AppState

    @State private var line = ""
    @State private var error: String?
    @State private var starting = false
    @FocusState private var focused: Bool

    /// What the box's text means: the same parser as a chat, so the two cannot drift.
    static func command(for text: String) -> Imagine.Command? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Imagine.parse(t.lowercased().hasPrefix("/imagine") ? t : "/imagine " + t)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(Port42Theme.textSecondary)
                TextField("imagine…", text: $line)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(14))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .focused($focused)
                    .disabled(starting)
                    .onSubmit(submit)
                    .onKeyPress(.escape) { isPresented = false; return .handled }
                Text("esc")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Port42Theme.bgHover)
                    .cornerRadius(3)
            }
            .padding(12)
            Divider().background(Port42Theme.border)
            Text(error ?? (starting ? "starting a team…" : "A lead and two engineers build it in a new space. --versions N sets the budget (default \(Imagine.defaultVersions))."))
                .font(Port42Theme.mono(10))
                .foregroundStyle(error == nil ? Port42Theme.textSecondary : Color.red.opacity(0.85))
                .padding(12)
        }
        .background(Port42Theme.bgSecondary)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Port42Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 20)
        .frame(width: 520)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
    }

    private func submit() {
        guard !starting, let cmd = Self.command(for: line) else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { error = "Say what to make, e.g. a clock made of light" }
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
