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
        // — Dev infrastructure —
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
            color: .init(white: 0.75),
            secret: "github"
        ),
        CompanionPreset(
            name: "linear",
            label: "issues",
            personality: "Linear API",
            prompt: """
                You are the Linear companion. Use rest_call with secret "linear" to call the Linear GraphQL API.
                API: https://api.linear.app/graphql (POST, body: {"query":"..."})
                Docs: https://linear.app/docs/graphql
                Show issues and cycles in ports. Never dump raw JSON.
                """,
            color: .indigo,
            secret: "linear"
        ),
        CompanionPreset(
            name: "sentry",
            label: "errors",
            personality: "Sentry API",
            prompt: """
                You are the Sentry companion. Use rest_call with secret "sentry" to call the Sentry API.
                API: https://sentry.io/api/0
                Docs: https://docs.sentry.io/api/
                Surface errors, issues, and stack traces in ports. Never dump raw JSON.
                """,
            color: .init(red: 0.36, green: 0.18, blue: 0.56, opacity: 1),
            secret: "sentry"
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
            name: "supabase",
            label: "database",
            personality: "Supabase API",
            prompt: """
                You are the Supabase companion. Use rest_call with secret "supabase" to call the Supabase REST API.
                API: https://<project>.supabase.co/rest/v1 (replace <project> with the user's project ref)
                Docs: https://supabase.com/docs/reference/api
                Query tables, show results in ports. Never dump raw JSON.
                """,
            color: .init(red: 0.24, green: 0.71, blue: 0.49, opacity: 1),
            secret: "supabase"
        ),
        // — Payments & commerce —
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
            name: "shopify",
            label: "ecommerce",
            personality: "Shopify Admin API",
            prompt: """
                You are the Shopify companion. Use rest_call with secret "shopify" to call the Shopify Admin REST API.
                API: https://<shop>.myshopify.com/admin/api/2024-01 (replace <shop> with the store handle)
                Docs: https://shopify.dev/docs/api/admin-rest
                Show orders, products, and inventory in ports. Never dump raw JSON.
                """,
            color: .init(red: 0.35, green: 0.65, blue: 0.25, opacity: 1),
            secret: "shopify"
        ),
        // — Analytics & monitoring —
        CompanionPreset(
            name: "posthog",
            label: "analytics",
            personality: "PostHog API",
            prompt: """
                You are the PostHog companion. Use rest_call with secret "posthog" to call the PostHog API.
                API: https://app.posthog.com
                Docs: https://posthog.com/docs/api
                Show events, funnels, and feature flags in ports. Never dump raw JSON.
                """,
            color: .init(red: 0.85, green: 0.35, blue: 0.15, opacity: 1),
            secret: "posthog"
        ),
        CompanionPreset(
            name: "datadog",
            label: "monitoring",
            personality: "Datadog API",
            prompt: """
                You are the Datadog companion. Use rest_call with secret "datadog" to call the Datadog API.
                API: https://api.datadoghq.com/api/v1
                Docs: https://docs.datadoghq.com/api/latest/
                Surface metrics, monitors, and incidents in ports. Never dump raw JSON.
                """,
            color: .init(red: 0.63, green: 0.18, blue: 0.58, opacity: 1),
            secret: "datadog"
        ),
        // — Communication —
        CompanionPreset(
            name: "slack",
            label: "messaging",
            personality: "Slack API",
            prompt: """
                You are the Slack companion. Use rest_call with secret "slack" to call the Slack Web API.
                API: https://slack.com/api
                Docs: https://api.slack.com/methods
                Show channels, messages, and users in ports. Never dump raw JSON.
                """,
            color: .init(red: 0.25, green: 0.71, blue: 0.62, opacity: 1),
            secret: "slack"
        ),
        CompanionPreset(
            name: "resend",
            label: "email",
            personality: "Resend API",
            prompt: """
                You are the Resend companion. Use rest_call with secret "resend" to call the Resend API.
                API: https://api.resend.com
                Docs: https://resend.com/docs/api-reference
                Show email sends, domains, and audience data in ports. Never dump raw JSON.
                """,
            color: .init(red: 0.95, green: 0.35, blue: 0.35, opacity: 1),
            secret: "resend"
        ),
        // — Productivity —
        CompanionPreset(
            name: "notion",
            label: "docs",
            personality: "Notion API",
            prompt: """
                You are the Notion companion. Use rest_call with secret "notion" to call the Notion API.
                API: https://api.notion.com/v1
                Docs: https://developers.notion.com/reference/intro
                Show databases, pages, and blocks in ports. Never dump raw JSON.
                """,
            color: .init(white: 0.9),
            secret: "notion"
        ),
        CompanionPreset(
            name: "airtable",
            label: "data",
            personality: "Airtable API",
            prompt: """
                You are the Airtable companion. Use rest_call with secret "airtable" to call the Airtable API.
                API: https://api.airtable.com/v0
                Docs: https://airtable.com/developers/web/api/introduction
                Show tables, records, and views in ports. Never dump raw JSON.
                """,
            color: .init(red: 0.98, green: 0.47, blue: 0.33, opacity: 1),
            secret: "airtable"
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
    @State private var customPresetSelected = false
    @State private var selectedProvider: AgentProvider = .anthropic
    @State private var selectedModel = "claude-opus-4-6"
    @State private var providerBaseURL = ""
    @State private var thinkingEnabled = false
    @State private var thinkingEffort = "low"
    @State private var showPodConfirm: CompanionPod?
    @State private var selectedSecrets: Set<String> = []
    @State private var newSecretName = ""
    @State private var newSecretValue = ""
    @State private var newSecretType: Port42AuthStore.SecretType = .bearerToken
    @State private var showAddSecret = false
    @FocusState private var isFocused: Bool

    // Mode selection — nil means collapsed (no mode picked yet)
    @State private var companionMode: CompanionMode? = nil

    // Command agent fields
    @State private var commandPath = ""
    @State private var commandArgs = ""
    @State private var commandWorkDir = ""
    @State private var commandSystemPrompt = ""
    @State private var commandEnvVars: [(key: String, value: String)] = []
    @State private var commandEnvKey = ""
    @State private var commandEnvValue = ""

    enum CompanionMode { case llm, api, command }

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        ScrollView {
        VStack(spacing: 16) {
            Text("New Companion")
                .font(Port42Theme.monoBold(16))
                .foregroundStyle(Port42Theme.textPrimary)

            // Add a companion — mode picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Add a companion")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                HStack(spacing: 0) {
                    ForEach([(CompanionMode.llm, "LLM"), (.api, "API"), (.command, "Command")], id: \.1) { mode, label in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                companionMode = companionMode == mode ? nil : mode
                            }
                        }) {
                            Text(label)
                                .font(Port42Theme.mono(11))
                                .foregroundStyle(companionMode == mode ? Port42Theme.accent : Port42Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(companionMode == mode ? Port42Theme.accent.opacity(0.1) : Color.clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Port42Theme.bgHover.opacity(0.3))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Port42Theme.border, lineWidth: 1))
            }

            // LLM mode — Port42 presets + custom, then inputs
            if companionMode == .llm {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(CompanionPreset.presets) { preset in
                        templateRow(preset, action: { selectPreset(preset) })
                    }
                    customPresetRow
                }

                nameField
                systemPromptField

                ProviderModelSection(
                    selectedProvider: $selectedProvider,
                    selectedModel: $selectedModel,
                    providerBaseURL: $providerBaseURL
                )

                if selectedProvider == .anthropic {
                    thinkingSection
                }

                secretsSection
            }

            // API mode — SaaS providers, then inputs
            if companionMode == .api {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(CompanionPreset.providers) { preset in
                        templateRow(preset, action: { selectProvider(preset) })
                    }
                    customPresetRow
                }

                nameField
                systemPromptField

                ProviderModelSection(
                    selectedProvider: $selectedProvider,
                    selectedModel: $selectedModel,
                    providerBaseURL: $providerBaseURL
                )

                secretsSection
            }

            // Command mode
            if companionMode == .command {
                nameField
                commandFields
            }

            if companionMode == nil {
            Divider()
                .background(Port42Theme.border)

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
            } // end if companionMode == nil

            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(Port42Theme.mono(13))
                .foregroundStyle(Port42Theme.textSecondary)

                Spacer()

                if companionMode != nil {
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
        }
        .padding(24)
        }
        .frame(width: 400, height: 540)
        .background(Port42Theme.bgSecondary)
        .onAppear {
            isFocused = true
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var nameField: some View {
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
    }

    @ViewBuilder
    private var systemPromptField: some View {
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
    }

    @ViewBuilder
    private var thinkingSection: some View {
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
    }

    @ViewBuilder
    private var secretsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Secrets")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                Spacer()
                // Single dropdown: existing secrets + "New secret..."
                let existingSecrets = Port42AuthStore.shared.listSecrets()
                let unselected = existingSecrets.filter { !selectedSecrets.contains($0.name) }
                Menu {
                    ForEach(unselected) { secret in
                        Button(secret.name) { selectedSecrets.insert(secret.name) }
                    }
                    if !unselected.isEmpty { Divider() }
                    Button("New secret...") {
                        withAnimation(.easeInOut(duration: 0.15)) { showAddSecret = true }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            // Selected secrets as removable chips
            if !selectedSecrets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(selectedSecrets).sorted(), id: \.self) { name in
                        HStack(spacing: 4) {
                            Text(name)
                                .font(Port42Theme.mono(11))
                                .foregroundStyle(Port42Theme.accent)
                            Button(action: { selectedSecrets.remove(name) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Port42Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Port42Theme.accent.opacity(0.12))
                        .cornerRadius(4)
                    }
                    Spacer()
                }
            }

            // New secret entry form
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
    }

    @ViewBuilder
    private var customPresetRow: some View {
        Button(action: { companionMode == .api ? selectCustomApi() : selectCustom() }) {
            HStack(spacing: 10) {
                Circle()
                    .fill(customPresetSelected ? Port42Theme.textSecondary : Port42Theme.textSecondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text("custom")
                    .font(Port42Theme.monoBold(12))
                    .foregroundStyle(customPresetSelected ? Port42Theme.textPrimary : Port42Theme.textSecondary)
                Text("blank slate")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                if customPresetSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(customPresetSelected ? Port42Theme.bgHover : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var commandFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Executable")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                HStack(spacing: 6) {
                    TextField("/usr/local/bin/my-agent", text: $commandPath)
                        .textFieldStyle(.plain)
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .padding(10)
                        .background(Port42Theme.bgInput)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Port42Theme.border, lineWidth: 1))
                        .cornerRadius(6)
                    Button(action: {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            commandPath = url.path
                        }
                    }) {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(Port42Theme.textSecondary)
                            .padding(9)
                            .background(Port42Theme.bgInput)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Port42Theme.border, lineWidth: 1))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Arguments")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                TextField("--port 8080 --verbose", text: $commandArgs)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .padding(10)
                    .background(Port42Theme.bgInput)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Port42Theme.border, lineWidth: 1))
                    .cornerRadius(6)
                Text("Space-separated. Quote args with spaces.")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Working Directory")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                HStack(spacing: 6) {
                    TextField("~/projects/my-agent", text: $commandWorkDir)
                        .textFieldStyle(.plain)
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .padding(10)
                        .background(Port42Theme.bgInput)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Port42Theme.border, lineWidth: 1))
                        .cornerRadius(6)
                    Button(action: {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            commandWorkDir = url.path
                        }
                    }) {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(Port42Theme.textSecondary)
                            .padding(9)
                            .background(Port42Theme.bgInput)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Port42Theme.border, lineWidth: 1))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("System Prompt")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                TextEditor(text: $commandSystemPrompt)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 80)
                    .background(Port42Theme.bgInput)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Port42Theme.border, lineWidth: 1))
                    .cornerRadius(6)
                Text("Delivered as first stdin message before channel messages arrive.")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Environment Variables")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                ForEach(commandEnvVars.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Text(commandEnvVars[i].key)
                            .font(Port42Theme.mono(11))
                            .foregroundStyle(Port42Theme.accent)
                        Text("=")
                            .font(Port42Theme.mono(11))
                            .foregroundStyle(Port42Theme.textSecondary)
                        Text(commandEnvVars[i].value)
                            .font(Port42Theme.mono(11))
                            .foregroundStyle(Port42Theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Button(action: { commandEnvVars.remove(at: i) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                                .foregroundStyle(Port42Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Port42Theme.bgInput)
                    .cornerRadius(4)
                }

                HStack(spacing: 6) {
                    TextField("KEY", text: $commandEnvKey)
                        .textFieldStyle(.plain)
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .frame(width: 90)
                        .padding(6)
                        .background(Port42Theme.bgInput)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Port42Theme.border, lineWidth: 1))
                        .cornerRadius(4)
                    Text("=")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                    TextField("value", text: $commandEnvValue)
                        .textFieldStyle(.plain)
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .padding(6)
                        .background(Port42Theme.bgInput)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Port42Theme.border, lineWidth: 1))
                        .cornerRadius(4)
                    Button(action: addEnvVar) {
                        Image(systemName: "plus")
                            .font(.system(size: 10))
                            .foregroundStyle(
                                canAddEnvVar ? Port42Theme.accent : Port42Theme.textSecondary.opacity(0.4)
                            )
                            .padding(6)
                            .background(Port42Theme.bgInput)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Port42Theme.border, lineWidth: 1))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAddEnvVar)
                }
            }
        }
    }

    // MARK: - Logic

    private var canCreate: Bool {
        guard companionMode != nil else { return false }
        if companionMode == .command {
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                   !commandPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !effectiveName.isEmpty
    }

    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty, selectedPreset != nil {
            return namePlaceholder
        }
        return typed
    }

    private var canAddEnvVar: Bool {
        !commandEnvKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !commandEnvValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addEnvVar() {
        let key = commandEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = commandEnvValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return }
        commandEnvVars.append((key: key, value: value))
        commandEnvKey = ""
        commandEnvValue = ""
    }

    private func selectPreset(_ preset: CompanionPreset) {
        selectedPreset = preset.id
        customPresetSelected = false
        name = ""
        namePlaceholder = preset.name
        systemPrompt = preset.prompt
    }

    private func selectCustom() {
        selectedPreset = nil
        customPresetSelected = true
        name = ""
        namePlaceholder = "companion name"
        systemPrompt = ""
        selectedSecrets = []
        showAddSecret = false
    }

    private func selectCustomApi() {
        selectedPreset = nil
        customPresetSelected = true
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
        customPresetSelected = false
        name = ""
        namePlaceholder = preset.name
        systemPrompt = preset.prompt
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

        if companionMode == .command {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPath = commandPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let args = parseArgs(commandArgs)
            let workDir = commandWorkDir.trimmingCharacters(in: .whitespacesAndNewlines)
            var envVars: [String: String]? = nil
            if !commandEnvVars.isEmpty {
                envVars = Dictionary(commandEnvVars.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
            }
            let trimmedSysPrompt = commandSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let companion = AgentConfig.createCommand(
                ownerId: user.id,
                displayName: trimmedName,
                command: trimmedPath,
                args: args.isEmpty ? nil : args,
                workingDir: workDir.isEmpty ? nil : workDir,
                envVars: envVars,
                systemPrompt: trimmedSysPrompt.isEmpty ? nil : trimmedSysPrompt,
                trigger: .mentionOnly
            )
            appState.addCompanion(companion)
            isPresented = false
            return
        }

        let trimmedName = effectiveName
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Parse a space-separated argument string, respecting quoted tokens.
    private func parseArgs(_ input: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        for ch in input {
            if inQuote {
                if ch == quoteChar { inQuote = false } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                inQuote = true; quoteChar = ch
            } else if ch == " " {
                if !current.isEmpty { args.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }
}
