import SwiftUI
import AppKit

/// A unified sidebar entry that wraps channels and companions (+ friends) for sorted display.
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
    @Binding var showNewCompanion: Bool
    @State private var editingCompanion: AgentConfig?
    @State private var editingChannel: Channel?
    @State private var channelToDelete: Channel?
    @State private var companionToDelete: AgentConfig?

    public init(showNewChannel: Binding<Bool>, showNewCompanion: Binding<Bool>) {
        self._showNewChannel = showNewChannel
        self._showNewCompanion = showNewCompanion
    }

    /// Build a sorted list of all sidebar items ordered by most recent activity.
    /// Uses cached lastActivityTimes — no DB reads during render.
    private var sortedItems: [SidebarItem] {
        var items: [(SidebarItem, Date)] = []

        for channel in appState.channels {
            if channel.type == "dm" { continue }
            let t = appState.lastActivityTimes[channel.id] ?? channel.createdAt
            items.append((.channel(channel), t))
        }

        for companion in appState.companions {
            let swimId = "swim-\(companion.id)"
            let t = appState.lastActivityTimes[swimId] ?? companion.createdAt
            items.append((.companion(companion), t))
        }

        for friend in appState.friends {
            let dmId = "dm-\(friend.senderId)"
            let t = appState.lastActivityTimes[dmId] ?? Date.distantPast
            items.append((.friend(friend), t))
        }

        items.sort { $0.1 > $1.1 }
        return items.map { $0.0 }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // New channel/companion header
            HStack(spacing: 6) {
                Button(action: { showNewChannel = true }) {
                    Label("New Channel", systemImage: "number")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Port42Theme.bgHover.opacity(0.5))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                Button(action: { showNewCompanion = true }) {
                    Label("New Companion", systemImage: "person.crop.circle.badge.plus")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Port42Theme.bgHover.opacity(0.5))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // Conversation list sorted by last activity
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

                // Background ports
                let bgPorts = appState.portWindows.backgroundPanels
                if !bgPorts.isEmpty {
                    Divider()
                        .background(Port42Theme.border)
                        .padding(.horizontal, 12)

                    ForEach(bgPorts) { panel in
                        Button(action: { appState.portWindows.restore(panel.id) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Port42Theme.textSecondary)
                                Text(panel.title)
                                    .font(Port42Theme.mono(12))
                                    .foregroundStyle(Port42Theme.textSecondary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()
        }
        .background(Port42Theme.bgSidebar)
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
            editingCompanion = nil
        }
        .sheet(item: $editingCompanion) { companion in
            EditCompanionSheet(
                isPresented: Binding(
                    get: { editingCompanion != nil },
                    set: { if !$0 { editingCompanion = nil } }
                ),
                companion: companion
            )
            .environmentObject(appState)
        }
        .sheet(isPresented: Binding(get: { editingChannel != nil }, set: { if !$0 { editingChannel = nil } })) {
            EditChannelSheet(channel: $editingChannel)
                .environmentObject(appState)
        }
        .confirmationDialog(
            "Delete \(channelToDelete?.name ?? "channel")?",
            isPresented: Binding(get: { channelToDelete != nil }, set: { if !$0 { channelToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let ch = channelToDelete { appState.deleteChannel(ch) }
                channelToDelete = nil
            }
            Button("Cancel", role: .cancel) { channelToDelete = nil }
        } message: {
            Text("This will permanently delete the channel and all its messages.")
        }
        .confirmationDialog(
            "Delete \(companionToDelete?.displayName ?? "companion")?",
            isPresented: Binding(get: { companionToDelete != nil }, set: { if !$0 { companionToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let comp = companionToDelete { appState.deleteCompanion(comp) }
                companionToDelete = nil
            }
            Button("Cancel", role: .cancel) { companionToDelete = nil }
        } message: {
            Text("This will permanently delete the companion and all its relationship data.")
        }
    }

    @ViewBuilder
    private func channelRow(_ channel: Channel) -> some View {
        let companionNames = ((try? appState.db.getAgentsForChannel(channelId: channel.id)) ?? []).map { $0.displayName }
        let uniqueSenders = (try? appState.db.getUniqueSenders(channelId: channel.id)) ?? []
        Button(action: { appState.selectChannel(channel) }) {
            ChannelRow(
                channel: channel,
                isActive: appState.activeSwimCompanion == nil
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

            Menu("Add Companion") {
                if !unassigned.isEmpty {
                    Section("Local") {
                        ForEach(unassigned) { comp in
                            Button("@\(comp.displayName)") {
                                appState.addCompanionToChannel(comp, channel: channel)
                            }
                        }
                    }
                }

                Section("Remote") {
                    Button("Connect OpenClaw Agent...") {
                        appState.openClawChannel = channel
                        appState.showOpenClawSheet = true
                    }
                    Button("Connect Python Agent...") {
                        appState.pythonAgentChannel = channel
                        appState.showPythonAgentSheet = true
                    }
                    Button("Connect LLM CLI") {
                        let secured = appState.ensureEncryptionKey(for: channel)
                        if appState.tunnel.authToken.isEmpty {
                            appState.pendingInviteChannel = secured
                            appState.showNgrokSetup = true
                        } else {
                            Task {
                                let token = try? await appState.sync.requestToken(channelId: secured.id)
                                let hostName = appState.currentUser?.displayName ?? "Port42"
                                guard let inviteURL = ChannelInvite.generateInviteURL(channel: secured, hostName: hostName, syncGatewayURL: appState.sync.gatewayURL, token: token) else { return }
                                let owner = appState.currentUser?.displayName ?? "user"
                                let prompt = """
You are invited to join \(hostName)'s Port42 channel #\(secured.name).
Use the port42 CLI to send messages and interact with agents:

  port42 send "message" --invite "\(inviteURL)" --owner "\(owner)" --name "$(basename $PWD)"
  port42 ask "@agent question" --invite "\(inviteURL)" --owner "\(owner)" --name "$(basename $PWD)" --timeout 120

Install: pip install 'port42[cli]'
"""
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(prompt, forType: .string)
                                appState.toastMessage = "LLM CLI prompt copied"
                            }
                        }
                    }
                    Button("Connect with Invitation Link") {
                        let secured = appState.ensureEncryptionKey(for: channel)
                        if appState.tunnel.authToken.isEmpty {
                            appState.pendingInviteChannel = secured
                            appState.showNgrokSetup = true
                        } else {
                            Task {
                                let token = try? await appState.sync.requestToken(channelId: secured.id)
                                ChannelInvite.copyToClipboard(channel: secured, hostName: appState.currentUser?.displayName, syncGatewayURL: appState.sync.gatewayURL, token: token)
                                appState.toastMessage = "Copied to clipboard"
                            }
                        }
                    }
                }
            }

            if !assigned.isEmpty {
                Menu("Remove Companion") {
                    ForEach(assigned) { comp in
                        Button("@\(comp.displayName)") {
                            appState.removeCompanionFromChannel(comp, channel: channel)
                        }
                    }
                }
            }

            Button("Edit Channel") {
                editingChannel = channel
            }

            Button("Copy Channel ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(channel.id, forType: .string)
                appState.toastMessage = "Channel ID copied"
            }

            Button("Delete Channel", role: .destructive) {
                channelToDelete = channel
            }
        }
    }

    @ViewBuilder
    private func companionRow(_ companion: AgentConfig) -> some View {
        let swimId = "swim-\(companion.id)"
        let depth = (try? appState.db.fetchFold(companionId: companion.id, channelId: swimId))?.depth
        Button(action: { appState.startSwim(with: companion) }) {
            CompanionRow(
                companion: companion,
                isActive: appState.activeSwimCompanion?.id == companion.id,
                depth: depth
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit Companion") {
                editingCompanion = companion
            }
            Button("Copy Companion ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(companion.id, forType: .string)
                appState.toastMessage = "Companion ID copied"
            }
            Button("Delete Companion", role: .destructive) {
                companionToDelete = companion
            }
        }
    }

    @ViewBuilder
    private func friendRow(_ friend: ChannelMember) -> some View {
        let dmId = "dm-\(friend.senderId)"
        let isActive = appState.activeSwimCompanion == nil
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
    let depth: Int?

    @State private var isHovered = false

    public init(companion: AgentConfig, isActive: Bool, depth: Int? = nil) {
        self.name = companion.displayName
        self.isActive = isActive
        self.depth = depth
    }

    public init(name: String, isActive: Bool, depth: Int? = nil) {
        self.name = name
        self.isActive = isActive
        self.depth = depth
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

            if let d = depth, d > 0 {
                Circle()
                    .fill(Port42Theme.textSecondary)
                    .frame(width: 5, height: 5)
                    .opacity(min(Double(d) / 10.0, 1.0) * 0.6 + 0.2)
            }
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
                .lineLimit(1)
                .truncationMode(.tail)

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

