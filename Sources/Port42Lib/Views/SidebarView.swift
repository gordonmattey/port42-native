import SwiftUI
import AppKit

public struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showNewChannel: Bool
    @State private var showNewCompanion = false
    @State private var showSignOut = false

    public init(showNewChannel: Binding<Bool>) {
        self._showNewChannel = showNewChannel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("PORT42")
                    .font(Port42Theme.monoBold(14))
                    .foregroundStyle(Port42Theme.accent)
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
            .padding(.vertical, 12)

            Divider()
                .background(Port42Theme.border)

            // Unified conversation list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(appState.channels) { channel in
                        Button(action: { appState.selectChannel(channel) }) {
                            ChannelRow(
                                channel: channel,
                                isActive: appState.activeSwimSession == nil
                                    && appState.currentChannel?.id == channel.id,
                                unreadCount: appState.unreadCounts[channel.id] ?? 0
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete Channel", role: .destructive) {
                                appState.deleteChannel(channel)
                            }
                        }
                    }

                    ForEach(appState.companions) { companion in
                        Button(action: { appState.startSwim(with: companion) }) {
                            CompanionRow(
                                companion: companion,
                                isActive: appState.activeSwimSession?.companion.id == companion.id
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if companion.mode == .llm {
                                Button("Copy Invite Link") {
                                    let link = AgentInvite.generateLink(from: companion)
                                    if !link.isEmpty {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(link, forType: .string)
                                    }
                                }
                            }
                            Button("Delete Swimmer", role: .destructive) {
                                appState.deleteCompanion(companion)
                            }
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
                .padding(.vertical, 10)
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

}

public struct CompanionRow: View {
    let companion: AgentConfig
    let isActive: Bool

    @State private var isHovered = false

    public init(companion: AgentConfig, isActive: Bool) {
        self.companion = companion
        self.isActive = isActive
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Port42Theme.textAgent)
                .frame(width: 8, height: 8)

            Text(companion.displayName)
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

    @State private var isHovered = false

    public init(channel: Channel, isActive: Bool, unreadCount: Int) {
        self.channel = channel
        self.isActive = isActive
        self.unreadCount = unreadCount
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

            Spacer()

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
