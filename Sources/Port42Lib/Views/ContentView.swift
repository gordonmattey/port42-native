import SwiftUI

public struct ContentView: View {
    public init() {}
    @EnvironmentObject var appState: AppState
    @State private var showNewChannel = false
    @State private var showQuickSwitcher = false

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
        .onReceive(NotificationCenter.default.publisher(for: .quickSwitcherRequested)) { _ in
            showQuickSwitcher.toggle()
        }
    }
}
