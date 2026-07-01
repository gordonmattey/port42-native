import SwiftUI
import AppKit
import WebKit

/// SHELL — S2.2b. The real shell desktop that replaces `ContentView` at the space rung: a Chrome
/// top bar (§7a) + a grid of tiled ports (the chat is a tile) composited over the dreamscape, plus
/// a bottom launcher dock. Tiles re-parent their registry webview into the focus overlay with no
/// reload. Drag/resize/park land in S3; positions are an auto-grid for now.

// The chat tile's stable synthetic id (it's not a tiled PortPanel — it hosts ChatView).
private let kChatTileId = "__chat__"

// MARK: - Chrome (Layer 2 top bar, §7a)

struct ShellChrome: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            mark
            // ✨ + active-space name → toggles the galaxy (the only way up).
            Button {
                withAnimation(.spring(response: 0.4)) {
                    if shell.zoom == .galaxy { shell.zoom = .space } else { shell.zoomOut() }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Port42Theme.accent)
                    Text(appState.currentSpace?.name ?? "—").font(Port42Theme.monoBold(12)).foregroundStyle(Port42Theme.textPrimary)
                }
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(Port42Theme.accent.opacity(shell.zoom == .galaxy ? 0.2 : 0.12), in: Capsule())
                .overlay(Capsule().stroke(Port42Theme.accent.opacity(shell.zoom == .galaxy ? 0.7 : 0.4), lineWidth: 1))
            }
            .buttonStyle(.plain).help("All spaces (⌘↑ / pinch out)")

            chromeButton("rectangle.3.group", "Arrange (⌘L)") { shell.arrangeBump += 1 }
            chromeButton("plus.square", "New Space (⌘N)") {
                appState.createSpace(name: "space \(appState.spaces.count + 1)")
            }

            Spacer()

            Text(appState.currentUser?.displayName ?? "you").font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
            chromeButton("power", "Exit shell (⌘Q)") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(.black.opacity(0.45))
        .overlay(Rectangle().fill(Port42Theme.accent.opacity(0.25)).frame(height: 1), alignment: .bottom)
    }

    private var mark: some View {
        HStack(spacing: 9) {
            Canvas { ctx, size in
                var d = Path()
                d.move(to: CGPoint(x: size.width / 2, y: 2)); d.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
                d.addLine(to: CGPoint(x: size.width / 2, y: size.height - 2)); d.addLine(to: CGPoint(x: 2, y: size.height / 2)); d.closeSubpath()
                ctx.fill(d, with: .color(Port42Theme.accent))
            }.frame(width: 16, height: 16).shadow(color: Port42Theme.accent, radius: 6)
            Text("PORT42").font(Port42Theme.monoBold(14)).foregroundStyle(Port42Theme.textPrimary)
            Text("// SHELL").font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textSecondary)
        }
    }

    private func chromeButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Port42Theme.textSecondary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help)
    }
}

// MARK: - Desktop (tiled ports over the dreamscape)

struct ShellDesktopView: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState

    /// The current space's tiled web ports (chat is rendered separately as the first tile).
    private var tiledPanels: [PortPanel] {
        guard let sid = appState.currentSpace?.id else { return [] }
        return appState.portWindows.panels.filter { $0.spaceId == sid && $0.presentation == "tiled" }
    }

    var body: some View {
        GeometryReader { geo in
            // tile 0 = chat; the rest = tiled ports. Auto-grid, centered in the work area.
            let count = tiledPanels.count + 1
            let cols = max(1, Int(ceil(sqrt(Double(count)))))
            let rows = Int(ceil(Double(count) / Double(cols)))
            let cellW = min(440, (geo.size.width - 60) / Double(cols))
            let cellH = min(420, (geo.size.height - 60) / Double(rows))
            let totalW = Double(cols) * cellW, totalH = Double(rows) * cellH
            let startX = (geo.size.width - totalW) / 2 + cellW / 2
            let startY = (geo.size.height - totalH) / 2 + cellH / 2

            ZStack {
                ForEach(Array(allTiles().enumerated()), id: \.element.id) { i, tile in
                    let cx = startX + Double(i % cols) * cellW
                    let cy = startY + Double(i / cols) * cellH
                    ShellTile(shell: shell, appState: appState, tile: tile,
                              size: CGSize(width: cellW - 24, height: cellH - 24))
                        .position(x: cx, y: cy)
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: count)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: shell.arrangeBump)
        }
    }

    private func allTiles() -> [ShellTileModel] {
        var out: [ShellTileModel] = [ShellTileModel(id: kChatTileId, title: "chat", panel: nil)]
        for p in tiledPanels { out.append(ShellTileModel(id: p.id, title: p.title, panel: p)) }
        return out
    }
}

struct ShellTileModel: Identifiable { let id: String; let title: String; let panel: PortPanel? }

// MARK: - A single tile

struct ShellTile: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    let tile: ShellTileModel
    let size: CGSize

    private var isFocused: Bool { shell.zoom == .focus(tile.id) }
    private var isSelected: Bool { shell.selectedTileId == tile.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(isFocused ? Port42Theme.textSecondary : Port42Theme.accent).frame(width: 7, height: 7)
                Text(tile.title).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                Spacer()
                Button { withAnimation(.spring(response: 0.4)) { shell.zoom = .focus(tile.id) } } label: {
                    Image(systemName: "viewfinder").font(.system(size: 9)).foregroundStyle(Port42Theme.textSecondary)
                }.buttonStyle(.plain).help("Focus (⌘↓)")
                if let panel = tile.panel {
                    Button { appState.portWindows.close(panel.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(red: 0.06, green: 0.07, blue: 0.09))

            ZStack {
                if isFocused {
                    VStack(spacing: 6) {
                        Image(systemName: "viewfinder").font(.system(size: 22)).foregroundStyle(Port42Theme.textSecondary)
                        Text("focused — Esc to return").font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.5))
                } else {
                    ShellTileBody(appState: appState, tile: tile)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Port42Theme.accent.opacity(0.7) : Port42Theme.accent.opacity(0.22), lineWidth: 1))
        .shadow(color: Port42Theme.accent.opacity(isSelected ? 0.3 : 0.12), radius: isSelected ? 20 : 10)
        .onTapGesture { shell.selectedTileId = tile.id }
        .onHover { if $0 { shell.selectedTileId = tile.id } }
    }
}

/// A tile's live body: the chat surface, or a tiled port's re-parented webview.
struct ShellTileBody: View {
    @ObservedObject var appState: AppState
    let tile: ShellTileModel

    var body: some View {
        if tile.id == kChatTileId {
            ChatView().environmentObject(appState)
        } else if let panel = tile.panel, let wv = appState.portWindows.webViews[panel.id] {
            PortWebViewHost(webView: wv, bridge: panel.bridge)
        } else {
            Color.black
        }
    }
}

// MARK: - Focus content (the immersive single port; same webview, re-parented)

struct ShellFocusContent: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    let id: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
                .onTapGesture { withAnimation(.spring(response: 0.4)) { shell.zoom = .space } }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(Port42Theme.accent).frame(width: 8, height: 8)
                    Text(title).font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
                    Text("· focus").font(Port42Theme.mono(10)).foregroundStyle(Port42Theme.textSecondary)
                    Spacer()
                    Button { withAnimation(.spring(response: 0.4)) { shell.zoom = .space } } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11)).foregroundStyle(Port42Theme.textSecondary)
                    }.buttonStyle(.plain).help("Exit focus (Esc)")
                }.padding(.horizontal, 16).padding(.vertical, 11).background(Color(red: 0.06, green: 0.07, blue: 0.09))
                body(for: id)
            }
            .frame(width: NSScreen.main.map { $0.frame.width * 0.78 } ?? 1100,
                   height: NSScreen.main.map { $0.frame.height * 0.8 } ?? 700)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Port42Theme.accent.opacity(0.5), lineWidth: 1))
            .shadow(color: Port42Theme.accent.opacity(0.4), radius: 50)
        }
    }

    private var panel: PortPanel? { appState.portWindows.panels.first { $0.id == id } }
    private var title: String { id == kChatTileId ? "chat" : (panel?.title ?? "port") }

    @ViewBuilder
    private func body(for id: String) -> some View {
        if id == kChatTileId || panel?.isChatPort == true {
            ChatView().environmentObject(appState)
        } else if let p = panel, let wv = appState.portWindows.webViews[p.id] {
            PortWebViewHost(webView: wv, bridge: p.bridge)
        } else {
            Color.black
        }
    }
}

// MARK: - Launcher dock (creates tiled ports)

struct ShellDock: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            ForEach(ShellDemoPort.all) { app in
                Button { spawn(app) } label: {
                    Image(systemName: app.icon).font(.system(size: 20, weight: .medium)).foregroundStyle(Port42Theme.accent)
                        .frame(width: 46, height: 46).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Port42Theme.accent.opacity(0.3), lineWidth: 1))
                }.buttonStyle(.plain).help(app.label)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Port42Theme.accent.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
    }

    private func spawn(_ app: ShellDemoPort) {
        guard let sid = appState.currentSpace?.id else { return }
        _ = appState.createPort(type: "web", title: app.label, html: app.html,
                                command: nil, cwd: nil, systemPrompt: nil,
                                spaceId: sid, createdBy: nil, createdByName: nil,
                                presentation: "tiled", position: nil)
        shell.arrangeBump += 1
    }
}

/// Self-contained demo web ports for the launcher (stand-ins until saved/favorite ports land).
struct ShellDemoPort: Identifiable {
    let id = UUID(); let icon: String; let label: String; let html: String
    static let all: [ShellDemoPort] = [
        ShellDemoPort(icon: "clock", label: "Clock", html: """
        <html><body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:radial-gradient(circle at 50% 40%,#06121a,#000);font-family:ui-monospace,monospace">
        <div id=t style="font-size:46px;font-weight:800;color:#00FF41;text-shadow:0 0 24px #00FF4199">--:--:--</div>
        <script>function p(n){return(n<10?'0':'')+n}setInterval(function(){var x=new Date();t.innerText=p(x.getHours())+':'+p(x.getMinutes())+':'+p(x.getSeconds())},250)</script></body></html>
        """),
        ShellDemoPort(icon: "waveform.path.ecg", label: "Pulse", html: """
        <html><body style="margin:0;background:#000;overflow:hidden"><canvas id=c></canvas><script>
        var x=c.getContext('2d'),t=0;function rs(){c.width=innerWidth;c.height=innerHeight}addEventListener('resize',rs);rs();
        function f(){t+=0.02;x.fillStyle='rgba(0,0,0,0.12)';x.fillRect(0,0,c.width,c.height);var cx=c.width/2,cy=c.height/2;
        for(var i=0;i<5;i++){var r=30+i*22+Math.sin(t+i)*14;x.beginPath();x.arc(cx,cy,r,0,7);x.strokeStyle='hsla('+(120+i*18+t*30)+',90%,55%,.8)';x.lineWidth=2;x.stroke()}
        requestAnimationFrame(f)}f()</script></body></html>
        """),
        ShellDemoPort(icon: "circle.grid.cross", label: "Matrix", html: """
        <html><body style="margin:0;background:#000;overflow:hidden"><canvas id=c></canvas><script>
        var x=c.getContext('2d');function rs(){c.width=innerWidth;c.height=innerHeight}addEventListener('resize',rs);rs();
        var cols=Math.floor(c.width/12),y=[];for(var i=0;i<cols;i++)y[i]=Math.random()*c.height;
        function f(){x.fillStyle='rgba(0,0,0,0.08)';x.fillRect(0,0,c.width,c.height);x.fillStyle='#00FF41';x.font='13px monospace';
        for(var i=0;i<cols;i++){var ch=String.fromCharCode(0x30A0+Math.random()*96);x.fillText(ch,i*12,y[i]);if(y[i]>c.height&&Math.random()>0.975)y[i]=0;y[i]+=13}requestAnimationFrame(f)}f()</script></body></html>
        """),
    ]
}
