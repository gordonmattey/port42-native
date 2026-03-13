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
                mentionCandidates: buildMentionCandidates(),
                localOwner: appState.currentUser?.displayName,
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
        .confirmationDialog(
            appState.activePermissionBridge?.pendingPermission?.permissionDescription.title ?? "Permission",
            isPresented: Binding(
                get: { appState.activePermissionBridge?.pendingPermission != nil },
                set: { if !$0 { appState.activePermissionBridge?.denyPermission(); appState.activePermissionBridge = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Allow") {
                appState.activePermissionBridge?.grantPermission()
                appState.activePermissionBridge = nil
            }
            Button("Deny", role: .cancel) {
                appState.activePermissionBridge?.denyPermission()
                appState.activePermissionBridge = nil
            }
        } message: {
            Text(appState.activePermissionBridge?.pendingPermission?.permissionDescription.message ?? "")
        }
    }

    private var channelEntries: [ChatEntry] {
        let currentUserId = appState.currentUser?.id
        return appState.messages.compactMap { message in
            // Hide empty placeholders (agent is still typing)
            if message.isAgent && message.content.isEmpty { return nil }
            return ChatEntry(
                id: message.id,
                senderName: message.senderName,
                content: message.content,
                timestamp: message.timestamp,
                isSystem: message.isSystem,
                isAgent: message.isAgent,
                senderOwner: message.senderOwner,
                syncStatus: message.syncStatus,
                isOwnMessage: message.senderId == currentUserId
            )
        }
    }

    /// Build mention candidates from local companions + remote channel members.
    /// Local entities show bare names, remote entities show namespaced names.
    private func buildMentionCandidates() -> [MentionSuggestion] {
        var seenIds = Set<String>()
        var seenNames = Set<String>()
        var candidates: [MentionSuggestion] = []

        let localUserId = appState.currentUser?.id
        let localOwner = appState.currentUser?.displayName

        // Local companions first (bare name, no namespace needed for your own agents)
        for companion in appState.companions {
            seenIds.insert(companion.id)
            let key = companion.displayName.lowercased()
            if seenNames.insert(key).inserted {
                candidates.append(MentionSuggestion(id: companion.id, name: companion.displayName, isAgent: true))
            }
        }

        // Remote members from channel message history
        guard let channelId = appState.currentChannel?.id else { return candidates }
        let members = (try? appState.db.getChannelMembers(channelId: channelId)) ?? []

        for member in members {
            if member.senderId == localUserId { continue }
            if seenIds.contains(member.senderId) { continue }
            seenIds.insert(member.senderId)
            let name = member.displayName(localOwner: localOwner)
            let key = name.lowercased()
            if seenNames.insert(key).inserted {
                candidates.append(MentionSuggestion(id: member.senderId, name: name, isAgent: member.isAgent))
            }
        }

        // Online users from presence who haven't messaged yet
        let onlineIds = appState.sync.onlineUsers[channelId] ?? []
        for userId in onlineIds {
            if userId == localUserId { continue }
            if seenIds.contains(userId) { continue }
            if let name = appState.sync.knownNames[userId] {
                let key = name.lowercased()
                if seenNames.insert(key).inserted {
                    candidates.append(MentionSuggestion(id: userId, name: name, isAgent: false))
                }
            }
        }

        return candidates
    }
}

public struct ChannelHeader: View {
    public init() {}
    @EnvironmentObject var appState: AppState
    @State private var showMembers = false

    private var members: [ChannelMember] {
        guard let id = appState.currentChannel?.id else { return [] }
        var result = (try? appState.db.getChannelMembers(channelId: id)) ?? []

        // Always include the current user even if they haven't messaged yet
        if let user = appState.currentUser,
           !result.contains(where: { $0.senderId == user.id }) {
            result.insert(ChannelMember(senderId: user.id, name: user.displayName, type: "human", owner: user.displayName), at: 0)
        }

        // Include local companions assigned to this channel
        let channelAgents = (try? appState.db.getAgentsForChannel(channelId: id)) ?? []
        for agent in channelAgents {
            if !result.contains(where: { $0.senderId == agent.id }) {
                result.append(ChannelMember(senderId: agent.id, name: agent.displayName, type: "agent", owner: appState.currentUser?.displayName))
            }
        }

        // Include online users from presence who haven't messaged yet (e.g. just-connected OpenClaw agents)
        let onlineIds = appState.sync.onlineUsers[id] ?? []
        for userId in onlineIds {
            if result.contains(where: { $0.senderId == userId }) { continue }
            if userId == appState.currentUser?.id { continue }
            if let name = appState.sync.knownNames[userId] {
                result.append(ChannelMember(senderId: userId, name: name, type: "agent", owner: nil))
            }
        }

        return result
    }

    private var onlineIds: Set<String> {
        guard let id = appState.currentChannel?.id else { return [] }
        var ids = appState.sync.onlineUsers[id] ?? []
        // Current user is always online
        if let userId = appState.currentUser?.id { ids.insert(userId) }
        // Local companions are always online
        for companion in appState.companions { ids.insert(companion.id) }
        return ids
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
            if !members.isEmpty {
                HStack(spacing: -4) {
                    ForEach(Array(members.prefix(8))) { member in
                        MemberAvatar(member: member, size: 20, isOnline: onlineIds.contains(member.senderId))
                    }
                    if members.count > 8 {
                        ZStack {
                            Circle()
                                .fill(Port42Theme.bgSecondary)
                                .frame(width: 20, height: 20)
                            Text("+\(members.count - 8)")
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
                        ForEach(members) { member in
                            HStack(spacing: 8) {
                                MemberAvatar(member: member, size: 16, isOnline: onlineIds.contains(member.senderId))
                                Text(member.displayName(localOwner: appState.currentUser?.displayName))
                                    .font(Port42Theme.mono(12))
                                    .foregroundStyle(Port42Theme.textPrimary)
                            }
                        }
                    }
                    .padding(12)
                }
            }

            Spacer()

            Button(action: copyConversation) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(Port42Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Copy conversation")
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .background(Port42Theme.bgPrimary)
    }

    private func copyConversation() {
        guard let channelId = appState.currentChannel?.id else { return }
        let messages = (try? appState.db.getMessages(channelId: channelId)) ?? []
        let lines: [String] = messages.map { msg in
            "\(msg.senderName): \(msg.content)"
        }
        let text: String = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: NSPasteboard.PasteboardType.string)
    }
}

/// Avatar circle for a channel member. Teal dot for companions, green dot for humans.
struct MemberAvatar: View {
    let member: ChannelMember
    let size: CGFloat
    var isOnline: Bool = false

    var body: some View {
        let color = Port42Theme.agentColor(for: member.name, owner: member.owner)
        ZStack {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
            Text(String(member.name.prefix(1)).uppercased())
                .font(Port42Theme.monoBold(size * 0.45))
                .foregroundStyle(.white)
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(member.isAgent ? Port42Theme.textAgent : Port42Theme.accent)
                .frame(width: size * 0.3, height: size * 0.3)
                .overlay(Circle().stroke(Port42Theme.bgPrimary, lineWidth: 1))
        }
    }
}
