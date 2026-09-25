import SwiftUI

/// Inline guided setup view for installing a CLI agent (Node, then Claude Code).
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
                Text(setup.target == "codex" ? "Node.js is required to install Codex." : "Node.js is required to install Claude Code.")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                actionButton("Install Node.js") {
                    setup.installNode()
                }

            case .claudeNotInstalled:
                Text(setup.target == "codex" ? "Installing Codex..." : "Installing Claude Code...")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .onAppear {
                        setup.installTarget()
                    }

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
                            .font(Port42Theme.mono(10))
                            .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("output-end")
                    }
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
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



    private func actionButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Port42Theme.monoBold(12))
                .foregroundStyle(Port42Theme.bgPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Port42Theme.accent)
                .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }
}
