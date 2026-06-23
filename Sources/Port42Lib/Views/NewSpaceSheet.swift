import SwiftUI

public struct NewSpaceSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var spaceName = ""
    @State private var heartbeatInterval = 0
    @State private var heartbeatPrompt = ""
    @FocusState private var isFocused: Bool

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 20) {
            Text("New Space")
                .font(Port42Theme.monoBold(16))
                .foregroundStyle(Port42Theme.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text("#")
                        .font(Port42Theme.mono(14))
                        .foregroundStyle(Port42Theme.textSecondary)

                    TextField("space-name", text: $spaceName)
                        .textFieldStyle(.plain)
                        .font(Port42Theme.mono(14))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .focused($isFocused)
                        .onSubmit {
                            create()
                        }
                }
                .padding(10)
                .background(Port42Theme.bgInput)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isFocused ? Port42Theme.borderActive : Port42Theme.border,
                            lineWidth: 1
                        )
                )
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
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(Port42Theme.mono(13))
                .foregroundStyle(Port42Theme.textSecondary)

                Button(action: create) {
                    Text("Create")
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(Port42Theme.bgPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            canCreate ? Port42Theme.accent : Port42Theme.accent.opacity(0.3)
                        )
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Port42Theme.bgSecondary)
        .onAppear {
            isFocused = true
        }
    }

    private var canCreate: Bool {
        !spaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        guard canCreate else { return }
        appState.createSpace(name: spaceName, heartbeatInterval: heartbeatInterval, heartbeatPrompt: heartbeatPrompt)
        isPresented = false
    }
}
