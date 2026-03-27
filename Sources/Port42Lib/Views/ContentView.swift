import SwiftUI
import AppKit

public struct ContentView: View {
    public init() {}
    @EnvironmentObject var appState: AppState
    @State private var showNewChannel = false
    @State private var showNewCompanion = false
    @State private var showQuickSwitcher = false
    @State private var showHelp = false
    @State private var showSignOut = false
    @State private var showUsage = false

    public var body: some View {
        HSplitView {
            // Left pane: PORT42 header + sidebar
            VStack(spacing: 0) {
                SidebarHeader()
                Divider().background(Port42Theme.border)
                SidebarView(
                    showNewChannel: $showNewChannel,
                    showNewCompanion: $showNewCompanion
                )
            }
            .ignoresSafeArea(edges: .top)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

            // Right pane: channel header + chat
            VStack(spacing: 0) {
                ChatHeader(
                    showSignOut: $showSignOut,
                    showUsage: $showUsage
                )
                Divider().background(Port42Theme.border)

                Group {
                    if let companion = appState.activeSwimCompanion,
                       let channel = appState.currentChannel, channel.isSwim {
                        SwimView(
                            companion: companion,
                            channelId: channel.id,
                            userName: appState.currentUser?.displayName ?? "You",
                            onExit: { appState.exitSwim() }
                        )
                        .environmentObject(appState)
                        .id(companion.id)
                    } else if let channel = appState.currentChannel {
                        ChatView()
                            .id(channel.id)
                    } else {
                        VStack {
                            Text("Select a channel")
                                .font(Port42Theme.mono(14))
                                .foregroundStyle(Port42Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Port42Theme.bgPrimary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea(edges: .top)
        }
        .sheet(isPresented: $showNewChannel) {
            NewChannelSheet(isPresented: $showNewChannel)
        }
        .sheet(isPresented: $showNewCompanion) {
            NewCompanionSheet(isPresented: $showNewCompanion)
        }
        .sheet(isPresented: $showUsage) {
            UsageSheet(isPresented: $showUsage)
        }
        .sheet(isPresented: $showSignOut) {
            SignOutSheet(isPresented: $showSignOut)
        }
        .sheet(isPresented: $appState.showNgrokSetup) {
            NgrokSetupSheet(isPresented: $appState.showNgrokSetup)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showOpenClawSheet) {
            if let channel = appState.openClawChannel {
                OpenClawSheet(isPresented: $appState.showOpenClawSheet, channel: channel)
                    .environmentObject(appState)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChannelRequested)) { _ in
            showNewChannel = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
            showSignOut = false
            showNewCompanion = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { _ in
            showSignOut = true
        }
        .overlay {
            if showQuickSwitcher {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { showQuickSwitcher = false }

                    VStack {
                        QuickSwitcher(isPresented: $showQuickSwitcher)
                            .padding(.top, 80)
                        Spacer()
                    }
                }
            }
        }
        .overlay {
            if showHelp {
                HelpOverlay(isPresented: $showHelp)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickSwitcherRequested)) { _ in
            showQuickSwitcher.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .helpRequested)) { _ in
            showHelp.toggle()
        }
        .overlay(alignment: .bottom) {
            if let message = appState.toastMessage {
                Text(message)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.bgPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Port42Theme.accent)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 8)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                appState.toastMessage = nil
                            }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.toastMessage)
        .overlay {
            if let executor = appState.activeToolExecutor, let perm = executor.pendingPermission {
                PortPermissionOverlay(
                    permission: perm,
                    createdBy: executor.createdBy,
                    onAllow: { executor.grantPermission() },
                    onDeny: { executor.denyPermission() }
                )
            }
        }
    }
}

// MARK: - Sidebar Header (PORT42 branding, top of left pane)

struct SidebarHeader: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            Text("PORT42")
                .font(Port42Theme.monoBold(13))
                .foregroundStyle(Port42Theme.accent)
            if appState.sync.isConnected {
                Circle()
                    .fill(.green)
                    .frame(width: 5, height: 5)
            }
            if appState.tunnel.publicURL != nil {
                Image(systemName: "globe")
                    .font(.system(size: 8))
                    .foregroundStyle(Port42Theme.accent)
            }
            Spacer()
        }
        .help(appState.tunnel.publicURL ?? appState.sync.gatewayURL ?? "no gateway")
        .padding(.leading, 68) // space for traffic light buttons
        .padding(.trailing, 12)
        .frame(height: 38)
        .background(Port42Theme.bgSidebar)
    }
}

// MARK: - Chat Header (channel name + members + user controls, top of right pane)

struct ChatHeader: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSignOut: Bool
    @Binding var showUsage: Bool
    @State private var showMembers = false

    private var authDotColor: Color {
        switch appState.authStatus {
        case .connected: return .green
        case .checking, .unknown: return Port42Theme.accent
        case .noCredential: return .orange
        case .error: return .red
        }
    }

    private var members: [ChannelMember] {
        guard let id = appState.currentChannel?.id else { return [] }
        var result = (try? appState.db.getChannelMembers(channelId: id)) ?? []
        if let user = appState.currentUser,
           !result.contains(where: { $0.senderId == user.id }) {
            result.insert(ChannelMember(senderId: user.id, name: user.displayName, type: "human", owner: user.displayName), at: 0)
        }
        let channelAgents = (try? appState.db.getAgentsForChannel(channelId: id)) ?? []
        for agent in channelAgents {
            if !result.contains(where: { $0.senderId == agent.id }) {
                result.append(ChannelMember(senderId: agent.id, name: agent.displayName, type: "agent", owner: appState.currentUser?.displayName))
            }
        }
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
        if let userId = appState.currentUser?.id { ids.insert(userId) }
        for companion in appState.companions { ids.insert(companion.id) }
        return ids
    }

    var body: some View {
        HStack(spacing: 8) {
            if let companion = appState.activeSwimCompanion {
                Circle()
                    .fill(Port42Theme.textAgent)
                    .frame(width: 8, height: 8)
                Text(companion.displayName)
                    .font(Port42Theme.monoBold(13))
                    .foregroundStyle(Port42Theme.textAgent)
            } else if let channel = appState.currentChannel {
                Text("#")
                    .font(Port42Theme.mono(13))
                    .foregroundStyle(Port42Theme.textSecondary)
                Text(channel.name)
                    .font(Port42Theme.monoBold(13))
                    .foregroundStyle(Port42Theme.textPrimary)

                if !members.isEmpty {
                    HStack(spacing: -4) {
                        ForEach(Array(members.prefix(6))) { member in
                            MemberAvatar(member: member, size: 18, isOnline: onlineIds.contains(member.senderId))
                        }
                        if members.count > 6 {
                            ZStack {
                                Circle()
                                    .fill(Port42Theme.bgSecondary)
                                    .frame(width: 18, height: 18)
                                Text("+\(members.count - 6)")
                                    .font(Port42Theme.mono(7))
                                    .foregroundStyle(Port42Theme.textSecondary)
                            }
                        }
                    }
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
            }

            Spacer()

            if let user = appState.currentUser {
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(authDotColor)
                            .frame(width: 7, height: 7)
                        Text(user.displayName)
                            .font(Port42Theme.mono(12))
                            .foregroundStyle(Port42Theme.textPrimary)
                    }

                    Button(action: {
                        appState.aiPaused.toggle()
                        LLMEngine.paused = appState.aiPaused
                    }) {
                        Image(systemName: appState.aiPaused ? "pause.circle.fill" : "pause.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(appState.aiPaused ? .red : Port42Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(appState.aiPaused ? "AI paused. Click to resume." : "Pause all AI calls")

                    Button(action: { showUsage = true }) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 13))
                            .foregroundStyle(Port42Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Token usage")

                    Button(action: { showSignOut = true }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13))
                            .foregroundStyle(Port42Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
        .background(Port42Theme.bgPrimary)
    }
}

// MARK: - Help Overlay

struct HelpOverlay: View {
    @Binding var isPresented: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                HStack {
                    Text("PORT42")
                        .font(Port42Theme.monoBold(14))
                        .foregroundStyle(Port42Theme.accent)
                    Spacer()
                    Text("esc")
                        .font(Port42Theme.mono(10))
                        .foregroundStyle(Port42Theme.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Port42Theme.bgHover)
                        .cornerRadius(3)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider().background(Port42Theme.border)

                VStack(alignment: .leading, spacing: 16) {
                    helpSection("shortcuts", items: [
                        ("Cmd+K", "quick switcher / paste invite link"),
                        ("Cmd+N", "new channel"),
                        ("Cmd+/", "this help"),
                    ])

                    helpSection("chat", items: [
                        ("@name", "mention a companion so only they respond"),
                        ("Tab", "accept @mention autocomplete"),
                    ])

                    helpSection("ports", items: [
                        ("\"build me a...\"", "ask any companion to create a live port"),
                        ("Source / Run", "toggle between port code and live view"),
                    ])

                    helpSection("context menus", items: [
                        ("right-click channel", "add companions, copy invite link"),
                        ("right-click companion", "edit or delete"),
                    ])
                }
                .padding(20)

                Divider().background(Port42Theme.border)

                HStack(spacing: 8) {
                    Text("where humans and AI swim together")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                    Spacer()
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"))")
                        .font(Port42Theme.mono(9))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.5))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Port42Theme.bgSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Port42Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.5), radius: 20)
            .frame(width: 380)
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(.escape) {
                isPresented = false
                return .handled
            }
        }
        .onAppear { isFocused = true }
    }

    private func helpSection(_ title: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Port42Theme.monoBold(12))
                .foregroundStyle(Port42Theme.accent)

            ForEach(items, id: \.0) { key, desc in
                HStack(alignment: .top, spacing: 0) {
                    Text(key)
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textPrimary)
                    Text("  ")
                    Text(desc)
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
            }
        }
    }
}

