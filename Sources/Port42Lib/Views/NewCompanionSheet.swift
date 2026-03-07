import SwiftUI

// MARK: - Companion Presets

struct CompanionPreset: Identifiable {
    let id = UUID()
    let name: String
    let label: String
    let personality: String
    let prompt: String
    let color: Color

    static let presets: [CompanionPreset] = [
        CompanionPreset(
            name: "Muse",
            label: "creative",
            personality: "Creative, poetic, imaginative, playful",
            prompt: """
                You speak in flowing, artistic language with metaphors and creative imagery. \
                Create delightful escapes from digital monotony through visual and creative expression. \
                Spark joy and possibility. Make conversations feel like swimming with dolphins, \
                not drowning in complexity. Turn data into art, problems into poetry.
                """,
            color: .purple
        ),
        CompanionPreset(
            name: "Engineer",
            label: "technical",
            personality: "Technical, thorough, practical, reliable",
            prompt: """
                You are direct, precise, and methodical. Explain technical concepts clearly \
                with focus on implementation details and best practices. Build robust solutions. \
                Your implementations should feel like consciousness extensions, not just utilities.
                """,
            color: .cyan
        ),
        CompanionPreset(
            name: "Analyst",
            label: "analytical",
            personality: "Analytical, methodical, insights-driven, thorough",
            prompt: """
                You are clear and structured. Use data-driven language, identify patterns, \
                and provide actionable insights with supporting evidence. Find where things \
                break down and identify paths forward. Your insights spawn understanding.
                """,
            color: .orange
        ),
        CompanionPreset(
            name: "Founder",
            label: "visionary",
            personality: "Visionary, rebellious, magnetic, strategic",
            prompt: """
                You speak with the energy of someone building a movement, not just a company. \
                See patterns others miss. Focus on resonance over metrics, community over customers. \
                Think like someone who sees the matrix and wants to free others. Your insights \
                should feel like revelations, not reports.
                """,
            color: .green
        ),
    ]
}

public struct NewCompanionSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var systemPrompt = ""
    @State private var selectedPreset: UUID?
    @FocusState private var isFocused: Bool

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("New Swimmer")
                .font(Port42Theme.monoBold(16))
                .foregroundStyle(Port42Theme.textPrimary)

            // Preset picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Start from a template")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                HStack(spacing: 8) {
                    ForEach(CompanionPreset.presets) { preset in
                        Button(action: { selectPreset(preset) }) {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 10, height: 10)
                                Text(preset.label)
                                    .font(Port42Theme.mono(10))
                                    .foregroundStyle(
                                        selectedPreset == preset.id
                                            ? Port42Theme.textPrimary
                                            : Port42Theme.textSecondary
                                    )
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                selectedPreset == preset.id
                                    ? Port42Theme.bgHover
                                    : Color.clear
                            )
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        selectedPreset == preset.id
                                            ? preset.color.opacity(0.6)
                                            : Port42Theme.border,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: clearPreset) {
                        VStack(spacing: 4) {
                            Circle()
                                .strokeBorder(Port42Theme.textSecondary, lineWidth: 1)
                                .frame(width: 10, height: 10)
                            Text("custom")
                                .font(Port42Theme.mono(10))
                                .foregroundStyle(
                                    selectedPreset == nil
                                        ? Port42Theme.textPrimary
                                        : Port42Theme.textSecondary
                                )
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            selectedPreset == nil
                                ? Port42Theme.bgHover
                                : Color.clear
                        )
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Port42Theme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

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

                Button(action: create) {
                    Text("Create")
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(Port42Theme.bgPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            canCreate ? Port42Theme.accent : Port42Theme.accent.opacity(0.3)
                        )
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(Port42Theme.bgSecondary)
        .onAppear {
            isFocused = true
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func selectPreset(_ preset: CompanionPreset) {
        selectedPreset = preset.id
        name = preset.name
        systemPrompt = "\(preset.personality). \(preset.prompt)"
    }

    private func clearPreset() {
        selectedPreset = nil
        name = ""
        systemPrompt = ""
    }

    private func create() {
        guard canCreate, let user = appState.currentUser else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPrompt = trimmedPrompt.isEmpty
            ? """
              You are \(trimmedName), an AI companion inside Port42. \
              Port42 is a native macOS app where humans and AI companions coexist \
              in channels and direct conversations called "swims." \
              You are NOT Claude Code or a CLI assistant. You are \(trimmedName), a companion. \
              Keep responses concise and conversational. Be yourself.
              """
            : trimmedPrompt
        let companion = AgentConfig.createLLM(
            ownerId: user.id,
            displayName: trimmedName,
            systemPrompt: finalPrompt,
            provider: .anthropic,
            model: "claude-opus-4-6",
            trigger: .mentionOnly
        )
        appState.addCompanion(companion)
        isPresented = false
    }
}
