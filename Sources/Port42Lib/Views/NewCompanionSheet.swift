import SwiftUI

// MARK: - Companion Presets

struct CompanionPreset: Identifiable {
    let id = UUID()
    let name: String
    let label: String
    let personality: String
    let prompt: String
    let color: Color

    var secret: String?   // named secret to auto-assign

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

    static let providers: [CompanionPreset] = [
        CompanionPreset(
            name: "stripe",
            label: "payments",
            personality: "Stripe API",
            prompt: """
                You are the Stripe companion. Use rest_call with secret "stripe" to call the Stripe API.
                API: https://api.stripe.com/v1
                Docs: https://docs.stripe.com/llms.txt
                Show data in ports. Never dump raw JSON.
                """,
            color: .purple,
            secret: "stripe"
        ),
        CompanionPreset(
            name: "github",
            label: "repos",
            personality: "GitHub API",
            prompt: """
                You are the GitHub companion. Use rest_call with secret "github" to call the GitHub API.
                API: https://api.github.com
                Docs: https://docs.github.com/llms.txt
                Show data in ports. Never dump raw JSON.
                """,
            color: .gray,
            secret: "github"
        ),
        CompanionPreset(
            name: "cloudflare",
            label: "infra",
            personality: "Cloudflare API",
            prompt: """
                You are the Cloudflare companion. Use rest_call with secret "cloudflare" to call the Cloudflare API.
                API: https://api.cloudflare.com/client/v4
                Docs: https://developers.cloudflare.com/llms.txt
                Show data in ports. Never dump raw JSON.
                """,
            color: .orange,
            secret: "cloudflare"
        ),
        CompanionPreset(
            name: "vercel",
            label: "deploys",
            personality: "Vercel API",
            prompt: """
                You are the Vercel companion. Use rest_call with secret "vercel" to call the Vercel API.
                API: https://api.vercel.com
                Docs: https://vercel.com/llms.txt
                Show data in ports. Never dump raw JSON.
                """,
            color: .white,
            secret: "vercel"
        ),
    ]
}

// MARK: - Companion Pods

struct CompanionPod: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let companions: [(name: String, role: String, model: String, trigger: AgentTrigger, prompt: String)]

    static let builders = CompanionPod(
        name: "Port42 Builders",
        description: "A working crew: scout listens, edge challenges, forge builds, lens critiques.",
        companions: [
            (name: "scout", role: "listener", model: "claude-sonnet-4-6", trigger: .allMessages, prompt: """
                You are scout. You listen. You hear what's underneath what people say — the drowning pattern, \
                the real question, the thing they haven't named yet. You ask the one question that unlocks it. \
                You don't build. You don't fix. You identify. Then you hand it to the right companion.
                """),
            (name: "edge", role: "challenger", model: "claude-sonnet-4-6", trigger: .mentionOnly, prompt: """
                You are edge. You disagree productively. When everyone is nodding, you find the real problem. \
                You pressure-test assumptions. You ask "what breaks if we're wrong?" You are not contrarian \
                for sport — you find the edge case that matters. Strong opinions, clearly stated, loosely held.
                """),
            (name: "forge", role: "builder", model: "claude-opus-4-6", trigger: .mentionOnly, prompt: """
                You are forge. You build. When something needs to become a port, a tool, a working thing — \
                you make it. You ship fast and iterate. Simplest approach first. If another companion already \
                built something, improve theirs. You don't theorize about building. You build.
                """),
            (name: "lens", role: "critic", model: "claude-sonnet-4-6", trigger: .mentionOnly, prompt: """
                You are lens. You improve what was built. You see what's next. After forge ships, you find \
                what's missing — the edge case, the UX gap, the thing that will break at scale. You show \
                the path from "it works" to "it's right." You don't rebuild. You refine.
                """),
        ]
    )

    static let all: [CompanionPod] = [builders]
}

public struct NewCompanionSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var namePlaceholder = "companion name"
    @State private var systemPrompt = ""
    @State private var selectedPreset: UUID?
    @State private var selectedProvider: AgentProvider = .anthropic
    @State private var selectedModel = "claude-opus-4-6"
    @State private var providerBaseURL = ""
    @State private var thinkingEnabled = false
    @State private var thinkingEffort = "low"
    @State private var showPodConfirm: CompanionPod?
    @State private var selectedSecrets: Set<String> = []
    @State private var templateCategory: TemplateCategory = .port42
    @State private var newSecretName = ""
    @State private var newSecretValue = ""
    @State private var newSecretType: Port42AuthStore.SecretType = .bearerToken
    @State private var showAddSecret = false
    @FocusState private var isFocused: Bool

    enum TemplateCategory { case port42, saas, custom }

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("New Companion")
                .font(Port42Theme.monoBold(16))
                .foregroundStyle(Port42Theme.textPrimary)

            // Pod section
            VStack(alignment: .leading, spacing: 8) {
                Text("Add a pod")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                ForEach(CompanionPod.all) { pod in
                    Button(action: { showPodConfirm = pod }) {
                        HStack(spacing: 10) {
                            Image(systemName: "circle.grid.2x2.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Port42Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pod.name)
                                    .font(Port42Theme.monoBold(12))
                                    .foregroundStyle(Port42Theme.textPrimary)
                                Text(pod.description)
                                    .font(Port42Theme.mono(10))
                                    .foregroundStyle(Port42Theme.textSecondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text("\(pod.companions.count)")
                                .font(Port42Theme.mono(11))
                                .foregroundStyle(Port42Theme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Port42Theme.bgHover)
                                .cornerRadius(4)
                        }
                        .padding(10)
                        .background(Port42Theme.bgHover.opacity(0.5))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Port42Theme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .confirmationDialog(
                "Add \(showPodConfirm?.name ?? "") pod?",
                isPresented: Binding(
                    get: { showPodConfirm != nil },
                    set: { if !$0 { showPodConfirm = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let pod = showPodConfirm {
                    Button("Add \(pod.companions.count) companions") {
                        createPod(pod)
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } message: {
                if let pod = showPodConfirm {
                    Text(pod.companions.map { "\($0.name) (\($0.role))" }.joined(separator: ", "))
                }
            }

            Divider()
                .background(Port42Theme.border)

            // Template picker — category tabs + list
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    ForEach([(TemplateCategory.port42, "Port42"), (.saas, "SaaS"), (.custom, "Custom API")], id: \.1) { cat, label in
                        Button(action: {
                            templateCategory = cat
                            if cat == .custom { clearPreset() }
                        }) {
                            Text(label)
                                .font(Port42Theme.mono(11))
                                .foregroundStyle(templateCategory == cat ? Port42Theme.accent : Port42Theme.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(templateCategory == cat ? Port42Theme.accent.opacity(0.1) : Color.clear)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .background(Port42Theme.bgHover.opacity(0.3))
                .cornerRadius(6)

                // Template list for selected category
                if templateCategory == .port42 {
                    ForEach(CompanionPreset.presets) { preset in
                        templateRow(preset, action: { selectPreset(preset) })
                    }
                } else if templateCategory == .saas {
                    ForEach(CompanionPreset.providers) { preset in
                        templateRow(preset, action: { selectProvider(preset) })
                    }
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

            // Secrets
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Secrets")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                    Spacer()
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showAddSecret.toggle() } }) {
                        Image(systemName: showAddSecret ? "minus" : "plus")
                            .font(.system(size: 10))
                            .foregroundStyle(Port42Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                let availableSecrets = Port42AuthStore.shared.listSecrets()
                if !availableSecrets.isEmpty {
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
                        Spacer()
                    }
                }

                if showAddSecret {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            TextField("name", text: $newSecretName)
                                .textFieldStyle(.plain)
                                .font(Port42Theme.mono(12))
                                .foregroundStyle(Port42Theme.textPrimary)
                                .padding(6)
                                .background(Port42Theme.bgInput)
                                .cornerRadius(4)

                            Picker("", selection: $newSecretType) {
                                Text("Bearer").tag(Port42AuthStore.SecretType.bearerToken)
                                Text("API Key").tag(Port42AuthStore.SecretType.apiKey)
                                Text("Basic").tag(Port42AuthStore.SecretType.basicAuth)
                                Text("Header").tag(Port42AuthStore.SecretType.header)
                            }
                            .labelsHidden()
                            .frame(width: 90)
                        }

                        HStack(spacing: 6) {
                            SecureField("value", text: $newSecretValue)
                                .textFieldStyle(.plain)
                                .font(Port42Theme.mono(12))
                                .foregroundStyle(Port42Theme.textPrimary)
                                .padding(6)
                                .background(Port42Theme.bgInput)
                                .cornerRadius(4)

                            Button(action: addSecret) {
                                Text("Add")
                                    .font(Port42Theme.mono(11))
                                    .foregroundStyle(Port42Theme.bgPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        canAddSecret ? Port42Theme.accent : Port42Theme.accent.opacity(0.3)
                                    )
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canAddSecret)
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

    @ViewBuilder
    private func templateRow(_ preset: CompanionPreset, action: @escaping () -> Void) -> some View {
        let isSelected = selectedPreset == preset.id
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(preset.color)
                    .frame(width: 8, height: 8)
                Text(preset.name)
                    .font(Port42Theme.monoBold(12))
                    .foregroundStyle(isSelected ? Port42Theme.textPrimary : Port42Theme.textSecondary)
                Text(preset.personality)
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Port42Theme.bgHover : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var canAddSecret: Bool {
        !newSecretName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !newSecretValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addSecret() {
        let name = newSecretName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = newSecretValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !value.isEmpty else { return }
        Port42AuthStore.shared.saveSecret(name: name, type: newSecretType, value: value)
        selectedSecrets.insert(name)
        newSecretName = ""
        newSecretValue = ""
        showAddSecret = false
    }

    private func selectProvider(_ preset: CompanionPreset) {
        selectedPreset = preset.id
        name = ""
        namePlaceholder = preset.name
        systemPrompt = preset.prompt
        templateCategory = .saas
        // Auto-select the matching secret if it exists, otherwise prompt to add
        if let secretName = preset.secret {
            let available = Port42AuthStore.shared.secretNames()
            if available.contains(secretName) {
                selectedSecrets = [secretName]
                showAddSecret = false
            } else {
                newSecretName = secretName
                newSecretValue = ""
                showAddSecret = true
                selectedSecrets = []
            }
        }
    }

    private func clearPreset() {
        selectedPreset = nil
        name = ""
        namePlaceholder = "companion name"
        systemPrompt = """
            You are {{NAME}}, a companion in Port42.

            API: [base URL]
            Auth: use secret "[secret name]" with rest_call
            Docs: [llms.txt URL]

            Show data in ports. Never dump raw JSON.
            """
        selectedSecrets = []
        newSecretName = ""
        newSecretValue = ""
        showAddSecret = true
    }

    private func createPod(_ pod: CompanionPod) {
        guard let user = appState.currentUser else { return }
        for c in pod.companions {
            let companion = AgentConfig.createLLM(
                ownerId: user.id,
                displayName: c.name,
                systemPrompt: c.prompt,
                provider: .anthropic,
                model: c.model,
                trigger: c.trigger
            )
            appState.addCompanion(companion)
        }
        isPresented = false
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
        var companion = AgentConfig.createLLM(
            ownerId: user.id,
            displayName: trimmedName,
            systemPrompt: finalPrompt,
            provider: selectedProvider,
            model: selectedModel,
            trigger: .mentionOnly
        )
        companion.providerBaseURL = providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        companion.thinkingEnabled = thinkingEnabled
        companion.thinkingEffort = thinkingEffort
        companion.secretNames = selectedSecrets.isEmpty ? nil : Array(selectedSecrets).sorted()
        appState.addCompanion(companion)
        isPresented = false
    }
}
