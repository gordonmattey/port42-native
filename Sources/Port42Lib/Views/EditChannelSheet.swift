import SwiftUI

public struct EditChannelSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var channel: Channel?

    @State private var channelName = ""
    @State private var heartbeatInterval = 0
    @State private var heartbeatPrompt = ""
    @FocusState private var nameFocused: Bool

    private let intervalOptions = [0, 1, 2, 5, 10, 15, 30, 60]

    public init(channel: Binding<Channel?>) {
        self._channel = channel
    }

    public var body: some View {
        guard let ch = channel else { return AnyView(EmptyView()) }
        return AnyView(content(ch))
    }

    @ViewBuilder
    private func content(_ ch: Channel) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit Channel")
                .font(Port42Theme.monoBold(16))
                .foregroundStyle(Port42Theme.textPrimary)

            // Name
            VStack(alignment: .leading, spacing: 6) {
                Text("name")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                HStack(spacing: 4) {
                    Text("#")
                        .font(Port42Theme.mono(14))
                        .foregroundStyle(Port42Theme.textSecondary)
                    TextField("channel-name", text: $channelName)
                        .textFieldStyle(.plain)
                        .font(Port42Theme.mono(14))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .focused($nameFocused)
                }
                .padding(10)
                .background(Port42Theme.bgInput)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(nameFocused ? Port42Theme.borderActive : Port42Theme.border, lineWidth: 1))
                .cornerRadius(6)
            }

            // Heartbeat
            VStack(alignment: .leading, spacing: 6) {
                Text("heartbeat")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)

                HStack(spacing: 8) {
                    Text("every")
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(Port42Theme.textSecondary)
                    Picker("", selection: $heartbeatInterval) {
                        Text("off").tag(0)
                        ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { mins in
                            Text("\(mins)m").tag(mins)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(Port42Theme.mono(13))
                    .tint(Port42Theme.accent)
                }

                if heartbeatInterval > 0 {
                    TextField("wake-up prompt", text: $heartbeatPrompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .lineLimit(3...5)
                        .padding(10)
                        .background(Port42Theme.bgInput)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Port42Theme.border, lineWidth: 1))
                        .cornerRadius(6)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") { channel = nil }
                    .buttonStyle(.plain)
                    .font(Port42Theme.mono(13))
                    .foregroundStyle(Port42Theme.textSecondary)

                Spacer()

                Button(action: save) {
                    Text("Save")
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(Port42Theme.bgPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(canSave ? Port42Theme.accent : Port42Theme.accent.opacity(0.3))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(Port42Theme.bgSecondary)
        .onAppear {
            channelName = ch.name
            heartbeatInterval = ch.heartbeatInterval
            heartbeatPrompt = ch.heartbeatPrompt
            nameFocused = true
        }
    }

    private var canSave: Bool {
        !channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard var ch = channel, canSave else { return }
        let cleanName = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: " ", with: "-")
        ch.name = cleanName
        ch.heartbeatInterval = heartbeatInterval
        ch.heartbeatPrompt = heartbeatInterval > 0 ? heartbeatPrompt : ""
        appState.updateChannel(ch)
        channel = nil
    }
}
