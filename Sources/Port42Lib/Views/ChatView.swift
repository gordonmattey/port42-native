import SwiftUI
import AppKit

public struct ChatView: View {
    public init() {}
    @EnvironmentObject var appState: AppState
    @State private var activePerm: PortPermission?

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Shared conversation content
                ConversationContent(
                    entries: spaceEntries,
                    placeholder: "chat with your reality... (press ? for help)",
                    error: appState.spaceErrors[appState.currentSpace?.id ?? ""],
                    typingNames: Array(appState.typingAgentNames.union(
                        appState.sync.remoteTypingNames[appState.currentSpace?.id ?? ""] ?? []
                    )),
                    toolingNames: Array(appState.toolingAgentNames),
                    mentionCandidates: buildMentionCandidates(),
                    localOwner: appState.currentUser?.displayName,
                    spaceId: appState.currentSpace?.id,
                    onSend: { content in appState.sendMessage(content: content) },
                    onStop: {
                        if let spaceId = appState.currentSpace?.id {
                            appState.cancelStreaming(spaceId: spaceId)
                        }
                    },
                    onRetry: {
                        if let spaceId = appState.currentSpace?.id {
                            AgentAuthResolver.shared.clearCache()
                            appState.retryLastMessage(spaceId: spaceId)
                        }
                    },
                    onDismissError: {
                        if let spaceId = appState.currentSpace?.id {
                            appState.spaceErrors[spaceId] = nil
                        }
                    },
                    onOpenSettings: {
                        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                    },
                    onTypingChanged: { isTyping in
                        if let spaceId = appState.currentSpace?.id,
                           let userName = appState.currentUser?.displayName {
                            appState.sync.sendTyping(spaceId: spaceId, senderName: userName, isTyping: isTyping)
                        }
                    }
                )
            }
            .overlay(alignment: .bottomTrailing) {
                Button(action: copyConversation) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Copy conversation")
                .padding(.trailing, 20)
                .padding(.bottom, 52)
            }

            // Inline permission overlay for inline ports
            if let perm = activePerm {
                PortPermissionOverlay(
                    permission: perm,
                    createdBy: appState.activePermissionBridge?.createdBy,
                    onAllow: {
                        appState.activePermissionBridge?.grantPermission()
                        appState.activePermissionBridge = nil
                    },
                    onDeny: {
                        appState.activePermissionBridge?.denyPermission()
                        appState.activePermissionBridge = nil
                    }
                )
            }
        }
        .background(Port42Theme.bgPrimary)
        .onReceive(appState.$activePermissionBridge) { bridge in
            activePerm = bridge?.pendingPermission
        }
    }

    private func copyConversation() {
        guard let spaceId = appState.currentSpace?.id else { return }
        let msgs = (try? appState.db.getMessages(spaceId: spaceId)) ?? []
        let text = msgs.map { "\($0.senderName): \($0.content)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appState.toastMessage = "Copied"
    }

    private var spaceEntries: [ChatEntry] {
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

    /// Build mention candidates from local companions + remote space members.
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

        // Remote members from space message history
        guard let spaceId = appState.currentSpace?.id else { return candidates }
        let members = (try? appState.db.getSpaceMembers(spaceId: spaceId)) ?? []

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
        let onlineIds = appState.sync.onlineUsers[spaceId] ?? []
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

/// Avatar circle for a space member. Teal dot for companions, green dot for humans.
struct MemberAvatar: View {
    let member: SpaceMember
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
