import SwiftUI
import AppKit

public struct SignOutSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var isHovering = false
    @State private var ngrokToken: String = UserDefaults.standard.string(forKey: "ngrokAuthToken") ?? ""
    @State private var ngrokDomain: String = UserDefaults.standard.string(forKey: "ngrokDomain") ?? ""
    @State private var editingToken = false
    @State private var autoUpdatesEnabled: Bool = UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? true
    @State private var selectedAuthMode: StoredAuthMode = Port42AuthStore.shared.loadMode()
    @State private var authCredentialInput = ""
    @State private var authSaved = false

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

                Button(action: doOff) {
                    VStack(spacing: 2) {
                        Text("off")
                            .font(Port42Theme.monoBold(14))
                        Text("keep data, boot from scratch")
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
                        Text("erase everything, start fresh")
                            .font(Port42Theme.mono(10))
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

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

            let modeLabel: String = {
                switch selectedAuthMode {
                case .autoDetect: return "Claude auto-detect"
                case .manualToken: return "Claude token"
                case .apiKey: return "Anthropic API key"
                }
            }()
            Text(modeLabel)
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
        }

        // Mode picker
        HStack(spacing: 6) {
            authModeButton(.autoDetect, label: "auto")
            authModeButton(.manualToken, label: "token")
            authModeButton(.apiKey, label: "API key")
        }

        // Credential input for manual modes
        if selectedAuthMode == .manualToken || selectedAuthMode == .apiKey {
            let placeholder = selectedAuthMode == .manualToken
                ? "paste Claude session token"
                : "paste Anthropic API key (sk-ant-...)"

            SecureField(placeholder, text: $authCredentialInput)
                .textFieldStyle(.plain)
                .font(Port42Theme.mono(12))
                .foregroundStyle(Port42Theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Port42Theme.bgPrimary)
                .cornerRadius(4)
                .onSubmit { saveAuthCredential() }

            HStack(spacing: 8) {
                Button(action: saveAuthCredential) {
                    Text(authCredentialInput.isEmpty ? "clear" : "save")
                        .font(Port42Theme.monoBold(12))
                        .foregroundStyle(Port42Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Port42Theme.accent.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)

                if authSaved {
                    Text("saved")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Spacer()
            }
        }
    }

    private func authModeButton(_ mode: StoredAuthMode, label: String) -> some View {
        Button(action: {
            withAnimation(.easeIn(duration: 0.1)) {
                selectedAuthMode = mode
                authSaved = false
                authCredentialInput = ""
            }
            Port42AuthStore.shared.saveMode(mode)
            if mode == .autoDetect {
                // Clear stored credentials when switching to auto
                AgentAuthResolver.shared.clearCache()
            }
        }) {
            Text(label)
                .font(Port42Theme.mono(11))
                .foregroundStyle(selectedAuthMode == mode ? Port42Theme.accent : Port42Theme.textSecondary.opacity(0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selectedAuthMode == mode ? Port42Theme.accent.opacity(0.15) : Port42Theme.bgPrimary)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func saveAuthCredential() {
        let value = authCredentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = selectedAuthMode == .manualToken ? "manualToken" : "apiKey"

        if value.isEmpty {
            // Clear credential
            Port42AuthStore.shared.deleteCredential(account: account)
        } else {
            Port42AuthStore.shared.saveCredential(value, account: account)
        }
        AgentAuthResolver.shared.clearCache()

        withAnimation(.easeIn(duration: 0.2)) {
            authSaved = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                authSaved = false
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

    private func toggleTunnel() {
        if appState.tunnel.isRunning {
            appState.tunnel.stop()
        } else {
            let port = GatewayProcess.shared.port
            appState.tunnel.start(port: port)
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
