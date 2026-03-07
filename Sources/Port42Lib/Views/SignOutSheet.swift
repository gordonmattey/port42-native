import SwiftUI

public struct SignOutSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var eraseAll = false
    @State private var isHovering = false
    @State private var gatewayURL: String = UserDefaults.standard.string(forKey: "gatewayURL") ?? ""

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

            // Gateway
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.sync.isConnected ? .green : Port42Theme.textSecondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                    Text("gateway")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                    Spacer()
                    if GatewayProcess.shared.isRunning {
                        Text("self-hosted")
                            .font(Port42Theme.mono(9))
                            .foregroundStyle(Port42Theme.accent.opacity(0.6))
                    }
                }

                HStack(spacing: 6) {
                    TextField("ws://localhost:8042", text: $gatewayURL)
                        .textFieldStyle(.plain)
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .padding(6)
                        .background(Port42Theme.bgPrimary)
                        .cornerRadius(4)
                        .onSubmit { connectGateway() }

                    Button(action: connectGateway) {
                        Text(appState.sync.isConnected ? "ok" : "go")
                            .font(Port42Theme.mono(10))
                            .foregroundStyle(appState.sync.isConnected ? .green : Port42Theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                Text("leave empty for self-hosted gateway")
                    .font(Port42Theme.mono(9))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)

            Divider().background(Port42Theme.border)

            // Erase toggle
            Toggle(isOn: $eraseAll.animation(.easeInOut(duration: 0.2))) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("erase everything")
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(eraseAll ? .red : Port42Theme.textSecondary)

                    Text("all data gone, start fresh")
                        .font(Port42Theme.mono(9))
                        .foregroundStyle(
                            eraseAll
                                ? .red.opacity(0.6)
                                : Port42Theme.textSecondary.opacity(0.5)
                        )
                }
            }
            .toggleStyle(.switch)
            .tint(.red)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            Spacer()

            // Actions
            VStack(spacing: 10) {
                Button(action: doSurface) {
                    Text(eraseAll ? "erase and surface" : "surface")
                        .font(Port42Theme.monoBold(13))
                        .foregroundStyle(eraseAll ? .white : Port42Theme.bgPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(eraseAll ? Color.red : Port42Theme.accent)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .scaleEffect(isHovering ? 1.02 : 1.0)
                .onHover { isHovering = $0 }

                Button("stay") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 320, height: 460)
        .background(Port42Theme.bgSecondary)
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textSecondary)
            Spacer()
            Text(value)
                .font(Port42Theme.monoBold(11))
                .foregroundStyle(Port42Theme.textPrimary)
        }
    }

    private func connectGateway() {
        let trimmed = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: "gatewayURL")
        if trimmed.isEmpty {
            appState.sync.disconnect()
        } else if let user = appState.currentUser {
            appState.sync.configure(gatewayURL: trimmed, userId: user.id, db: appState.db)
            appState.sync.connect()
            for channel in appState.channels {
                appState.sync.joinChannel(channel.id)
            }
        }
    }

    private func doSurface() {
        let shouldErase = eraseAll
        isPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if shouldErase {
                appState.resetApp()
            } else {
                appState.lockApp()
            }
        }
    }
}
