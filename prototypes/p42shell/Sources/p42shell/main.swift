// PORT42 // SHELL — rev 8. Throwaway fullscreen GUI-shell prototype.
// Design captured for production in docs/spec-shell-reimplementation.md.
//
// A SPACE IS A ROOM — people + companions + the desktop their conversation produces:
//   • ONE ambient surface: dreamscape = screensaver = desktop. Idle dissolves chrome+ports into it.
//   • Ports are registry-owned WKWebViews, re-parented with NO reload between hosts:
//     TILED (desktop) ↔ FLOATING (pop-out NSPanel) ↔ PARKED (right-edge minimize dock).
//   • CHAT IS A PORT: each space has a native chat tile (mirrors the real isChatPort) with a MEMBER
//     header — you + the space's companions — and live companion status.
//   • COMPANIONS are a primitive of the SPACE (not chrome): in the chat member row + each galaxy
//     world; one companion can belong to several spaces.
//   • THE LOOP: type → a companion thinks → PORTS → tiles appear, it replies, desktop auto-arranges.
//   • ONE FLAT LEVEL — spaces (no modes). Each has its own accent, dock, companions, chat.
//
// NAV/LAYOUT:
//   • ZOOM LADDER: galaxy (all spaces) → space → focus (one port). ⌘↑/↓ or PINCH (one rung/squeeze);
//     in galaxy, HOVER a world + pinch-in / ⌘↓ dives in. Galaxy grid responsive (max 3 across).
//   • TWO DOCKS: bottom launcher CREATES ports; right-edge rail PARKS (drag a tile in / click to restore).
//   • EXPOSÉ (Tab), drag+resize, z-order, arrange (⌘L, auto on every open).
//
// EXITS (never trapped):  Esc  ·  ⌘Q  ·  ⏻ top-right.
// Keys:  ⌘K palette · ⌘J chat · Tab exposé · ⌘1…7 spaces · ⌘↑/↓ or pinch zoom · ⌘L arrange

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
        w.allowsMagnification = false   // pinch drives the shell zoom ladder, not webview zoom
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

// MARK: - Companions & chat (rev3)

enum CStatus { case idle, thinking, porting }

/// A companion is a SPACE member — it inhabits one or more spaces (keyed "mode-space") and populates
/// their desktops. Reference type so its live status can be observed by the Chrome dot + the chat
/// typing row independently (and so the SAME companion shared across spaces shares one status).
final class Companion: Identifiable, ObservableObject {
    let id = UUID()
    let name: String; let color: Color; let glyph: String
    let spaces: Set<String>                 // the space NAMES this companion belongs to — can be several
    @Published var status: CStatus = .idle
    init(_ name: String, _ color: Color, _ glyph: String, _ spaces: [String]) {
        self.name = name; self.color = color; self.glyph = glyph; self.spaces = Set(spaces)
    }
}

struct ChatMsg: Identifiable { let id = UUID(); let who: String; let color: Color; let text: String; let isUser: Bool }

enum PortKind { case web, chat }

// MARK: - Model

enum Presentation { case tiled, floating, parked }   // parked = minimized to the right-edge dock

final class Port: Identifiable, ObservableObject {
    let id = UUID()
    let icon: String; let title: String; let html: String
    @Published var pos: CGPoint
    @Published var size: CGSize
    @Published var z: Int
    @Published var presentation: Presentation = .tiled
    @Published var space: Int
    let isTerminal: Bool
    let kind: PortKind
    let tint: Color
    init(_ app: AppDef, pos: CGPoint, z: Int, space: Int) {
        icon = app.icon; title = app.title; html = app.html; self.pos = pos; self.z = z; self.space = space
        size = app.size; isTerminal = app.terminal; kind = .web; tint = P42.accent
    }
    // rev3: a chat port — a native conversation surface, not a webview. "chat is just a port."
    init(chatPos pos: CGPoint, z: Int, space: Int, tint: Color) {
        icon = "bubble.left.and.bubble.right"; title = "chat"; html = ""; self.pos = pos; self.z = z
        self.space = space; size = CGSize(width: 400, height: 384)
        isTerminal = false; kind = .chat; self.tint = tint
    }
    // Terminal + chat bodies are interactive (select / scroll / type) — move via titlebar only.
    var interactiveBody: Bool { isTerminal || kind == .chat }
}

// rev6: ONE flat level. A SPACE is a room — its own accent, dock, companions, ports and chat.
// (Modes are gone: a "mode" was just a meta-space, a second hierarchy that cost more than it gave.)
struct SpaceDef {
    let name: String
    let accent: Color
    let dock: [Int]    // indices into Apps.all — this space's dock
    let seed: [Int]    // app indices seeded on first entry — the space's default layout
}

final class Shell: ObservableObject {
    static let shared = Shell()
    @Published var ports: [Port] = []
    @Published var space = 0
    @Published var showPalette = false
    @Published var expose = false
    @Published var galaxy = false                // all-spaces constellation (zoom UP)
    @Published var focusId: UUID? = nil          // immersive single port (zoom DOWN)
    @Published var selectedId: UUID? = nil       // the highlighted port (hover/click) — zoom DOWN targets it
    @Published var galaxyHover: Int? = nil       // which space-world the mouse is over in galaxy (zoom-in enters it)
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

    // rev6: ONE flat level — spaces. Each carries its own accent + dock + companions + chat.
    let spaces: [SpaceDef] = [
        SpaceDef(name: "main",  accent: P42.accent,                                dock: [0,1,5], seed: [0,1]),
        SpaceDef(name: "music", accent: Color(red: 1.0,  green: 0.42, blue: 0.70), dock: [5,1],   seed: [5]),
        SpaceDef(name: "api",   accent: P42.gold,                                  dock: [3,2,4], seed: [3,2]),
        SpaceDef(name: "ui",    accent: Color(red: 0.40, green: 0.78, blue: 1.0),  dock: [4,1,3], seed: [4]),
        SpaceDef(name: "infra", accent: Color(red: 0.45, green: 0.90, blue: 0.55), dock: [2,3],   seed: [2]),
        SpaceDef(name: "read",  accent: P42.accent2,                               dock: [4,1],   seed: [4]),
        SpaceDef(name: "write", accent: Color(red: 0.30, green: 0.85, blue: 0.80), dock: [1,0],   seed: [1]),
    ]
    // Companions are SPACE members (by name). Some belong to several spaces — Echo→main+music,
    // Nova→music+ui, Forge→api+infra, Bit→api+ui, Sage→read+write.
    let roster: [Companion] = [
        Companion("Echo",  P42.accent,                                "waveform",     ["main", "music"]),
        Companion("Iris",  Color(red: 1.0,  green: 0.42, blue: 0.70), "eye",          ["main"]),
        Companion("Nova",  P42.gold,                                  "sparkles",     ["music", "ui"]),
        Companion("Forge", P42.gold,                                  "hammer.fill",  ["api", "infra"]),
        Companion("Bit",   Color(red: 0.40, green: 0.78, blue: 1.0),  "cpu",          ["api", "ui"]),
        Companion("Patch", Color(red: 0.45, green: 0.90, blue: 0.55), "bandage.fill", ["infra"]),
        Companion("Sage",  P42.accent2,                               "book.closed",  ["read", "write"]),
        Companion("Vale",  Color(red: 0.30, green: 0.85, blue: 0.80), "leaf",         ["write"]),
    ]
    @Published var chat: [String: [ChatMsg]] = [:]
    var spaceDef: SpaceDef { spaces[space] }
    var accent: Color { spaceDef.accent }
    var dockApps: [AppDef] { spaceDef.dock.map { Apps.all[$0] } }
    var spaceNames: [String] { spaces.map { $0.name } }
    var crew: [Companion] { crewIn(space) }
    func crewIn(_ s: Int) -> [Companion] { roster.filter { $0.spaces.contains(spaces[s].name) } }
    var chatKey: String { chatKey(space) }
    func chatKey(_ s: Int) -> String { "\(s)" }

    var current: [Port] { ports.filter { $0.space == space } }
    func portsIn(_ s: Int) -> [Port] { ports.filter { $0.space == s } }
    var frontmost: Port? { current.max(by: { $0.z < $1.z }) }

    // rev8: parking dock on the right edge. A parked port is minimized off the desktop into a
    // right-edge rail (presentation:.parked); its registry webview stays alive (no reload on restore).
    var parkWidth: CGFloat { max(64, screenW * 0.05) }
    @Published var draggingOverPark = false
    var desktopTiles: [Port] { current.filter { $0.presentation != .parked } }   // what the desktop renders + arranges
    var parkedPorts: [Port] { current.filter { $0.presentation == .parked } }
    func park(_ p: Port) {
        withAnimation(.spring(response: 0.35)) { p.presentation = .parked }
        arrange(quiet: true)
        say("parked \(p.title)")
    }
    func unpark(_ p: Port) {
        withAnimation(.spring(response: 0.35)) { p.presentation = .tiled }
        focus(p)
        arrange(quiet: true)
        say("restored \(p.title)")
    }
    /// The highlighted port zoom-down targets: the selection if it's in the current space, else frontmost.
    var selectedPort: Port? { current.first(where: { $0.id == selectedId }) ?? frontmost }

    // Zoom ladder:  GALAXY (all spaces) · EXPOSÉ · DESKTOP · FOCUS.
    // ⌘↑ / pinch-out step UP toward galaxy; ⌘↓ / pinch-in step DOWN toward a single focused port.
    func zoomUp() {
        withAnimation(.spring(response: 0.45)) {
            if focusId != nil { focusId = nil }           // focus → desktop
            else if expose { expose = false }             // exposé → desktop
            else if !galaxy { galaxy = true; galaxyHover = nil }   // desktop → galaxy
        }
    }
    func zoomDown() {
        // In galaxy, zoom-IN enters the space the mouse is over (mouseover + ⌘↓ / pinch-in).
        if galaxy {
            if let h = galaxyHover, h != space { switchSpace(h) }   // enter the HOVERED space
            else { withAnimation(.spring(response: 0.45)) { galaxy = false } }   // none hovered → current space
            return
        }
        withAnimation(.spring(response: 0.45)) {
            if expose { expose = false }                  // exposé → desktop
            else if focusId == nil, let p = selectedPort { focusId = p.id }  // desktop → focus the HIGHLIGHTED port
        }
    }

    // Trackpad pinch drives the same ladder: spread (zoom IN) steps down, pinch (zoom OUT) steps up.
    // ONE rung per gesture — a single squeeze moves exactly one level (was firing several rungs in
    // one continuous pinch, rocketing galaxy→space→focus). Release and pinch again to go further.
    var pinchAccum: CGFloat = 0
    var pinchFired = false
    func pinch(_ delta: CGFloat, phase: NSEvent.Phase) {
        if phase == .began { pinchAccum = 0; pinchFired = false }
        guard !pinchFired else { return }
        pinchAccum += delta
        let threshold: CGFloat = 0.32
        if pinchAccum > threshold { pinchFired = true; zoomDown() }        // spread → in → down one rung
        else if pinchAccum < -threshold { pinchFired = true; zoomUp() }    // pinch → out → up one rung
    }
    @discardableResult func unwind() -> Bool {     // Esc peels one zoom level; false = nothing left → quit
        if focusId != nil { withAnimation(.spring(response: 0.4)) { focusId = nil }; return true }
        if galaxy { withAnimation { galaxy = false }; return true }
        if expose { withAnimation { expose = false }; return true }
        if showPalette { showPalette = false; return true }
        return false
    }

    func switchSpace(_ s: Int) {
        guard s != space, spaces.indices.contains(s) else { return }
        seed(s)
        withAnimation(.spring(response: 0.35)) { space = s; expose = false; galaxy = false; selectedId = nil }
        say("space · \(spaceNames[s])")
    }
    func seed(_ s: Int) {
        guard !seeded.contains(s) else { return }
        seeded.insert(s)
        for app in spaces[s].seed { spawn(Apps.all[app], space: s, quiet: true) }
        // every space gets a chat tile (chat is just a port) + a greeting from its own crew.
        let spaceCrew = crewIn(s)
        let tint = spaceCrew.first?.color ?? P42.accent
        zCounter += 1
        ports.append(Port(chatPos: CGPoint(x: 240, y: 250), z: zCounter, space: s, tint: tint))
        if let c = spaceCrew.first {
            let others = spaceCrew.dropFirst().map { $0.name }.joined(separator: ", ")
            let hello = others.isEmpty
                ? "‘\(spaces[s].name)’ ready. ask me to open something — e.g. “open a clock and a system monitor”."
                : "‘\(spaces[s].name)’ ready — \(c.name) here with \(others). ask any of us to open something."
            chat[chatKey(s)] = [ChatMsg(who: c.name, color: c.color, text: hello, isUser: false)]
        }
    }

    // MARK: Chat + companion loop (rev3)

    func focusChat() {
        if let chatPort = current.first(where: { $0.kind == .chat }) {
            withAnimation(.spring(response: 0.4)) { galaxy = false; expose = false; focusId = chatPort.id }
        }
    }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let key = chatKey
        chat[key, default: []].append(ChatMsg(who: "you", color: P42.text, text: text, isUser: true))
        respond(to: text.lowercased(), in: key)
    }

    // Scripted companion behaviour: think → maybe open tiles → reply. A prototype stand-in for the
    // real loop (companion calls port.create); here it shows the magic: a message arranges the desktop.
    private func respond(to lower: String, in key: String) {
        let comp = crew.first(where: { lower.contains("@" + $0.name.lowercased()) }) ?? crew.first
        guard let comp else { return }
        withAnimation { comp.status = .thinking }
        let opens = parseOpen(lower)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if opens.isEmpty {
                comp.status = .idle
                self.chat[key, default: []].append(ChatMsg(who: comp.name, color: comp.color, text: self.smalltalk(lower, comp), isUser: false))
            } else {
                withAnimation { comp.status = .porting }
                for (i, app) in opens.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(i)) { self.spawn(app) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(opens.count) + 0.3) {
                    comp.status = .idle
                    let names = opens.map { $0.title }.joined(separator: " · ")
                    self.chat[key, default: []].append(ChatMsg(who: comp.name, color: comp.color, text: "opened \(names) on the desktop.", isUser: false))
                    self.arrange()
                }
            }
        }
    }

    private func parseOpen(_ s: String) -> [AppDef] {
        if s.contains("everything") || s.contains("dashboard") { return [Apps.all[0], Apps.all[2], Apps.all[1]] }
        var out: [AppDef] = []
        if s.contains("clock") || s.contains("time")   { out.append(Apps.all[0]) }
        if s.contains("pulse")                          { out.append(Apps.all[1]) }
        if s.contains("system") || s.contains("monitor") || s.contains("cpu") { out.append(Apps.all[2]) }
        if s.contains("shell") || s.contains("terminal") { out.append(Apps.all[3]) }
        if s.contains("matrix")                         { out.append(Apps.all[4]) }
        if s.contains("synth") || s.contains("music")   { out.append(Apps.all[5]) }
        return out
    }

    private func smalltalk(_ s: String, _ c: Companion) -> String {
        if s.contains("hello") || s.contains("hey") || s.hasPrefix("hi") { return "hey — I'm \(c.name). ask me to open a clock, a system monitor, a terminal…" }
        if s.contains("arrange") || s.contains("tidy") { arrange(); return "tidied the desktop." }
        if s.contains("who")   { return "I'm \(c.name), companion for ‘\(spaceNames[space])’." }
        if s.contains("thank") { return "anytime." }
        return "try: “open a clock and a system monitor”, or “@\(c.name) show me the matrix”."
    }

    func spawn(_ app: AppDef, at: CGPoint? = nil, space s: Int? = nil, quiet: Bool = false) {
        let ss = s ?? space
        zCounter += 1
        let n = portsIn(ss).count
        let p = at ?? CGPoint(x: 330 + Double(n % 4) * 90, y: 200 + Double(n % 3) * 80)
        ports.append(Port(app, pos: p, z: zCounter, space: ss))
        if !quiet {
            say("opened \(app.title)")
            arrange(quiet: true)   // user-initiated opens (dock / palette / chat) tidy the desktop; seeding stays quiet
        }
    }
    func focus(_ p: Port) { zCounter += 1; p.z = zCounter; selectedId = p.id }

    var interactive: Bool { !expose && !galaxy && !showPalette && !booting && focusId == nil && !idle }
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
        // Terminal/chat exception: the body is for text selection / typing, not moving. Move via
        // titlebar, resize via edges.
        let inTitlebar = pt.y < tileRect(h.port).minY + 32
        if h.port.interactiveBody && !h.edge && !inTitlebar { dragId = nil; return }
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
            // rev8: dragging a tile into the right-edge strip arms the parking dock (drop = minimize).
            draggingOverPark = (pt.x > screenW - parkWidth)
        }
        return true   // consume → don't leak the drag into the webview
    }
    func mouseUp() -> Bool {
        let armed = dragArmed
        // rev8: released over the parking strip → minimize the dragged tile into the right dock.
        if draggingOverPark, let id = dragId, let p = ports.first(where: { $0.id == id }), p.presentation == .tiled {
            park(p)
        }
        draggingOverPark = false
        dragId = nil; dragArmed = false
        return armed
    }
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
    func arrange(quiet: Bool = false) {
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
        if !quiet { say("arranged \(items.count)") }
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
            // rev7: ONE unit — the magic (galaxy) icon + active space name locked together. Toggles
            // the all-spaces galaxy. (The separate galaxy button is gone; this is the only way up.)
            Button(action: { withAnimation { if shell.galaxy { shell.unwind() } else { shell.zoomUp() } } }) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(shell.galaxy ? shell.accent : shell.accent.opacity(0.9))
                    Text(shell.spaceNames[shell.space]).font(P42.mono(12, .bold)).foregroundStyle(P42.text)
                }
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(shell.accent.opacity(shell.galaxy ? 0.2 : 0.12), in: Capsule())
                .overlay(Capsule().stroke(shell.accent.opacity(shell.galaxy ? 0.7 : 0.4), lineWidth: 1))
            }.buttonStyle(.plain).help("\(shell.spaceNames[shell.space]) — all spaces (⌘↑ / pinch out)")
            // rev7.2: desktop-layout controls sit WITH the space — arrange (tidy into a grid) + exposé.
            // rev7.3: give them a real 26×26 hit target (bare glyphs were finicky to click).
            Button(action: { shell.arrange() }) {
                Image(systemName: "rectangle.3.group").font(.system(size: 12)).foregroundStyle(P42.dim)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Arrange (⌘L)")
            Button(action: { withAnimation { shell.expose.toggle() } }) {
                Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(shell.expose ? P42.accent : P42.dim)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Exposé (Tab)")
            Spacer()
            // rev5: companions are NOT here anymore — they live IN the space (the chat tile's member
            // header). The chrome holds only global app status, not who's in a space.
            // status cluster moved up from ContentView.swift:185
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

// rev5: member chips for the chat header — companions live IN the space, alongside you. People +
// agents in one room: "it's all about chat with companions."

/// You, as a member of the space.
struct MeChip: View {
    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(P42.text.opacity(0.14)).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(P42.text.opacity(0.4), lineWidth: 1))
                Image(systemName: "person.fill").font(.system(size: 8)).foregroundStyle(P42.text)
            }
            Text("you").font(P42.mono(10)).foregroundStyle(P42.text)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.white.opacity(0.05), in: Capsule())
    }
}

/// A companion member — glyph + name + live status (pulses when thinking/porting), observed live.
struct CompanionChip: View {
    @ObservedObject var c: Companion
    var body: some View {
        let active = c.status != .idle
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(c.color.opacity(0.20)).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(c.color.opacity(active ? 1 : 0.5), lineWidth: active ? 1.5 : 1))
                Image(systemName: c.glyph).font(.system(size: 8)).foregroundStyle(c.color)
            }
            Text(c.name).font(P42.mono(10)).foregroundStyle(active ? c.color : P42.text)
            if active { Text(c.status == .porting ? "ports" : "…").font(P42.mono(8)).foregroundStyle(P42.dim) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(active ? c.color.opacity(0.14) : Color.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().stroke(active ? c.color.opacity(0.5) : .clear, lineWidth: 1))
        .shadow(color: active ? c.color.opacity(0.4) : .clear, radius: active ? 5 : 0)
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
                } else if port.kind == .chat {
                    ChatTile(port: port)
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
    // The highlighted/selected port (what ⌘↓ zooms into) gets the bright border + glow.
    var isTop: Bool { shell.selectedPort?.id == port.id }

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

// rev6: a wrapping flow layout — members (and galaxy worlds) flow to as many rows as needed instead
// of overflowing a single horizontal line. (macOS 13+ Layout protocol.)
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxRowW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { maxRowW = max(maxRowW, x - spacing); x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        maxRowW = max(maxRowW, x - spacing)
        return CGSize(width: maxW == .infinity ? max(0, maxRowW) : maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Chat tile (rev3 — chat is just a port)

struct ChatTile: View {
    @ObservedObject var shell = Shell.shared
    let port: Port
    @State private var draft = ""
    @FocusState private var focused: Bool
    var key: String { shell.chatKey(port.space) }
    var msgs: [ChatMsg] { shell.chat[key] ?? [] }
    var crew: [Companion] { shell.crewIn(port.space) }

    var body: some View {
        VStack(spacing: 0) {
            // MEMBERS — people + agents in this space. Companions live HERE, in the conversation,
            // as a primitive of the space — not as global chrome status. Members WRAP to as many
            // rows as needed (rev6 — was a horizontal scroll that broke past a few companions).
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 10)).foregroundStyle(port.tint)
                    Text(shell.spaces[port.space].name).font(P42.mono(11, .bold)).foregroundStyle(P42.text)
                    Spacer()
                    Text("\(crew.count + 1) in this space").font(P42.mono(9)).foregroundStyle(P42.dim)
                }
                FlowLayout(spacing: 6) {
                    MeChip()
                    ForEach(crew) { CompanionChip(c: $0) }
                }
            }
            .padding(.horizontal, 11).padding(.top, 10).padding(.bottom, 8)
            .background(.black.opacity(0.30))
            .overlay(Rectangle().fill(port.tint.opacity(0.25)).frame(height: 1), alignment: .bottom)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(msgs) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.isUser ? "you" : m.who).font(P42.mono(9, .bold)).foregroundStyle(m.color)
                                Text(m.text).font(P42.mono(12)).foregroundStyle(P42.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading).id(m.id)
                        }
                        // live typing/porting rows — each observes its own companion
                        ForEach(shell.crewIn(port.space)) { c in CompanionStatusRow(c: c) }
                    }
                    .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                    .id("chatbottom")
                }
                .onChange(of: msgs.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chatbottom", anchor: .bottom) } }
            }
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(port.tint)
                TextField("message \(shell.crewIn(port.space).first?.name ?? "companions")…", text: $draft)
                    .textFieldStyle(.plain).font(P42.mono(12)).foregroundStyle(P42.text).focused($focused)
                    .onSubmit { shell.send(draft); draft = "" }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(.black.opacity(0.35))
            .overlay(Rectangle().fill(port.tint.opacity(0.25)).frame(height: 1), alignment: .top)
        }
        .background(Color(red: 0.04, green: 0.05, blue: 0.07))
    }
}

/// One companion's live status line in the chat (reactive — observes the companion, hides when idle).
struct CompanionStatusRow: View {
    @ObservedObject var c: Companion
    var body: some View {
        if c.status != .idle {
            HStack(spacing: 6) {
                Circle().fill(c.color).frame(width: 5, height: 5)
                    .opacity(0.6).overlay(Circle().stroke(c.color, lineWidth: 1))
                Text(c.status == .porting ? "\(c.name) is porting…" : "\(c.name) is thinking…")
                    .font(P42.mono(10)).foregroundStyle(P42.dim)
            }
        }
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

// MARK: - Parking dock (right edge — rev8)

/// The right-edge minimize rail. Drag a tile into the right ~5% strip to PARK it here (it becomes a
/// chip, registry webview kept alive); click a chip to RESTORE it to the desktop. Faint when idle,
/// glows as a drop target while a tile is dragged over it. Distinct from the bottom launcher, which
/// CREATES ports.
struct ParkRail: View {
    @ObservedObject var shell = Shell.shared
    @State private var hovering = false
    var parked: [Port] { shell.parkedPorts }
    var active: Bool { shell.draggingOverPark }        // a tile is being dragged over (drop target)
    var lit: Bool { active || hovering }               // drag-over OR plain mouseover → highlight
    var body: some View {
        let w = shell.parkWidth
        let bg: Color = active ? shell.accent.opacity(0.16)
            : (hovering ? Color.white.opacity(0.07) : Color.white.opacity(parked.isEmpty ? 0.015 : 0.035))
        let border: Color = active ? shell.accent.opacity(0.85)
            : (hovering ? shell.accent.opacity(0.45) : P42.dim.opacity(parked.isEmpty ? 0.12 : 0.25))
        return VStack(spacing: 9) {
            Image(systemName: active ? "tray.and.arrow.down.fill" : "tray")
                .font(.system(size: 13))
                .foregroundStyle(active ? shell.accent : (hovering ? P42.text : P42.dim.opacity(parked.isEmpty ? 0.5 : 0.9)))
            ForEach(parked) { p in
                Button(action: { shell.unpark(p) }) {
                    VStack(spacing: 3) {
                        Image(systemName: p.icon).font(.system(size: 15)).foregroundStyle(p.tint)
                            .frame(width: 42, height: 42)
                            .background(p.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.tint.opacity(0.45), lineWidth: 1))
                        Text(p.title).font(P42.mono(7)).foregroundStyle(P42.dim).lineLimit(1)
                    }
                    .frame(width: w - 12).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Restore \(p.title)")
            }
            Spacer()
        }
        .frame(width: w)
        .padding(.top, 14).padding(.bottom, 12)
        .background(bg)
        .overlay(Rectangle().fill(border).frame(width: lit ? 1.5 : 1), alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.2), value: lit)
        .animation(.spring(response: 0.3), value: parked.count)
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
        .animation(.spring(response: 0.3), value: shell.space)
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

// MARK: - Galaxy (zoom UP — all SPACES as worlds; rev6: spaces ARE the worlds now, no modes)

struct GalaxyView: View {
    @ObservedObject var shell = Shell.shared
    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea().onTapGesture { withAnimation { shell.galaxy = false } }
            GeometryReader { geo in
                // rev7: bigger tiles, MAX 3 across, responsive — fewer columns on a narrower screen.
                let avail = geo.size.width * 0.82
                let cols = max(1, min(3, Int(avail / 320)))
                let columns = Array(repeating: GridItem(.flexible(minimum: 200, maximum: 290), spacing: 22), count: cols)
                VStack(spacing: 20) {
                    Text("PORT42 · SPACES").font(P42.mono(13, .bold)).foregroundStyle(P42.text).tracking(5)
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(shell.spaces.indices, id: \.self) { i in SpaceWorld(index: i) }
                        }
                        .frame(maxWidth: avail)
                        .padding(.vertical, 6)
                    }
                    Text("a space is a room — people + companions · hover + ⌘↓ / pinch-in to dive in · ⌘1…7 jump")
                        .font(P42.mono(10)).foregroundStyle(P42.dim)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .padding(.vertical, 30)
            }
        }.transition(.scale(scale: 1.12).combined(with: .opacity))
    }
}

struct SpaceWorld: View {
    @ObservedObject var shell = Shell.shared
    let index: Int
    var def: SpaceDef { shell.spaces[index] }
    var portCount: Int { shell.portsIn(index).filter { $0.kind != .chat }.count }
    var crew: [Companion] { shell.crewIn(index) }
    var on: Bool { shell.space == index }
    var hovered: Bool { shell.galaxyHover == index }
    var hot: Bool { on || hovered }
    var body: some View {
        Button(action: {
            if index == shell.space { withAnimation { shell.galaxy = false } } else { shell.switchSpace(index) }
        }) {
            VStack(spacing: 13) {
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width/2, y: size.height/2)
                        ctx.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)),
                            with: .radialGradient(Gradient(colors: [def.accent.opacity(0.55), def.accent.opacity(0.04), .clear]),
                                center: c, startRadius: 0, endRadius: size.width/2))
                        let r = size.width * 0.26 + sin(t * 1.4 + Double(index)) * 4
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r*2, height: r*2)), with: .color(def.accent.opacity(0.92)))
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r*2, height: r*2)), with: .color(.white.opacity(0.25)), lineWidth: 1)
                        // orbiting ports (moons)
                        let n = max(portCount, 1)
                        for s in 0..<min(n, 8) {
                            let a = t * 0.6 + Double(s) / Double(n) * 6.283
                            let rr = size.width * 0.42
                            let mx = c.x + cos(a) * rr, my = c.y + sin(a) * rr * 0.46
                            ctx.fill(Path(ellipseIn: CGRect(x: mx - 3, y: my - 3, width: 6, height: 6)), with: .color(.white.opacity(0.9)))
                        }
                    }
                }.frame(width: 132, height: 132)
                Text(def.name.uppercased()).font(P42.mono(14, .bold)).foregroundStyle(hot ? def.accent : P42.text).tracking(2)
                // members — companions are a primitive of the space (visible even zoomed out)
                HStack(spacing: 4) {
                    Image(systemName: "person.fill").font(.system(size: 9)).foregroundStyle(P42.text.opacity(0.85))
                    ForEach(crew) { c in Image(systemName: c.glyph).font(.system(size: 9)).foregroundStyle(c.color) }
                }
                Text("\(portCount) ports · \(crew.count) companions").font(P42.mono(10)).foregroundStyle(P42.dim)
            }
            .padding(18).frame(maxWidth: .infinity)
            .background(hot ? def.accent.opacity(0.10) : Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(hot ? def.accent.opacity(0.7) : P42.dim.opacity(0.25), lineWidth: hot ? 1.5 : 1))
            .shadow(color: hovered ? def.accent.opacity(0.4) : .clear, radius: 16)
            .scaleEffect(hovered ? 1.04 : (on ? 1.02 : 1))
        }
        .buttonStyle(.plain)
        // rev7: hovering a world arms it — ⌘↓ / pinch-in then dives into THIS space.
        .onHover { h in shell.galaxyHover = h ? index : (shell.galaxyHover == index ? nil : shell.galaxyHover) }
        .animation(.spring(response: 0.3), value: hovered)
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
                if port.kind == .chat { ChatTile(port: port) } else { AdoptingHost(id: port.id, html: port.html) }
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
                        ForEach(shell.desktopTiles) { port in
                            Tile(port: port, exposeFrame: shell.expose ? exposeRect(port, in: geo.size) : nil)
                        }
                    }
                    // rev8: parking dock on the right edge (drag a tile here to minimize; click to restore).
                    // Inset below the Chrome bar so the strip never covers the header.
                    HStack(alignment: .top) { Spacer(); ParkRail() }.padding(.top, 48)
                    // rev7: spaces sidebar removed — galaxy (hover + dive / click) and ⌘1…7 switch spaces.
                    // bottom launcher = CREATE new ports (not switch); right dock = PARK existing ports.
                    VStack { Spacer(); Dock().padding(.bottom, 24) }
                }
                .opacity(shell.idle ? 0 : 1)
                .allowsHitTesting(!shell.idle)
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
            .animation(.spring(response: 0.4), value: shell.galaxy)
            .animation(.spring(response: 0.4), value: shell.focusId)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
    }
    func exposeRect(_ port: Port, in size: CGSize) -> CGRect {
        let items = shell.desktopTiles
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
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .magnify]) { e in
            Shell.shared.bump()
            // Pinch-zoom drives the ladder; consume it so webviews don't also zoom. No coords needed.
            if e.type == .magnify { Shell.shared.pinch(e.magnification, phase: e.phase); return nil }
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
            if cmd, e.charactersIgnoringModifiers == "j" { Shell.shared.focusChat(); return nil }   // ⌘J → chat
            if cmd, e.charactersIgnoringModifiers == "l" { Shell.shared.arrange(); return nil }
            // ⌘1…⌘7 jump straight to a space (rev6: spaces are the only level now)
            if cmd, let d = e.charactersIgnoringModifiers, let i = Int(d), Shell.shared.spaces.indices.contains(i - 1) {
                Shell.shared.switchSpace(i - 1); return nil
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
