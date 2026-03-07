import SwiftUI

public struct ChatView: View {
    public init() {}
    @EnvironmentObject var appState: AppState

    public var body: some View {
        VStack(spacing: 0) {
            // Channel header
            ChannelHeader()

            Divider()
                .background(Port42Theme.border)

            // Shared conversation content
            ConversationContent(
                entries: channelEntries,
                placeholder: "Message #\(appState.currentChannel?.name ?? "")...",
                onSend: { content in appState.sendMessage(content: content) }
            )
        }
        .background(Port42Theme.bgPrimary)
    }

    private var channelEntries: [ChatEntry] {
        appState.messages.map { message in
            ChatEntry(
                id: message.id,
                senderName: message.senderName,
                content: message.content,
                timestamp: message.timestamp,
                isSystem: message.isSystem,
                isAgent: message.isAgent
            )
        }
    }
}

public struct ChannelHeader: View {
    public init() {}
    @EnvironmentObject var appState: AppState

    public var body: some View {
        HStack {
            Text("#")
                .font(Port42Theme.mono(16))
                .foregroundStyle(Port42Theme.textSecondary)
            Text(appState.currentChannel?.name ?? "")
                .font(Port42Theme.monoBold(16))
                .foregroundStyle(Port42Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Port42Theme.bgPrimary)
    }
}
