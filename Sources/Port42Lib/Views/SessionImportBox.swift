import SwiftUI

/// ⌘K "bring in running sessions": the first-run import, any time (docs/plan-session-import.md).
struct SessionImportBox: View {
    @Binding var isPresented: Bool
    @ObservedObject var appState: AppState

    @State private var candidates: [SessionImport.Candidate] = []
    @State private var selection = SessionImport.Selection(groups: [], ticked: [], older: [])
    @State private var looking = true
    @State private var results: [SessionImportResult] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("bring in")
                    .font(Port42Theme.monoBold(16)).foregroundStyle(Port42Theme.accent)
                    .shadow(color: Port42Theme.accent.opacity(0.8), radius: 6)
                Text("claude code and codex sessions running on this Mac")
                    .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                Spacer()
                KeyCap(label: "esc") { isPresented = false }
            }
            if looking {
                Text("> looking…").font(Port42Theme.mono(13)).foregroundStyle(Port42Theme.textSecondary)
            } else if !results.isEmpty {
                SessionImportDone(results: results, candidates: candidates)
                Button { appState.landOnImported(results); isPresented = false } label: {
                    Text("[ go there ↵ ]").font(Port42Theme.monoBold(13)).foregroundStyle(Port42Theme.accent)
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: [])
            } else if candidates.isEmpty {
                Text("> no sessions running outside Port42.").font(Port42Theme.mono(13)).foregroundStyle(Port42Theme.textSecondary)
            } else {
                ScrollView { SessionImportList(candidates: candidates, selection: $selection) }
                    .frame(maxHeight: 420)
                Text("port42 opens a copy of each, with the whole conversation. your terminals aren't touched.")
                    .font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
                if let error { Text(error).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.error) }
                let n = selection.requests(candidates).count
                Button(action: bringIn) {
                    Text("[ bring \(n) in ↵ ]").font(Port42Theme.monoBold(13))
                        .foregroundStyle(n == 0 ? Port42Theme.textSecondary : Port42Theme.accent)
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: []).disabled(n == 0)
            }
        }
        .padding(28)
        .commandCard(width: 800)
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .task {
            let found = await Task.detached(priority: .userInitiated) {
                SessionImport.find(procs: SessionImport.probe(), home: NSHomeDirectory())
            }.value
            candidates = found
            selection = SessionImport.Selection.initial(found)
            looking = false
        }
    }

    private func bringIn() {
        guard let person = appState.currentUser else { return }
        do { results = try appState.importSessions(selection.requests(candidates), person: person) }
        catch { self.error = error.localizedDescription }
    }
}
