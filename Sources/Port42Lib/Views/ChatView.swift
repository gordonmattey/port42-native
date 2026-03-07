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
                placeholder: "chat with your reality... (press ? for help)",
                typingNames: Array(appState.typingAgentNames),
                mentionCandidates: appState.companions.map {
                    MentionSuggestion(id: $0.id, name: $0.displayName)
                },
                onSend: { content in appState.sendMessage(content: content) }
            )
        }
        .background(Port42Theme.bgPrimary)
    }

    private var channelEntries: [ChatEntry] {
        appState.messages.compactMap { message in
            // Hide empty placeholders (agent is still typing)
            if message.isAgent && message.content.isEmpty { return nil }
            return ChatEntry(
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

    private var onlineCount: Int {
        guard let id = appState.currentChannel?.id else { return 0 }
        return appState.sync.onlineUsers[id]?.count ?? 0
    }

    public var body: some View {
        HStack {
            Text("#")
                .font(Port42Theme.mono(16))
                .foregroundStyle(Port42Theme.textSecondary)
            Text(appState.currentChannel?.name ?? "")
                .font(Port42Theme.monoBold(16))
                .foregroundStyle(Port42Theme.textPrimary)

            if onlineCount > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("\(onlineCount) online")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                .padding(.leading, 8)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Port42Theme.bgPrimary)
    }
}
