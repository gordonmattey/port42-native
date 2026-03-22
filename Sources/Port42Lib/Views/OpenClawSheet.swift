import SwiftUI

// MARK: - OpenClaw Agent Sheet

/// Sheet for connecting an OpenClaw agent to a Port42 channel.
/// Auto-detects local OpenClaw gateway, lists available agents,
/// and configures the connection with one click.
struct OpenClawSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState
    let channel: Channel

    @StateObject private var openclaw = OpenClawService()
    @State private var selectedAgent: String?
    @State private var trigger: String = "mention"
    @State private var isWorking = false
    @State private var installingPlugin = false
    @State private var successMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Port42Theme.border)
            content
            Divider().background(Port42Theme.border)
            footer
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(Port42Theme.bgSecondary)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Port42Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear {
            openclaw.connect()
        }
        .onDisappear {
            openclaw.disconnect()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("connect openclaw agent")
                .font(Port42Theme.monoBold(13))
                .foregroundStyle(Port42Theme.accent)
            Spacer()
            Button(action: { isPresented = false }) {
                Text("esc")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Port42Theme.bgHover)
                    .cornerRadius(3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Channel target
            HStack(spacing: 6) {
                Text("channel")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                Text("#\(channel.name)")
                    .font(Port42Theme.monoBold(11))
                    .foregroundStyle(Port42Theme.accent)
            }

            switch openclaw.status {
            case .notInstalled:
                notInstalledView
            case .gatewayOffline:
                gatewayOfflineView
            case .connecting:
                connectingView
            case .connected:
                if let successMessage {
                    successView(successMessage)
                } else {
                    connectedView
                }
            case .idle:
                EmptyView()
            case .error(let msg):
                errorView(msg)
            }

            if let err = openclaw.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(err)
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button("copy error") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(err, forType: .string)
                    }
                    .font(Port42Theme.mono(10))
                    .buttonStyle(.plain)
                    .foregroundStyle(Port42Theme.textSecondary)
                }
            }

        }
        .padding(20)
    }

    // MARK: - Status views

    private var notInstalledView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("openclaw not detected")
                .font(Port42Theme.monoBold(12))
                .foregroundStyle(Port42Theme.textPrimary)
            Text("install openclaw then reopen this sheet")
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary)
            Link("openclaw.ai", destination: URL(string: "https://openclaw.ai")!)
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.accent)
        }
    }

    private var gatewayOfflineView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("openclaw gateway is not running")
                .font(Port42Theme.monoBold(12))
                .foregroundStyle(Port42Theme.textPrimary)
            Text("start it with: openclaw gateway")
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary)
            Button("retry") {
                openclaw.connect()
            }
            .font(Port42Theme.mono(11))
            .buttonStyle(.plain)
            .foregroundStyle(Port42Theme.accent)
        }
    }

    private var connectingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.6)
            Text("connecting to openclaw...")
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary)
        }
    }

    private var connectedView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !openclaw.pluginInstalled {
                // Auto-install plugin
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("installing port42-openclaw plugin...")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                .onAppear {
                    guard !installingPlugin else { return }
                    Task {
                        installingPlugin = true
                        _ = await openclaw.installPlugin()
                        installingPlugin = false
                    }
                }
            } else {
                // Agent selection
                if openclaw.agents.isEmpty {
                    Text("no agents found in openclaw")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                } else {
                    agentSelectionView
                    triggerSelectionView
                    connectButton
                }
            }
        }
    }

    private var agentSelectionView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("agent")
                .font(Port42Theme.monoBold(11))
                .foregroundStyle(Port42Theme.textSecondary)

            VStack(spacing: 0) {
                ForEach(openclaw.agents) { agent in
                    Button(action: { selectedAgent = agent.id }) {
                        HStack(spacing: 8) {
                            Image(systemName: selectedAgent == agent.id ? "circle.fill" : "circle")
                                .font(.system(size: 8))
                                .foregroundStyle(selectedAgent == agent.id ? Port42Theme.accent : Port42Theme.textSecondary)
                            Text(agent.id)
                                .font(Port42Theme.mono(12))
                                .foregroundStyle(Port42Theme.textPrimary)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(selectedAgent == agent.id ? Port42Theme.bgHover : .clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Port42Theme.bgPrimary)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Port42Theme.border, lineWidth: 1)
            )
        }
        .onAppear {
            if selectedAgent == nil, let first = openclaw.agents.first {
                selectedAgent = first.id
            }
        }
    }

    private var triggerSelectionView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("responds to")
                .font(Port42Theme.monoBold(11))
                .foregroundStyle(Port42Theme.textSecondary)

            HStack(spacing: 12) {
                triggerOption("@mentions only", value: "mention")
                triggerOption("all messages", value: "all")
            }
        }
    }

    private func triggerOption(_ label: String, value: String) -> some View {
        Button(action: { trigger = value }) {
            HStack(spacing: 6) {
                Image(systemName: trigger == value ? "circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(trigger == value ? Port42Theme.accent : Port42Theme.textSecondary)
                Text(label)
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    private var connectButton: some View {
        Button(action: connectAgent) {
            HStack {
                if isWorking {
                    ProgressView()
                        .scaleEffect(0.6)
                }
                Text(isWorking ? "connecting..." : "connect to #\(channel.name)")
                    .font(Port42Theme.monoBold(12))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(selectedAgent != nil ? Port42Theme.accent : Port42Theme.bgHover)
            .foregroundStyle(selectedAgent != nil ? Color.black : Port42Theme.textSecondary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(selectedAgent == nil || isWorking)
    }

    private func successView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(Port42Theme.monoBold(12))
                .foregroundStyle(Port42Theme.accent)
            Text("the agent will appear in the channel shortly")
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary)
        }
    }

    // MARK: - Error view

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(Port42Theme.mono(11))
                .foregroundStyle(.red)
            Button("retry") {
                openclaw.connect()
            }
            .font(Port42Theme.mono(11))
            .buttonStyle(.plain)
            .foregroundStyle(Port42Theme.accent)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary)
            
            Spacer()

            if openclaw.updateAvailable {
                Text("update available")
                    .font(Port42Theme.mono(9))
                    .foregroundStyle(.orange)
            } else if let version = openclaw.openclawVersion {
                Text("v\(version)")
                    .font(Port42Theme.mono(9))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch openclaw.status {
        case .connected: return Port42Theme.accent
        case .connecting: return .yellow
        case .notInstalled, .gatewayOffline, .error: return .red
        case .idle: return Port42Theme.textSecondary
        }
    }

    private var statusText: String {
        switch openclaw.status {
        case .connected:
            if openclaw.pluginInstalled {
                return "openclaw connected, plugin installed"
            }
            return "openclaw connected"
        case .connecting: return "connecting..."
        case .notInstalled: return "openclaw not found"
        case .gatewayOffline: return "gateway offline"
        case .error(let msg): return msg
        case .idle: return "idle"
        }
    }

    // MARK: - Actions

    private func connectAgent() {
        guard let agentId = selectedAgent else { return }
        isWorking = true

        Task {
            // Generate invite link for this channel
            let secured = appState.ensureEncryptionKey(for: channel)
            let token = try? await appState.sync.requestToken(channelId: secured.id)

            guard let inviteURL = ChannelInvite.generateInviteURL(
                channel: secured,
                hostName: appState.currentUser?.displayName,
                syncGatewayURL: appState.sync.gatewayURL,
                token: token
            ) else {
                openclaw.error = "Could not generate invite link. Make sure tunneling is configured."
                isWorking = false
                return
            }

            let success = await openclaw.addChannelAgent(
                agentId: agentId,
                inviteURL: inviteURL,
                trigger: trigger,
                owner: appState.currentUser?.displayName ?? "port42"
            )

            isWorking = false

            if success {
                successMessage = "@\(agentId) connected to #\(channel.name)"
                Analytics.shared.openClawConnected()
            }
        }
    }
}
