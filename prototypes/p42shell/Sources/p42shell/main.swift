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

enum Apps {
    // icon, label, title, html
    static let all: [(String, String, String, String)] = [
        ("clock",              "Clock",   "clock.port",  clock),
        ("waveform.path.ecg",  "Pulse",   "pulse.port",  pulse),
        ("cpu",                "System",  "sys.port",    sys),
        ("terminal",           "Shell",   "term.port",   term),
        ("circle.grid.cross",  "Matrix",  "matrix.port", matrix),
        ("sun.max",            "Synth",   "synth.port",  synth),
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
    let space: Int
    init(_ app: (String,String,String,String), pos: CGPoint, z: Int, space: Int) {
        icon = app.0; title = app.2; html = app.3; self.pos = pos; self.z = z; self.space = space
        size = CGSize(width: 380, height: 270)
    }
}

final class Shell: ObservableObject {
    static let shared = Shell()
    @Published var ports: [Port] = []
    @Published var space = 0
    @Published var showPalette = false
    @Published var expose = false
    @Published var booting = true
    @Published var bootLines: [String] = []
    @Published var idle = false
    @Published var mouse = CGPoint(x: 0.5, y: 0.5)   // normalized, for parallax
    var lastInput = Date()
    var zCounter = 10
    let spaces = ["home", "build", "deep"]
    var panels: [UUID: PopoutPanel] = [:]

    var current: [Port] { ports.filter { $0.space == space } }

    func spawn(_ app: (String,String,String,String), at: CGPoint? = nil) {
        zCounter += 1
        let n = ports.count
        let p = at ?? CGPoint(x: 360 + Double(n % 4) * 70, y: 220 + Double(n % 3) * 70)
        ports.append(Port(app, pos: p, z: zCounter, space: space))
    }
    func focus(_ p: Port) { zCounter += 1; p.z = zCounter }
    func close(_ p: Port) {
        panels[p.id]?.close()
        Registry.shared.drop(p.id)
        ports.removeAll { $0.id == p.id }
    }
    func bump() { lastInput = Date(); if idle { withAnimation(.easeOut(duration: 0.5)) { idle = false } } }
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
        TimelineView(.animation) { tl in
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
                    with: .radialGradient(Gradient(colors: [P42.accent.opacity(0.16 + 0.10*(1-b)), .clear]),
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
                    ctx.stroke(p, with: .color(P42.accent.opacity(0.05 + 0.18*f)), lineWidth: 1)
                }
                let cx = size.width/2 + px
                for i in -11...11 {
                    var p = Path(); p.move(to: CGPoint(x: cx + Double(i)*22, y: horizon)); p.addLine(to: CGPoint(x: cx + Double(i)*size.width/9, y: size.height))
                    ctx.stroke(p, with: .color(P42.accent.opacity(0.06)), lineWidth: 1)
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
            Spacer()
            // virtual spaces switcher
            HStack(spacing: 8) {
                ForEach(Array(shell.spaces.enumerated()), id: \.0) { i, name in
                    Button(action: { withAnimation(.spring(response:0.3)) { shell.space = i } }) {
                        Text(name).font(P42.mono(11, shell.space == i ? .bold : .regular))
                            .foregroundStyle(shell.space == i ? P42.accent : P42.dim)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(shell.space == i ? P42.accent.opacity(0.12) : .clear, in: Capsule())
                            .overlay(Capsule().stroke(shell.space == i ? P42.accent.opacity(0.5) : .clear, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            // status cluster moved up from ContentView.swift:185
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
    @State private var drag = CGSize.zero
    @State private var resz = CGSize.zero

    var body: some View {
        let floating = port.presentation == .floating
        let w = max(240, port.size.width + resz.width), h = max(150, port.size.height + resz.height)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(floating ? P42.dim : P42.accent).frame(width: 7, height: 7)
                Text(port.title).font(P42.mono(11)).foregroundStyle(P42.text)
                Spacer()
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
            .gesture(DragGesture().onChanged { drag = $0.translation }
                .onEnded { v in port.pos.x += v.translation.width; port.pos.y += v.translation.height; drag = .zero })

            ZStack {
                if floating {
                    VStack(spacing: 6) {
                        Image(systemName: "macwindow.on.rectangle").font(.system(size: 24)).foregroundStyle(P42.dim)
                        Text("floating — click to focus").font(P42.mono(10)).foregroundStyle(P42.dim)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.5))
                    .onTapGesture { shell.panels[port.id]?.makeKeyAndOrderFront(nil) }
                } else {
                    AdoptingHost(id: port.id, html: port.html)
                }
                // resize handle
                if !floating && exposeFrame == nil {
                    VStack { Spacer(); HStack { Spacer()
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9)).foregroundStyle(P42.dim.opacity(0.6)).padding(4)
                        .gesture(DragGesture().onChanged { resz = $0.translation }
                            .onEnded { _ in port.size.width = w; port.size.height = h; resz = .zero }) } }
                }
            }.frame(width: w, height: h)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isTop ? P42.accent.opacity(0.7) : P42.accent.opacity(0.25), lineWidth: 1))
        .shadow(color: P42.accent.opacity(isTop ? 0.3 : 0.12), radius: isTop ? 22 : 12)
        .scaleEffect(exposeFrame != nil ? min(exposeFrame!.width / w, exposeFrame!.height / h) : 1, anchor: .center)
        .position(exposeFrame?.origin ?? CGPoint(x: port.pos.x + drag.width, y: port.pos.y + drag.height))
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
            let sz = NSSize(width: 420, height: 320)
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
    var matches: [(String,String,String,String)] { q.isEmpty ? Apps.all : Apps.all.filter { $0.1.lowercased().contains(q.lowercased()) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(P42.dim)
                TextField("run a port…", text: $q).textFieldStyle(.plain).font(P42.mono(15)).foregroundStyle(P42.text).focused($focused)
                .onSubmit { if let m = matches.first { shell.spawn(m); shell.showPalette = false } } }.padding(16)
            Divider().overlay(P42.accent.opacity(0.2))
            ForEach(matches, id: \.1) { m in
                HStack(spacing: 12) { Image(systemName: m.0).foregroundStyle(P42.accent).frame(width: 22)
                    Text(m.1).font(P42.mono(14)).foregroundStyle(P42.text); Spacer()
                    Text(m.2).font(P42.mono(11)).foregroundStyle(P42.dim) }
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
    @State private var hover: String?
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Apps.all, id: \.1) { app in
                Button(action: { shell.spawn(app) }) {
                    Image(systemName: app.0).font(.system(size: 21, weight: .medium)).foregroundStyle(P42.accent)
                        .frame(width: 50, height: 50).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(P42.accent.opacity(0.3), lineWidth: 1))
                        .scaleEffect(hover == app.1 ? 1.2 : 1).shadow(color: hover == app.1 ? P42.accent.opacity(0.6) : .clear, radius: 12)
                }.buttonStyle(.plain).onHover { hover = $0 ? app.1 : (hover == app.1 ? nil : hover) }
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover).help(app.1)
            }
        }.padding(.horizontal, 18).padding(.vertical, 11)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(P42.accent.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
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
                    ForEach(shell.current) { port in
                        Tile(port: port, exposeFrame: shell.expose ? exposeRect(port, in: geo.size) : nil)
                    }
                    VStack { Spacer(); Dock().padding(.bottom, 24) }
                }
                .opacity(shell.idle ? 0 : 1)
                .allowsHitTesting(!shell.idle)
                // idle hint
                if shell.idle {
                    VStack { Spacer(); Text("PORT42 // move to wake").font(P42.mono(12)).foregroundStyle(P42.dim).padding(.bottom, 40) }
                        .transition(.opacity)
                }
                if shell.showPalette {
                    ZStack { Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { shell.showPalette = false }; Palette() }.transition(.opacity)
                }
                if shell.booting { Boot() }
            }
            .animation(.easeInOut(duration: 0.25), value: shell.showPalette)
            .animation(.easeInOut(duration: 0.5), value: shell.booting)
            .animation(.easeInOut(duration: 0.5), value: shell.space)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
    }
    func exposeRect(_ port: Port, in size: CGSize) -> CGRect {
        let items = shell.current
        let idx = items.firstIndex(where: { $0.id == port.id }) ?? 0
        let cols = Int(ceil(sqrt(Double(max(1, items.count)))))
        let rows = Int(ceil(Double(items.count) / Double(cols)))
        let cw = size.width / Double(cols), ch = (size.height - 120) / Double(rows)
        let r = idx / cols, c = idx % cols
        return CGRect(x: cw * (Double(c) + 0.5), y: 90 + ch * (Double(r) + 0.5), width: cw * 0.82, height: ch * 0.82)
    }
}

// MARK: - Window + driver

final class KioskWindow: KioskBase { }
class KioskBase: NSWindow { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }

final class Delegate: NSObject, NSApplicationDelegate {
    var window: KioskWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.main!
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
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel]) { e in
            Shell.shared.bump()
            if e.type == .mouseMoved, let cv = self.window.contentView {
                let p = e.locationInWindow
                Shell.shared.mouse = CGPoint(x: p.x / cv.bounds.width, y: 1 - p.y / cv.bounds.height)
            }
            return e
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            Shell.shared.bump()
            let cmd = e.modifierFlags.contains(.command)
            if e.keyCode == 53 { if Shell.shared.showPalette { Shell.shared.showPalette = false; return nil }
                                 if Shell.shared.expose { withAnimation { Shell.shared.expose = false }; return nil }
                                 NSApp.terminate(nil); return nil }
            if e.keyCode == 48 { withAnimation { Shell.shared.expose.toggle() }; return nil }   // Tab
            if cmd, e.charactersIgnoringModifiers == "q" { NSApp.terminate(nil); return nil }
            if cmd, e.charactersIgnoringModifiers == "k" { Shell.shared.showPalette.toggle(); return nil }
            if cmd, let d = e.charactersIgnoringModifiers, let i = Int(d), (1...3).contains(i) {
                withAnimation { Shell.shared.space = i - 1 }; return nil
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
                Shell.shared.spawn(Apps.all[0]); Shell.shared.spawn(Apps.all[1])
                Shell.shared.space = 1; Shell.shared.spawn(Apps.all[4]); Shell.shared.spawn(Apps.all[2]); Shell.shared.space = 0
            } }
        }
    }
    func applicationWillTerminate(_ n: Notification) { NSApp.presentationOptions = [] }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
