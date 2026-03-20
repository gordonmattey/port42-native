import SwiftUI

/// Inline guided setup view for Claude Code installation and authentication.
/// Embeddable in both SetupView (boot) and SignOutSheet (settings).
public struct ClaudeCodeSetupView: View {
    @ObservedObject var setup: ClaudeCodeSetup

    public init(setup: ClaudeCodeSetup) {
        self.setup = setup
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status / action area
            switch setup.state {
            case .idle:
                EmptyView()

            case .checking:
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Checking environment...")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                }

            case .noNode:
                Text("Node.js is required to install Claude Code.")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                actionButton("Install Node.js") {
                    setup.installNode()
                }

            case .claudeNotInstalled:
                Text("Installing Claude Code...")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .onAppear {
                        setup.installClaudeCode()
                    }

            case .claudeNeedsAuth:
                Text("Claude Code is installed. Sign in with your Claude subscription.")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                actionButton("Sign in to Claude") {
                    setup.authenticate()
                }

            case .multipleTokens(let entries):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(">")
                            .font(Port42Theme.monoBold(14))
                            .foregroundStyle(Port42Theme.accent)
                        Text("Multiple Claude accounts detected")
                            .font(Port42Theme.monoBold(12))
                            .foregroundStyle(Port42Theme.textPrimary)
                    }

                    Text("Select which account to use:")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)

                    Spacer().frame(height: 4)

                    ForEach(entries) { entry in
                        tokenEntryButton(entry)
                    }
                }
                .padding(12)
                .background(Port42Theme.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Port42Theme.accent.opacity(0.3), lineWidth: 1)
                )

            case .running(let status):
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(status)
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                }

            case .failed(let message):
                HStack(spacing: 6) {
                    Text("!")
                        .font(Port42Theme.monoBold(13))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(.red.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }

                actionButton("Retry") {
                    setup.diagnose()
                }

            case .success:
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("Connected via Claude Code")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(.green)
                }
            }

            // Output area (shown when there is output to display)
            if !setup.output.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(setup.output)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("output-end")
                    }
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(Port42Theme.bgPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .onChange(of: setup.output) { _, _ in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("output-end", anchor: .bottom)
                        }
                    }
                }

                // Cancel button when a process is running
                if case .running = setup.state {
                    Button(action: { setup.cancel() }) {
                        Text("cancel")
                            .font(Port42Theme.mono(11))
                            .foregroundStyle(Port42Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func tokenEntryButton(_ entry: ClaudeKeychainEntry) -> some View {
        Button(action: { setup.selectKeychainEntry(entry) }) {
            HStack(spacing: 8) {
                Text("\u{25B8}")
                    .font(Port42Theme.monoBold(12))
                    .foregroundStyle(Port42Theme.accent)

                Text(entry.label)
                    .font(Port42Theme.monoBold(12))
                    .foregroundStyle(Port42Theme.textPrimary)

                if let exp = entry.expiresAt {
                    Text(expiryLabel(exp))
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(exp > Date() ? Port42Theme.textSecondary.opacity(0.6) : .orange.opacity(0.8))
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Port42Theme.accent.opacity(0.08))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Port42Theme.accent.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func expiryLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, HH:mm"
        let dateStr = fmt.string(from: date)
        return date > Date() ? "expires \(dateStr)" : "expired \(dateStr)"
    }

    private func actionButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Port42Theme.monoBold(12))
                .foregroundStyle(Port42Theme.bgPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Port42Theme.accent)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }
}
