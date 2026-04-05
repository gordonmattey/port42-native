import SwiftUI

public struct EditCompanionSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    let companion: AgentConfig

    @State private var name: String
    @State private var systemPrompt: String
    @State private var selectedProvider: AgentProvider
    @State private var selectedModel: String
    @State private var providerBaseURL: String
    @State private var thinkingEnabled: Bool
    @State private var thinkingEffort: String
    @State private var selectedSecrets: Set<String>
    @FocusState private var isFocused: Bool

    public init(isPresented: Binding<Bool>, companion: AgentConfig) {
        self._isPresented = isPresented
        self.companion = companion
        self._name = State(initialValue: companion.displayName)
        self._systemPrompt = State(initialValue: companion.systemPrompt ?? "")
        self._selectedProvider = State(initialValue: companion.provider ?? .anthropic)
        self._selectedModel = State(initialValue: companion.model ?? "claude-opus-4-6")
        self._providerBaseURL = State(initialValue: companion.providerBaseURL ?? "")
        self._thinkingEnabled = State(initialValue: companion.thinkingEnabled)
        self._thinkingEffort = State(initialValue: companion.thinkingEffort)
        self._selectedSecrets = State(initialValue: Set(companion.secretNames ?? []))
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Edit Companion")
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

            ProviderModelSection(
                selectedProvider: $selectedProvider,
                selectedModel: $selectedModel,
                providerBaseURL: $providerBaseURL
            )

            // Extended Thinking: only for Anthropic
            if selectedProvider == .anthropic {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Extended Thinking")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                    Spacer()
                    Toggle("", isOn: $thinkingEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Port42Theme.accent)
                }

                if thinkingEnabled {
                    HStack(spacing: 6) {
                        ForEach(["low", "medium", "high"], id: \.self) { effort in
                            Button(action: { thinkingEffort = effort }) {
                                Text(effort)
                                    .font(Port42Theme.mono(11))
                                    .foregroundStyle(
                                        thinkingEffort == effort
                                            ? Port42Theme.accent
                                            : Port42Theme.textSecondary
                                    )
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background(
                                        thinkingEffort == effort
                                            ? Port42Theme.accent.opacity(0.1)
                                            : Color.clear
                                    )
                                    .cornerRadius(5)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(
                                                thinkingEffort == effort
                                                    ? Port42Theme.accent.opacity(0.5)
                                                    : Port42Theme.border,
                                                lineWidth: 1
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("Uses more tokens. Only active on Claude Code OAuth.")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                }
            }
            } // end if selectedProvider == .anthropic

            // Secret access
            let availableSecrets = Port42AuthStore.shared.listSecrets()
            if !availableSecrets.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Secrets")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                    HStack(spacing: 6) {
                        ForEach(availableSecrets) { secret in
                            Button(action: {
                                if selectedSecrets.contains(secret.name) {
                                    selectedSecrets.remove(secret.name)
                                } else {
                                    selectedSecrets.insert(secret.name)
                                }
                            }) {
                                Text(secret.name)
                                    .font(Port42Theme.mono(11))
                                    .foregroundStyle(selectedSecrets.contains(secret.name) ? Port42Theme.accent : Port42Theme.textSecondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        selectedSecrets.contains(secret.name)
                                            ? Port42Theme.accent.opacity(0.15)
                                            : Port42Theme.bgSecondary.opacity(0.5)
                                    )
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
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
        updated.provider = selectedProvider
        updated.providerBaseURL = providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.model = selectedModel
        updated.thinkingEnabled = thinkingEnabled
        updated.thinkingEffort = thinkingEffort
        updated.secretNames = selectedSecrets.isEmpty ? nil : Array(selectedSecrets).sorted()
        appState.updateCompanion(updated)
        isPresented = false
    }
}
