import SwiftUI
import AppKit

/// A unified sidebar entry that wraps channels and swimmers (companions + friends) for sorted display.
private enum SidebarItem: Identifiable {
    case channel(Channel)
    case companion(AgentConfig)
    case friend(ChannelMember)

    var id: String {
        switch self {
        case .channel(let c): return "ch-\(c.id)"
        case .companion(let c): return "comp-\(c.id)"
        case .friend(let f): return "fr-\(f.senderId)"
        }
    }

    /// Display name for this sidebar item
    var swimmerName: String? {
        switch self {
        case .channel: return nil
        case .companion(let c): return c.displayName
        case .friend(let f): return f.name
        }
    }
}

public struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showNewChannel: Bool
    @State private var showNewCompanion = false
    @State private var showSignOut = false

    public init(showNewChannel: Binding<Bool>) {
        self._showNewChannel = showNewChannel
    }

    /// Build a sorted list of all sidebar items ordered by most recent activity.
    private var sortedItems: [SidebarItem] {
        var items: [(SidebarItem, Date)] = []

        for channel in appState.channels {
            // Skip DM channels from the channel list (they show as friend rows)
            if channel.type == "dm" { continue }
            let lastMsg = (try? appState.db.getLastMessageTime(channelId: channel.id)) ?? channel.createdAt
            items.append((.channel(channel), lastMsg))
        }

        for companion in appState.companions {
            let lastSwim = (try? appState.db.getLastSwimTime(companionId: companion.id)) ?? companion.createdAt
            items.append((.companion(companion), lastSwim))
        }

        for friend in appState.friends {
            // Check if a DM channel exists for activity time
            let dmId = "dm-\(friend.senderId)"
            let lastDM = (try? appState.db.getLastMessageTime(channelId: dmId)) ?? Date.distantPast
            // Also check when they last appeared in any channel
            items.append((.friend(friend), lastDM))
        }

        items.sort { $0.1 > $1.1 }
        return items.map { $0.0 }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 4) {
                    Text("PORT42")
                        .font(Port42Theme.monoBold(14))
                        .foregroundStyle(Port42Theme.accent)
                    if appState.sync.isConnected {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                    }
                    if appState.tunnel.publicURL != nil {
                        Image(systemName: "globe")
                            .font(.system(size: 8))
                            .foregroundStyle(Port42Theme.accent)
                    }
                }
                .help(appState.tunnel.publicURL ?? appState.sync.gatewayURL ?? "no gateway")
                Spacer()
                Menu {
                    Button(action: { showNewChannel = true }) {
                        Label("New Channel", systemImage: "number")
                    }
                    Button(action: { showNewCompanion = true }) {
                        Label("New Swimmer", systemImage: "person.crop.circle.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            Divider()
                .background(Port42Theme.border)

            // Unified conversation list sorted by last activity
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(sortedItems) { item in
                        switch item {
                        case .channel(let channel):
                            channelRow(channel)
                        case .companion(let companion):
                            companionRow(companion)
                        case .friend(let friend):
                            friendRow(friend)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Spacer()

            // User info
            if let user = appState.currentUser {
                Divider()
                    .background(Port42Theme.border)
                HStack(spacing: 8) {
                    Circle()
                        .fill(Port42Theme.accent)
                        .frame(width: 8, height: 8)
                    Text(user.displayName)
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textPrimary)
                    Spacer()
                    Button(action: { showSignOut = true }) {
                        Text("surface")
                            .font(Port42Theme.mono(10))
                            .foregroundStyle(Port42Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Port42Theme.bgSidebar)
        .sheet(isPresented: $showSignOut) {
            SignOutSheet(isPresented: $showSignOut)
        }
        .sheet(isPresented: $showNewCompanion) {
            NewCompanionSheet(isPresented: $showNewCompanion)
        }
    }

    @ViewBuilder
    private func channelRow(_ channel: Channel) -> some View {
        let companionNames = ((try? appState.db.getAgentsForChannel(channelId: channel.id)) ?? []).map { $0.displayName }
        let uniqueSenders = (try? appState.db.getUniqueSenders(channelId: channel.id)) ?? []
        Button(action: { appState.selectChannel(channel) }) {
            ChannelRow(
                channel: channel,
                isActive: appState.activeSwimSession == nil
                    && appState.currentChannel?.id == channel.id,
                unreadCount: appState.unreadCounts[channel.id] ?? 0,
                companionNames: companionNames,
                onlineCount: max(1, uniqueSenders.count)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            let assigned = (try? appState.db.getAgentsForChannel(channelId: channel.id)) ?? []
            let assignedIds = Set(assigned.map { $0.id })
            let unassigned = appState.companions.filter { !assignedIds.contains($0.id) }

            if !unassigned.isEmpty {
                Menu("Add Swimmer") {
                    ForEach(unassigned) { comp in
                        Button("@\(comp.displayName)") {
                            appState.addCompanionToChannel(comp, channel: channel)
                        }
                    }
                }
            }
            if !assigned.isEmpty {
                Menu("Remove Swimmer") {
                    ForEach(assigned) { comp in
                        Button("@\(comp.displayName)") {
                            appState.removeCompanionFromChannel(comp, channel: channel)
                        }
                    }
                }
            }

            Divider()

            Button("Copy Invitation") {
                let secured = appState.ensureEncryptionKey(for: channel)
                if appState.tunnel.authToken.isEmpty {
                    appState.pendingInviteChannel = secured
                    appState.showNgrokSetup = true
                } else {
                    Task {
                        let token = try? await appState.sync.requestToken(channelId: secured.id)
                        ChannelInvite.copyToClipboard(channel: secured, hostName: appState.currentUser?.displayName, syncGatewayURL: appState.sync.gatewayURL, token: token)
                    }
                }
            }

            Button("Delete Channel", role: .destructive) {
                appState.deleteChannel(channel)
            }
        }
    }

    @ViewBuilder
    private func companionRow(_ companion: AgentConfig) -> some View {
        Button(action: { appState.startSwim(with: companion) }) {
            CompanionRow(
                companion: companion,
                isActive: appState.activeSwimSession?.companion.id == companion.id
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Swimmer", role: .destructive) {
                appState.deleteCompanion(companion)
            }
        }
    }

    @ViewBuilder
    private func friendRow(_ friend: ChannelMember) -> some View {
        let dmId = "dm-\(friend.senderId)"
        let isActive = appState.activeSwimSession == nil
            && appState.currentChannel?.id == dmId
        let displayName = friend.displayName(localOwner: appState.currentUser?.displayName)
        Button(action: { appState.startDM(with: friend) }) {
            CompanionRow(
                name: displayName,
                isActive: isActive
            )
        }
        .buttonStyle(.plain)
    }
}

public struct CompanionRow: View {
    let name: String
    let isActive: Bool

    @State private var isHovered = false

    public init(companion: AgentConfig, isActive: Bool) {
        self.name = companion.displayName
        self.isActive = isActive
    }

    public init(name: String, isActive: Bool) {
        self.name = name
        self.isActive = isActive
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Port42Theme.textAgent)
                .frame(width: 8, height: 8)

            Text(name)
                .font(Port42Theme.mono(13))
                .foregroundStyle(
                    isActive ? Port42Theme.textAgent : Port42Theme.textSecondary
                )

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            isActive ? Port42Theme.textAgent.opacity(0.1)
            : isHovered ? Port42Theme.bgHover
            : Color.clear
        )
        .cornerRadius(4)
        .padding(.horizontal, 8)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

public struct ChannelRow: View {
    let channel: Channel
    let isActive: Bool
    let unreadCount: Int
    let companionNames: [String]
    let onlineCount: Int

    @State private var isHovered = false

    public init(channel: Channel, isActive: Bool, unreadCount: Int, companionNames: [String] = [], onlineCount: Int = 0) {
        self.channel = channel
        self.isActive = isActive
        self.unreadCount = unreadCount
        self.companionNames = companionNames
        self.onlineCount = onlineCount
    }

    private var isEncrypted: Bool {
        channel.encryptionKey != nil
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text("#")
                .font(Port42Theme.mono(14))
                .foregroundStyle(
                    isActive ? Port42Theme.accent : Port42Theme.textSecondary
                )

            Text(channel.name)
                .font(Port42Theme.mono(13))
                .foregroundStyle(
                    isActive ? Port42Theme.accent
                    : unreadCount > 0 ? Port42Theme.textPrimary
                    : Port42Theme.textSecondary
                )
                .fontWeight(unreadCount > 0 ? .bold : .regular)

            if isEncrypted {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(
                        isActive ? Port42Theme.accent : Port42Theme.textSecondary
                    )
            }

            // Companion dots
            if !companionNames.isEmpty {
                HStack(spacing: -3) {
                    ForEach(companionNames.prefix(3), id: \.self) { name in
                        Circle()
                            .fill(Port42Theme.agentColor(for: name))
                            .frame(width: 6, height: 6)
                    }
                }
            }

            Spacer()

            // Online count
            if onlineCount > 0 {
                HStack(spacing: 3) {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                    Text("\(onlineCount)")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textPrimary)
                }
            }

            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.bgPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Port42Theme.accent)
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            isActive ? Port42Theme.accent.opacity(0.1)
            : isHovered ? Port42Theme.bgHover
            : Color.clear
        )
        .cornerRadius(4)
        .padding(.horizontal, 8)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

