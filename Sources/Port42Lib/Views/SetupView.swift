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
    @State private var apiKeyInput = ""
    @State private var manualTokenInput = ""
    @State private var authMethod: AuthMethod?
    @State private var authError: String?
    @State private var isCheckingAuth = false
    @StateObject private var claudeSetup = ClaudeCodeSetup()
    @State private var keychainEntries: [ClaudeKeychainEntry] = []
    @State private var selectedTokenIndex: Int = 0
    @State private var submittedName: String?
    @State private var appleAuthStatus: String?
    @State private var showAnalyticsConsent = false
    @State private var terminalVisible = false
    @State private var showSettings = false
    @State private var terminalOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var revealedSuffixes: Set<Int> = []
    @FocusState private var isFocused: Bool
    @FocusState private var isApiKeyFocused: Bool
    @FocusState private var isManualTokenFocused: Bool
    @FocusState private var isAuthPickerFocused: Bool

    enum AuthMethod {
        case claudeCode
        case manualToken
        case apiKey
    }

    enum SetupPhase {
        case boot       // POST lines + name prompt (all in one terminal)
        case transition // fade to black, diamond
        case swim       // full-screen swim session
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
        let keychainOK = appState.currentUser.map { AppUser.keychainHasKey(account: $0.id) } ?? false
        let keychainStatus = keychainOK ? "OK" : "FAILED"
        var lines: [TermLine] = [
            .init(text: "", style: .blank, delay: 0.5),
            .init(text: "Creating reality instance for \(name)...", style: .post, delay: 0.8),
            .init(text: "Generating P256 identity key pair...", style: .post, delay: 0.8),
            .init(text: "Storing private key in Keychain... \(keychainStatus)", style: .post, delay: 1.0),
            .init(text: "Public key: \(keyFingerprint)", style: .dim, delay: 0.6),
        ]
        #if !RELEASE
        let appleStatus = appleAuthStatus ?? "pending"
        lines.append(.init(text: "Linking Apple identity... \(appleStatus)", style: .post, delay: 0.6))
        #endif
        lines += [
            .init(text: "", style: .blank, delay: 0.6),
            .init(text: "Welcome, \(name).", style: .header, delay: 0.6),
            .init(text: "", style: .blank, delay: 0.5),
        ]
        return lines
    }

    private var keyFingerprint: String {
        let pk = appState.currentUser?.publicKey ?? ""
        if pk.count >= 16 {
            return String(pk.prefix(8)) + "..." + String(pk.suffix(8))
        }
        return pk.isEmpty ? "pending" : pk
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
            case .swim:
                swimTerminal
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
        .sheet(isPresented: $showSettings) {
            SignOutSheet(isPresented: $showSettings)
        }
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

                        // Auth options (appear after analytics consent)
                        if showAuthOptions {
                            authOptionsContent
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
                        completeAuth()
                    }
                    scrollToEnd(proxy: proxy)
                }
            }
        }
    }

    // MARK: - Auth Options (inline, not a separate terminal)

    private var authSelected: AuthMethod {
        authMethod ?? .claudeCode
    }

    private var isMultiTokenState: Bool {
        if case .multipleTokens = claudeSetup.state { return true }
        return false
    }

    private var authOptionsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Neural bridge requires an AI connection.")
                .font(Port42Theme.mono(13))
                .foregroundStyle(Port42Theme.textSecondary)

            Spacer().frame(height: 4)

            Text("Choose your connection method:")
                .font(Port42Theme.mono(13))
                .foregroundStyle(Port42Theme.textPrimary)

            Spacer().frame(height: 8)

            // Option 1: Claude subscription (accounts + enter token)
            if keychainEntries.count > 1 {
                // Header
                Text("Claude subscription")
                    .font(Port42Theme.mono(13))
                    .foregroundStyle(authSelected == .claudeCode || authSelected == .manualToken ? Port42Theme.textPrimary : Port42Theme.textSecondary.opacity(0.5))

                // Detected accounts
                ForEach(Array(keychainEntries.enumerated()), id: \.element.id) { idx, entry in
                    subOptionButton(
                        selected: authSelected == .claudeCode && selectedTokenIndex == idx,
                        label: entry.label,
                        hint: {
                            var parts: [String] = []
                            if let suf = entry.suffix { parts.append(String(suf.prefix(8))) }
                            if let exp = entry.expiresAt {
                                let fmt = DateFormatter()
                                fmt.dateFormat = "MMM d, HH:mm"
                                let label = exp > Date() ? "exp \(fmt.string(from: exp))" : "expired \(fmt.string(from: exp))"
                                parts.append(label)
                            }
                            return parts.isEmpty ? nil : parts.joined(separator: " · ")
                        }()
                    ) {
                        selectTokenEntry(idx)
                    }
                }

                // Enter session key manually (as last sub-option)
                subOptionButton(
                    selected: authSelected == .manualToken,
                    label: "enter OAuth session key manually",
                    hint: nil
                ) {
                    selectManualToken()
                }
            } else {
                // No multi-account: just Claude subscription (sub-options show after selection)
                authOptionButton(.claudeCode, label: "Claude subscription", hint: "(auto-detect)", action: selectAndSubmitClaudeCode)

                if authMethod == .claudeCode || authMethod == .manualToken {
                    subOptionButton(
                        selected: authSelected == .manualToken,
                        label: "enter OAuth session key manually",
                        hint: nil
                    ) {
                        selectManualToken()
                    }
                }
            }

            if authMethod == .manualToken {
                Spacer().frame(height: 8)
                SecureField("paste your OAuth session key", text: $manualTokenInput)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(13))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .focused($isManualTokenFocused)
                    .onSubmit { submitManualToken() }

                if !manualTokenInput.isEmpty {
                    Button(action: submitManualToken) {
                        Text("connect \u{21B5}")
                            .font(Port42Theme.mono(11))
                            .foregroundStyle(Port42Theme.accent.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }

            Spacer().frame(height: 4)

            // Option 2: API key
            authOptionButton(.apiKey, label: "API key", hint: nil, action: selectApiKey)

            if authMethod == .apiKey {
                Spacer().frame(height: 8)
                SecureField("paste your Anthropic API key", text: $apiKeyInput)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(13))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .focused($isApiKeyFocused)
                    .onSubmit { submitApiKey() }

                if !apiKeyInput.isEmpty {
                    Button(action: submitApiKey) {
                        Text("connect \u{21B5}")
                            .font(Port42Theme.mono(11))
                            .foregroundStyle(Port42Theme.accent.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }

            if isCheckingAuth {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Connecting...")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                .padding(.top, 4)
            }

            if let error = authError {
                HStack(spacing: 6) {
                    Text("!")
                        .font(Port42Theme.monoBold(13))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .padding(.top, 4)
            }

            // Guided setup for Claude Code (shown when no tokens found, not for multi-token picker)
            if authMethod == .claudeCode, keychainEntries.isEmpty,
               claudeSetup.state != .idle, claudeSetup.state != .success,
               !isMultiTokenState {
                ClaudeCodeSetupView(setup: claudeSetup)
                    .padding(.top, 8)
            }

            Spacer().frame(height: 8)

            Text("Auto-detect reads from Claude Code/Desktop. Session key for manual OAuth entry.")
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.4))
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isAuthPickerFocused)
        .onKeyPress(.downArrow) {
            cycleAuthMethod(forward: true)
            return .handled
        }
        .onKeyPress(.upArrow) {
            cycleAuthMethod(forward: false)
            return .handled
        }
        .onKeyPress(.return) {
            submitSelectedAuth()
            return .handled
        }
    }

    private func subOptionButton(selected: Bool, label: String, hint: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(selected ? ">" : " ")
                    .font(Port42Theme.monoBold(14))
                    .foregroundStyle(Port42Theme.accent)
                    .opacity(selected ? (cursorVisible ? 1 : 0.3) : 0)
                Text("\u{25B8} \(label)")
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(selected ? Port42Theme.textPrimary : Port42Theme.textSecondary.opacity(0.5))
                if let hint {
                    Text(hint)
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.3))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 20)
    }

    private func authOptionButton(_ method: AuthMethod, label: String, hint: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(authSelected == method ? ">" : " ")
                    .font(Port42Theme.monoBold(14))
                    .foregroundStyle(Port42Theme.accent)
                    .opacity(authSelected == method ? (cursorVisible ? 1 : 0.3) : 0)
                Text(label)
                    .font(Port42Theme.mono(13))
                    .foregroundStyle(authSelected == method ? Port42Theme.textPrimary : Port42Theme.textSecondary.opacity(0.5))
                if let hint {
                    Text(hint)
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.4))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func submitSelectedAuth() {
        switch authSelected {
        case .claudeCode:
            if keychainEntries.count > 1 {
                selectTokenEntry(selectedTokenIndex)
            } else {
                selectAndSubmitClaudeCode()
            }
        case .manualToken:
            selectManualToken()
        case .apiKey:
            selectApiKey()
        }
    }

    private func selectTokenEntry(_ index: Int) {
        guard index < keychainEntries.count else { return }
        selectedTokenIndex = index
        authMethod = .claudeCode
        isCheckingAuth = true

        let entry = keychainEntries[index]
        DispatchQueue.global(qos: .userInitiated).async {
            AgentAuthResolver.shared.selectEntry(entry)
            DispatchQueue.main.async {
                isCheckingAuth = false
                completeAuth()
            }
        }
    }

    private func cycleAuthMethod(forward: Bool) {
        if keychainEntries.count > 1 {
            // Multi-account mode: flat list is [entry0, entry1, ..., enterToken, apiKey]
            // Map current position to an index in that flat list
            let entryCount = keychainEntries.count
            let totalPositions = entryCount + 2 // entries + "enter token" + "API key"

            var currentPos: Int
            if authSelected == .claudeCode {
                currentPos = selectedTokenIndex
            } else if authSelected == .manualToken {
                currentPos = entryCount  // "enter token" position
            } else {
                currentPos = entryCount + 1 // API key
            }

            let newPos = forward
                ? min(currentPos + 1, totalPositions - 1)
                : max(currentPos - 1, 0)

            withAnimation(.easeIn(duration: 0.1)) {
                if newPos < entryCount {
                    authMethod = .claudeCode
                    selectedTokenIndex = newPos
                } else if newPos == entryCount {
                    authMethod = .manualToken
                } else {
                    authMethod = .apiKey
                }
            }
        } else {
            // Simple mode: [claudeCode, manualToken (sub-item), apiKey]
            let order: [AuthMethod] = [.claudeCode, .manualToken, .apiKey]
            let current = authSelected
            guard let idx = order.firstIndex(of: current) else { return }
            let next = forward ? min(idx + 1, order.count - 1) : max(idx - 1, 0)
            withAnimation(.easeIn(duration: 0.1)) { authMethod = order[next] }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isAuthPickerFocused = true
        }
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

        // Pre-fill API key from environment if available (but keep auto-detect as default)
        if let envKey = ProcessInfo.processInfo.environment.first(where: {
            $0.key.uppercased().contains("API_KEY") && !$0.value.isEmpty
        }) {
            apiKeyInput = envKey.value
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

    // MARK: - Swim (full-screen with dreamscape video showing through)

    private var swimTerminal: some View {
        ZStack {
            // Blue tint matching the dive transition, lets dreamscape video show through
            Color(red: 0.0, green: 0.15, blue: 0.3).opacity(0.3).ignoresSafeArea()

            if let session = appState.activeSwimSession {
                VStack(spacing: 0) {
                    // Branded top bar for first swim
                    HStack {
                        Circle()
                            .fill(Port42Theme.textAgent)
                            .frame(width: 8, height: 8)

                        Text(session.companion.displayName)
                            .font(Port42Theme.monoBold(14))
                            .foregroundStyle(Port42Theme.textAgent)

                        Text("swim session")
                            .font(Port42Theme.monoFontSmall)
                            .foregroundStyle(Port42Theme.textSecondary)

                        Spacer()

                        Button(action: {
                            NotificationCenter.default.post(name: .enterAquariumRequested, object: nil)
                        }) {
                            HStack(spacing: 8) {
                                Text("\u{1F42C}")
                                    .font(.system(size: 16))
                                Text("swim in open water")
                                    .font(Port42Theme.monoBold(12))
                                    .foregroundStyle(.black)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Port42Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .shadow(color: Port42Theme.accent.opacity(0.4), radius: 8)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.7))

                    Divider().background(Port42Theme.border.opacity(0.5))

                    // Chat content (same as SwimView internals)
                    ConversationContent(
                        entries: session.chatEntries(userName: submittedName ?? displayName),
                        placeholder: "Message \(session.companion.displayName)...",
                        isStreaming: session.isStreaming,
                        error: session.error,
                        typingNames: session.isStreaming ? [session.companion.displayName] : [],
                        onSend: { content in session.send(content) },
                        onStop: { session.stop() },
                        onRetry: { session.retry() },
                        onDismissError: { session.error = nil },
                        onOpenSettings: {
                            showSettings = true
                        }
                    )
                }
            }
        }
        .onAppear {
            Analytics.shared.screen("Setup_Swim")
            sendFirstMessage()
        }
    }

    private func sendFirstMessage() {
        guard let session = appState.activeSwimSession,
              session.messages.isEmpty else { return }
        let name = submittedName ?? displayName
        // Small delay so the swim view renders before the stream starts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            session.send("hey, i'm \(name). where am i?")
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
                    withAnimation(.easeIn(duration: 0.2)) {
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

        // Trigger Apple sign-in (dev only), then start create sequence
        Task {
            #if !RELEASE
            await performAppleSignIn()
            #endif

            // Start create sequence (which shows analytics then auth options)
            try? await Task.sleep(nanoseconds: 400_000_000)
            withAnimation(.easeIn(duration: 0.2)) {
                startCreateSequence()
            }
        }
    }

    private func performAppleSignIn() async {
        let appleAuth = AppleAuthService()
        let nonce = UUID().uuidString
        do {
            let result = try await appleAuth.authenticate(nonce: nonce)
            // Store Apple user ID on AppUser
            if var user = appState.currentUser {
                user.appleUserID = result.appleUserID
                try appState.db.saveUser(user)
                appState.currentUser = user
            }
            appleAuthStatus = "OK"
            NSLog("[Port42] Apple sign-in linked successfully")
        } catch {
            // Apple sign-in failed or cancelled, continue without it.
            // User can still use local features, just won't auth to remote gateway.
            appleAuthStatus = "skipped"
            NSLog("[Port42] Apple sign-in skipped: \(error)")
        }
    }

    private func selectApiKey() {
        claudeSetup.cancel()
        withAnimation(.easeIn(duration: 0.1)) {
            authMethod = .apiKey
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isApiKeyFocused = true
        }
    }

    private func selectManualToken() {
        claudeSetup.cancel()
        withAnimation(.easeIn(duration: 0.1)) {
            authMethod = .manualToken
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isManualTokenFocused = true
        }
    }

    private func submitManualToken() {
        let token = manualTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        authError = nil
        isCheckingAuth = true

        Port42AuthStore.shared.saveCredential(token)
        Port42AuthStore.shared.savePreference(pref: .manualEntry)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isCheckingAuth = false
            completeAuth()
        }
    }

    private func selectAndSubmitClaudeCode() {
        authMethod = .claudeCode
        tryClaudeCodeAuth()
    }

    private func tryClaudeCodeAuth() {
        NSLog("[Port42] tryClaudeCodeAuth() called")
        authError = nil
        isCheckingAuth = true

        DispatchQueue.global(qos: .userInitiated).async {
            let resolver = AgentAuthResolver.shared

            // Check Port42's own stored credentials first (no Keychain prompt)
            if Port42AuthStore.shared.loadPreference() == .manualEntry,
               Port42AuthStore.shared.loadCredential() != nil {
                DispatchQueue.main.async {
                    isCheckingAuth = false
                    completeAuth()
                }
                return
            }

            // Attributes-only query (zero Keychain prompts)
            let entries = resolver.listKeychainEntries()
            NSLog("[Port42] Found %d Keychain entries", entries.count)

            DispatchQueue.main.async {
                isCheckingAuth = false
                keychainEntries = entries
                if entries.count > 1 {
                    // Picker will show inline, wait for user selection
                    selectedTokenIndex = 0
                } else if entries.count == 1 {
                    // Single entry: select it (one Keychain prompt for data)
                    DispatchQueue.global(qos: .userInitiated).async {
                        resolver.selectEntry(entries[0])
                        DispatchQueue.main.async { completeAuth() }
                    }
                } else {
                    claudeSetup.diagnose()
                }
            }
        }
    }

    private func submitApiKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        authError = nil
        isCheckingAuth = true

        Port42AuthStore.shared.saveCredential(key)
        Port42AuthStore.shared.savePreference(pref: .manualEntry)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isCheckingAuth = false
            completeAuth()
        }
    }

    private func completeAuth() {
        let method: String
        switch authMethod {
        case .claudeCode: method = "claude_code"
        case .manualToken: method = "manual_token"
        case .apiKey: method = "api_key"
        case .none: method = "unknown"
        }
        Analytics.shared.setupStep("auth_\(method)")
        let name = submittedName ?? displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.completeSetup(displayName: name)
        phase = .transition
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
            withAnimation(.easeInOut(duration: 0.4)) {
                phase = .swim
            }
        }
    }
}
