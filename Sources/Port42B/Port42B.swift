import SwiftUI
import AppKit
import Port42Lib

@main
struct Port42B: App {
    @StateObject private var appState: AppState

    init() {
        do {
            let db = try DatabaseService(subdirectory: "Port42B")
            _appState = StateObject(wrappedValue: AppState(db: db))
        } catch {
            fatalError("[Port42B] Failed to initialize database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            TransitionRootB(appState: appState)
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 600)
                .background(Port42Theme.bgPrimary)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Channel") {
                    NotificationCenter.default.post(name: .newChannelRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Quick Switcher") {
                    NotificationCenter.default.post(name: .quickSwitcherRequested, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}

struct TransitionRootB: View {
    @ObservedObject var appState: AppState
    @State private var diveProgress: CGFloat = 0.0
    @State private var isDiving = false

    private var showDreamscapeVideo: Bool {
        appState.showDreamscape || isDiving || !appState.isSetupComplete
    }

    var body: some View {
        ZStack {
            if showDreamscapeVideo {
                DreamscapeVideoLayer()
                    .ignoresSafeArea()
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
            }

            if appState.showDreamscape && !isDiving {
                LockScreenView()
            } else if appState.isSetupComplete {
                ContentView()
            } else if !appState.showDreamscape {
                SetupView()
            }

            if isDiving {
                Color(red: 0.0, green: 0.15, blue: 0.3)
                    .ignoresSafeArea()
                    .opacity(diveProgress * 0.7)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .opacity(diveProgress)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: appState.isSetupComplete) { _, newValue in
            if newValue {
                // Simple fade transition instead of breakout video
                isDiving = true
                withAnimation(.easeIn(duration: 0.5)) { diveProgress = 1.0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeOut(duration: 0.8)) { diveProgress = 0.0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { isDiving = false }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .diveRequested)) { _ in
            isDiving = true
            withAnimation(.easeIn(duration: 2.0)) { diveProgress = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                appState.unlock()
                withAnimation(.easeOut(duration: 1.2)) { diveProgress = 0.0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { isDiving = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .enterAquariumRequested)) { _ in
            appState.isSetupComplete = true
        }
        .onOpenURL { url in
            guard url.scheme == "port42" else { return }
            switch url.host {
            case "agent":
                if let invite = try? AgentInvite.parse(link: url.absoluteString),
                   let user = appState.currentUser {
                    let agent = AgentConfig.createLLM(
                        ownerId: user.id, displayName: invite.displayName,
                        systemPrompt: invite.systemPrompt, provider: invite.provider,
                        model: invite.model, trigger: .mentionOnly
                    )
                    appState.addCompanion(agent)
                }
            case "channel":
                if let invite = ChannelInvite.parse(url: url) {
                    appState.joinChannelFromInvite(invite)
                }
            default: break
            }
        }
    }
}
