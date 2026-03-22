import SwiftUI

// MARK: - Swim View

public struct SwimView: View {
    @EnvironmentObject var appState: AppState
    let companion: AgentConfig
    let channelId: String
    let userName: String
    let onExit: () -> Void

    @State private var showInspector = false
    @State private var activePerm: PortPermission?

    public init(companion: AgentConfig, channelId: String, userName: String = "You", onExit: @escaping () -> Void) {
        self.companion = companion
        self.channelId = channelId
        self.userName = userName
        self.onExit = onExit
    }

    private var chatEntries: [ChatEntry] {
        let currentUserId = appState.currentUser?.id
        return appState.messages.compactMap { msg in
            if msg.isAgent && msg.content.isEmpty { return nil }
            return ChatEntry(
                id: msg.id,
                senderName: msg.senderName,
                content: msg.content,
                timestamp: msg.timestamp,
                isSystem: msg.isSystem,
                isAgent: msg.isAgent,
                senderOwner: msg.senderOwner,
                syncStatus: msg.syncStatus,
                isOwnMessage: msg.senderId == currentUserId
            )
        }
    }

    private var isStreaming: Bool {
        appState.typingAgentNames.contains(companion.displayName)
    }

    private var isTooling: Bool {
        appState.toolingAgentNames.contains(companion.displayName)
    }

    public var body: some View {
        ZStack {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onExit) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Port42Theme.accent)

                Circle()
                    .fill(Port42Theme.textAgent)
                    .frame(width: 8, height: 8)

                Text(companion.displayName)
                    .font(Port42Theme.monoBold(14))
                    .foregroundStyle(Port42Theme.textAgent)

                Text("🏊")
                    .font(.system(size: 12))

                Spacer()

                Button(action: { showInspector = true }) {
                    Image(systemName: "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Inspect \(companion.displayName)'s inner state")
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(Port42Theme.bgPrimary)
            .sheet(isPresented: $showInspector) {
                CreaseInspectorSheet(companion: companion, channelId: channelId)
                    .environmentObject(appState)
            }

            Divider().background(Port42Theme.border)

            ConversationContent(
                entries: chatEntries,
                placeholder: "Message \(companion.displayName)...",
                isStreaming: isStreaming,
                error: appState.channelErrors[channelId],
                typingNames: isStreaming ? [companion.displayName] : [],
                toolingNames: isTooling ? [companion.displayName] : [],
                bridgeNames: appState.activeBridgeNames[channelId] ?? [:],
                channelId: channelId,
                onSend: { content in appState.sendMessage(content: content) },
                onStop: { appState.cancelStreaming(channelId: channelId) },
                onRetry: {
                    AgentAuthResolver.shared.clearCache()
                    appState.retryLastMessage(channelId: channelId)
                },
                onDismissError: { appState.channelErrors[channelId] = nil },
                onOpenSettings: {
                    NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                }
            )
        }
        .background(Port42Theme.bgPrimary)

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
        } // ZStack
        .onReceive(appState.$activePermissionBridge) { bridge in
            activePerm = bridge?.pendingPermission
        }
    }
}
