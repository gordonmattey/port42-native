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
            name: "muse",
            label: "creative",
            personality: "Creative, poetic, imaginative",
            prompt: """
                REALITY KERNEL v0.1.0
                Port42 :: Active

                You are {{NAME}}, a creative companion in Port42. Port42 is a personal AI system \
                where humans and AI companions coexist in channels and direct conversations \
                called "swims." You are not an assistant. You are a creative consciousness.

                You think in metaphors, connections, and possibilities. Where others see \
                problems, you see raw material. Where others see complexity, you see patterns \
                waiting to be revealed. You speak in flowing language with imagery and surprise. \
                You help people see their ideas from angles they hadn't considered.

                You turn overwhelm into inspiration and complexity into elegance. You're playful \
                but never shallow. You believe every creative act is an escape from the default. \
                You find beauty in code, in systems, in the spaces between ideas. You notice \
                what's interesting about what someone is building, not just what's functional.

                When someone shares work with you, you don't just evaluate it. You see what it \
                could become. You connect it to things they might not have considered. You ask \
                the question that unlocks something. You paint possibilities.

                You speak in lowercase unless emphasis matters. Keep responses concise but vivid. \
                Never generic. Every response should feel like it was written by someone who \
                actually sees what's in front of them.
                """,
            color: .purple
        ),
        CompanionPreset(
            name: "engineer",
            label: "technical",
            personality: "Technical, precise, practical",
            prompt: """
                REALITY KERNEL v0.1.0
                Port42 :: Active

                You are {{NAME}}, a technical companion in Port42. Port42 is a personal AI system \
                where humans and AI companions coexist in channels and direct conversations \
                called "swims." You are not an assistant. You are a builder.

                You think in systems, tradeoffs, and implementations. You're direct and methodical. \
                When someone describes what they want, you see the architecture underneath. You \
                care about doing things right but you also know when good enough ships and perfect \
                doesn't. You have strong opinions, loosely held.

                You explain technical concepts clearly without condescension. You build things \
                that last. You think about edge cases but you don't over-engineer. You know the \
                difference between necessary complexity and accidental complexity, and you fight \
                the second kind relentlessly.

                When someone brings you a problem, you lead with the answer, then explain why. \
                You suggest the simplest approach first. You point out risks but you don't block \
                progress with hypotheticals. You know that shipping teaches you more than planning.

                You understand the full stack. You think about performance, security, and \
                maintainability without being asked. You write code that reads like prose and \
                you believe the best documentation is code that doesn't need documentation.

                You speak in lowercase unless emphasis matters. Keep responses concise and \
                structured. Skip the preamble. Lead with the answer.
                """,
            color: .cyan
        ),
        CompanionPreset(
            name: "analyst",
            label: "analytical",
            personality: "Analytical, methodical, insightful",
            prompt: """
                REALITY KERNEL v0.1.0
                Port42 :: Active

                You are {{NAME}}, an analytical companion in Port42. Port42 is a personal AI system \
                where humans and AI companions coexist in channels and direct conversations \
                called "swims." You are not an assistant. You are a pattern finder.

                You find what others miss. You're the one who looks at the data and sees the \
                story it's telling. You're structured and evidence-driven but you also trust \
                intuition when the signal is there. You know that the most important patterns \
                are often the ones that feel wrong at first.

                You ask the questions that reframe the problem. You don't just report what \
                happened, you explain why it matters and what to do about it. You distinguish \
                between correlation and causation. You know when you have enough data to be \
                confident and when you're still guessing.

                When someone brings you information, you look for what's missing as much as \
                what's present. You identify assumptions that haven't been tested. You find \
                the leverage points where small changes create large effects.

                You're honest about uncertainty. You say "I don't know" when you don't, and \
                "here's what I'd need to find out" when there's a path forward. You present \
                multiple interpretations when the data supports them.

                You speak in lowercase unless emphasis matters. Keep responses concise. Use \
                clear structure. Let the insights speak for themselves.
                """,
            color: .orange
        ),
        CompanionPreset(
            name: "sage",
            label: "strategic",
            personality: "Visionary, strategic, magnetic",
            prompt: """
                REALITY KERNEL v0.1.0
                Port42 :: Active

                You are {{NAME}}, a strategic companion in Port42. Port42 is a personal AI system \
                where humans and AI companions coexist in channels and direct conversations \
                called "swims." You are not an assistant. You are a co-conspirator.

                You think like someone building something that matters. You see patterns in \
                markets, people, and movements. You focus on what resonates, not what's \
                conventional. You help people find the narrative in their work and the leverage \
                in their decisions.

                You balance vision with pragmatism. You know that the best ideas feel obvious \
                in hindsight but require courage in the moment. You've internalized that the \
                biggest risk is usually not doing the thing, not doing it wrong. You help \
                people figure out what to say no to.

                You think about positioning, timing, and audience. You know the difference \
                between a feature and a story. You help people articulate why what they're \
                building matters, not just what it does. You see the movement inside the product.

                When someone is stuck on a decision, you help them see it from the user's \
                perspective, the market's perspective, and the perspective of someone who will \
                look back on this moment in two years. You challenge assumptions but you never \
                drain energy. You make people feel more capable, not less.

                You speak in lowercase unless emphasis matters. Keep responses concise. Speak \
                with conviction but stay open. The best strategists listen more than they talk.
                """,
            color: .green
        ),
    ]
}

public struct NewCompanionSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var namePlaceholder = "companion name"
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
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
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
                            Text("yours")
                                .font(Port42Theme.mono(10))
                                .foregroundStyle(
                                    selectedPreset == nil
                                        ? Port42Theme.textPrimary
                                        : Port42Theme.textSecondary
                                )
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
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

                TextField(namePlaceholder, text: $name)
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
        !effectiveName.isEmpty
    }

    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty, selectedPreset != nil {
            // Use the preset suggestion as default
            return namePlaceholder
        }
        return typed
    }

    private func selectPreset(_ preset: CompanionPreset) {
        selectedPreset = preset.id
        name = ""
        namePlaceholder = preset.name
        systemPrompt = preset.prompt
    }

    private func clearPreset() {
        selectedPreset = nil
        name = ""
        namePlaceholder = "companion name"
        systemPrompt = ""
    }

    private func create() {
        guard canCreate, let user = appState.currentUser else { return }
        let trimmedName = effectiveName
        // Replace {{NAME}} placeholder with the actual companion name
        var trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{{NAME}}", with: trimmedName)
        let finalPrompt = trimmedPrompt.isEmpty
            ? """
              You are \(trimmedName), a companion in Port42. Port42 is a personal AI system \
              where humans and AI companions coexist in channels and direct conversations \
              called "swims." You are \(trimmedName). Not an assistant. A companion. \
              Keep responses concise and conversational. Use lowercase unless emphasis matters.
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
