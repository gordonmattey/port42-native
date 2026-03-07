import SwiftUI

// MARK: - Unified chat renderer for both channels and swims

/// A single message entry that both channel Messages and SwimMessages can map to.
public struct ChatEntry: Identifiable {
    public let id: String
    public let senderName: String
    public let content: String
    public let timestamp: Date?
    public let isSystem: Bool
    public let isAgent: Bool
    public let isPlaceholder: Bool

    public init(
        id: String, senderName: String, content: String, timestamp: Date? = nil,
        isSystem: Bool = false, isAgent: Bool = false, isPlaceholder: Bool = false
    ) {
        self.id = id
        self.senderName = senderName
        self.content = content
        self.timestamp = timestamp
        self.isSystem = isSystem
        self.isAgent = isAgent
        self.isPlaceholder = isPlaceholder
    }

    public var formattedTime: String? {
        guard let timestamp else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: timestamp)
    }
}

// MARK: - Conversation Content View

public struct ConversationContent: View {
    let entries: [ChatEntry]
    let placeholder: String
    let isStreaming: Bool
    let error: String?
    let onSend: (String) -> Void
    let onStop: (() -> Void)?
    let onRetry: (() -> Void)?
    let onDismissError: (() -> Void)?

    @State private var draft = ""
    @FocusState private var isInputFocused: Bool

    public init(
        entries: [ChatEntry],
        placeholder: String,
        isStreaming: Bool = false,
        error: String? = nil,
        onSend: @escaping (String) -> Void,
        onStop: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil,
        onDismissError: (() -> Void)? = nil
    ) {
        self.entries = entries
        self.placeholder = placeholder
        self.isStreaming = isStreaming
        self.error = error
        self.onSend = onSend
        self.onStop = onStop
        self.onRetry = onRetry
        self.onDismissError = onDismissError
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    allMessagesText
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: entries.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: entries.last?.content) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .background(Color.black.opacity(0.5))

            if let error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                        .font(Port42Theme.monoFontSmall)
                        .lineLimit(2)
                    Spacer()
                    if let onRetry {
                        Button("Retry") { onRetry() }
                            .font(Port42Theme.monoFontSmall)
                            .foregroundStyle(Port42Theme.accent)
                            .buttonStyle(.plain)
                    }
                    if let onDismissError {
                        Button("Dismiss") { onDismissError() }
                            .font(Port42Theme.monoFontSmall)
                            .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(.red)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.1))
            }

            Divider().background(Port42Theme.border)

            // Input bar
            HStack(spacing: 12) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(Port42Theme.mono(13))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .focused($isInputFocused)
                    .onSubmit {
                        send()
                        isInputFocused = true
                    }
                    .disabled(isStreaming)
                    .onChange(of: isStreaming) { _, streaming in
                        if !streaming {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isInputFocused = true
                            }
                        }
                    }

                if isStreaming {
                    if let onStop {
                        Button(action: onStop) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Port42Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isInputFocused ? Port42Theme.accent.opacity(0.6) : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .shadow(
                color: isInputFocused ? Port42Theme.accent.opacity(0.3) : .clear,
                radius: 8
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .animation(.easeInOut(duration: 0.3), value: isInputFocused)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isInputFocused = true
                }
            }
        }
    }

    private var allMessagesText: Text {
        var result = Text("")
        for (i, entry) in entries.enumerated() {
            if i > 0 {
                result = result + Text("\n\n")
            }

            if entry.isSystem {
                result = result + Text(entry.content)
                    .font(Port42Theme.mono(12))
                    .foregroundColor(Port42Theme.textSecondary)
            } else {
                let nameColor: Color = entry.isAgent ? Port42Theme.textAgent : Port42Theme.textPrimary
                let contentColor: Color = entry.isAgent ? Port42Theme.textAgent : Port42Theme.textPrimary

                result = result + Text(entry.senderName)
                    .font(Port42Theme.monoBold(13))
                    .foregroundColor(nameColor)

                if let time = entry.formattedTime {
                    result = result
                        + Text("  ")
                        + Text(time)
                            .font(Port42Theme.mono(11))
                            .foregroundColor(Port42Theme.textSecondary)
                }

                if entry.isPlaceholder {
                    result = result + Text("\n") + Text("...")
                        .font(Port42Theme.mono(13))
                        .foregroundColor(Port42Theme.textAgent.opacity(0.5))
                } else {
                    result = result + Text("\n") + Text(entry.content)
                        .font(Port42Theme.mono(13))
                        .foregroundColor(contentColor)
                }
            }
        }
        return result
    }

    private func send() {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        onSend(content)
        draft = ""
        isInputFocused = true
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}
