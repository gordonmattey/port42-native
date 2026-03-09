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
    @State private var authMethod: AuthMethod?
    @State private var authError: String?
    @State private var isCheckingAuth = false
    @State private var submittedName: String?
    @State private var appleAuthStatus: String?
    @State private var showAnalyticsConsent = false
    @State private var terminalVisible = false
    @State private var terminalOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @FocusState private var isFocused: Bool
    @FocusState private var isApiKeyFocused: Bool

    enum AuthMethod {
        case claudeCode
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

        enum Style {
            case post
            case header
            case body
            case accent
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
            .init(text: "Checking consciousness drivers... OK", style: .post, delay: 0.7),
            .init(text: "Loading memory subsystem... OK", style: .post, delay: 0.6),
            .init(text: "Initializing possibility engine... OK", style: .post, delay: 0.8),
            .init(text: "", style: .blank, delay: 0.8),
            .init(text: "Welcome to Port 42.", style: .header, delay: 0.6),
            .init(text: "", style: .blank, delay: 0.5),
            .init(text: "", style: .blank, delay: 0.3),
            .init(text: "This is not a chatbot.", style: .body, delay: 0.6),
            .init(text: "This is not an app.", style: .body, delay: 0.5),
            .init(text: "This is a Reality Compiler.", style: .accent, delay: 0.6),
            .init(text: "", style: .blank, delay: 0.8),
        ]
    }

    // MARK: - Create Sequence

    private var createSequence: [TermLine] {
        let name = submittedName ?? ""
        let keychainOK = appState.currentUser.map { AppUser.keychainHasKey(account: $0.id) } ?? false
        let keychainStatus = keychainOK ? "OK" : "FAILED"
        let appleStatus = appleAuthStatus ?? "pending"
        return [
            .init(text: "", style: .blank, delay: 0.5),
            .init(text: "Creating reality instance for \(name)...", style: .post, delay: 0.8),
            .init(text: "", style: .blank, delay: 0.6),
            .init(text: "Generating P256 identity key pair...", style: .post, delay: 0.8),
            .init(text: "Storing private key in Keychain... \(keychainStatus)", style: .post, delay: 1.0),
            .init(text: "Public key: \(keyFingerprint)", style: .dim, delay: 0.6),
            .init(text: "Linking Apple identity... \(appleStatus)", style: .post, delay: 0.6),
            .init(text: "", style: .blank, delay: 0.6),
            .init(text: "Detecting Claude Code credentials...", style: .post, delay: 0.8),
            .init(text: "macOS may prompt for Keychain access. Click Allow.", style: .dim, delay: 0.6),
            .init(text: "", style: .blank, delay: 0.6),
            .init(text: "", style: .blank, delay: 0.8),
            .init(text: "Welcome, \(name).", style: .header, delay: 0.6),
            .init(text: "", style: .blank, delay: 0.5),
        ]
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
    }

    // MARK: - Single Continuous Terminal

    private var setupTerminal: some View {
        setupTerminalContent
            .frame(width: 520)
            .frame(maxHeight: 500)
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
                            termLineView(line)
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

                        // Analytics consent (after name, before create)
                        if showAnalyticsConsent {
                            analyticsConsentContent
                                .id("analytics")
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

                        // Auth options (appear after create sequence)
                        if showAuthOptions {
                            authOptionsContent
                                .id("auth")
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
            }
        }
    }

    // MARK: - Auth Options (inline, not a separate terminal)

    private var authSelected: AuthMethod {
        authMethod ?? .claudeCode
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

            Button(action: selectAndSubmitClaudeCode) {
                HStack(spacing: 8) {
                    Text(authSelected == .claudeCode ? ">" : " ")
                        .font(Port42Theme.monoBold(14))
                        .foregroundStyle(Port42Theme.accent)
                    Text("Use Claude Code subscription")
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(authSelected == .claudeCode ? Port42Theme.textPrimary : Port42Theme.textSecondary.opacity(0.5))
                    if authSelected == .claudeCode {
                        Text("(auto-detect)")
                            .font(Port42Theme.mono(11))
                            .foregroundStyle(Port42Theme.textSecondary.opacity(0.4))
                    }
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            Spacer().frame(height: 4)

            Button(action: selectApiKey) {
                HStack(spacing: 8) {
                    Text(authSelected == .apiKey ? ">" : " ")
                        .font(Port42Theme.monoBold(14))
                        .foregroundStyle(Port42Theme.accent)
                    Text("Enter API key")
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(authSelected == .apiKey ? Port42Theme.textPrimary : Port42Theme.textSecondary.opacity(0.5))
                }
            }
            .buttonStyle(.plain)

            if authMethod == .apiKey {
                Spacer().frame(height: 8)

                HStack(spacing: 6) {
                    Text("sk-")
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))

                    SecureField("paste your Anthropic API key", text: $apiKeyInput)
                        .textFieldStyle(.plain)
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .focused($isApiKeyFocused)
                        .onSubmit { submitApiKey() }
                }

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

            Spacer().frame(height: 8)

            Text("Claude Code subscribers connect automatically. macOS will prompt for Keychain access.")
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.4))
        }
        .onKeyPress(.downArrow) {
            if authSelected != .apiKey { selectApiKey() }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if authSelected != .claudeCode {
                withAnimation(.easeIn(duration: 0.1)) { authMethod = .claudeCode }
            }
            return .handled
        }
        .focusable()
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
        withAnimation(.easeIn(duration: 0.15)) {
            showAnalyticsConsent = false
        }
        startCreateSequence()
    }

    // MARK: - Transition (fade to black, diamond, reveal)

    private var transitionView: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            if diamondVisible {
                Text("\u{25C7}")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Port42Theme.accent)
                    .transition(.opacity)
            }
        }
        .opacity(transitionOpacity)
        .onAppear {
            startTransition()
        }
    }

    // MARK: - Swim (full-screen)

    private var swimTerminal: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                if let session = appState.activeSwimSession {
                    Circle()
                        .fill(Port42Theme.textAgent)
                        .frame(width: 8, height: 8)

                    Text(session.companion.displayName)
                        .font(Port42Theme.monoBold(14))
                        .foregroundStyle(Port42Theme.textAgent)

                    Text("swim session")
                        .font(Port42Theme.monoFontSmall)
                        .foregroundStyle(Port42Theme.textSecondary)
                }

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

            // Chat content fills remaining space
            if let session = appState.activeSwimSession {
                ConversationContent(
                    entries: session.chatEntries(userName: submittedName ?? displayName),
                    placeholder: "Message \(session.companion.displayName)...",
                    isStreaming: session.isStreaming,
                    error: session.error,
                    onSend: { content in session.send(content) },
                    onStop: { session.stop() },
                    onRetry: { session.retry() },
                    onDismissError: { session.error = nil }
                )
            }
        }
        .onAppear {
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
    private func termLineView(_ line: TermLine) -> some View {
        if line.style == .blank {
            Spacer().frame(height: 6)
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
                proxy.scrollTo("auth", anchor: .bottom)
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
            // Auto-detect Claude Code credentials during boot
            // The Keychain prompt will appear here if needed
            DispatchQueue.global(qos: .userInitiated).async {
                let resolver = AgentAuthResolver.shared
                let found = resolver.autoDetect() != nil
                DispatchQueue.main.async {
                    if found {
                        // Credentials found, skip auth options and go straight to swim
                        completeAuth()
                    } else {
                        // No credentials found, show manual auth options
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            withAnimation(.easeIn(duration: 0.2)) {
                                showAuthOptions = true
                            }
                        }
                    }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + lines[index].delay) {
            update(index + 1)
            revealLines(lines, current: index + 1, update: update, completion: completion)
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

        // Generate identity key pair and store in Keychain now,
        // so the create sequence can show the real fingerprint
        let user = AppUser.createLocal(displayName: name)
        do {
            try appState.db.saveUser(user)
            appState.currentUser = user
        } catch {
            NSLog("[Port42] Failed to save user during key gen: \(error)")
        }

        // Trigger Apple sign-in, then show analytics consent
        Task {
            await performAppleSignIn()

            // Show analytics consent after Apple sign-in completes (or is skipped)
            try? await Task.sleep(nanoseconds: 400_000_000)
            withAnimation(.easeIn(duration: 0.2)) {
                showAnalyticsConsent = true
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
        withAnimation(.easeIn(duration: 0.1)) {
            authMethod = .apiKey
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isApiKeyFocused = true
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

        // Keychain access can block with a system prompt, so run off main thread
        DispatchQueue.global(qos: .userInitiated).async {
            NSLog("[Port42] About to call autoDetect()")
            let resolver = AgentAuthResolver.shared
            let found = resolver.autoDetect() != nil
            NSLog("[Port42] autoDetect() returned: found=\(found)")
            DispatchQueue.main.async {
                isCheckingAuth = false
                if found {
                    NSLog("[Port42] Auth found, completing")
                    completeAuth()
                } else {
                    NSLog("[Port42] Auth not found")
                    authError = "Claude Code credentials not found. Sign in to Claude Code first, or use an API key."
                }
            }
        }
    }

    private func submitApiKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        authError = nil
        isCheckingAuth = true

        // TODO: store the API key for LLMEngine to use
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isCheckingAuth = false
            completeAuth()
        }
    }

    private func completeAuth() {
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
