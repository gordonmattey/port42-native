import SwiftUI

public struct ContentView: View {
    public init() {}
    @EnvironmentObject var appState: AppState
    @State private var showNewChannel = false
    @State private var showQuickSwitcher = false
    @State private var showHelp = false

    public var body: some View {
        NavigationSplitView {
            SidebarView(showNewChannel: $showNewChannel)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            if let session = appState.activeSwimSession {
                SwimView(
                    session: session,
                    userName: appState.currentUser?.displayName ?? "You",
                    onExit: { appState.exitSwim() }
                )
                .id(session.companion.id)
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
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showNewChannel) {
            NewChannelSheet(isPresented: $showNewChannel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChannelRequested)) { _ in
            showNewChannel = true
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
    }
}

// MARK: - Help Overlay

struct HelpOverlay: View {
    @Binding var isPresented: Bool

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

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        helpSection("shortcuts", items: [
                            ("Cmd+K", "quick switcher / paste invite link"),
                            ("Cmd+N", "new channel"),
                            ("?", "this help"),
                        ])

                        helpSection("chat", items: [
                            ("@name", "mention a companion (only they respond)"),
                            ("message", "everyone in the channel can respond"),
                        ])

                        helpSection("companions", items: [
                            ("right-click channel", "add or remove companions"),
                            ("click companion", "start a direct swim"),
                        ])

                        helpSection("sync", items: [
                            ("right-click channel", "copy invite link"),
                            ("Cmd+K + paste link", "join a channel from another instance"),
                        ])
                    }
                    .padding(20)
                }

                Divider().background(Port42Theme.border)

                Text("a chat app where humans and AI companions coexist")
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .padding(.vertical, 10)
            }
            .background(Port42Theme.bgSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Port42Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.5), radius: 20)
            .frame(width: 380)
            .onKeyPress(.escape) {
                isPresented = false
                return .handled
            }
        }
    }

    private func helpSection(_ title: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Port42Theme.monoBold(12))
                .foregroundStyle(Port42Theme.accent)

            ForEach(items, id: \.0) { key, desc in
                HStack(alignment: .top, spacing: 12) {
                    Text(key)
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .frame(width: 120, alignment: .trailing)
                    Text(desc)
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textSecondary)
                    Spacer()
                }
            }
        }
    }
}
