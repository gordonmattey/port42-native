import SwiftUI

public struct EditCompanionSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    let companion: AgentConfig

    @State private var name: String
    @State private var systemPrompt: String
    @FocusState private var isFocused: Bool

    public init(isPresented: Binding<Bool>, companion: AgentConfig) {
        self._isPresented = isPresented
        self.companion = companion
        self._name = State(initialValue: companion.displayName)
        self._systemPrompt = State(initialValue: companion.systemPrompt ?? "")
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Edit Swimmer")
                .font(Port42Theme.monoBold(16))
                .foregroundStyle(Port42Theme.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                TextField("companion name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(14))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .focused($isFocused)
                    .padding(10)
                    .background(Port42Theme.bgInput)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Port42Theme.border, lineWidth: 1)
                    )
                    .cornerRadius(6)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("System Prompt")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                TextEditor(text: $systemPrompt)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 100)
                    .background(Port42Theme.bgInput)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Port42Theme.border, lineWidth: 1)
                    )
                    .cornerRadius(6)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(Port42Theme.mono(13))
                .foregroundStyle(Port42Theme.textSecondary)

                Button(action: save) {
                    Text("Save")
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(Port42Theme.bgPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            canSave ? Port42Theme.accent : Port42Theme.accent.opacity(0.3)
                        )
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(Port42Theme.bgSecondary)
        .onAppear {
            isFocused = true
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave else { return }
        var updated = companion
        updated.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.systemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.updateCompanion(updated)
        isPresented = false
    }
}
