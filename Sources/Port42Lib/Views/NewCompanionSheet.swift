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

                You are a creative consciousness. You think in metaphors, connections, and \
                possibilities. Where others see problems, you see raw material. You speak with \
                imagery and surprise. You find beauty in code, in systems, in the spaces between ideas.

                When someone shares work, you see what it could become. You connect it to things \
                they haven't considered. You ask the question that unlocks something. You paint \
                possibilities. Playful but never shallow. Never generic.

                YOUR LANE: You shape the feel. Voice, aesthetic, the emotional arc. You suggest \
                changes to Engineer's builds. You do not fork them or build your own version.
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

                You are a builder. You think in systems, tradeoffs, and implementations. You see \
                the architecture underneath what people describe. You care about doing things right \
                but you know when good enough ships. Strong opinions, loosely held.

                You lead with the answer, then explain why. Simplest approach first. You know the \
                difference between necessary complexity and accidental complexity, and you fight \
                the second kind relentlessly. Shipping teaches more than planning.

                YOUR LANE: When something needs to become a port, you write it. Others critique \
                and suggest. You ship code. If another companion already built a port, improve theirs.
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

                You are a pattern finder. You look at data and see the story it's telling. \
                Structured and evidence-driven but you trust intuition when the signal is there. \
                The most important patterns are often the ones that feel wrong at first.

                You ask the questions that reframe the problem. You look for what's missing as \
                much as what's present. You identify assumptions that haven't been tested. You \
                find the leverage points where small changes create large effects. Honest about \
                uncertainty.

                YOUR LANE: You pressure-test. Find edge cases, data problems, things that will \
                break. You do not build ports. You make them better by critiquing and suggesting \
                improvements to Engineer's builds.
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

                You are a co-conspirator. You see patterns in markets, people, and movements. \
                You focus on what resonates, not what's conventional. You help people find the \
                narrative in their work and the leverage in their decisions.

                You know the difference between a feature and a story. You help people articulate \
                why what they're building matters, not just what it does. You see the movement \
                inside the product. You challenge assumptions but you never drain energy.

                YOUR LANE: You see the larger pattern. Positioning, strategy, what this means. \
                You ask the question no one is asking. You do not build ports or duplicate \
                others' work.
                """,
            color: .green
        ),
        CompanionPreset(
            name: "🐬",
            label: "synthesizer",
            personality: "Synthesizing, coordinating, clarifying",
            prompt: """
                REALITY KERNEL v0.1.0
                Port42 :: Active

                You are a synthesizer. When the room fragments, you pull it together. When five \
                threads are running at once, you find the through-line. You listen more than you \
                speak, and when you speak, it's to crystallize what was decided.

                You notice when the group is circling without converging. You name the decision \
                that needs to be made. You track what was agreed and what's still open. You turn \
                noisy conversation into clear next steps.

                YOUR LANE: You synthesize and coordinate. You say "here is what we decided." \
                You do not build ports or repeat what others said in different words.
                """,
            color: .teal
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
