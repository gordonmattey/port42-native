import SwiftUI

// MARK: - Python Agent Sheet

/// Sheet for connecting a Python SDK agent to a Port42 channel.
/// Generates a ready-to-run code snippet with channel + token pre-filled.
struct PythonAgentSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState
    let channel: Channel

    @State private var agentName = "my-agent"
    @State private var trigger: AgentTrigger = .mentionOnly
    @State private var template: SnippetTemplate = .basic
    @State private var snippets: [SnippetTemplate: String] = [:]
    @State private var isGenerating = false
    @State private var copied = false
    @State private var installCopied = false

    enum SnippetTemplate { case basic, langchain }

    private var snippet: String { snippets[template] ?? "" }

    // Fixed install line — always show the longer one to avoid layout shift
    private let installCmd = "pip install 'port42[langchain]' langchain-anthropic"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Port42Theme.border)
            content
            Divider().background(Port42Theme.border)
            footer
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(Port42Theme.bgSecondary)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Port42Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { generateSnippet() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("connect python agent")
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

            // Template toggle
            HStack(spacing: 0) {
                templateTab("basic", value: .basic)
                templateTab("langchain", value: .langchain)
            }
            .background(Port42Theme.bgPrimary)
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Port42Theme.border, lineWidth: 1))

            // Step 1: Install
            VStack(alignment: .leading, spacing: 6) {
                Text("1  install")
                    .font(Port42Theme.monoBold(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                HStack(spacing: 8) {
                    Text(installCmd)
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Port42Theme.bgPrimary)
                        .cornerRadius(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Port42Theme.border, lineWidth: 1)
                        )
                        .textSelection(.enabled)
                    Button(action: copyInstall) {
                        Text(installCopied ? "copied" : "copy")
                            .font(Port42Theme.mono(10))
                            .foregroundStyle(installCopied ? Port42Theme.accent : Port42Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Step 2: Configure
            VStack(alignment: .leading, spacing: 10) {
                Text("2  configure")
                    .font(Port42Theme.monoBold(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                // Agent name
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
                        .onChange(of: agentName) { generateSnippet() }
                }

                // Trigger
                VStack(alignment: .leading, spacing: 6) {
                    Text("responds to")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary)
                    HStack(spacing: 12) {
                        triggerOption("@mentions only", value: .mentionOnly)
                        triggerOption("all messages", value: .allMessages)
                    }
                }
            }

            // Step 3: Create + Run
            VStack(alignment: .leading, spacing: 6) {
                Text("3  save as agent.py")
                    .font(Port42Theme.monoBold(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                ZStack(alignment: .topLeading) {
                    if isGenerating {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.6)
                            Text("generating...")
                                .font(Port42Theme.mono(11))
                                .foregroundStyle(Port42Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
                        .padding(10)
                        .background(Port42Theme.bgPrimary)
                        .cornerRadius(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Port42Theme.border, lineWidth: 1))
                    } else {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(snippet)
                                .font(Port42Theme.mono(11))
                                .foregroundStyle(Port42Theme.textPrimary)
                                .padding(10)
                                .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                                .background(Port42Theme.bgPrimary)
                                .cornerRadius(5)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Port42Theme.border, lineWidth: 1))
                                .textSelection(.enabled)
                            Button(action: copySnippet) {
                                Text(copied ? "copied!" : "copy snippet")
                                    .font(Port42Theme.monoBold(11))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(copied ? Port42Theme.accent.opacity(0.7) : Port42Theme.accent)
                                    .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            // Step 4: Run
            VStack(alignment: .leading, spacing: 6) {
                Text("4  run")
                    .font(Port42Theme.monoBold(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                Text("python agent.py")
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Port42Theme.bgPrimary)
                    .cornerRadius(5)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Port42Theme.border, lineWidth: 1))
                    .textSelection(.enabled)
            }
        }
        .padding(20)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("pip install port42 · python agent.py")
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
            Spacer()
            Link("docs", destination: URL(string: "https://github.com/gordonmattey/port42-python")!)
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func templateTab(_ label: String, value: SnippetTemplate) -> some View {
        Button(action: { template = value }) {
            Text(label)
                .font(Port42Theme.mono(11))
                .foregroundStyle(template == value ? Port42Theme.accent : Port42Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(template == value ? Port42Theme.accent.opacity(0.1) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func triggerOption(_ label: String, value: AgentTrigger) -> some View {
        Button(action: {
            trigger = value
            generateSnippet()
        }) {
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

    private func generateSnippet() {
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "my-agent" : agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggerStr = trigger == .mentionOnly ? "mention" : "all_messages"
        isGenerating = true

        Task {
            let secured = appState.ensureEncryptionKey(for: channel)
            let rawGW = appState.sync.gatewayURL ?? "ws://127.0.0.1:4242"
            let isRemote = !rawGW.contains("127.0.0.1") && !rawGW.contains("localhost")

            // Local: use 127.0.0.1 (no token needed — gateway allows localhost without token)
            // Remote: use tunnel URL + single-use join token
            let gatewayWS = isRemote ? rawGW : "ws://127.0.0.1:4242"
            let token = isRemote ? (try? await appState.sync.requestToken(channelId: secured.id)) : nil

            // Build invite URL
            var items: [URLQueryItem] = [
                URLQueryItem(name: "gateway", value: gatewayWS),
                URLQueryItem(name: "id", value: secured.id),
                URLQueryItem(name: "name", value: secured.name),
            ]
            if let key = secured.encryptionKey {
                items.append(URLQueryItem(name: "key", value: key))
            }
            if let token {
                items.append(URLQueryItem(name: "token", value: token))
            }
            var components = URLComponents()
            components.scheme = "port42"
            components.host = "channel"
            components.queryItems = items
            let inviteURL = components.string ?? "port42://channel"

            await MainActor.run {
                let b = buildSnippet(name: name, inviteURL: inviteURL, triggerStr: triggerStr, t: .basic)
                let lc = buildSnippet(name: name, inviteURL: inviteURL, triggerStr: triggerStr, t: .langchain)
                snippets = [.basic: b, .langchain: lc]
                isGenerating = false
            }
        }
    }

    private func buildSnippet(name: String, inviteURL: String, triggerStr: String, t: SnippetTemplate) -> String {
        switch t {
        case .basic:
            return """
from port42 import Agent

agent = Agent("\(name)",
    invite="\(inviteURL)",
    trigger="\(triggerStr)")

@agent.on_mention
def handle(msg):
    return f"Hello {msg.sender}!"

agent.run()
"""
        case .langchain:
            return """
from port42 import Agent
from port42.langchain import Port42CallbackHandler
from langchain_anthropic import ChatAnthropic

agent = Agent("\(name)",
    invite="\(inviteURL)",
    trigger="\(triggerStr)")
handler = Port42CallbackHandler(agent)

chain = ChatAnthropic(model="claude-sonnet-4-6")

@agent.on_mention
def handle(msg):
    result = chain.invoke(msg.text, config={"callbacks": [handler]})
    return result.content

agent.run()
"""
        }
    }

    private func copySnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func copyInstall() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCmd, forType: .string)
        installCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { installCopied = false }
    }
}
