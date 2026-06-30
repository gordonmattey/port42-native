// PORT42 // SHELL — rev 2. Throwaway fullscreen GUI-shell prototype.
//
// The thesis, made live:
//   • ONE ambient surface: dreamscape background = screensaver = desktop. Idle dissolves the
//     chrome+ports into it; any input wakes them back.  (Layer 0 / Layer 2 of plan-port42-shell.md)
//   • Ports are registry-owned WKWebViews. POP-OUT moves the *live* view into a floating NSPanel
//     with NO reload (the proven re-parent), DOCK-BACK reverses it — DOM/JS state preserved.
//   • Virtual SPACES: each space has its own set of port tiles; switching swaps the desktop.
//   • EXPOSÉ: zoom all tiles to a grid. Focus/z-order. Drag + resize.
//   • Chrome (§7a): PORT42 mark top-left (in the freed traffic-light gap) + the global status/action
//     cluster moved up from the sidebar (gateway/tunnel/key/pause/usage/settings).
//
// EXITS (never trapped):  Esc  ·  ⌘Q  ·  ⏻ top-right.   Keys:  ⌘K palette · Tab exposé · ⌘1/2/3 spaces

import AppKit
import WebKit
import SwiftUI

// MARK: - Theme

enum P42 {
    static let accent  = Color(red: 0.0,  green: 0.831, blue: 0.667)   // #00d4aa
    static let accent2 = Color(red: 0.62, green: 0.28, blue: 0.98)
    static let gold    = Color(red: 1.0,  green: 0.74, blue: 0.2)
    static let text    = Color(red: 0.86, green: 0.92, blue: 0.94)
    static let dim     = Color(red: 0.42, green: 0.48, blue: 0.52)
    static func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w, design: .monospaced) }
    static let nsAccent = NSColor(red: 0, green: 0.831, blue: 0.667, alpha: 1)
}

// MARK: - Port content (self-contained animated HTML)

struct AppDef { let icon, label, title, html: String; let size: CGSize; var terminal: Bool = false }

enum Apps {
    static let all: [AppDef] = [
        AppDef(icon: "clock",             label: "Clock",  title: "clock.port",  html: clock,  size: CGSize(width: 300, height: 168)),
        AppDef(icon: "waveform.path.ecg", label: "Pulse",  title: "pulse.port",  html: pulse,  size: CGSize(width: 260, height: 260)),
        AppDef(icon: "cpu",               label: "System", title: "sys.port",    html: sys,    size: CGSize(width: 300, height: 228)),
        AppDef(icon: "terminal",          label: "Shell",  title: "term.port",   html: term,   size: CGSize(width: 440, height: 280), terminal: true),
        AppDef(icon: "circle.grid.cross", label: "Matrix", title: "matrix.port", html: matrix, size: CGSize(width: 280, height: 300)),
        AppDef(icon: "sun.max",           label: "Synth",  title: "synth.port",  html: synth,  size: CGSize(width: 340, height: 206)),
    ]

    static let clock = #"""
    <html><body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:radial-gradient(circle at 50% 40%,#06121a,#000);font-family:ui-monospace,monospace">
    <div style="text-align:center"><div id=t style="font-size:50px;font-weight:800;color:#00d4aa;text-shadow:0 0 24px #00d4aa99;letter-spacing:2px">--:--:--</div>
    <div id=d style="margin-top:6px;color:#456;font-size:12px;letter-spacing:3px"></div></div>
    <script>function p(n){return(n<10?'0':'')+n}setInterval(function(){var x=new Date();t.innerText=p(x.getHours())+':'+p(x.getMinutes())+':'+p(x.getSeconds());d.innerText=x.toDateString().toUpperCase()},250)</script></body></html>
    """#

    static let pulse = #"""
    <html><body style="margin:0;background:#000;overflow:hidden"><canvas id=c></canvas><script>
    var x=c.getContext('2d'),t=0;function rs(){c.width=innerWidth;c.height=innerHeight}addEventListener('resize',rs);rs();
    function f(){t+=0.02;x.fillStyle='rgba(0,0,0,0.12)';x.fillRect(0,0,c.width,c.height);var cx=c.width/2,cy=c.height/2;
    for(var i=0;i<5;i++){var r=36+i*24+Math.sin(t+i)*16;x.beginPath();x.arc(cx,cy,r,0,7);x.strokeStyle='hsla('+(160+i*18+t*30)+',90%,55%,.8)';x.lineWidth=2;x.stroke()}
    for(var k=0;k<60;k++){var a=k/60*6.28+t,rr=100+Math.sin(t*2+k)*38;x.fillStyle='hsla('+(170+k*3)+',90%,60%,.9)';x.fillRect(cx+Math.cos(a)*rr,cy+Math.sin(a)*rr,2.5,2.5)}
    requestAnimationFrame(f)}f()</script></body></html>
    """#

    static let sys = #"""
    <html><body style="margin:0;height:100vh;background:#04080a;color:#9fb;font-family:ui-monospace,monospace;font-size:12px;padding:14px;box-sizing:border-box">
    <div style="color:#00d4aa;font-weight:700;margin-bottom:10px">◢ SYSTEM</div><div id=o></div><script>
    var up=0;function bar(p){var n=Math.round(p/5),s='';for(var i=0;i<20;i++)s+=i<n?'█':'·';return s}
    function tk(){up++;var cpu=30+Math.sin(up/7)*20+Math.random()*8,mem=55+Math.sin(up/13)*10,net=Math.random()*100;
    o.innerHTML='cpu  '+bar(cpu)+' '+cpu.toFixed(0)+'%<br>mem  '+bar(mem)+' '+mem.toFixed(0)+'%<br>net  '+bar(net)+' '+net.toFixed(0)+'%<br><br><span style=color:#456>uptime</span> '+up+'s<br><span style=color:#456>shell</span>  port42://kiosk<br><span style=color:#456>host</span>   '+navigator.platform}
    tk();setInterval(tk,1000)</script></body></html>
    """#

    static let term = #"""
    <html><body style="margin:0;height:100vh;background:#000;color:#00d4aa;font-family:ui-monospace,monospace;font-size:13px;padding:12px;box-sizing:border-box" onclick="i.focus()">
    <div id=out>port42 shell v0.2 — type a command (try: help)<br></div><div style="display:flex"><span>›&nbsp;</span><span id=i contenteditable style="outline:none;flex:1;color:#cfe"></span></div><script>
    i.focus();i.addEventListener('keydown',function(e){if(e.key==='Enter'){e.preventDefault();var v=i.innerText.trim();
    var r=v==='ls'?'ports  spaces  companions':v==='whoami'?'gordon':v==='help'?'ls whoami spaces clear date':v==='spaces'?'home  build  deep':v==='clear'?'__c__':v==='date'?new Date().toString():v?'sh: '+v+': not found':'';
    if(r==='__c__'){out.innerHTML=''}else{out.innerHTML+='<span style=color:#9fb>› '+v+'</span><br>'+(r?r+'<br>':'')}i.innerText=''}})</script></body></html>
    """#

    static let matrix = #"""
    <html><body style="margin:0;background:#000;overflow:hidden"><canvas id=c></canvas><script>
    var x=c.getContext('2d');function rs(){c.width=innerWidth;c.height=innerHeight}addEventListener('resize',rs);rs();
    var cols=Math.floor(c.width/12),y=[];for(var i=0;i<cols;i++)y[i]=Math.random()*c.height;
    function f(){x.fillStyle='rgba(0,0,0,0.08)';x.fillRect(0,0,c.width,c.height);x.fillStyle='#00d4aa';x.font='13px monospace';
    for(var i=0;i<cols;i++){var ch=String.fromCharCode(0x30A0+Math.random()*96);x.fillText(ch,i*12,y[i]);if(y[i]>c.height&&Math.random()>0.975)y[i]=0;y[i]+=13}requestAnimationFrame(f)}f()</script></body></html>
    """#

    static let synth = #"""
    <html><body style="margin:0;background:linear-gradient(#1a0b2e,#06030f);overflow:hidden"><canvas id=c></canvas><script>
    var x=c.getContext('2d'),t=0;function rs(){c.width=innerWidth;c.height=innerHeight}addEventListener('resize',rs);rs();
    function f(){t+=0.01;x.clearRect(0,0,c.width,c.height);var cx=c.width/2,h=c.height*0.52;
    var g=x.createLinearGradient(0,h-90,0,h+30);g.addColorStop(0,'#ff2e88');g.addColorStop(1,'#ffb02e');x.fillStyle=g;
    x.beginPath();x.arc(cx,h,80,Math.PI,0);x.fill();
    x.globalCompositeOperation='destination-out';for(var i=0;i<7;i++){x.fillStyle='#000';x.fillRect(cx-80,h-70+i*11,160,5)}x.globalCompositeOperation='source-over';
    x.strokeStyle='rgba(0,212,170,.5)';for(var j=0;j<16;j++){var yy=h+10+(j+ (t*4)%1)*(c.height-h)/16;x.beginPath();x.moveTo(0,yy);x.lineTo(c.width,yy);x.lineWidth=1;x.stroke()}
    for(var k=-9;k<10;k++){x.beginPath();x.moveTo(cx+k*22,h+10);x.lineTo(cx+k*c.width/8,c.height);x.stroke()}requestAnimationFrame(f)}f()</script></body></html>
    """#
}

// MARK: - Webview registry (one WKWebView per port, ever)

final class Registry {
    static let shared = Registry()
    private var views: [UUID: WKWebView] = [:]
    func web(_ id: UUID, html: String) -> WKWebView {
        if let w = views[id] { return w }
        let cfg = WKWebViewConfiguration()
        let p = WKWebpagePreferences(); p.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = p
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        w.loadHTMLString(html, baseURL: nil)
        views[id] = w
        return w
    }
    func drop(_ id: UUID) { views[id]?.removeFromSuperview(); views[id] = nil }
    func peek(_ id: UUID) -> WKWebView? { views[id] }
    // Focus-follows-mouse: make the port's webview first responder and focus its first input (saves a click).
    func activate(_ id: UUID) {
        guard let w = views[id] else { return }
        w.window?.makeFirstResponder(w)
        w.evaluateJavaScript("var e=document.querySelector('input,textarea,[contenteditable]');if(e){e.focus();}", completionHandler: nil)
    }
}

// MARK: - Model

enum Presentation { case tiled, floating }

final class Port: Identifiable, ObservableObject {
    let id = UUID()
    let icon: String; let title: String; let html: String
    @Published var pos: CGPoint
    @Published var size: CGSize
    @Published var z: Int
    @Published var presentation: Presentation = .tiled
    @Published var mode: Int
    @Published var space: Int
    let isTerminal: Bool
    init(_ app: AppDef, pos: CGPoint, z: Int, mode: Int, space: Int) {
        icon = app.icon; title = app.title; html = app.html; self.pos = pos; self.z = z; self.mode = mode; self.space = space
        size = app.size; isTerminal = app.terminal
    }
}

// A MODE is a meta-space: a whole-shell state with its own accent, its own dock apps, and its own
// set of Port42 SPACES. Switching mode reconfigures the workspace; switching space swaps the ports.
struct ModeDef {
    let name: String
    let accent: Color
    let dock: [Int]        // indices into Apps.all — this mode's dock
    let spaces: [String]   // the Port42 spaces that live in this mode
    let seed: [(Int, Int)] // (spaceIndex, appIndex) seeded on first entry — the mode's default layout
}

final class Shell: ObservableObject {
    static let shared = Shell()
    @Published var ports: [Port] = []
    @Published var mode = 0
    @Published var space = 0
    @Published var showPalette = false
    @Published var expose = false
    @Published var showSpaces = false           // spaces-in-mode overview
    @Published var galaxy = false                // all-modes constellation (zoom UP)
    @Published var focusId: UUID? = nil          // immersive single port (zoom DOWN)
    @Published var booting = true
    @Published var bootLines: [String] = []
    @Published var idle = false
    @Published var mouse = CGPoint(x: 0.5, y: 0.5)   // normalized, for parallax
    @Published var toast: String?
    var toastTick = 0
    var lastInput = Date()
    var zCounter = 10
    var screenW: CGFloat = 1440; var screenH: CGFloat = 900
    var notch: CGFloat = 0
    var seeded = Set<Int>()
    var panels: [UUID: PopoutPanel] = [:]

    let modes: [ModeDef] = [
        ModeDef(name: "home",  accent: P42.accent,  dock: [0,1,5], spaces: ["main","music"],     seed: [(0,0),(0,1)]),
        ModeDef(name: "build", accent: P42.gold,    dock: [3,2,4], spaces: ["api","ui","infra"], seed: [(0,3),(0,2),(1,5)]),
        ModeDef(name: "deep",  accent: P42.accent2, dock: [4,1],   spaces: ["read","write"],     seed: [(0,4)]),
    ]
    var modeDef: ModeDef { modes[mode] }
    var accent: Color { modeDef.accent }
    var dockApps: [AppDef] { modeDef.dock.map { Apps.all[$0] } }
    var spaceNames: [String] { modeDef.spaces }

    var current: [Port] { ports.filter { $0.mode == mode && $0.space == space } }
    func portsIn(_ m: Int, _ s: Int) -> [Port] { ports.filter { $0.mode == m && $0.space == s } }
    var frontmost: Port? { current.max(by: { $0.z < $1.z }) }

    // Zoom ladder:  GALAXY ↑  Mode  ·  Spaces  ·  Ports(expose)  ·  ↓ FOCUS
    func zoomUp() { withAnimation(.spring(response: 0.45)) { focusId = nil; expose = false; showSpaces = false; galaxy = true } }
    func zoomDown() { if let p = frontmost { withAnimation(.spring(response: 0.45)) { galaxy = false; showSpaces = false; expose = false; focusId = p.id } } }
    @discardableResult func unwind() -> Bool {     // Esc peels one zoom level; false = nothing left → quit
        if focusId != nil { withAnimation(.spring(response: 0.4)) { focusId = nil }; return true }
        if galaxy { withAnimation { galaxy = false }; return true }
        if showSpaces { withAnimation { showSpaces = false }; return true }
        if expose { withAnimation { expose = false }; return true }
        if showPalette { showPalette = false; return true }
        return false
    }

    func switchMode(_ m: Int) {
        guard m != mode else { return }
        seed(m)
        withAnimation(.spring(response: 0.35)) { mode = m; space = 0; expose = false; showSpaces = false }
        say("mode · \(modes[m].name)")
    }
    func switchSpace(_ s: Int) {
        withAnimation(.spring(response: 0.3)) { space = s; expose = false; showSpaces = false }
        say("space · \(spaceNames[s])")
    }
    func seed(_ m: Int) {
        guard !seeded.contains(m) else { return }
        seeded.insert(m)
        for (s, app) in modes[m].seed { spawn(Apps.all[app], mode: m, space: s, quiet: true) }
    }

    func spawn(_ app: AppDef, at: CGPoint? = nil, mode m: Int? = nil, space s: Int? = nil, quiet: Bool = false) {
        let mm = m ?? mode, ss = s ?? space
        zCounter += 1
        let n = portsIn(mm, ss).count
        let p = at ?? CGPoint(x: 330 + Double(n % 4) * 90, y: 200 + Double(n % 3) * 80)
        ports.append(Port(app, pos: p, z: zCounter, mode: mm, space: ss))
        if !quiet { say("opened \(app.title)") }
    }
    func focus(_ p: Port) { zCounter += 1; p.z = zCounter }

    var interactive: Bool { !expose && !galaxy && !showSpaces && !showPalette && !booting && focusId == nil && !idle }
    // Full tile rect in top-left window coords (titlebar ≈ 32pt above the content).
    func tileRect(_ p: Port) -> CGRect {
        CGRect(x: p.pos.x - p.size.width/2, y: p.pos.y - (p.size.height + 32)/2, width: p.size.width, height: p.size.height + 32)
    }
    struct PortHit { let port: Port; let left, right, top, bottom: Bool; var edge: Bool { left || right || top || bottom } }
    func portHit(at pt: CGPoint, margin: CGFloat = 9) -> PortHit? {
        for p in current.sorted(by: { $0.z > $1.z }) where p.presentation == .tiled {
            let r = tileRect(p)
            if r.insetBy(dx: -2, dy: -2).contains(pt) {
                return PortHit(port: p, left: pt.x - r.minX < margin, right: r.maxX - pt.x < margin,
                               top: pt.y - r.minY < margin, bottom: r.maxY - pt.y < margin)
            }
        }
        return nil
    }

    var lastHovered: UUID?
    // Focus-follows-mouse: hover a port → front + focus its entry box. Also sets the resize cursor on edges.
    func hoverFocus(at pt: CGPoint) {
        guard interactive else { return }
        guard let h = portHit(at: pt) else { lastHovered = nil; return }
        if h.port.id != lastHovered { lastHovered = h.port.id; focus(h.port); Registry.shared.activate(h.port.id) }
        let lr = h.left || h.right, tb = h.top || h.bottom
        ((lr && tb) ? NSCursor.crosshair : lr ? .resizeLeftRight : tb ? .resizeUpDown : .arrow).set()
    }

    // AppKit-level drag: edges resize, body/titlebar move; plain clicks pass through (threshold-armed).
    var dragId: UUID?; var dragStart = CGPoint.zero; var dragPos = CGPoint.zero; var dragSize = CGSize.zero
    var dragL = false, dragR = false, dragT = false, dragB = false, dragResize = false, dragArmed = false
    func mouseDown(at pt: CGPoint) {
        guard interactive, let h = portHit(at: pt) else { dragId = nil; return }
        focus(h.port)
        // Terminal exception: its body is for text selection, not moving. Move via titlebar, resize via edges.
        let inTitlebar = pt.y < tileRect(h.port).minY + 32
        if h.port.isTerminal && !h.edge && !inTitlebar { dragId = nil; return }
        dragId = h.port.id; dragStart = pt; dragPos = h.port.pos; dragSize = h.port.size
        dragL = h.left; dragR = h.right; dragT = h.top; dragB = h.bottom; dragResize = h.edge; dragArmed = false
    }
    func mouseDragged(at pt: CGPoint) -> Bool {
        guard let id = dragId, let p = ports.first(where: { $0.id == id }) else { return false }
        let dx = pt.x - dragStart.x, dy = pt.y - dragStart.y
        if !dragArmed && abs(dx) + abs(dy) > 5 { dragArmed = true }
        guard dragArmed else { return false }
        if dragResize {
            var w = dragSize.width, h = dragSize.height, cx = dragPos.x, cy = dragPos.y
            if dragR { w += dx; cx += dx/2 }
            if dragL { w -= dx; cx += dx/2 }
            if dragB { h += dy; cy += dy/2 }
            if dragT { h -= dy; cy += dy/2 }
            p.size = CGSize(width: max(240, w), height: max(150, h)); p.pos = CGPoint(x: cx, y: cy)
        } else {
            p.pos = CGPoint(x: dragPos.x + dx, y: dragPos.y + dy)
        }
        return true   // consume → don't leak the drag into the webview
    }
    func mouseUp() -> Bool { let armed = dragArmed; dragId = nil; dragArmed = false; return armed }
    func close(_ p: Port) {
        panels[p.id]?.close()
        Registry.shared.drop(p.id)
        ports.removeAll { $0.id == p.id }
    }
    func move(_ p: Port, toSpace s: Int) { withAnimation { p.space = s }; say("moved \(p.title) → \(spaceNames[s])") }
    func bump() { lastInput = Date(); if idle { withAnimation(.easeOut(duration: 0.5)) { idle = false } } }

    func say(_ m: String) {
        toastTick += 1; let mine = toastTick
        withAnimation(.spring(response: 0.3)) { toast = m }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.toastTick == mine { withAnimation(.easeOut(duration: 0.4)) { self.toast = nil } }
        }
    }

    // Tidy the current space into a fitted grid centered in the work area.
    func arrange() {
        let items = current.filter { $0.presentation == .tiled }.sorted { $0.z < $1.z }
        guard !items.isEmpty else { return }
        let cols = Int(ceil(sqrt(Double(items.count))))
        let rows = Int(ceil(Double(items.count) / Double(cols)))
        let cellW = (items.map { $0.size.width }.max() ?? 320) + 40
        let cellH = (items.map { $0.size.height }.max() ?? 240) + 50
        let totalW = Double(cols) * cellW, totalH = Double(rows) * cellH
        let startX = (screenW - totalW) / 2 + cellW / 2
        let startY = max(70, (screenH - totalH) / 2) + cellH / 2 - 20
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            for (i, p) in items.enumerated() {
                p.pos = CGPoint(x: startX + Double(i % cols) * cellW, y: startY + Double(i / cols) * cellH)
            }
        }
        say("arranged \(items.count)")
    }
}

// MARK: - Adopting host (tiled webview)

struct AdoptingHost: NSViewRepresentable {
    let id: UUID; let html: String
    func makeNSView(context: Context) -> NSView {
        let c = NSView()
        let w = Registry.shared.web(id, html: html)
        w.removeFromSuperview()
        c.addSubview(w)
        w.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            w.topAnchor.constraint(equalTo: c.topAnchor), w.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            w.leadingAnchor.constraint(equalTo: c.leadingAnchor), w.trailingAnchor.constraint(equalTo: c.trailingAnchor)])
        return c
    }
    func updateNSView(_ v: NSView, context: Context) {}
    static func dismantleNSView(_ v: NSView, coordinator: ()) {}   // never tear down the registry webview
}

// MARK: - Pop-out floating panel (the proven re-parent target)

final class PopoutPanel: NSPanel {
    var dockBack: (() -> Void)?
    override func close() { dockBack?(); super.close() }
    override var canBecomeKey: Bool { true }
}

// MARK: - Dreamscape background (Layer 0 — screensaver = desktop)

struct Dreamscape: View {
    @ObservedObject var shell = Shell.shared
    var body: some View {
        let accent = shell.accent
        return TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let px = (shell.mouse.x - 0.5) * 30, py = (shell.mouse.y - 0.5) * 20
            Canvas { ctx, size in
                // deep space gradient
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(Gradient(colors: [Color(red:0.03,green:0.0,blue:0.08), .black]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                // nebula glows (breathing)
                let b = 0.5 + 0.5 * sin(t * 0.4)
                ctx.fill(Path(ellipseIn: CGRect(x: size.width*0.2 - 220 + px, y: size.height*0.15 - 220 + py, width: 440, height: 440)),
                    with: .radialGradient(Gradient(colors: [P42.accent2.opacity(0.22 + 0.12*b), .clear]),
                        center: CGPoint(x: size.width*0.2 + px, y: size.height*0.15 + py), startRadius: 0, endRadius: 260))
                ctx.fill(Path(ellipseIn: CGRect(x: size.width*0.8 - 220 - px, y: size.height*0.7 - 220 - py, width: 440, height: 440)),
                    with: .radialGradient(Gradient(colors: [accent.opacity(0.18 + 0.12*(1-b)), .clear]),
                        center: CGPoint(x: size.width*0.8 - px, y: size.height*0.7 - py), startRadius: 0, endRadius: 260))
                // starfield (deterministic pseudo-random, drifting)
                for i in 0..<160 {
                    let sx = (Double((i*73 + 17) % 1000)/1000.0 * size.width + t*6).truncatingRemainder(dividingBy: size.width)
                    let sy = Double((i*131 + 53) % 1000)/1000.0 * size.height
                    let tw = 0.4 + 0.6 * abs(sin(t*1.5 + Double(i)))
                    let r = (i % 7 == 0) ? 1.6 : 0.8
                    ctx.fill(Path(ellipseIn: CGRect(x: sx + px*0.3, y: sy + py*0.3, width: r, height: r)),
                        with: .color(.white.opacity(0.5 * tw)))
                }
                // synthwave perspective floor
                let horizon = size.height * 0.62
                let scroll = t.truncatingRemainder(dividingBy: 1.0)
                for i in 0..<24 {
                    let f = (Double(i) + scroll) / 24.0
                    let y = horizon + (size.height - horizon) * f * f
                    var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(p, with: .color(accent.opacity(0.05 + 0.18*f)), lineWidth: 1)
                }
                let cx = size.width/2 + px
                for i in -11...11 {
                    var p = Path(); p.move(to: CGPoint(x: cx + Double(i)*22, y: horizon)); p.addLine(to: CGPoint(x: cx + Double(i)*size.width/9, y: size.height))
                    ctx.stroke(p, with: .color(accent.opacity(0.06)), lineWidth: 1)
                }
            }
        }.ignoresSafeArea()
    }
}

// MARK: - PORT42 mark (top-left, in the freed traffic-light gap)

struct Mark: View {
    var body: some View {
        HStack(spacing: 9) {
            Canvas { ctx, size in
                var d = Path()
                d.move(to: CGPoint(x: size.width/2, y: 2)); d.addLine(to: CGPoint(x: size.width-2, y: size.height/2))
                d.addLine(to: CGPoint(x: size.width/2, y: size.height-2)); d.addLine(to: CGPoint(x: 2, y: size.height/2)); d.closeSubpath()
                ctx.fill(d, with: .linearGradient(Gradient(colors: [P42.accent, P42.accent2]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                ctx.stroke(d, with: .color(P42.accent), lineWidth: 1)
            }.frame(width: 18, height: 18).shadow(color: P42.accent, radius: 6)
            Text("PORT42").font(P42.mono(14, .bold)).foregroundStyle(P42.text)
            Text("// SHELL").font(P42.mono(11)).foregroundStyle(P42.dim)
        }
    }
}

// MARK: - Chrome (Layer 2 top bar): mark · spaces · status cluster (moved from sidebar §7a)

struct Chrome: View {
    @ObservedObject var shell = Shell.shared
    var body: some View {
        HStack(spacing: 16) {
            Mark()
            // global create actions (from SidebarView header)
            chromeIcon("number", "New Space"); chromeIcon("person.crop.circle.badge.plus", "New Companion")
            Spacer().frame(width: 18)
            // MODES (meta-spaces) — left of the notch/camera, each reconfigures the whole shell
            HStack(spacing: 8) {
                Text("MODE").font(P42.mono(9)).foregroundStyle(P42.dim.opacity(0.7)).tracking(2)
                ForEach(Array(shell.modes.enumerated()), id: \.0) { i, m in
                    let on = shell.mode == i
                    Button(action: { shell.switchMode(i) }) {
                        HStack(spacing: 5) {
                            Circle().fill(m.accent).frame(width: 5, height: 5).opacity(on ? 1 : 0.4)
                            Text(m.name.uppercased()).font(P42.mono(10, on ? .bold : .regular)).tracking(1)
                                .foregroundStyle(on ? m.accent : P42.dim)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(on ? m.accent.opacity(0.14) : .clear, in: Capsule())
                        .overlay(Capsule().stroke(on ? m.accent.opacity(0.55) : .clear, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                // breadcrumb into the active space + spaces overview
                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(P42.dim)
                Button(action: { withAnimation { shell.showSpaces.toggle() } }) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 10))
                        Text(shell.spaceNames[shell.space]).font(P42.mono(10)).tracking(1)
                    }.foregroundStyle(shell.showSpaces ? shell.accent : P42.text)
                }.buttonStyle(.plain).help("Spaces in this mode (⌘E)")
            }
            Spacer()
            // status cluster moved up from ContentView.swift:185
            Button(action: { if shell.galaxy { shell.unwind() } else { shell.zoomUp() } }) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(shell.galaxy ? shell.accent : P42.dim)
            }.buttonStyle(.plain).help("Galaxy — all modes (⌘↑)")
            Button(action: { shell.arrange() }) {
                Image(systemName: "rectangle.3.group").font(.system(size: 12)).foregroundStyle(P42.dim)
            }.buttonStyle(.plain).help("Arrange (⌘L)")
            Button(action: { withAnimation { shell.expose.toggle() } }) {
                Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(shell.expose ? P42.accent : P42.dim)
            }.buttonStyle(.plain).help("Exposé (Tab)")
            Text("gordon").font(P42.mono(12)).foregroundStyle(P42.text)
            status("bolt.fill", .green, "Gateway connected")
            status("globe", P42.accent, "Tunnel active")
            status("key.fill", P42.gold, "API key OK")
            status("pause.circle", P42.dim, "Pause AI")
            status("chart.bar", P42.dim, "Token usage")
            status("gearshape", P42.dim, "Settings")
            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power").font(.system(size: 13, weight: .bold)).foregroundStyle(P42.text)
                    .padding(6).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).help("Exit shell (Esc / ⌘Q)")
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(.black.opacity(0.45))
        .overlay(Rectangle().fill(P42.accent.opacity(0.25)).frame(height: 1), alignment: .bottom)
    }
    func status(_ s: String, _ c: Color, _ h: String) -> some View {
        Image(systemName: s).font(.system(size: 11)).foregroundStyle(c).help(h)
    }
    func chromeIcon(_ s: String, _ h: String) -> some View {
        Image(systemName: s).font(.system(size: 12)).foregroundStyle(P42.dim).help(h)
    }
}

// MARK: - Port tile

struct Tile: View {
    @ObservedObject var port: Port
    @ObservedObject var shell = Shell.shared
    let exposeFrame: CGRect?    // when expose mode, override position+scale

    var body: some View {
        let floating = port.presentation == .floating
        let inOverlay = floating || shell.focusId == port.id   // webview lives elsewhere (panel / focus overlay)
        let w = port.size.width, h = port.size.height   // move/resize are handled in AppKit (Shell.mouse*)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(inOverlay ? P42.dim : P42.accent).frame(width: 7, height: 7)
                Text(port.title).font(P42.mono(11)).foregroundStyle(P42.text)
                Spacer()
                Button(action: { withAnimation(.spring(response: 0.45)) { shell.focusId = port.id } }) {
                    Image(systemName: "viewfinder").font(.system(size: 9)).foregroundStyle(P42.dim)
                }.buttonStyle(.plain).help("Focus — immersive (⌘↓)")
                Button(action: popToggle) {
                    Image(systemName: floating ? "arrow.down.right.and.arrow.up.left" : "macwindow")
                        .font(.system(size: 9)).foregroundStyle(P42.dim)
                }.buttonStyle(.plain).help(floating ? "Dock back" : "Pop out to floating window")
                Button(action: { shell.close(port) }) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(P42.dim)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(red:0.06,green:0.07,blue:0.09))
            .contentShape(Rectangle())
            .contextMenu {
                Menu("Move to space") {
                    ForEach(Array(shell.spaceNames.enumerated()), id: \.0) { i, name in
                        Button(name) { shell.move(port, toSpace: i) }.disabled(i == port.space)
                    }
                }
                Button(floating ? "Dock back" : "Pop out") { popToggle() }
                Divider()
                Button("Close", role: .destructive) { shell.close(port) }
            }

            ZStack {
                if inOverlay {
                    VStack(spacing: 6) {
                        Image(systemName: floating ? "macwindow.on.rectangle" : "viewfinder").font(.system(size: 24)).foregroundStyle(P42.dim)
                        Text(floating ? "floating — click to focus" : "focused — Esc to return").font(P42.mono(10)).foregroundStyle(P42.dim)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.5))
                    .onTapGesture { if floating { shell.panels[port.id]?.makeKeyAndOrderFront(nil) } else { withAnimation { shell.focusId = port.id } } }
                } else {
                    AdoptingHost(id: port.id, html: port.html)
                }
            }.frame(width: w, height: h)
        }
        .frame(width: w)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isTop ? P42.accent.opacity(0.7) : P42.accent.opacity(0.25), lineWidth: 1))
        .shadow(color: P42.accent.opacity(isTop ? 0.3 : 0.12), radius: isTop ? 22 : 12)
        .scaleEffect(exposeFrame != nil ? min(exposeFrame!.width / w, exposeFrame!.height / h) : 1, anchor: .center)
        .position(exposeFrame?.origin ?? CGPoint(x: port.pos.x, y: port.pos.y))
        .zIndex(Double(port.z))
        .onTapGesture {
            if shell.expose { withAnimation { shell.expose = false }; shell.focus(port) }
            else { shell.focus(port) }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: exposeFrame?.origin)
    }
    var isTop: Bool { shell.current.max(by: { $0.z < $1.z })?.id == port.id }

    func popToggle() {
        if port.presentation == .tiled { popOut() } else { dockBack() }
    }
    func popOut() {
        port.presentation = .floating
        DispatchQueue.main.async {
            let w = Registry.shared.web(port.id, html: port.html)
            let screen = NSScreen.main!.frame
            let sz = NSSize(width: port.size.width + 16, height: port.size.height + 36)
            let panel = PopoutPanel(contentRect: NSRect(x: screen.midX - 100, y: screen.midY - 80, width: sz.width, height: sz.height),
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = port.title
            panel.titlebarAppearsTransparent = true
            panel.backgroundColor = NSColor.black
            panel.isFloatingPanel = true
            panel.level = .floating
            let host = NSView()
            w.removeFromSuperview(); host.addSubview(w)
            w.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([w.topAnchor.constraint(equalTo: host.topAnchor), w.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                w.leadingAnchor.constraint(equalTo: host.leadingAnchor), w.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
            panel.contentView = host
            panel.dockBack = { [weak port] in port?.presentation = .tiled; Shell.shared.panels[port?.id ?? UUID()] = nil }
            Shell.shared.panels[port.id] = panel
            panel.makeKeyAndOrderFront(nil)
        }
    }
    func dockBack() {
        if let panel = shell.panels[port.id] { panel.close() }   // triggers dockBack closure
    }
}

// MARK: - Command palette

struct Palette: View {
    @ObservedObject var shell = Shell.shared
    @State private var q = ""
    @FocusState private var focused: Bool
    var matches: [AppDef] { q.isEmpty ? Apps.all : Apps.all.filter { $0.label.lowercased().contains(q.lowercased()) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(P42.dim)
                TextField("run a port…", text: $q).textFieldStyle(.plain).font(P42.mono(15)).foregroundStyle(P42.text).focused($focused)
                .onSubmit { if let m = matches.first { shell.spawn(m); shell.showPalette = false } } }.padding(16)
            Divider().overlay(P42.accent.opacity(0.2))
            ForEach(Array(matches.enumerated()), id: \.0) { _, m in
                HStack(spacing: 12) { Image(systemName: m.icon).foregroundStyle(P42.accent).frame(width: 22)
                    Text(m.label).font(P42.mono(14)).foregroundStyle(P42.text); Spacer()
                    Text(m.title).font(P42.mono(11)).foregroundStyle(P42.dim) }
                .padding(.horizontal, 16).padding(.vertical, 11).contentShape(Rectangle())
                .onTapGesture { shell.spawn(m); shell.showPalette = false }
            }
        }.frame(width: 460)
        .background(Color(red:0.05,green:0.06,blue:0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(P42.accent.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.7), radius: 40).onAppear { focused = true }
    }
}

// MARK: - Dock

struct Dock: View {
    @ObservedObject var shell = Shell.shared
    var cursorX: CGFloat { shell.mouse.x * shell.screenW }
    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(shell.dockApps.enumerated()), id: \.0) { _, app in
                DockIcon(app: app, cursorX: cursorX)
            }
        }.padding(.horizontal, 18).padding(.vertical, 10).frame(height: 74, alignment: .bottom)
        .animation(.spring(response: 0.3), value: shell.mode)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(P42.accent.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
    }
}

struct DockIcon: View {
    @ObservedObject var shell = Shell.shared
    let app: AppDef; let cursorX: CGFloat
    var body: some View {
        GeometryReader { g in
            let mid = g.frame(in: .global).midX
            let d = abs(cursorX - mid)
            let s = 1 + 0.7 * exp(-(d * d) / (2 * 70 * 70))   // gaussian magnification
            Button(action: { shell.spawn(app) }) {
                Image(systemName: app.icon).font(.system(size: 21, weight: .medium)).foregroundStyle(P42.accent)
                    .frame(width: 46, height: 46).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(P42.accent.opacity(0.3), lineWidth: 1))
                    .shadow(color: P42.accent.opacity(min(0.7, (s - 1) * 1.2)), radius: 14 * (s - 1) + 1)
                    .scaleEffect(s, anchor: .bottom)
            }.buttonStyle(.plain).help(app.label)
            .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
        }.frame(width: 46, height: 46)
    }
}

// MARK: - Boot overlay

struct Boot: View {
    @ObservedObject var shell = Shell.shared
    var body: some View {
        ZStack { Color.black
            VStack(alignment: .leading, spacing: 6) {
                Text("PORT42 // SHELL").font(P42.mono(22, .bold)).foregroundStyle(P42.accent).shadow(color: P42.accent, radius: 12)
                ForEach(shell.bootLines, id: \.self) { Text($0).font(P42.mono(13)).foregroundStyle(P42.dim) }
            }
        }.ignoresSafeArea().transition(.opacity)
    }
}

// MARK: - Space rail (the spaces inside the current mode)

struct SpaceRail: View {
    @ObservedObject var shell = Shell.shared
    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(shell.spaceNames.enumerated()), id: \.0) { i, name in
                let on = shell.space == i
                let count = shell.portsIn(shell.mode, i).count
                Button(action: { shell.switchSpace(i) }) {
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(on ? shell.accent.opacity(0.18) : Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(on ? shell.accent : P42.dim.opacity(0.4), lineWidth: on ? 1.5 : 1))
                            .frame(width: 44, height: 44)
                            .overlay(Text(name.prefix(1).uppercased()).font(P42.mono(16, .bold)).foregroundStyle(on ? shell.accent : P42.dim))
                            .shadow(color: on ? shell.accent.opacity(0.5) : .clear, radius: 10)
                        if count > 0 {
                            Text("\(count)").font(P42.mono(8, .bold)).foregroundStyle(.black)
                                .padding(3).background(on ? shell.accent : P42.dim, in: Circle()).offset(x: 6, y: -6)
                        }
                    }
                }.buttonStyle(.plain).help("\(name) — \(count) ports")
            }
            Button(action: { withAnimation { shell.showSpaces = true } }) {
                Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(P42.dim)
                    .frame(width: 44, height: 30).background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).help("Spaces overview (⌘E)")
        }
        .padding(8)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(shell.accent.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Spaces overview (zoom out to all spaces in the mode, each showing its ports)

struct SpacesOverview: View {
    @ObservedObject var shell = Shell.shared
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { withAnimation { shell.showSpaces = false } }
            VStack(spacing: 20) {
                HStack(spacing: 8) {
                    Circle().fill(shell.accent).frame(width: 7, height: 7)
                    Text("\(shell.modeDef.name.uppercased()) · SPACES").font(P42.mono(13, .bold)).foregroundStyle(shell.accent).tracking(3)
                }
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(shell.spaceNames.enumerated()), id: \.0) { i, name in
                        SpaceCard(index: i, name: name)
                    }
                    Button(action: { shell.say("spaces are fixed in this prototype") }) {
                        VStack(spacing: 8) { Image(systemName: "plus").font(.system(size: 20)); Text("new space").font(P42.mono(11)) }
                            .foregroundStyle(P42.dim).frame(width: 150, height: 170)
                            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(P42.dim.opacity(0.4)))
                    }.buttonStyle(.plain)
                }
            }
        }.transition(.opacity)
    }
}

struct SpaceCard: View {
    @ObservedObject var shell = Shell.shared
    let index: Int; let name: String
    var ports: [Port] { shell.portsIn(shell.mode, index) }
    var on: Bool { shell.space == index }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle().fill(on ? shell.accent : P42.dim).frame(width: 6, height: 6)
                Text(name).font(P42.mono(13, .bold)).foregroundStyle(P42.text)
                Spacer()
                Text("\(ports.count)").font(P42.mono(11)).foregroundStyle(P42.dim)
            }
            Divider().overlay(P42.dim.opacity(0.3))
            if ports.isEmpty {
                Spacer(); Text("empty").font(P42.mono(11)).foregroundStyle(P42.dim.opacity(0.6)).frame(maxWidth: .infinity); Spacer()
            } else {
                ForEach(ports.prefix(4)) { p in
                    HStack(spacing: 7) {
                        Image(systemName: p.icon).font(.system(size: 10)).foregroundStyle(shell.accent).frame(width: 14)
                        Text(p.title).font(P42.mono(10)).foregroundStyle(P42.text).lineLimit(1)
                    }
                }
                if ports.count > 4 { Text("+\(ports.count - 4) more").font(P42.mono(9)).foregroundStyle(P42.dim) }
                Spacer(minLength: 0)
            }
        }
        .padding(12).frame(width: 200, height: 170, alignment: .top)
        .background(Color(red: 0.05, green: 0.06, blue: 0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? shell.accent.opacity(0.7) : P42.accent.opacity(0.18), lineWidth: on ? 1.5 : 1))
        .shadow(color: on ? shell.accent.opacity(0.35) : .black.opacity(0.4), radius: on ? 20 : 10)
        .scaleEffect(on ? 1.04 : 1)
        .onTapGesture { shell.switchSpace(index) }
    }
}

// MARK: - Galaxy (zoom UP — all modes as worlds)

struct GalaxyView: View {
    @ObservedObject var shell = Shell.shared
    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea().onTapGesture { withAnimation { shell.galaxy = false } }
            VStack(spacing: 26) {
                Text("PORT42 · GALAXY").font(P42.mono(13, .bold)).foregroundStyle(P42.text).tracking(5)
                HStack(spacing: 44) {
                    ForEach(Array(shell.modes.enumerated()), id: \.0) { i, m in ModeWorld(index: i, mode: m) }
                }
                Text("a mode is a world · click to enter · ⌘↑ galaxy · ⌘↓ focus").font(P42.mono(10)).foregroundStyle(P42.dim)
            }
        }.transition(.scale(scale: 1.15).combined(with: .opacity))
    }
}

struct ModeWorld: View {
    @ObservedObject var shell = Shell.shared
    let index: Int; let mode: ModeDef
    var portCount: Int { shell.ports.filter { $0.mode == index }.count }
    var on: Bool { shell.mode == index }
    var body: some View {
        Button(action: { withAnimation(.spring(response: 0.5)) { shell.switchMode(index); shell.galaxy = false } }) {
            VStack(spacing: 14) {
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width/2, y: size.height/2)
                        ctx.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)),
                            with: .radialGradient(Gradient(colors: [mode.accent.opacity(0.55), mode.accent.opacity(0.04), .clear]),
                                center: c, startRadius: 0, endRadius: size.width/2))
                        let r = size.width * 0.26 + sin(t * 1.4 + Double(index)) * 4
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r*2, height: r*2)), with: .color(mode.accent.opacity(0.92)))
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r*2, height: r*2)), with: .color(.white.opacity(0.25)), lineWidth: 1)
                        // orbiting spaces (moons)
                        let n = mode.spaces.count
                        for s in 0..<n {
                            let a = t * 0.6 + Double(s) / Double(max(1, n)) * 6.283
                            let rr = size.width * 0.42
                            let mx = c.x + cos(a) * rr, my = c.y + sin(a) * rr * 0.46
                            let dot = shell.portsIn(index, s).count > 0 ? 8.0 : 5.0
                            ctx.fill(Path(ellipseIn: CGRect(x: mx - dot/2, y: my - dot/2, width: dot, height: dot)), with: .color(.white.opacity(0.9)))
                        }
                    }
                }.frame(width: 158, height: 158)
                Text(mode.name.uppercased()).font(P42.mono(13, .bold)).foregroundStyle(on ? mode.accent : P42.text).tracking(2)
                Text("\(mode.spaces.count) spaces · \(portCount) ports").font(P42.mono(10)).foregroundStyle(P42.dim)
            }
            .padding(18)
            .background(on ? mode.accent.opacity(0.08) : Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(on ? mode.accent.opacity(0.6) : P42.dim.opacity(0.25), lineWidth: on ? 1.5 : 1))
            .scaleEffect(on ? 1.05 : 1)
        }.buttonStyle(.plain)
    }
}

// MARK: - Focus (zoom DOWN — one port, immersive; same registry webview, no reload)

struct FocusOverlay: View {
    @ObservedObject var shell = Shell.shared
    let port: Port
    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea().onTapGesture { withAnimation(.spring(response: 0.4)) { shell.focusId = nil } }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(shell.accent).frame(width: 8, height: 8)
                    Text(port.title).font(P42.mono(12)).foregroundStyle(P42.text)
                    Text("· focus").font(P42.mono(10)).foregroundStyle(P42.dim)
                    Spacer()
                    Button(action: { withAnimation(.spring(response: 0.4)) { shell.focusId = nil } }) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11)).foregroundStyle(P42.dim)
                    }.buttonStyle(.plain).help("Exit focus (Esc)")
                }.padding(.horizontal, 16).padding(.vertical, 11).background(Color(red: 0.06, green: 0.07, blue: 0.09))
                AdoptingHost(id: port.id, html: port.html)
            }
            .frame(width: shell.screenW * 0.78, height: shell.screenH * 0.8)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(shell.accent.opacity(0.5), lineWidth: 1))
            .shadow(color: shell.accent.opacity(0.4), radius: 50)
        }.transition(.scale(scale: 0.82).combined(with: .opacity))
    }
}

// MARK: - Root

struct ShellView: View {
    @ObservedObject var shell = Shell.shared
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Dreamscape()
                // Layer 2 — chrome + ports, dissolve on idle
                Group {
                    VStack(spacing: 0) { Chrome(); Spacer() }
                    // Tiles in their OWN ZStack so their .zIndex(port.z) doesn't leak out of the
                    // flattening Group and paint over the overlays below.
                    ZStack {
                        ForEach(shell.current) { port in
                            Tile(port: port, exposeFrame: shell.expose ? exposeRect(port, in: geo.size) : nil)
                        }
                    }
                    // Space rail — the spaces inside this mode (left edge, vertically centered)
                    HStack { SpaceRail().padding(.leading, 14); Spacer() }
                    VStack { Spacer(); Dock().padding(.bottom, 24) }
                }
                .opacity(shell.idle ? 0 : 1)
                .allowsHitTesting(!shell.idle)
                if shell.showSpaces { SpacesOverview().zIndex(100) }
                if shell.galaxy { GalaxyView().zIndex(110) }
                if let fid = shell.focusId, let p = shell.ports.first(where: { $0.id == fid }) { FocusOverlay(port: p).zIndex(120) }
                // idle hint
                if shell.idle {
                    VStack { Spacer(); Text("PORT42 // move to wake").font(P42.mono(12)).foregroundStyle(P42.dim).padding(.bottom, 40) }
                        .transition(.opacity)
                }
                if let t = shell.toast {
                    VStack { Spacer()
                        Text(t).font(P42.mono(11)).foregroundStyle(P42.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.7), in: Capsule())
                            .overlay(Capsule().stroke(P42.accent.opacity(0.4), lineWidth: 1))
                            .padding(.bottom, 96)
                    }.transition(.move(edge: .bottom).combined(with: .opacity)).allowsHitTesting(false)
                }
                if shell.showPalette {
                    ZStack { Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { shell.showPalette = false }; Palette() }.transition(.opacity)
                }
                if shell.booting { Boot() }
            }
            .animation(.easeInOut(duration: 0.25), value: shell.showPalette)
            .animation(.easeInOut(duration: 0.5), value: shell.booting)
            .animation(.easeInOut(duration: 0.5), value: shell.space)
            .animation(.easeInOut(duration: 0.5), value: shell.mode)
            .animation(.easeInOut(duration: 0.25), value: shell.showSpaces)
            .animation(.spring(response: 0.4), value: shell.galaxy)
            .animation(.spring(response: 0.4), value: shell.focusId)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
    }
    func exposeRect(_ port: Port, in size: CGSize) -> CGRect {
        let items = shell.current
        let idx = items.firstIndex(where: { $0.id == port.id }) ?? 0
        let cols = Int(ceil(sqrt(Double(max(1, items.count)))))
        let rows = Int(ceil(Double(items.count) / Double(cols)))
        let top = 90.0
        let cw = size.width / Double(cols), ch = (size.height - top - 30) / Double(rows)
        let r = idx / cols, c = idx % cols
        return CGRect(x: cw * (Double(c) + 0.5), y: top + ch * (Double(r) + 0.5), width: cw * 0.82, height: ch * 0.82)
    }
}

// MARK: - Window + driver

final class KioskWindow: KioskBase { }
class KioskBase: NSWindow { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }

final class Delegate: NSObject, NSApplicationDelegate {
    var window: KioskWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.main!
        Shell.shared.screenW = screen.frame.width; Shell.shared.screenH = screen.frame.height
        // Clear the camera/notch. safeAreaInsets.top can read 0 once the menu bar is hidden, so
        // detect the notch via auxiliaryTopLeftArea (the menu-bar strip beside it) and floor at 38.
        let notched = screen.safeAreaInsets.top > 0 || screen.auxiliaryTopLeftArea != nil
        Shell.shared.notch = notched ? max(screen.safeAreaInsets.top, 38) : 0
        window = KioskWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = true; window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: ShellView())
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSApp.activate(ignoringOtherApps: true)

        installInput()
        runBoot()
        // idle watcher
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if !Shell.shared.idle && Date().timeIntervalSince(Shell.shared.lastInput) > 9 {
                withAnimation(.easeInOut(duration: 1.2)) { Shell.shared.idle = true }
            }
        }
    }
    func installInput() {
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]) { e in
            Shell.shared.bump()
            guard let cv = self.window.contentView else { return e }
            let lp = e.locationInWindow
            let pt = CGPoint(x: lp.x, y: cv.bounds.height - lp.y)   // top-left coords
            switch e.type {
            case .mouseMoved:
                Shell.shared.mouse = CGPoint(x: lp.x / cv.bounds.width, y: 1 - lp.y / cv.bounds.height)
                Shell.shared.hoverFocus(at: pt)
            case .leftMouseDown:  Shell.shared.mouseDown(at: pt)
            case .leftMouseDragged: if Shell.shared.mouseDragged(at: pt) { return nil }   // consume → move/resize
            case .leftMouseUp:    if Shell.shared.mouseUp() { return nil }                 // swallow the up that ended a drag
            default: break
            }
            return e
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            Shell.shared.bump()
            let cmd = e.modifierFlags.contains(.command)
            if e.keyCode == 53 { if !Shell.shared.unwind() { NSApp.terminate(nil) }; return nil }   // Esc peels a level / quits
            if cmd, e.keyCode == 126 { Shell.shared.zoomUp(); return nil }     // ⌘↑ → galaxy (UP)
            if cmd, e.keyCode == 125 { Shell.shared.zoomDown(); return nil }   // ⌘↓ → focus frontmost (DOWN)
            if e.keyCode == 48 { withAnimation { Shell.shared.expose.toggle() }; return nil }   // Tab
            if cmd, e.charactersIgnoringModifiers == "q" { NSApp.terminate(nil); return nil }
            if cmd, e.charactersIgnoringModifiers == "k" { Shell.shared.showPalette.toggle(); return nil }
            if cmd, e.charactersIgnoringModifiers == "l" { Shell.shared.arrange(); return nil }
            if cmd, e.charactersIgnoringModifiers == "e" { withAnimation { Shell.shared.showSpaces.toggle() }; return nil }
            if cmd, let d = e.charactersIgnoringModifiers, let i = Int(d), (1...3).contains(i) {
                Shell.shared.switchMode(i - 1); return nil
            }
            return e
        }
    }
    func runBoot() {
        let lines = ["▸ mounting space   port42://kiosk", "▸ WindowServer     attached (host: macOS)",
                     "▸ compositor       online", "▸ ports registry   ready", "▸ dreamscape       breathing",
                     "▸ companions       standing by", "▸ shell up. welcome back, gordon."]
        var i = 0
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
            if i < lines.count { Shell.shared.bootLines.append(lines[i]); i += 1 }
            else { t.invalidate(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation { Shell.shared.booting = false }
                Shell.shared.seed(0)   // home mode's default layout
            } }
        }
    }
    func applicationWillTerminate(_ n: Notification) { NSApp.presentationOptions = [] }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
