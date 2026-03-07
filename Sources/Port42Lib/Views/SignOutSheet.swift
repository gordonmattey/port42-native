import SwiftUI
import AppKit

public struct SignOutSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var eraseAll = false
    @State private var isHovering = false
    @State private var ngrokToken: String = UserDefaults.standard.string(forKey: "ngrokAuthToken") ?? ""
    @State private var ngrokDomain: String = UserDefaults.standard.string(forKey: "ngrokDomain") ?? ""
    @State private var editingToken = false

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
        .frame(width: 340, height: 580)
        .background(Port42Theme.bgSecondary)
    }

    @ViewBuilder
    private var sharingSection: some View {
        if let publicURL = appState.tunnel.publicURL {
            // Tunnel is live
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("sharing enabled")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textPrimary)
                Spacer()
            }

            HStack(spacing: 6) {
                Text(publicURL.replacingOccurrences(of: "wss://", with: ""))
                    .font(Port42Theme.mono(9))
                    .foregroundStyle(Port42Theme.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(publicURL, forType: .string)
                }) {
                    Text("copy")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Port42Theme.accent.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Button(action: toggleTunnel) {
                    Text("stop")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        } else if appState.tunnel.isRunning {
            // Starting up
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text(appState.tunnel.status)
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary)
            }
        } else {
            // Not sharing yet
            HStack(spacing: 6) {
                Circle()
                    .fill(Port42Theme.textSecondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text("sharing")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                Spacer()
                Text("local only")
                    .font(Port42Theme.mono(9))
                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
            }

            if !ngrokToken.isEmpty && !editingToken {
                // One-tap share button with edit option
                Button(action: toggleTunnel) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.system(size: 11))
                        Text("share over internet")
                            .font(Port42Theme.monoBold(11))
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
                            .font(Port42Theme.mono(10))
                    }
                    .foregroundStyle(Port42Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Port42Theme.textSecondary.opacity(0.08))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            } else {
                // Token setup or editing
                if ngrokToken.isEmpty {
                    Text("to share channels with others over the internet, add a free ngrok token")
                        .font(Port42Theme.mono(9))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }

                SecureField("paste ngrok token here", text: $ngrokToken)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Port42Theme.bgPrimary)
                    .cornerRadius(4)
                    .onChange(of: ngrokToken) { _, newValue in
                        appState.tunnel.setAuthToken(newValue)
                    }

                HStack(spacing: 4) {
                    Text("get one free at")
                        .font(Port42Theme.mono(9))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                    Text("ngrok.com")
                        .font(Port42Theme.monoBold(9))
                        .foregroundStyle(Port42Theme.accent.opacity(0.7))
                        .onTapGesture {
                            if let url = URL(string: "https://dashboard.ngrok.com/get-started/your-authtoken") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    Spacer()
                    if editingToken {
                        Button(action: { editingToken = false }) {
                            Text("done")
                                .font(Port42Theme.monoBold(9))
                                .foregroundStyle(Port42Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !appState.tunnel.status.isEmpty && appState.tunnel.status != "needs auth token" {
                    Text(appState.tunnel.status)
                        .font(Port42Theme.mono(9))
                        .foregroundStyle(.red.opacity(0.7))
                }
            }
        }
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

    private func toggleTunnel() {
        if appState.tunnel.isRunning {
            appState.tunnel.stop()
        } else {
            let port = GatewayProcess.shared.port
            appState.tunnel.start(port: port)
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
