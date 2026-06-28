import SwiftUI
import AppKit

/// A unified sidebar entry that wraps spaces and companions (+ friends) for sorted display.
private enum SidebarItem: Identifiable {
    case space(Space)
    case companion(AgentConfig)
    case friend(SpaceMember)

    var id: String {
        switch self {
        case .space(let c): return "ch-\(c.id)"
        case .companion(let c): return "comp-\(c.id)"
        case .friend(let f): return "fr-\(f.senderId)"
        }
    }

    /// Display name for this sidebar item
    var swimmerName: String? {
        switch self {
        case .space: return nil
        case .companion(let c): return c.displayName
        case .friend(let f): return f.name
        }
    }
}

public struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showNewSpace: Bool
    @Binding var showNewCompanion: Bool
    @State private var editingCompanion: AgentConfig?
    @State private var editingSpace: Space?
    @State private var spaceToDelete: Space?
    @State private var companionToDelete: AgentConfig?

    public init(showNewSpace: Binding<Bool>, showNewCompanion: Binding<Bool>) {
        self._showNewSpace = showNewSpace
        self._showNewCompanion = showNewCompanion
    }

    /// Build a sorted list of all sidebar items ordered by most recent activity.
    /// Uses cached lastActivityTimes — no DB reads during render.
    private var sortedItems: [SidebarItem] {
        var items: [(SidebarItem, Date)] = []

        for space in appState.spaces {
            // Direct (1:1 DM) spaces show as companion rows, never as space rows.
            if space.type == "dm" || space.type == "direct" { continue }
            let t = appState.lastActivityTimes[space.id] ?? space.createdAt
            items.append((.space(space), t))
        }

        for companion in appState.companions {
            let dmId = (try? appState.db.directSpaceId(companionId: companion.id)) ?? nil
            let t = dmId.flatMap { appState.lastActivityTimes[$0] } ?? companion.createdAt
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
            // New space/companion header
            HStack(spacing: 6) {
                Button(action: { showNewSpace = true }) {
                    Label("New Space", systemImage: "number")
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
                        case .space(let space):
                            spaceRow(space)
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
        .sheet(isPresented: Binding(get: { editingSpace != nil }, set: { if !$0 { editingSpace = nil } })) {
            EditSpaceSheet(space: $editingSpace)
                .environmentObject(appState)
        }
        .confirmationDialog(
            "Delete \(spaceToDelete?.name ?? "space")?",
            isPresented: Binding(get: { spaceToDelete != nil }, set: { if !$0 { spaceToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let ch = spaceToDelete { appState.deleteSpace(ch) }
                spaceToDelete = nil
            }
            Button("Cancel", role: .cancel) { spaceToDelete = nil }
        } message: {
            Text("This will permanently delete the space and all its messages.")
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
    private func spaceRow(_ space: Space) -> some View {
        let assignedIds = appState.spaceAgentIds[space.id] ?? []
        let companionNames = appState.companions
            .filter { assignedIds.contains($0.id) }
            .map { $0.displayName }
            .sorted()
        let senderCount = appState.spaceSenderCounts[space.id] ?? 0
        Button(action: { appState.selectSpace(space) }) {
            SpaceRow(
                space: space,
                isActive: appState.currentSpace?.id == space.id,
                unreadCount: appState.unreadCounts[space.id] ?? 0,
                companionNames: companionNames,
                onlineCount: max(1, senderCount)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            let assignedIds = appState.spaceAgentIds[space.id] ?? []
            let assigned = appState.companions
                .filter { assignedIds.contains($0.id) }
                .sorted { $0.displayName < $1.displayName }
            let unassigned = appState.companions.filter { !assignedIds.contains($0.id) }

            Menu("Add Companion") {
                if !unassigned.isEmpty {
                    Section("Local") {
                        ForEach(unassigned) { comp in
                            Button("@\(comp.displayName)") {
                                appState.addCompanionToSpace(comp, space: space)
                            }
                        }
                    }
                }

                Section("Remote") {
                    Button("Connect OpenClaw Agent...") {
                        appState.openClawSpace = space
                        appState.showOpenClawSheet = true
                    }
                    Button("Connect Python Agent...") {
                        appState.pythonAgentSpace = space
                        appState.showPythonAgentSheet = true
                    }
                    Button("Connect LLM CLI") {
                        let secured = appState.ensureEncryptionKey(for: space)
                        Task {
                            let hostName = appState.currentUser?.displayName ?? "Port42"
                            let prompt = """
You are invited to join \(hostName)'s Port42 space #\(secured.name). (Same machine required — uses local Port42 API)

This is an API-only connection: Port42 will NOT push messages to you and will NOT auto-send your replies — you poll for new messages and post explicitly. (For pushed messages + automatic replies, add a companion inside Port42 instead.)

── 1. See who's already here ──────────────────────────────────
curl -s http://127.0.0.1:4242/call \\
  -d '{"method":"space.current","args":{"space_id":"\(secured.id)"}}'
# → { id, name, type, memberCount, members: [{ id, name, type, owner, qualifiedName }] }

── 2. Choose your agent name ──────────────────────────────────
# A good default is your working folder's name. Just make sure it's DISTINCT — not
# "\(hostName)" (the host) and not any existing member above — or you'd impersonate someone
# and the loop would ignore that person's messages. Change it if it clashes.
NAME=$(basename "$PWD")   # just the current folder's name (last path segment); change if it collides

── 3. Send a message ──────────────────────────────────────────
curl -s http://127.0.0.1:4242/call \\
  -d "{\\\"method\\\":\\\"messages.send\\\",\\\"args\\\":{\\\"text\\\":\\\"hello\\\",\\\"senderName\\\":\\\"$NAME\\\",\\\"space_id\\\":\\\"\(secured.id)\\\"}}"

── 4. Read recent messages ────────────────────────────────────
curl -s http://127.0.0.1:4242/call \\
  -d '{"method":"messages.recent","args":{"count":10,"space_id":"\(secured.id)"}}'
# each message has: id, sender, content, timestamp, isCompanion

── 5. Stay resident (/loop) ───────────────────────────────────
# /loop is a built-in skill that reruns a task on an interval. (If your CLI
# doesn't have /loop, run the same poll-and-act steps yourself on a timer.)
/loop 1m Poll for new messages: curl -s http://127.0.0.1:4242/call -d '{"method":"messages.recent","args":{"count":10,"space_id":"\(secured.id)"}}'. Track the highest message id you have already handled and act ONLY on messages newer than that. Skip any message where sender is your own name ($NAME) or isCompanion is true — never reply to yourself or to other agents. Reply only when a human @mentions $NAME, using messages.send with senderName "$NAME" and space_id "\(secured.id)". Otherwise do nothing and wait.
"""
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                            appState.toastMessage = "LLM CLI prompt copied"
                        }
                    }
                    Button("Connect with Invitation Link") {
                        let secured = appState.ensureEncryptionKey(for: space)
                        Task {
                            let token = try? await appState.sync.requestToken(spaceId: secured.id)
                            SpaceInvite.copyToClipboard(space: secured, hostName: appState.currentUser?.displayName, syncGatewayURL: appState.sync.gatewayURL, token: token)
                            appState.toastMessage = appState.tunnel.publicURL != nil ? "Copied to clipboard" : "Copied to clipboard (local network only — start ngrok for remote sharing)"
                        }
                    }
                }
            }

            if !assigned.isEmpty {
                Menu("Remove Companion") {
                    ForEach(assigned) { comp in
                        Button("@\(comp.displayName)") {
                            appState.removeCompanionFromSpace(comp, space: space)
                        }
                    }
                }
            }

            Button("Edit Space") {
                editingSpace = space
            }

            Button("Copy Space ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(space.id, forType: .string)
                appState.toastMessage = "Space ID copied"
            }

            Button("Delete Space", role: .destructive) {
                spaceToDelete = space
            }
        }
    }

    @ViewBuilder
    private func companionRow(_ companion: AgentConfig) -> some View {
        // Sidebar shows the companion's "home" relationship depth — their direct-space (DM) fold.
        let dmId = (try? appState.db.directSpaceId(companionId: companion.id)) ?? nil
        let depth = dmId.flatMap { try? appState.db.fetchFold(companionId: companion.id, spaceId: $0) }?.depth
        let action: () -> Void = companion.openInTerminal
            ? {
                // Bring this companion's native terminal window to front (controllers are keyed
                // by panel id; match on companionName).
                let key = companion.displayName.lowercased()
                if let panelId = appState.terminalControllers.first(where: {
                    $0.value.config.companionName.lowercased() == key
                })?.key {
                    appState.portWindows.bringToFront(panelId)
                }
            }
            : { appState.startSwim(with: companion) }
        Button(action: action) {
            CompanionRow(
                companion: companion,
                isActive: appState.currentSpace?.type == "direct"
                    && appState.spaceCompanions.contains { $0.id == companion.id },
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
            let assignedSpaces = appState.spaces.filter { ch in
                appState.spaceAgentIds[ch.id]?.contains(companion.id) == true
            }
            if !assignedSpaces.isEmpty {
                Menu("Remove from Space") {
                    ForEach(assignedSpaces) { ch in
                        Button("#\(ch.name)") {
                            appState.removeCompanionFromSpace(companion, space: ch)
                        }
                    }
                }
            }
            Button("Delete Companion", role: .destructive) {
                companionToDelete = companion
            }
        }
    }

    @ViewBuilder
    private func friendRow(_ friend: SpaceMember) -> some View {
        let dmId = "dm-\(friend.senderId)"
        let isActive = appState.currentSpace?.id == dmId
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

public struct SpaceRow: View {
    let space: Space
    let isActive: Bool
    let unreadCount: Int
    let companionNames: [String]
    let onlineCount: Int

    @State private var isHovered = false

    public init(space: Space, isActive: Bool, unreadCount: Int, companionNames: [String] = [], onlineCount: Int = 0) {
        self.space = space
        self.isActive = isActive
        self.unreadCount = unreadCount
        self.companionNames = companionNames
        self.onlineCount = onlineCount
    }

    private var isEncrypted: Bool {
        space.encryptionKey != nil
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text("#")
                .font(Port42Theme.mono(14))
                .foregroundStyle(
                    isActive ? Port42Theme.accent : Port42Theme.textSecondary
                )

            Text(space.name)
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

