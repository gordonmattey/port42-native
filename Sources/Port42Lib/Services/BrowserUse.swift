import AppKit
import WebKit

// MARK: - Browser use, Phase 2 (docs/plan-browser-use.md)
//
// A companion drives a browser port the person can see: it LOOKS (a picture of the page with every
// actionable element outlined and numbered, and the list of them), decides one step, and ACTS (a click,
// typing, a key, a scroll, a navigation), then looks again.
//
// How the input is delivered was measured first (spike, 2026-09-30, a WKWebView in a window):
// - A click is a mouse down and up sent to the web view: the page sees a trusted click. It makes the web
//   view first responder, so the responder is put back afterwards; the page keeps its own focus.
// - A key (Enter, Tab, Escape, arrows, a letter as a shortcut) is a key down and up sent to the web view:
//   trusted, and it reaches the page's focused element even when the web view is not first responder.
//   Sent back to back they are dropped, so they are spaced.
// - Text does not insert from key events unless the web view is first responder, which would take the
//   person's keyboard. `insertText` through the editing command does insert it, as trusted input.

/// Looking at a browser port: the element scan and the marked-up picture.
enum BrowserLook {

    /// The script world the scan runs in: the page cannot see it, call it, or change its numbering.
    static let world = WKContentWorld.world(name: "port42.look")

    /// One thing on the page a companion can act on.
    struct Element: Equatable {
        var n: Int
        var role: String
        var label: String
        /// In the page's CSS pixels, relative to the visible viewport.
        var x: Double, y: Double, w: Double, h: Double
        var type: String?
        var value: String?

        var bridgeValue: BridgeValue {
            var o: [String: BridgeValue] = ["n": .int(n), "role": .string(role), "label": .string(label),
                                            "box": .array([.double(x), .double(y), .double(w), .double(h)])]
            if let type { o["type"] = .string(type) }
            if let value { o["value"] = .string(value) }
            return .object(o)
        }
    }

    /// The most elements a look returns: a page with more is summarized by the first ones on screen.
    static let maxElements = 150
    /// The most page text a look returns.
    static let maxText = 6_000

    /// Finds what can be acted on in the visible viewport, numbers it, and keeps the numbering in this
    /// world for `port.act`. A password field's value is never returned.
    static let scanJS = """
    const sel = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],'
      + '[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=row],[role=switch],'
      + '[role=textbox],[role=combobox],[contenteditable=""],[contenteditable=true],[onclick]';
    const vw = window.innerWidth, vh = window.innerHeight;
    const seen = new Set(), marks = [], out = [];
    const clean = (s) => (s || '').replace(/\\s+/g, ' ').trim().slice(0, 80);
    for (const el of document.querySelectorAll(sel)) {
      if (out.length >= \(maxElements)) break;
      const r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2 || r.bottom <= 0 || r.right <= 0 || r.top >= vh || r.left >= vw) continue;
      const st = getComputedStyle(el);
      if (st.visibility === 'hidden' || st.display === 'none' || Number(st.opacity) === 0) continue;
      const cx = Math.min(Math.max(r.left + r.width / 2, 0), vw - 1), cy = Math.min(Math.max(r.top + r.height / 2, 0), vh - 1);
      const top = document.elementFromPoint(cx, cy);
      if (top && top !== el && !el.contains(top) && !top.contains(el)) continue;   // covered by something else
      let anc = el.parentElement, nested = false;
      while (anc) { if (seen.has(anc) && anc.tagName !== 'TR' && anc.getAttribute('role') !== 'row') { nested = true; break; } anc = anc.parentElement; }
      if (nested) continue;
      seen.add(el);
      const tag = el.tagName.toLowerCase();
      const type = tag === 'input' ? (el.type || 'text') : undefined;
      const labelled = el.getAttribute('aria-labelledby');
      const label = clean(el.getAttribute('aria-label'))
        || (labelled ? clean(labelled.split(' ').map(id => document.getElementById(id)?.innerText).join(' ')) : '')
        || clean(el.innerText) || clean(el.getAttribute('placeholder')) || clean(el.getAttribute('title'))
        || clean(el.getAttribute('alt')) || clean(el.getAttribute('name')) || (type === 'submit' ? clean(el.value) : '');
      const role = el.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'input' ? 'input' : tag);
      const e = { n: out.length + 1, role, label, x: r.left, y: r.top, w: r.width, h: r.height };
      if (type) e.type = type;
      if ((tag === 'input' || tag === 'textarea' || tag === 'select') && type !== 'password') e.value = clean(el.value);
      marks.push(el);
      out.push(e);
    }
    globalThis.__port42marks = marks;
    return { elements: out, text: (document.body ? document.body.innerText : '').slice(0, \(maxText)),
             url: location.href, title: document.title, vw, vh };
    """

    /// Parse what the scan returned. Pure.
    static func parse(_ raw: Any?) -> (elements: [Element], text: String) {
        guard let o = raw as? [String: Any] else { return ([], "") }
        let els = (o["elements"] as? [[String: Any]] ?? []).compactMap { e -> Element? in
            guard let n = (e["n"] as? NSNumber)?.intValue else { return nil }
            func d(_ k: String) -> Double { (e[k] as? NSNumber)?.doubleValue ?? 0 }
            return Element(n: n, role: e["role"] as? String ?? "", label: e["label"] as? String ?? "",
                           x: d("x"), y: d("y"), w: d("w"), h: d("h"),
                           type: e["type"] as? String, value: e["value"] as? String)
        }
        return (els, o["text"] as? String ?? "")
    }

    /// The page as a PNG at one pixel per point, each element outlined and numbered (set-of-marks), so a
    /// model can name what it means by number. `scale` turns CSS pixels into the image's pixels.
    static func markedPNG(_ page: NSImage, size: CGSize, elements: [Element], scale: Double) -> Data? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        page.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        let color = NSColor(calibratedRed: 1, green: 0.2, blue: 0.6, alpha: 1)
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        for e in elements {
            // The image's origin is bottom-left; the page's is top-left.
            let r = NSRect(x: e.x * scale, y: Double(h) - (e.y + e.h) * scale, width: e.w * scale, height: e.h * scale)
            color.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1.5
            path.stroke()
            let tag = NSAttributedString(string: " \(e.n) ", attributes: [.font: font, .foregroundColor: NSColor.white])
            let ts = tag.size()
            let tagRect = NSRect(x: max(0, r.minX), y: min(Double(h) - ts.height, r.maxY - ts.height), width: ts.width, height: ts.height)
            color.setFill()
            NSBezierPath(rect: tagRect).fill()
            tag.draw(at: tagRect.origin)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Where looks are written, one file per look, kept for the session.
    static var directory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("port42-looks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Acting on a browser port: one step, delivered as real input.
@MainActor
enum BrowserAct {

    /// The gap between input events: sent back to back, WebKit drops all but the first (measured).
    static let eventGap: UInt64 = 60_000_000

    /// A key by name, as `port.act` takes it, to its virtual key code and the characters it types. Pure.
    nonisolated static func key(_ name: String) -> (code: UInt16, chars: String)? {
        switch name.lowercased() {
        case "enter", "return": return (36, "\r")
        case "tab": return (48, "\t")
        case "escape", "esc": return (53, "\u{1b}")
        case "backspace", "delete": return (51, "\u{7f}")
        case "space": return (49, " ")
        case "up", "arrowup": return (126, "\u{F700}")
        case "down", "arrowdown": return (125, "\u{F701}")
        case "left", "arrowleft": return (123, "\u{F702}")
        case "right", "arrowright": return (124, "\u{F703}")
        case "pageup": return (116, "\u{F72C}")
        case "pagedown": return (121, "\u{F72D}")
        case "home": return (115, "\u{F729}")
        case "end": return (119, "\u{F72B}")
        default:
            // A single character is itself: a letter as a site's shortcut (Gmail's e, #, j, k).
            guard name.count == 1 else { return nil }
            return (0, name)
        }
    }

    /// Modifier names to flags. Pure.
    nonisolated static func modifiers(_ names: [String]) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for n in names.map({ $0.lowercased() }) {
            switch n {
            case "cmd", "command", "meta": f.insert(.command)
            case "shift": f.insert(.shift)
            case "alt", "option": f.insert(.option)
            case "ctrl", "control": f.insert(.control)
            default: break
            }
        }
        return f
    }

    /// A point in the page's CSS pixels to the web view's own coordinates (the view is flipped, so y
    /// runs down as in the page), allowing for the person's zoom. Pure.
    nonisolated static func viewPoint(cssX: Double, cssY: Double, magnification: Double) -> CGPoint {
        CGPoint(x: cssX * magnification, y: cssY * magnification)
    }

    static func click(_ wv: WKWebView, at p: CGPoint) async {
        guard let window = wv.window else { return }
        let before = window.firstResponder
        let wp = wv.convert(p, to: nil)
        func mouse(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let move = mouse(.mouseMoved) { wv.mouseMoved(with: move) }       // hover first, as a pointer would
        try? await Task.sleep(nanoseconds: eventGap)
        if let down = mouse(.leftMouseDown) { wv.mouseDown(with: down) }
        if let up = mouse(.leftMouseUp) { wv.mouseUp(with: up) }
        try? await Task.sleep(nanoseconds: eventGap)
        // The click made the web view first responder; the person's keyboard goes back where it was.
        if let before, before !== window.firstResponder { window.makeFirstResponder(before) }
    }

    static func press(_ wv: WKWebView, code: UInt16, chars: String, modifiers: NSEvent.ModifierFlags) async {
        guard let window = wv.window else { return }
        func key(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: t, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
        }
        if let down = key(.keyDown) { wv.keyDown(with: down) }
        try? await Task.sleep(nanoseconds: eventGap / 3)
        if let up = key(.keyUp) { wv.keyUp(with: up) }
        try? await Task.sleep(nanoseconds: eventGap)
    }

    static func scroll(_ wv: WKWebView, at p: CGPoint, dy: Double) async {
        guard let window = wv.window,
              let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-dy), wheel2: 0, wheel3: 0) else { return }
        let wp = wv.convert(p, to: nil)
        let screen = window.convertPoint(toScreen: wp)
        let flippedY = (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y
        cg.location = CGPoint(x: screen.x, y: flippedY)
        if let e = NSEvent(cgEvent: cg) { wv.scrollWheel(with: e) }
        try? await Task.sleep(nanoseconds: eventGap)
    }
}
