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
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(shell.accent)
                    Text(appState.currentSpace?.name ?? "—").font(Port42Theme.monoBold(12)).foregroundStyle(Port42Theme.textPrimary)
                }
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(shell.accent.opacity(shell.zoom == .galaxy ? 0.2 : 0.12), in: Capsule())
                .overlay(Capsule().stroke(shell.accent.opacity(shell.zoom == .galaxy ? 0.7 : 0.4), lineWidth: 1))
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
        .overlay(Rectangle().fill(shell.accent.opacity(0.25)).frame(height: 1), alignment: .bottom)
    }

    private var mark: some View {
        HStack(spacing: 9) {
            Canvas { ctx, size in
                var d = Path()
                d.move(to: CGPoint(x: size.width / 2, y: 2)); d.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
                d.addLine(to: CGPoint(x: size.width / 2, y: size.height - 2)); d.addLine(to: CGPoint(x: 2, y: size.height / 2)); d.closeSubpath()
                ctx.fill(d, with: .color(shell.accent))
            }.frame(width: 16, height: 16).shadow(color: shell.accent, radius: 6)
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

// MARK: - Desktop (tiled ports over the dreamscape; movable + resizable, z-ordered)

struct ShellDesktopView: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState

    private var sid: String? { appState.currentSpace?.id }

    /// The current space's tiled web ports (chat renders separately as the back-anchor tile).
    private var tiledPanels: [PortPanel] {
        guard let sid else { return [] }
        return appState.portWindows.panels.filter { $0.spaceId == sid && $0.presentation == "tiled" }
    }

    var body: some View {
        GeometryReader { geo in
            // Each tile places itself with `.position` (which sets a real layout frame, so its
            // hover/hit region lands where the tile is drawn — `.offset` leaves the layout frame at
            // the origin, piling every tile's tracking area on the top-left). The trick that stops a
            // greedy positioned frame from swallowing clicks: NO interactive modifier (onHover /
            // gesture) is attached AFTER `.position` — they all sit on the bounded tile content.
            ZStack {
                // Chat = the back anchor (z 0), its frame held in ShellState.
                ShellTile(shell: shell, appState: appState,
                          tile: ShellTileModel(id: ShellState.chatTileId, title: "chat", panel: nil),
                          frame: resolvedChatFrame(area: geo.size))
                    .zIndex(0)
                // Tiled ports painted back-to-front by z (positions from the panel record).
                ForEach(tiledPanels.sorted { $0.z < $1.z }, id: \.id) { p in
                    ShellTile(shell: shell, appState: appState,
                              tile: ShellTileModel(id: p.id, title: p.title, panel: p),
                              frame: resolvedPortFrame(p, area: geo.size))
                        .zIndex(Double(max(p.z, 1)))
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: shell.arrangeBump)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: tiledPanels.count)
            .onAppear { seedIfNeeded(area: geo.size) }
            .onChange(of: appState.currentSpace?.id) { _, _ in shell.ensureChatPlaced(area: geo.size) }  // new space → place its chat
            .onChange(of: tiledPanels.count) { _, _ in shell.applyArrange(area: geo.size) }   // spawn/park/close re-grids
            .onChange(of: shell.arrangeBump) { _, _ in shell.applyArrange(area: geo.size) }   // ⌘L
        }
    }

    /// The chat tile's frame — its ShellState slot, or a seeded top-left cell until arrange runs.
    private func resolvedChatFrame(area: CGSize) -> CGRect {
        if let sid, let f = shell.chatFrame(space: sid) { return f }
        return CGRect(x: 40, y: 70, width: ShellState.defaultTileSize.width, height: ShellState.defaultTileSize.height)
    }

    /// A port tile's frame — its persisted position/size, or a cheap cascade seed until arrange runs.
    private func resolvedPortFrame(_ p: PortPanel, area: CGSize) -> CGRect {
        let size = shell.clampTileSize(p.size)
        if let pos = p.position { return CGRect(origin: pos, size: size) }
        let i = tiledPanels.firstIndex { $0.id == p.id } ?? 0
        return CGRect(x: 330 + Double(i % 4) * 90, y: 200 + Double(i % 3) * 80, width: size.width, height: size.height)
    }

    /// Seed the grid on first entry into a space (nothing positioned yet). Hand-tuned layouts that
    /// come back from the DB with positions are left exactly as-is (arrange only re-grids on spawn/⌘L).
    private func seedIfNeeded(area: CGSize) {
        shell.ensureChatPlaced(area: area)                                     // chat only (restart-safe)
        if tiledPanels.contains(where: { $0.position == nil }) {               // a never-positioned port →
            shell.applyArrange(area: area)                                     // grid everything once
        }
    }
}

struct ShellTileModel: Identifiable { let id: String; let title: String; let panel: PortPanel? }

// MARK: - A single tile (draggable titlebar, bottom-right resize grip, z-order on grab/focus)

struct ShellTile: View {
    @ObservedObject var shell: ShellState
    @ObservedObject var appState: AppState
    let tile: ShellTileModel
    let frame: CGRect

    /// A tile corner (any corner resizes; the opposite corner stays pinned).
    enum Corner { case nw, ne, sw, se }

    @State private var moveDelta: CGSize = .zero
    @State private var resizeCorner: Corner? = nil
    @State private var resizeDelta: CGSize = .zero

    private let titleBarH: CGFloat = 34

    private var isFocused: Bool { shell.zoom == .focus(tile.id) }
    private var isSelected: Bool { shell.selectedTileId == tile.id }
    private var sid: String? { appState.currentSpace?.id }

    /// The tile's live frame = its committed frame plus an in-progress move OR corner-resize. The
    /// tile is placed top-left via `.offset`, so both move and resize just recompute this rect.
    private var liveFrame: CGRect {
        if let c = resizeCorner { return Self.resized(frame, corner: c, by: resizeDelta) }
        return CGRect(x: frame.minX + moveDelta.width, y: frame.minY + moveDelta.height,
                      width: frame.width, height: frame.height)
    }
    private var liveSize: CGSize { liveFrame.size }
    /// Center for `.position`. The tile's own frame stays bounded (liveSize), so its hover/hit region
    /// tracks where it's drawn — unlike `.offset`, which leaves the layout frame at the origin.
    private var liveCenter: CGPoint { CGPoint(x: liveFrame.midX, y: liveFrame.midY) }

    /// Apply a corner drag to a frame: the dragged corner follows the delta, the OPPOSITE corner
    /// stays pinned, and the result clamps to the min tile size (so a corner can't cross past it).
    /// Pure + static → headless-testable (`ShellLayoutTests`).
    static func resized(_ f: CGRect, corner c: Corner, by d: CGSize) -> CGRect {
        let minW = ShellState.minTileSize.width, minH = ShellState.minTileSize.height
        let east = (c == .ne || c == .se), south = (c == .sw || c == .se)
        let fixedX = east ? f.minX : f.maxX               // pinned (opposite) edge
        let fixedY = south ? f.minY : f.maxY
        let dragX = (east ? f.maxX : f.minX) + d.width    // dragged edge, moved by the delta
        let dragY = (south ? f.maxY : f.minY) + d.height
        // The dragged edge's side is fixed by the corner (east→right edge, west→left edge); clamp to
        // the min without flipping past the pinned edge — so dragging a corner across just stops.
        let x: CGFloat, w: CGFloat, y: CGFloat, h: CGFloat
        if east { x = fixedX; w = max(minW, dragX - fixedX) } else { w = max(minW, fixedX - dragX); x = fixedX - w }
        if south { y = fixedY; h = max(minH, dragY - fixedY) } else { h = max(minH, fixedY - dragY); y = fixedY - h }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
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
            .frame(width: liveSize.width, height: max(0, liveSize.height - titleBarH))
        }
        .frame(width: liveSize.width, height: liveSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? shell.accent.opacity(0.7) : shell.accent.opacity(0.25), lineWidth: 1))
        // Invisible resize zones on ALL four corners (no visible grip). Overlaid on top so a corner
        // grab resizes even over the titlebar/body; the buttons are inset to clear the top corners.
        .overlay(cornerHandle(.nw), alignment: .topLeading)
        .overlay(cornerHandle(.ne), alignment: .topTrailing)
        .overlay(cornerHandle(.sw), alignment: .bottomLeading)
        .overlay(cornerHandle(.se), alignment: .bottomTrailing)
        .shadow(color: shell.accent.opacity(isSelected ? 0.3 : 0.12), radius: isSelected ? 22 : 12)
        .onHover { if $0 { shell.selectedTileId = tile.id } }   // BEFORE .position → tracking area on the bounded tile
        .position(x: liveCenter.x, y: liveCenter.y)            // place last; nothing interactive after it
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            // Drag handle = dot + title + trailing gap; scoped so the focus/close buttons still tap.
            HStack(spacing: 8) {
                Circle().fill(isFocused ? Port42Theme.textSecondary : shell.accent).frame(width: 7, height: 7)
                Text(tile.title).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
                Spacer(minLength: 8)
            }
            .frame(maxHeight: .infinity)          // fill the full titlebar height so the WHOLE bar drags
            .contentShape(Rectangle())
            .gesture(moveGesture)
            Button { shell.bringToFront(tile.id); withAnimation(.spring(response: 0.4)) { shell.zoom = .focus(tile.id) } } label: {
                Image(systemName: "viewfinder").font(.system(size: 9)).foregroundStyle(Port42Theme.textSecondary)
            }.buttonStyle(.plain).help("Focus (⌘↓)")
            if let panel = tile.panel {
                Button { appState.portWindows.close(panel.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Port42Theme.textSecondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.leading, 10).padding(.trailing, 18)   // trailing inset clears the top-right resize zone
        .frame(maxWidth: .infinity)          // span the tile so the drag handle is easy to grab
        .frame(height: titleBarH)
        .background(Color(red: 0.06, green: 0.07, blue: 0.09))
    }

    /// An invisible 16×16 corner drag zone that resizes from that corner.
    private func cornerHandle(_ corner: Corner) -> some View {
        Color.clear
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .gesture(resizeGesture(corner))
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                if moveDelta == .zero { shell.bringToFront(tile.id) }   // grabbing a tile raises it
                moveDelta = v.translation
            }
            .onEnded { v in
                commit(origin: CGPoint(x: frame.minX + v.translation.width, y: frame.minY + v.translation.height),
                       size: CGSize(width: frame.width, height: frame.height))
                moveDelta = .zero
            }
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture()
            .onChanged { v in
                if resizeCorner == nil { shell.bringToFront(tile.id) }
                resizeCorner = corner
                resizeDelta = v.translation
            }
            .onEnded { v in
                let f = Self.resized(frame, corner: corner, by: v.translation)
                commit(origin: f.origin, size: f.size)
                resizeCorner = nil
                resizeDelta = .zero
            }
    }

    /// Persist the tile's new geometry (drag/resize end). Chat → the ShellState slot; a port → the
    /// panel record (survives restart, §4). `updateTileFrame` handles the persist.
    private func commit(origin: CGPoint, size: CGSize) {
        if tile.id == ShellState.chatTileId {
            if let sid { shell.setChatFrame(CGRect(origin: origin, size: size), space: sid) }
        } else {
            appState.portWindows.updateTileFrame(id: tile.id, position: origin, size: size)
        }
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
                    Circle().fill(shell.accent).frame(width: 8, height: 8)
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
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(shell.accent.opacity(0.5), lineWidth: 1))
            .shadow(color: shell.accent.opacity(0.4), radius: 50)
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
                    Image(systemName: app.icon).font(.system(size: 20, weight: .medium)).foregroundStyle(shell.accent)
                        .frame(width: 46, height: 46).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(shell.accent.opacity(0.3), lineWidth: 1))
                }.buttonStyle(.plain).help(app.label)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(shell.accent.opacity(0.25), lineWidth: 1))
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
