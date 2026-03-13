import SwiftUI
import AppKit

public struct NgrokSetupSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var token = ""
    @FocusState private var isFocused: Bool

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("\u{25C7}")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(Port42Theme.accent)

                Text("invite others")
                    .font(Port42Theme.monoBold(14))
                    .foregroundStyle(Port42Theme.textPrimary)
            }
            .padding(.top, 28)
            .padding(.bottom, 12)

            Divider().background(Port42Theme.border)

            VStack(alignment: .leading, spacing: 12) {
                Text("to invite others to your channels, Port42 uses ngrok to create a secure tunnel to your local gateway.")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("paste your ngrok auth token below.")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                SecureField("ngrok auth token", text: $token)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Port42Theme.bgPrimary)
                    .cornerRadius(5)
                    .focused($isFocused)
                    .onSubmit { save() }

                HStack(spacing: 4) {
                    Text("get one free at")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
                    Text("ngrok.com")
                        .font(Port42Theme.monoBold(10))
                        .foregroundStyle(Port42Theme.accent)
                        .onTapGesture {
                            if let url = URL(string: "https://dashboard.ngrok.com/get-started/your-authtoken") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Spacer()

            VStack(spacing: 10) {
                Button(action: save) {
                    Text("save and connect")
                        .font(Port42Theme.monoBold(13))
                        .foregroundStyle(Port42Theme.bgPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Port42Theme.accent.opacity(0.3)
                            : Port42Theme.accent)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 340, height: 380)
        .background(Port42Theme.bgSecondary)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    private func save() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.tunnel.setAuthToken(trimmed)
        let port = GatewayProcess.shared.port
        appState.tunnel.start(port: port)
        Analytics.shared.ngrokConfigured()

        // Copy the pending invite link now that tunnel is configured
        if let channel = appState.pendingInviteChannel {
            Task {
                let token = try? await appState.sync.requestToken(channelId: channel.id)
                ChannelInvite.copyToClipboard(channel: channel, hostName: appState.currentUser?.displayName, syncGatewayURL: appState.sync.gatewayURL, token: token)
            }
            appState.pendingInviteChannel = nil
        }

        isPresented = false
    }
}
