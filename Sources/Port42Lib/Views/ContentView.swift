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
                if let docked = appState.portWindows.dockedPanel {
                    HSplitView {
                        ChatView()
                            .id(channel.id)
                        DockedPortView(panel: docked, manager: appState.portWindows)
                            .frame(minWidth: 200)
                    }
                } else {
                    ChatView()
                        .id(channel.id)
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
        .overlay {
            FloatingPortOverlay(manager: appState.portWindows)
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

// MARK: - Floating Port Overlay

struct FloatingPortOverlay: View {
    @ObservedObject var manager: PortWindowManager

    var body: some View {
        ZStack {
            ForEach(manager.floatingPanels) { panel in
                FloatingPortPanel(panel: panel, manager: manager)
            }
        }
        .allowsHitTesting(!manager.floatingPanels.isEmpty)
    }
}

struct FloatingPortPanel: View {
    let panel: PortPanel
    @ObservedObject var manager: PortWindowManager
    @State private var dragOffset: CGSize = .zero
    @State private var height: CGFloat = 300

    var body: some View {
        panelContent
            .frame(width: panel.size.width, height: panel.size.height)
            .background(Port42Theme.bgPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(panelBorder)
            .shadow(color: .black.opacity(0.5), radius: 12)
            .position(panelPosition)
            .onTapGesture { manager.bringToFront(panel.id) }
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            titleBar
            PortView(html: panel.html, bridge: panel.bridge, height: $height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(Port42Theme.accent)
            Text(panel.title)
                .font(Port42Theme.mono(11))
                .foregroundStyle(Port42Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            dockButton
            closeButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Port42Theme.bgSecondary)
        .gesture(dragGesture)
    }

    private var dockButton: some View {
        Button(action: { manager.dock(panel.id) }) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 10))
                .foregroundStyle(Port42Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Dock right")
    }

    private var closeButton: some View {
        Button(action: { manager.close(panel.id) }) {
            Image(systemName: "xmark")
                .font(.system(size: 10))
                .foregroundStyle(Port42Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Close")
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Port42Theme.border, lineWidth: 1)
    }

    private var panelPosition: CGPoint {
        CGPoint(
            x: panel.position.x + panel.size.width / 2 + dragOffset.width,
            y: panel.position.y + panel.size.height / 2 + dragOffset.height
        )
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let newPos = CGPoint(
                    x: panel.position.x + value.translation.width,
                    y: panel.position.y + value.translation.height
                )
                manager.move(panel.id, to: newPos)
                dragOffset = .zero
            }
    }
}

// MARK: - Docked Port View

struct DockedPortView: View {
    let panel: PortPanel
    @ObservedObject var manager: PortWindowManager
    @State private var height: CGFloat = 400

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

                Button(action: { manager.undock(panel.id) }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Port42Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Undock")

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

            PortView(html: panel.html, bridge: panel.bridge, height: $height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Port42Theme.bgPrimary)
    }
}
