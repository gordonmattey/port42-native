import SwiftUI

public struct ContentView: View {
    public init() {}
    @EnvironmentObject var appState: AppState
    @State private var showNewChannel = false
    @State private var showQuickSwitcher = false
    @State private var showHelp = false
    @State private var dockWidth: CGFloat = 380
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
                HStack(spacing: 0) {
                    ChatView()
                        .id(channel.id)
                    if let docked = appState.portWindows.dockedPanel {
                        DockDivider(dockWidth: $dockWidth)
                        DockedPortView(panel: docked, manager: appState.portWindows)
                            .frame(width: dockWidth)
                    }
                }
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
                        ("@name", "mention a swimmer so only they respond"),
                        ("Tab", "accept @mention autocomplete"),
                    ])

                    helpSection("ports", items: [
                        ("\"build me a...\"", "ask any companion to create a live port"),
                        ("Source / Run", "toggle between port code and live view"),
                    ])

                    helpSection("context menus", items: [
                        ("right-click channel", "add swimmers, copy invite link"),
                        ("right-click swimmer", "edit or delete"),
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

// MARK: - Dock Divider

struct DockDivider: View {
    @Binding var dockWidth: CGFloat
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Port42Theme.accent.opacity(0.5) : Port42Theme.border)
            .frame(width: isDragging ? 3 : 1)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        dockWidth = max(200, min(600, dockWidth - value.translation.width))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

// MARK: - Docked Port View

struct DockedPortView: View {
    let panel: PortPanel
    @ObservedObject var manager: PortWindowManager
    @EnvironmentObject var appState: AppState
    @State private var showCode = false

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(Port42Theme.accent)
                Text(panel.title)
                    .font(Port42Theme.mono(11))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .lineLimit(1)
                Spacer()

                Button(action: { showCode.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: showCode ? "play.fill" : "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 10))
                        Text(showCode ? "Run" : "Source")
                            .font(Port42Theme.mono(10))
                    }
                    .foregroundStyle(Port42Theme.accent)
                }
                .buttonStyle(.plain)
                .help(showCode ? "Run port" : "View source")

                Button(action: {
                    var t = Transaction(animation: nil)
                    t.disablesAnimations = true
                    withTransaction(t) { manager.undock(panel.id) }
                }) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Float")

                Button(action: { manager.close(panel.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Port42Theme.bgSecondary)

            if showCode {
                ScrollView(.vertical) {
                    Text(panel.html)
                        .font(Port42Theme.mono(12))
                        .foregroundColor(Port42Theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let webView = manager.webViews[panel.id] {
                PortWebViewHost(webView: webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Port42Theme.bgPrimary)
        .onChange(of: panel.bridge.pendingPermission) { _, perm in
            if perm != nil {
                appState.activePermissionBridge = panel.bridge
            }
        }
    }
}
