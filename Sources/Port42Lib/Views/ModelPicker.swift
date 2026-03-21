import SwiftUI

// MARK: - Model Options

struct ModelOption: Identifiable {
    let id: String       // model identifier sent to API
    let label: String    // short display name
    let note: String     // cost/capability hint
}

let anthropicModelOptions: [ModelOption] = [
    ModelOption(id: "claude-haiku-4-5-20251001", label: "haiku",  note: "fast · cheap"),
    ModelOption(id: "claude-sonnet-4-6",          label: "sonnet", note: "balanced"),
    ModelOption(id: "claude-opus-4-6",            label: "opus",   note: "best · costly"),
]

let geminiModelOptions: [ModelOption] = [
    ModelOption(id: "gemini-2.0-flash",  label: "flash",    note: "fast · cheap"),
    ModelOption(id: "gemini-2.5-flash",  label: "flash 2.5", note: "balanced"),
    ModelOption(id: "gemini-2.5-pro",    label: "pro",      note: "best · costly"),
]

// Keep backward-compat alias
let modelOptions = anthropicModelOptions

func defaultModel(for provider: AgentProvider) -> String {
    switch provider {
    case .anthropic: return "claude-opus-4-6"
    case .gemini: return "gemini-2.0-flash"
    case .compatibleEndpoint: return ""
    }
}

// MARK: - ModelPicker (Anthropic, fixed list)

struct ModelPicker: View {
    @Binding var selectedModel: String
    var options: [ModelOption] = anthropicModelOptions

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                Button(action: { selectedModel = option.id }) {
                    VStack(spacing: 3) {
                        Text(option.label)
                            .font(Port42Theme.monoBold(11))
                            .foregroundStyle(
                                selectedModel == option.id
                                    ? Port42Theme.accent
                                    : Port42Theme.textPrimary
                            )
                        Text(option.note)
                            .font(Port42Theme.mono(9))
                            .foregroundStyle(Port42Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        selectedModel == option.id
                            ? Port42Theme.accent.opacity(0.1)
                            : Color.clear
                    )
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                selectedModel == option.id
                                    ? Port42Theme.accent.opacity(0.5)
                                    : Port42Theme.border,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - ProviderPicker

struct ProviderPicker: View {
    @Binding var selectedProvider: AgentProvider

    private let providers: [(AgentProvider, String)] = [
        (.anthropic, "Anthropic"),
        (.gemini, "Gemini"),
        (.compatibleEndpoint, "Compatible"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(providers, id: \.0) { provider, label in
                Button(action: { selectedProvider = provider }) {
                    Text(label)
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(
                            selectedProvider == provider
                                ? Port42Theme.accent
                                : Port42Theme.textSecondary
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            selectedProvider == provider
                                ? Port42Theme.accent.opacity(0.1)
                                : Color.clear
                        )
                        .cornerRadius(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(
                                    selectedProvider == provider
                                        ? Port42Theme.accent.opacity(0.5)
                                        : Port42Theme.border,
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - ProviderModelSection
// Renders the full provider + model selection block including base URL and warnings.

struct ProviderModelSection: View {
    @Binding var selectedProvider: AgentProvider
    @Binding var selectedModel: String
    @Binding var providerBaseURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider")
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary)

            ProviderPicker(selectedProvider: $selectedProvider)
                .onChange(of: selectedProvider) { _, newProvider in
                    selectedModel = defaultModel(for: newProvider)
                    if newProvider != .compatibleEndpoint {
                        providerBaseURL = ""
                    }
                }

            // Gemini: warning if no key configured
            if selectedProvider == .gemini,
               Port42AuthStore.shared.loadCredential(provider: "gemini") == nil {
                Text("Add a Gemini API key in Settings → AI connection to use this provider.")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.8))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Port42Theme.accent.opacity(0.08))
                    .cornerRadius(5)
            }

            // Compatible: base URL field
            if selectedProvider == .compatibleEndpoint {
                TextField("http://localhost:11434/v1", text: $providerBaseURL)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .padding(8)
                    .background(Port42Theme.bgInput)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Port42Theme.border, lineWidth: 1)
                    )
                    .cornerRadius(6)
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary)

            switch selectedProvider {
            case .anthropic:
                ModelPicker(selectedModel: $selectedModel, options: anthropicModelOptions)
            case .gemini:
                ModelPicker(selectedModel: $selectedModel, options: geminiModelOptions)
            case .compatibleEndpoint:
                TextField("llama3.2, mistral, gpt-4o…", text: $selectedModel)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .padding(8)
                    .background(Port42Theme.bgInput)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Port42Theme.border, lineWidth: 1)
                    )
                    .cornerRadius(6)
            }
        }
    }
}
