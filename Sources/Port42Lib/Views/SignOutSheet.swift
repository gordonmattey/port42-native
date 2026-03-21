import SwiftUI
import AppKit

public struct SignOutSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var isHovering = false
    @State private var ngrokToken: String = UserDefaults.standard.string(forKey: "ngrokAuthToken") ?? ""
    @State private var ngrokDomain: String = UserDefaults.standard.string(forKey: "ngrokDomain") ?? ""
    @State private var editingToken = false
    @FocusState private var apiKeyFieldFocused: Bool
    @State private var autoUpdatesEnabled: Bool = UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? true
    @State private var selectedAuthPref: AuthPreference = Port42AuthStore.shared.loadPreference()
    @State private var authCredentialInput = ""
    @State private var authSaved = false
    @State private var detectedType: CredentialType = .unknown
    @State private var testResult: TestConnectionResult = .idle
    @StateObject private var claudeSetup = ClaudeCodeSetup()
    @State private var autoDetectStatus: AutoDetectStatus = .unknown
    @State private var currentCheckId: UUID?

    enum AutoDetectStatus: Equatable {
        case unknown
        case checking
        case connected(expiresIn: String?, account: String?)
        case notFound
    }

    enum TestConnectionResult: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text("\u{25C7}")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(Port42Theme.accent)

                if let user = appState.currentUser {
                    Text(user.displayName)
                        .font(Port42Theme.mono(14))
                        .foregroundStyle(Port42Theme.textPrimary)
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            Divider().background(Port42Theme.border)

            // Stats
            VStack(spacing: 10) {
                statRow(label: "channels", value: "\(appState.channels.count)")
                statRow(label: "companions", value: "\(appState.companions.count)")
                statRow(label: "messages", value: "\(appState.messages.count)+")
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 24)

            Divider().background(Port42Theme.border)

            // Sharing
            VStack(alignment: .leading, spacing: 8) {
                sharingSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider().background(Port42Theme.border)

            // AI Connection
            VStack(alignment: .leading, spacing: 8) {
                aiConnectionSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider().background(Port42Theme.border)

            // Updates
            VStack(alignment: .leading, spacing: 8) {
                updatesSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Spacer()

            // Actions
            VStack(spacing: 10) {
                Button(action: doSignOut) {
                    VStack(spacing: 2) {
                        Text("sign out")
                            .font(Port42Theme.monoBold(14))
                        Text("screensaver lock")
                            .font(Port42Theme.mono(10))
                    }
                    .foregroundStyle(Port42Theme.bgPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Port42Theme.accent)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    Button(action: doOff) {
                        VStack(spacing: 2) {
                            Text("off")
                                .font(Port42Theme.monoBold(14))
                            Text("reboot")
                                .font(Port42Theme.mono(10))
                        }
                        .foregroundStyle(Port42Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Port42Theme.textSecondary.opacity(0.15))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: doReset) {
                        VStack(spacing: 2) {
                            Text("reset")
                                .font(Port42Theme.monoBold(14))
                            Text("erase all")
                                .font(Port42Theme.mono(10))
                        }
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Button("stay") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(Port42Theme.mono(12))
                .foregroundStyle(Port42Theme.textSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 380, height: 740)
        .background(Port42Theme.bgSecondary)
        .onDisappear {
            claudeSetup.cancel()
        }
    }

    @ViewBuilder
    private var sharingSection: some View {
        if let publicURL = appState.tunnel.publicURL {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("open to the world")
                    .font(Port42Theme.mono(13))
                    .foregroundStyle(Port42Theme.textPrimary)
                Spacer()
            }

            HStack(spacing: 6) {
                Text(publicURL.replacingOccurrences(of: "wss://", with: ""))
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(publicURL, forType: .string)
                }) {
                    Text("copy")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Port42Theme.accent.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Button(action: toggleTunnel) {
                    Text("stop")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        } else if appState.tunnel.isRunning {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text(appState.tunnel.status)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textSecondary)
            }
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(Port42Theme.textSecondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text("connections")
                    .font(Port42Theme.mono(13))
                    .foregroundStyle(Port42Theme.textSecondary)
                Spacer()
                Text("local only")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
            }

            if !ngrokToken.isEmpty && !editingToken {
                Button(action: toggleTunnel) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.system(size: 11))
                        Text("invite others")
                            .font(Port42Theme.monoBold(12))
                    }
                    .foregroundStyle(Port42Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Port42Theme.accent.opacity(0.1))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)

                Button(action: { editingToken = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "key")
                            .font(.system(size: 9))
                        Text("change token")
                            .font(Port42Theme.mono(11))
                    }
                    .foregroundStyle(Port42Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Port42Theme.textSecondary.opacity(0.08))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            } else {
                if ngrokToken.isEmpty {
                    Text("to invite others to your channels, add a free ngrok token")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }

                SecureField("paste ngrok token here", text: $ngrokToken)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Port42Theme.bgPrimary)
                    .cornerRadius(4)
                    .onSubmit {
                        appState.tunnel.setAuthToken(ngrokToken)
                    }
                    .onChange(of: ngrokToken) { _, newValue in
                        if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            appState.tunnel.setAuthToken(newValue)
                        }
                    }

                HStack(spacing: 4) {
                    Text("get one free at")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                    Text("ngrok.com")
                        .font(Port42Theme.monoBold(11))
                        .foregroundStyle(Port42Theme.accent)
                        .onTapGesture {
                            if let url = URL(string: "https://dashboard.ngrok.com/get-started/your-authtoken") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    Spacer()
                    if editingToken {
                        Button(action: { editingToken = false }) {
                            Text("done")
                                .font(Port42Theme.monoBold(11))
                                .foregroundStyle(Port42Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !appState.tunnel.status.isEmpty && appState.tunnel.status != "needs auth token" {
                    Text(appState.tunnel.status)
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
        }
    }

    @ViewBuilder
    private var aiConnectionSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain")
                .font(.system(size: 11))
                .foregroundStyle(Port42Theme.textSecondary)
            Text("Claude connection")
                .font(Port42Theme.mono(13))
                .foregroundStyle(Port42Theme.textSecondary)
            Spacer()
        }

        // Two mode buttons
        HStack(spacing: 6) {
            authPrefButton(.autoDetect, label: "auto")
            authPrefButton(.manualEntry, label: "manual")
        }

        // Auto-detect status and guided setup
        Group { if selectedAuthPref == .autoDetect {
            switch autoDetectStatus {
            case .unknown:
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("checking...")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                }

            case .checking:
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Detecting...")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                }

            case .connected(let expiresIn, let account):
                HStack(spacing: 6) {
                    if let account {
                        Text(account)
                            .font(Port42Theme.mono(11))
                            .foregroundStyle(Port42Theme.textPrimary)
                    }
                    if let exp = expiresIn {
                        Text("expires in \(exp)")
                            .font(Port42Theme.mono(10))
                            .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                    }
                }
                HStack(spacing: 8) {
                    Button(action: doTestConnection) {
                        Text("test")
                            .font(Port42Theme.mono(11))
                            .foregroundStyle(Port42Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Port42Theme.accent.opacity(0.1))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Button(action: refreshAutoDetect) {
                        Text("refresh")
                            .font(Port42Theme.mono(11))
                            .foregroundStyle(Port42Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Port42Theme.accent.opacity(0.1))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    testResultView
                }

                // Account switcher when multiple entries exist
                if case .multipleTokens = claudeSetup.state {
                    ClaudeCodeSetupView(setup: claudeSetup)
                }

            case .notFound:
                HStack(spacing: 6) {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                    Text("no Claude Code token found")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(.orange)
                }

                ClaudeCodeSetupView(setup: claudeSetup)
                    .onAppear {
                        if claudeSetup.state == .idle {
                            claudeSetup.diagnose()
                        }
                    }
            }

        } }
        .onChange(of: claudeSetup.state) { _, newState in
            if newState == .success {
                // Invalidate any in-flight async check so it won't overwrite
                currentCheckId = nil
                let resolver = AgentAuthResolver.shared
                let exp = resolver.cachedExpiryDescription
                let acct = resolver.activeAccountLabel
                autoDetectStatus = .connected(expiresIn: exp, account: acct)
            }
        }
        .onAppear {
            if selectedAuthPref == .autoDetect {
                checkAutoDetect()
            }
        }

        // Manual mode: single input field with live type detection
        if selectedAuthPref == .manualEntry {
            SecureField("paste API key or OAuth session key", text: $authCredentialInput)
                .textFieldStyle(.plain)
                .font(Port42Theme.mono(12))
                .foregroundStyle(Port42Theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Port42Theme.bgPrimary)
                .cornerRadius(4)
                .onSubmit { saveManualCredential() }
                .onChange(of: authCredentialInput) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    detectedType = trimmed.isEmpty ? .unknown : TokenDetector.detect(trimmed)
                    testResult = .idle
                }
                .focused($apiKeyFieldFocused)
                .onChange(of: apiKeyFieldFocused) { _, focused in
                    if !focused { saveManualCredential() }
                }

            // Live detection label
            if !authCredentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 6) {
                    if detectedType == .unknown {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                    Text("detected: \(TokenDetector.humanLabel(detectedType))")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(detectedType == .unknown ? .orange : Port42Theme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                Button(action: saveManualCredential) {
                    Text(authCredentialInput.isEmpty ? "clear" : "save")
                        .font(Port42Theme.monoBold(12))
                        .foregroundStyle(Port42Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Port42Theme.accent.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Button(action: doTestConnection) {
                    Text("test")
                        .font(Port42Theme.monoBold(12))
                        .foregroundStyle(Port42Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Port42Theme.accent.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)

                testResultView

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testResult {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
        case .success:
            Text("connected")
                .font(Port42Theme.mono(11))
                .foregroundStyle(.green)
                .transition(.opacity)
        case .failure(let msg):
            Text(msg)
                .font(Port42Theme.mono(10))
                .foregroundStyle(.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }

    private func authPrefButton(_ pref: AuthPreference, label: String) -> some View {
        Button(action: {
            withAnimation(.easeIn(duration: 0.1)) {
                selectedAuthPref = pref
                authSaved = false
                testResult = .idle
                // Pre-fill with saved credential when switching to manual
                if pref == .manualEntry {
                    authCredentialInput = Port42AuthStore.shared.loadCredential() ?? ""
                    let trimmed = authCredentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    detectedType = trimmed.isEmpty ? .unknown : TokenDetector.detect(trimmed)
                }
            }
            Port42AuthStore.shared.savePreference(pref: pref)
            if pref == .autoDetect {
                AgentAuthResolver.shared.clearCache()
                checkAutoDetect()
            } else {
                claudeSetup.cancel()
            }
            // Update global auth status
            appState.authStatus = .checking
            DispatchQueue.global(qos: .userInitiated).async {
                let status = AgentAuthResolver.shared.checkStatus()
                DispatchQueue.main.async {
                    appState.authStatus = status
                }
            }
        }) {
            Text(label)
                .font(Port42Theme.mono(11))
                .foregroundStyle(selectedAuthPref == pref ? Port42Theme.accent : Port42Theme.textSecondary.opacity(0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selectedAuthPref == pref ? Port42Theme.accent.opacity(0.15) : Port42Theme.bgPrimary)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func saveManualCredential() {
        let value = authCredentialInput.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.isEmpty {
            Port42AuthStore.shared.deleteCredential()
        } else {
            Port42AuthStore.shared.saveCredential(value)
        }
        AgentAuthResolver.shared.resetAuth()

        withAnimation(.easeIn(duration: 0.2)) {
            authSaved = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                authSaved = false
            }
        }

        // Update global auth status
        appState.authStatus = .checking
        DispatchQueue.global(qos: .userInitiated).async {
            let status = AgentAuthResolver.shared.checkStatus()
            DispatchQueue.main.async {
                appState.authStatus = status
            }
        }
    }

    private func doTestConnection() {
        // Commit any unsaved input before testing so the test uses what's on screen
        if selectedAuthPref == .manualEntry {
            saveManualCredential()
        }
        testResult = .testing
        Task {
            let error = await LLMEngine.testConnection()
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) {
                    if let error {
                        testResult = .failure(error)
                    } else {
                        testResult = .success
                    }
                }
                // Auto-clear success after 5s
                if testResult == .success {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            if testResult == .success { testResult = .idle }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Port42Theme.textSecondary)
            Text("updates")
                .font(Port42Theme.mono(13))
                .foregroundStyle(Port42Theme.textSecondary)
            Spacer()

            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            Text("v\(version) (\(build))")
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
        }

        HStack(spacing: 8) {
            Button(action: {
                isPresented = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .checkForUpdatesRequested, object: nil)
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11))
                    Text("check now")
                        .font(Port42Theme.monoBold(12))
                }
                .foregroundStyle(Port42Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Port42Theme.accent.opacity(0.1))
                .cornerRadius(5)
            }
            .buttonStyle(.plain)

            Spacer()

            Toggle(isOn: $autoUpdatesEnabled) {
                Text("auto")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Port42Theme.accent)
            .onChange(of: autoUpdatesEnabled) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "SUAutomaticallyUpdate")
                UserDefaults.standard.set(newValue, forKey: "SUEnableAutomaticChecks")
            }
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Port42Theme.mono(13))
                .foregroundStyle(Port42Theme.textSecondary)
            Spacer()
            Text(value)
                .font(Port42Theme.monoBold(13))
                .foregroundStyle(Port42Theme.textPrimary)
        }
    }

    private func checkAutoDetect() {
        autoDetectStatus = .checking
        let checkId = UUID()
        currentCheckId = checkId
        DispatchQueue.global(qos: .userInitiated).async {
            let resolver = AgentAuthResolver.shared
            let entries = resolver.listKeychainEntries()
            let status = resolver.checkStatus()

            DispatchQueue.main.async {
                // Stale check: a selection happened while we were async
                guard self.currentCheckId == checkId else { return }

                let isConnected: Bool
                if case .connected = status { isConnected = true } else { isConnected = false }

                if entries.count > 1 {
                    if isConnected {
                        let expiresIn = resolver.cachedExpiryDescription
                        let account = resolver.activeAccountLabel
                        autoDetectStatus = .connected(expiresIn: expiresIn, account: account)
                    } else {
                        autoDetectStatus = .notFound
                    }
                    claudeSetup.state = .multipleTokens(entries)
                } else if entries.count == 1 {
                    autoDetectStatus = .checking
                    DispatchQueue.global(qos: .userInitiated).async {
                        resolver.selectEntry(entries[0])
                        let expiresIn = resolver.cachedExpiryDescription
                        let account = resolver.activeAccountLabel
                        DispatchQueue.main.async {
                            autoDetectStatus = .connected(expiresIn: expiresIn, account: account)
                        }
                    }
                } else if isConnected {
                    let expiresIn = resolver.cachedExpiryDescription
                    let account = resolver.activeAccountLabel
                    autoDetectStatus = .connected(expiresIn: expiresIn, account: account)
                } else {
                    autoDetectStatus = .notFound
                }
            }
        }
    }

    private func refreshAutoDetect() {
        AgentAuthResolver.shared.clearCache()
        testResult = .idle
        checkAutoDetect()
    }

    private func toggleTunnel() {
        if appState.tunnel.isRunning {
            appState.tunnel.stop()
            Analytics.shared.ngrokToggled(enabled: false)
        } else {
            let port = GatewayProcess.shared.port
            appState.tunnel.start(port: port)
            Analytics.shared.ngrokToggled(enabled: true)
        }
    }

    private func doSignOut() {
        isPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            appState.lockApp()
        }
    }

    private func doOff() {
        isPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            appState.powerOff()
        }
    }

    private func doReset() {
        isPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            appState.resetApp()
        }
    }
}
