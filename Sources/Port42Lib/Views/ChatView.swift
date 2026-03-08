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
                typingNames: Array(appState.typingAgentNames.union(
                    appState.sync.remoteTypingNames[appState.currentChannel?.id ?? ""] ?? []
                )),
                mentionCandidates: appState.companions.map {
                    MentionSuggestion(id: $0.id, name: $0.displayName)
                },
                onSend: { content in appState.sendMessage(content: content) },
                onTypingChanged: { isTyping in
                    if let channelId = appState.currentChannel?.id,
                       let userName = appState.currentUser?.displayName {
                        appState.sync.sendTyping(channelId: channelId, senderName: userName, isTyping: isTyping)
                    }
                }
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
                isAgent: message.isAgent,
                senderOwner: message.senderOwner
            )
        }
    }
}

public struct ChannelHeader: View {
    public init() {}
    @EnvironmentObject var appState: AppState
    @State private var showMembers = false

    private var memberNames: [String] {
        guard let id = appState.currentChannel?.id else { return [] }
        return (try? appState.db.getUniqueSenders(channelId: id)) ?? []
    }

    public var body: some View {
        HStack {
            Text("#")
                .font(Port42Theme.mono(16))
                .foregroundStyle(Port42Theme.textSecondary)
            Text(appState.currentChannel?.name ?? "")
                .font(Port42Theme.monoBold(16))
                .foregroundStyle(Port42Theme.textPrimary)

            // Member avatars (click to see list)
            if !memberNames.isEmpty {
                HStack(spacing: -4) {
                    ForEach(memberNames.prefix(8), id: \.self) { name in
                        ZStack {
                            Circle()
                                .fill(Port42Theme.agentColor(for: name))
                                .frame(width: 20, height: 20)
                            Text(String(name.prefix(1)).uppercased())
                                .font(Port42Theme.monoBold(9))
                                .foregroundStyle(.white)
                        }
                        .overlay(
                            Circle()
                                .stroke(Port42Theme.bgPrimary, lineWidth: 1.5)
                        )
                    }
                    if memberNames.count > 8 {
                        ZStack {
                            Circle()
                                .fill(Port42Theme.bgSecondary)
                                .frame(width: 20, height: 20)
                            Text("+\(memberNames.count - 8)")
                                .font(Port42Theme.mono(8))
                                .foregroundStyle(Port42Theme.textSecondary)
                        }
                    }
                }
                .padding(.leading, 8)
                .onTapGesture { showMembers.toggle() }
                .popover(isPresented: $showMembers, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("members")
                            .font(Port42Theme.monoBold(11))
                            .foregroundStyle(Port42Theme.textSecondary)
                        ForEach(memberNames, id: \.self) { name in
                            HStack(spacing: 8) {
                                ZStack {
                                    Circle()
                                        .fill(Port42Theme.agentColor(for: name))
                                        .frame(width: 16, height: 16)
                                    Text(String(name.prefix(1)).uppercased())
                                        .font(Port42Theme.monoBold(8))
                                        .foregroundStyle(.white)
                                }
                                Text(name)
                                    .font(Port42Theme.mono(12))
                                    .foregroundStyle(Port42Theme.textPrimary)
                            }
                        }
                    }
                    .padding(12)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Port42Theme.bgPrimary)
    }
}
