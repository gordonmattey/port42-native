import SwiftUI

public struct SetupView: View {
    public init() {}
    @EnvironmentObject var appState: AppState
    @State private var displayName = ""
    @State private var phase: SetupPhase = .boot
    @State private var visibleBootLines = 0
    @State private var showNameInput = false
    @State private var showCreateLines = false
    @State private var visibleCreateLines = 0
    @State private var showAuthOptions = false
    @State private var cursorVisible = true
    @State private var transitionOpacity = 0.0
    @State private var diamondVisible = false
    @StateObject private var claudeSetup = ClaudeCodeSetup()
    @State private var submittedName: String?
    @State private var showAnalyticsConsent = false
    @State private var terminalVisible = false
    @State private var terminalOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var revealedSuffixes: Set<Int> = []
    @FocusState private var isFocused: Bool
    @FocusState private var isAuthPickerFocused: Bool
    /// The option under the cursor in the agent chooser.
    @State private var cliSelected = 0
    /// Bumped after an install finishes, so the chooser re-reads which CLIs exist.
    @State private var cliScanTick = 0


    /// Setup is the BIOS and the handover, nothing else. The old `.swim` phase (a bespoke
    /// full-screen chat with its own branded bar and a 🐬 "swim in open water" button) is gone:
    /// the first swim runs in the real shell, focused on the space's chat tile.
    /// See `docs/plan-unify-onboarding-shell.md`.
    enum SetupPhase {
        case boot       // POST lines + name prompt (all in one terminal)
        case transition // fade to black, diamond, then hand to the shell
    }

    // MARK: - Line Model

    private struct TermLine {
        let text: String
        let style: Style
        let delay: Double
        var suffix: String? = nil
        var suffixDelay: Double = 0

        enum Style {
            case post
            case header
            case body
            case accent
            case warn
            case dim
            case blank
        }
    }

    // MARK: - Boot Sequence

    private var bootSequence: [TermLine] {
        [
            .init(text: "[BIOS POST]", style: .dim, delay: 0.3),
            .init(text: "...", style: .dim, delay: 0.4),
            .init(text: "...", style: .dim, delay: 0.4),
            .init(text: "...", style: .dim, delay: 0.4),
            .init(text: "", style: .blank, delay: 0.6),
            .init(text: "REALITY KERNEL v0.1.0", style: .post, delay: 0.8),
            .init(text: "Port42 :: Active", style: .warn, delay: 0.5),
            .init(text: "", style: .blank, delay: 0.4),
            .init(text: "Checking consciousness drivers...", style: .post, delay: 0.7, suffix: " OK", suffixDelay: 1.5),
            .init(text: "Loading memory subsystem...", style: .post, delay: 0.7, suffix: " OK", suffixDelay: 1.5),
            .init(text: "Initializing possibility engine...", style: .post, delay: 0.7, suffix: " OK", suffixDelay: 1.5),
            .init(text: "", style: .blank, delay: 0.6),
            .init(text: "Welcome to Port42.", style: .header, delay: 0.6),
            .init(text: "", style: .blank, delay: 0.5),
            .init(text: "Your companions. Your friends. One room.", style: .accent, delay: 0.6),
            .init(text: "", style: .blank, delay: 0.8),
        ]
    }

    // MARK: - Create Sequence

    private var createSequence: [TermLine] {
        let name = submittedName ?? ""
        var lines: [TermLine] = [
            .init(text: "", style: .blank, delay: 0.5),
            .init(text: "Creating reality instance for \(name)...", style: .post, delay: 0.8),
        ]
        lines += [
            .init(text: "", style: .blank, delay: 0.6),
            .init(text: "Welcome, \(name).", style: .header, delay: 0.6),
            .init(text: "", style: .blank, delay: 0.5),
        ]
        return lines
    }


    // MARK: - Body

    public var body: some View {
        ZStack {
            switch phase {
            case .boot:
                setupTerminal
                    .scaleEffect(terminalVisible ? 1.0 : 0.8)
                    .opacity(terminalVisible ? 1.0 : 0.0)
            case .transition:
                transitionView
            }
        }
        .onAppear {
            Analytics.shared.screen("Boot")
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                terminalVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                startBootSequence()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 530_000_000)
                cursorVisible.toggle()
            }
        }
        // (The Settings sheet lived here for the retired `.swim` phase, whose branded bar was the
        // only thing that could open it. Settings is a shell overlay now — ShellState.showSettings.)
    }

    // MARK: - Single Continuous Terminal

    private var setupTerminal: some View {
        setupTerminalContent
            .frame(width: 520)
            .frame(maxHeight: 700)
            .background(Port42Theme.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Port42Theme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
            .offset(
                x: terminalOffset.width + dragOffset.width,
                y: terminalOffset.height + dragOffset.height
            )
            .tint(Port42Theme.accent)
    }

    private var setupTerminalContent: some View {
        VStack(spacing: 0) {
            terminalTitleBar(title: "port42")

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        // Boot lines
                        ForEach(Array(bootSequence.prefix(visibleBootLines).enumerated()), id: \.offset) { idx, line in
                            termLineView(line, index: idx)
                                .id("boot-\(idx)")
                        }

                        // Name input (appears after boot completes)
                        if showNameInput && submittedName == nil {
                            Spacer().frame(height: 8)

                            HStack(spacing: 6) {
                                Text(">")
                                    .font(Port42Theme.monoBold(14))
                                    .foregroundStyle(Port42Theme.accent)
                                Text("what is your name?")
                                    .font(Port42Theme.mono(13))
                                    .foregroundStyle(Port42Theme.textSecondary)
                            }

                            HStack(spacing: 6) {
                                Text(">")
                                    .font(Port42Theme.monoBold(14))
                                    .foregroundStyle(Port42Theme.accent)

                                TextField("", text: $displayName)
                                    .textFieldStyle(.plain)
                                    .font(Port42Theme.mono(14))
                                    .foregroundStyle(Port42Theme.textPrimary)
                                    .focused($isFocused)
                                    .onSubmit { submitName() }

                                if canSubmitName {
                                    Button(action: submitName) {
                                        Text("enter \u{21B5}")
                                            .font(Port42Theme.mono(11))
                                            .foregroundStyle(Port42Theme.accent.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Show submitted name as echo (like Ouroboros echoes input)
                        if let name = submittedName, !showCreateLines {
                            HStack(spacing: 6) {
                                Text(">")
                                    .font(Port42Theme.monoBold(14))
                                    .foregroundStyle(Port42Theme.accent)
                                Text(name)
                                    .font(Port42Theme.mono(14))
                                    .foregroundStyle(Port42Theme.textPrimary)
                            }
                        }

                        // Create sequence lines (appear after name submitted)
                        if showCreateLines {
                            // Echo the submitted name first
                            HStack(spacing: 6) {
                                Text(">")
                                    .font(Port42Theme.monoBold(14))
                                    .foregroundStyle(Port42Theme.accent)
                                Text(submittedName ?? "")
                                    .font(Port42Theme.mono(14))
                                    .foregroundStyle(Port42Theme.textPrimary)
                            }

                            ForEach(Array(createSequence.prefix(visibleCreateLines).enumerated()), id: \.offset) { idx, line in
                                termLineView(line)
                                    .id("create-\(idx)")
                            }
                        }

                        // Analytics consent (after "Welcome, name.", before auth)
                        if showAnalyticsConsent {
                            analyticsConsentContent
                                .id("analytics")
                        }

                        // The agent chooser (appears after analytics consent)
                        if showAuthOptions {
                            agentChooserContent
                                .id("auth")

                            // Bottom padding so scroll can reach auth content
                            Spacer().frame(height: 20)
                                .id("auth-bottom")
                        }

                        // Blinking cursor at the bottom when no input is shown
                        if !showNameInput && !showAuthOptions && visibleBootLines > 0 {
                            blinkingCursor
                                .padding(.top, 4)
                                .id("cursor")
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: visibleBootLines) { _, _ in
                    scrollToEnd(proxy: proxy)
                }
                .onChange(of: visibleCreateLines) { _, _ in
                    scrollToEnd(proxy: proxy)
                }
                .onChange(of: showAnalyticsConsent) { _, _ in
                    scrollToEnd(proxy: proxy)
                }
                .onChange(of: showAuthOptions) { _, _ in
                    scrollToEnd(proxy: proxy)
                }
                .onChange(of: claudeSetup.state) { _, newState in
                    if newState == .success {
                        cliScanTick += 1   // an install finished: offer what is now there
                        cliSelected = 0
                    }
                    scrollToEnd(proxy: proxy)
                }
            }
        }
    }

    // MARK: - The agent Echo runs on

    /// The CLI agents on this machine, in the order offered. Echo runs on one of them. Port42 holds no
    /// model and reads no provider credential (D9): the agent signs in to its own account, in its own
    /// terminal. `cliScanTick` is read so the list is re-evaluated after an install.
    private var detectedCLIs: [String] {
        _ = cliScanTick
        return ["claude", "codex"].filter { ClaudeCodeSetup.findBinary($0) != nil }
    }

    private func agentLabel(_ cli: String) -> String { cli == "codex" ? "Codex" : "Claude Code" }

    /// What the chooser offers: the CLIs found, or with none found, the two installers.
    private var agentOptions: [String] {
        let found = detectedCLIs
        return found.isEmpty ? ["install:claude", "install:codex"] : found
    }

    private var agentChooserContent: some View {
        let found = detectedCLIs
        let options = agentOptions
        let installing = claudeSetup.state != .idle && claudeSetup.state != .success
        return VStack(alignment: .leading, spacing: 8) {
            if found.isEmpty {
                Text("Port42 runs your AI agent in its own terminal. No agent was found on this Mac.")
                    .font(Port42Theme.mono(13)).foregroundStyle(Port42Theme.textSecondary)
                Spacer().frame(height: 4)
                Text("Install one:").font(Port42Theme.mono(13)).foregroundStyle(Port42Theme.textPrimary)
            } else if found.count == 1 {
                Text("Found \(agentLabel(found[0])).").font(Port42Theme.mono(13)).foregroundStyle(Port42Theme.textPrimary)
            } else {
                Text("Found Claude Code and Codex. Pick the one Echo runs on:")
                    .font(Port42Theme.mono(13)).foregroundStyle(Port42Theme.textPrimary)
            }
            Spacer().frame(height: 4)
            ForEach(Array(options.enumerated()), id: \.offset) { idx, option in
                let install = option.hasPrefix("install:")
                let cli = install ? String(option.dropFirst("install:".count)) : option
                agentOptionButton(idx, label: install ? "install \(agentLabel(cli))" : agentLabel(cli),
                                  hint: cli == "codex" ? "your ChatGPT account" : "your Claude subscription") {
                    cliSelected = idx
                    submitAgentChoice()
                }
            }
            if installing {
                ClaudeCodeSetupView(setup: claudeSetup).padding(.top, 8)
            }
            Spacer().frame(height: 8)
            Text("Your agent signs in to its own account in its own terminal. Port42 never sees that credential.")
                .font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary.opacity(0.4))
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isAuthPickerFocused)
        .onKeyPress(.downArrow) {
            cliSelected = min(cliSelected + 1, agentOptions.count - 1); return .handled
        }
        .onKeyPress(.upArrow) {
            cliSelected = max(cliSelected - 1, 0); return .handled
        }
        .onKeyPress(.return) {
            submitAgentChoice(); return .handled
        }
    }

    private func agentOptionButton(_ idx: Int, label: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(cliSelected == idx ? ">" : " ")
                    .font(Port42Theme.monoBold(14)).foregroundStyle(Port42Theme.accent)
                    .opacity(cliSelected == idx ? (cursorVisible ? 1 : 0.3) : 0)
                Text(label).font(Port42Theme.mono(13))
                    .foregroundStyle(cliSelected == idx ? Port42Theme.textPrimary : Port42Theme.textSecondary.opacity(0.5))
                Text(hint).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary.opacity(0.4))
            }
        }
        .buttonStyle(.plain)
    }

    /// Enter on the chooser: run Echo on the chosen CLI, or start installing one.
    private func submitAgentChoice() {
        let options = agentOptions
        guard cliSelected < options.count else { return }
        let option = options[cliSelected]
        if option.hasPrefix("install:") {
            claudeSetup.target = String(option.dropFirst("install:".count))
            claudeSetup.diagnose()   // Node first when npm is missing, then the CLI
            return
        }
        Analytics.shared.setupStep("agent_\(option)")
        let name = submittedName ?? displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.completeSetup(displayName: name, cli: option)
        phase = .transition
    }

    // MARK: - Analytics Consent

    private var analyticsConsentContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer().frame(height: 4)

            Text("help improve Port42?")
                .font(Port42Theme.monoBold(13))
                .foregroundStyle(Port42Theme.textPrimary)

            Text("we collect anonymous product analytics to measure performance and improve the experience. no personal data, no messages, no tracking.")
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 8)

            HStack(spacing: 12) {
                Button(action: { respondToAnalytics(optIn: true) }) {
                    Text("sure")
                        .font(Port42Theme.monoBold(13))
                        .foregroundStyle(Port42Theme.bgPrimary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Port42Theme.accent)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)

                Button(action: { respondToAnalytics(optIn: false) }) {
                    Text("no thanks")
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            Text("you can change this anytime in settings.")
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.4))
        }
    }

    private func respondToAnalytics(optIn: Bool) {
        Analytics.shared.setOptIn(optIn)
        Analytics.shared.setupStep(optIn ? "analytics_opted_in" : "analytics_opted_out")
        withAnimation(.easeIn(duration: 0.15)) {
            showAnalyticsConsent = false
        }

        // Show auth options after analytics consent
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeIn(duration: 0.2)) {
                showAuthOptions = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isAuthPickerFocused = true
            }
        }
    }

    // MARK: - Transition (fade to black, circle, reveal)

    private var transitionView: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            if diamondVisible {
                Text("\u{25CB}")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Port42Theme.accent)
                    .transition(.opacity)
            }
        }
        .opacity(transitionOpacity)
        .onAppear {
            Analytics.shared.screen("Setup_Transition")
            startTransition()
        }
    }

    // MARK: - Shared Components

    private var blinkingCursor: some View {
        Rectangle()
            .fill(Port42Theme.accent)
            .frame(width: 8, height: 14)
            .opacity(cursorVisible ? 1 : 0)
    }

    @ViewBuilder
    private func termLineView(_ line: TermLine, index: Int = -1) -> some View {
        if line.style == .blank {
            Spacer().frame(height: 6)
        } else if let suffix = line.suffix {
            HStack(spacing: 0) {
                Text(line.text)
                    .font(Port42Theme.mono(13))
                    .foregroundStyle(lineColor(for: line.style))
                if revealedSuffixes.contains(index) {
                    Text(suffix)
                        .font(Port42Theme.monoBold(14))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .transition(.opacity)
                }
            }
        } else {
            Text(line.text)
                .font(line.style == .header ? Port42Theme.monoBold(14) : Port42Theme.mono(13))
                .foregroundStyle(lineColor(for: line.style))
        }
    }

    private func lineColor(for style: TermLine.Style) -> Color {
        switch style {
        case .post: return Port42Theme.accent
        case .header: return Port42Theme.textPrimary
        case .body: return Port42Theme.textSecondary
        case .accent: return Port42Theme.accent
        case .warn: return .yellow
        case .dim: return Port42Theme.textSecondary.opacity(0.6)
        case .blank: return .clear
        }
    }

    private func terminalTitleBar(
        title: String,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.red.opacity(0.8)).frame(width: 10, height: 10)
                Circle().fill(Color.yellow.opacity(0.8)).frame(width: 10, height: 10)
                Circle().fill(Color.green.opacity(0.8)).frame(width: 10, height: 10)
            }

            Spacer()

            Text(title)
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary)

            Spacer()

            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Port42Theme.bgPrimary)
        .onHover { hovering in
            if hovering {
                NSCursor.openHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    NSCursor.closedHand.set()
                    dragOffset = value.translation
                }
                .onEnded { value in
                    NSCursor.openHand.set()
                    terminalOffset.width += value.translation.width
                    terminalOffset.height += value.translation.height
                    dragOffset = .zero
                }
        )
    }

    private func scrollToEnd(proxy: ScrollViewProxy) {
        if showAuthOptions {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("auth-bottom", anchor: .bottom)
            }
        } else if visibleCreateLines > 0 {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("create-\(visibleCreateLines - 1)", anchor: .bottom)
            }
        } else if showAnalyticsConsent {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("analytics", anchor: .bottom)
            }
        }
    }

    // MARK: - Animation

    private func startBootSequence() {
        let lines = bootSequence
        revealLines(lines, current: 0) { count in
            visibleBootLines = count
        } completion: {
            withAnimation(.easeIn(duration: 0.2)) {
                showNameInput = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    private func startCreateSequence() {
        showCreateLines = true
        let lines = createSequence
        revealLines(lines, current: 0) { count in
            visibleCreateLines = count
        } completion: {
            // Show analytics consent after "Welcome, name." before auth options
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeIn(duration: 0.2)) {
                    showAnalyticsConsent = true
                }
            }
        }
    }

    private func revealLines(
        _ lines: [TermLine],
        current index: Int,
        update: @escaping (Int) -> Void,
        completion: @escaping () -> Void
    ) {
        guard index < lines.count else {
            completion()
            return
        }
        let line = lines[index]
        DispatchQueue.main.asyncAfter(deadline: .now() + line.delay) {
            update(index + 1)
            if line.suffix != nil && line.suffixDelay > 0 {
                // Show line first, then reveal suffix after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + line.suffixDelay) {
                    _ = withAnimation(.easeIn(duration: 0.2)) {
                        revealedSuffixes.insert(index)
                    }
                    revealLines(lines, current: index + 1, update: update, completion: completion)
                }
            } else {
                revealLines(lines, current: index + 1, update: update, completion: completion)
            }
        }
    }

    // MARK: - Helpers

    private var canSubmitName: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitName() {
        guard canSubmitName else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        submittedName = name
        showNameInput = false
        Analytics.shared.setupStep("name_entered")

        // Generate identity key pair and store in Keychain now,
        // so the create sequence can show the real fingerprint
        let user = AppUser.createLocal(displayName: name)
        do {
            try appState.db.saveUser(user)
            appState.currentUser = user
        } catch {
            NSLog("[Port42] Failed to save user during key gen: \(error)")
        }

        Task {
            // Start create sequence (which shows analytics then auth options)
            try? await Task.sleep(nanoseconds: 400_000_000)
            withAnimation(.easeIn(duration: 0.2)) {
                startCreateSequence()
            }
        }
    }


    private func startTransition() {
        withAnimation(.easeIn(duration: 0.5)) {
            transitionOpacity = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeIn(duration: 0.3)) {
                diamondVisible = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                diamondVisible = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            // Hand the first swim to the SHELL: it opens focused on the space's chat tile and
            // seeds the opening message there. The bespoke `.swim` phase below is unreachable
            // from here now and retires with phase 6.
            appState.enterShellFromSetup()
        }
    }
}
