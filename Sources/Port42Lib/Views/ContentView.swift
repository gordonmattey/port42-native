import SwiftUI
import AppKit

public struct ContentView: View {
    public init() {}
    @EnvironmentObject var appState: AppState
    @State private var showNewSpace = false
    @State private var showNewCompanion = false
    @State private var showQuickSwitcher = false
    @State private var showHelp = false

    public var body: some View {
        // Sidebar only — chat lives in the floating chat port
        VStack(spacing: 0) {
            SidebarHeader()
            Divider().background(Port42Theme.border)
            SidebarView(
                showNewSpace: $showNewSpace,
                showNewCompanion: $showNewCompanion
            )
        }
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 180, maxWidth: .infinity)
        .background(Port42Theme.bgSidebar)
        .sheet(isPresented: $showNewSpace) {
            NewSpaceSheet(isPresented: $showNewSpace)
        }
        .sheet(isPresented: $showNewCompanion) {
            NewCompanionSheet(isPresented: $showNewCompanion)
        }
        .sheet(isPresented: $appState.showNgrokSetup) {
            NgrokSetupSheet(isPresented: $appState.showNgrokSetup)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showOpenClawSheet) {
            if let space = appState.openClawSpace {
                OpenClawSheet(isPresented: $appState.showOpenClawSheet, space: space)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showPythonAgentSheet) {
            if let space = appState.pythonAgentSpace {
                PythonAgentSheet(isPresented: $appState.showPythonAgentSheet, space: space)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showAgentConnectSheet) {
            if let space = appState.agentConnectSpace {
                AgentConnectSheet(
                    isPresented: $appState.showAgentConnectSheet,
                    space: space,
                    inviteURL: appState.agentConnectInviteURL
                )
                .environmentObject(appState)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newSpaceRequested)) { _ in
            showNewSpace = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
            showNewCompanion = false
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

// MARK: - AppKit tooltip overlay
//
// .help() doesn't fire in hiddenTitleBar windows. TooltipHost is placed as an
// overlay (not background) so it is the topmost NSView under the cursor —
// that's what AppKit needs to trigger the tooltip tracking area. hitTest
// returns nil so clicks fall through to the underlying buttons.

private class PassthroughTooltipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct TooltipHost: NSViewRepresentable {
    let tooltip: String
    func makeNSView(context: Context) -> PassthroughTooltipView {
        let v = PassthroughTooltipView()
        v.toolTip = tooltip
        return v
    }
    func updateNSView(_ nsView: PassthroughTooltipView, context: Context) {
        nsView.toolTip = tooltip
    }
}

private extension View {
    func appKitTooltip(_ text: String) -> some View {
        self.overlay(TooltipHost(tooltip: text))
    }
}

// MARK: - Sidebar Header

struct SidebarHeader: View {
    @EnvironmentObject var appState: AppState
    @State private var showSignOut = false
    @State private var showUsage = false

    private var authDotColor: Color {
        switch appState.authStatus {
        case .connected: return .green
        case .checking, .unknown: return Port42Theme.accent
        case .noCredential: return .orange
        case .error: return .red
        }
    }

    private var gatewayTooltip: String {
        appState.sync.isConnected
            ? "Gateway connected — \(appState.sync.gatewayURL ?? "local")"
            : "Gateway disconnected"
    }

    private var authTooltip: String {
        switch appState.authStatus {
        case .connected(let type, _):
            return "Anthropic \(TokenDetector.humanLabel(type)) active"
        case .checking, .unknown: return "Checking credentials…"
        case .noCredential: return "No Anthropic key — open Settings"
        case .error(let msg): return "Anthropic auth error: \(msg)"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            if let user = appState.currentUser {
                HStack(spacing: 8) {
                    Text(user.displayName)
                        .font(Port42Theme.mono(12))
                        .foregroundStyle(Port42Theme.textPrimary)

                    // Gateway status
                    Image(systemName: appState.sync.isConnected ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(appState.sync.isConnected ? .green : Port42Theme.textSecondary)
                        .appKitTooltip(gatewayTooltip)

                    // Tunnel status (only when active)
                    if let url = appState.tunnel.publicURL {
                        Image(systemName: "globe")
                            .font(.system(size: 10))
                            .foregroundStyle(Port42Theme.accent)
                            .appKitTooltip("Tunnel active — \(url)")
                    }

                    // API key status
                    Image(systemName: "key.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(authDotColor)
                        .appKitTooltip(authTooltip)

                    Button(action: {
                        appState.aiPaused.toggle()
                        LLMEngine.paused = appState.aiPaused
                    }) {
                        Image(systemName: appState.aiPaused ? "pause.circle.fill" : "pause.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(appState.aiPaused ? .red : Port42Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .appKitTooltip(appState.aiPaused ? "AI paused — click to resume" : "Pause all AI calls")

                    Button(action: { showUsage = true }) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 13))
                            .foregroundStyle(Port42Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .appKitTooltip("Token usage")

                    Button(action: { showSignOut = true }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13))
                            .foregroundStyle(Port42Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .appKitTooltip("Settings")
                }
            }
        }
        .padding(.leading, 68)
        .padding(.trailing, 12)
        .frame(height: 38)
        .background(Port42Theme.bgSidebar)
        .sheet(isPresented: $showSignOut) {
            SignOutSheet(isPresented: $showSignOut)
        }
        .sheet(isPresented: $showUsage) {
            UsageSheet(isPresented: $showUsage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { _ in
            showSignOut = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllSheets)) { _ in
            showSignOut = false
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
                        ("Cmd+N", "new space"),
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
                        ("right-click space", "add companions, copy invite link"),
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

