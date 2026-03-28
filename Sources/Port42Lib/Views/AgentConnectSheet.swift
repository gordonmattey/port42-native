import SwiftUI

// MARK: - Agent Connect Sheet

/// Unified "Bring Your Own Agent" sheet. Shown when a channel invite deep link
/// contains an encryption key — lets the user choose OpenClaw or Python/LangChain,
/// with common fields (agent name, trigger) shared up top.
struct AgentConnectSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState
    let channel: Channel
    let inviteURL: String?

    enum SDKChoice { case python, openclaw }

    @State private var sdk: SDKChoice = .python
    @State private var agentName = "my-agent"
    @State private var trigger: AgentTrigger = .mentionOnly

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Port42Theme.border)
            content
            Divider().background(Port42Theme.border)
            footer
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(Port42Theme.bgSecondary)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Port42Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("connect an agent")
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

            // Channel
            HStack(spacing: 6) {
                Text("channel")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                Text("#\(channel.name)")
                    .font(Port42Theme.monoBold(11))
                    .foregroundStyle(Port42Theme.accent)
            }

            // Common: agent name
            VStack(alignment: .leading, spacing: 4) {
                Text("agent name")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary)
                TextField("my-agent", text: $agentName)
                    .font(Port42Theme.mono(12))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Port42Theme.bgPrimary)
                    .cornerRadius(5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Port42Theme.border, lineWidth: 1)
                    )
            }

            // Common: trigger
            VStack(alignment: .leading, spacing: 6) {
                Text("responds to")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary)
                HStack(spacing: 12) {
                    triggerOption("@mentions only", value: .mentionOnly)
                    triggerOption("all messages", value: .allMessages)
                }
            }

            Divider().background(Port42Theme.border)

            // SDK choice
            VStack(alignment: .leading, spacing: 8) {
                Text("framework")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary)
                HStack(spacing: 0) {
                    sdkTab("Python / LangChain", value: .python)
                    sdkTab("OpenClaw", value: .openclaw)
                }
                .background(Port42Theme.bgPrimary)
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Port42Theme.border, lineWidth: 1))
            }

            // SDK description
            switch sdk {
            case .python:
                Text("pip install port42 · python agent.py")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
            case .openclaw:
                Text("openclaw.ai · any LLM, any tool")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
            }

            // Connect button
            Button(action: connect) {
                Text("connect to #\(channel.name)")
                    .font(Port42Theme.monoBold(12))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Port42Theme.accent)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("LangChain · OpenClaw · any Python framework")
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func sdkTab(_ label: String, value: SDKChoice) -> some View {
        Button(action: { sdk = value }) {
            Text(label)
                .font(Port42Theme.mono(11))
                .foregroundStyle(sdk == value ? Port42Theme.accent : Port42Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(sdk == value ? Port42Theme.accent.opacity(0.1) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func triggerOption(_ label: String, value: AgentTrigger) -> some View {
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

    private func connect() {
        isPresented = false
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "my-agent" : agentName.trimmingCharacters(in: .whitespacesAndNewlines)

        switch sdk {
        case .python:
            appState.pythonAgentChannel = channel
            appState.pythonAgentName = name
            appState.pythonAgentTrigger = trigger
            appState.pythonAgentPrefilledInviteURL = inviteURL
            appState.showPythonAgentSheet = true

        case .openclaw:
            appState.openClawChannel = channel
            appState.showOpenClawSheet = true
        }
    }
}
