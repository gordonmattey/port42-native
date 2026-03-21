import SwiftUI

struct ModelOption: Identifiable {
    let id: String       // model identifier sent to API
    let label: String    // short display name
    let note: String     // cost/capability hint
}

let modelOptions: [ModelOption] = [
    ModelOption(id: "claude-haiku-4-5-20251001", label: "haiku",  note: "fast · cheap"),
    ModelOption(id: "claude-sonnet-4-6",          label: "sonnet", note: "balanced"),
    ModelOption(id: "claude-opus-4-6",            label: "opus",   note: "best · costly"),
]

struct ModelPicker: View {
    @Binding var selectedModel: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(modelOptions) { option in
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
