import Testing
import Foundation
import WebKit
@testable import Port42Lib

/// The port sandbox: a port is ONE origin, and the bridge belongs to that origin — not to whatever
/// document happens to be sitting in the webview.
///
/// Written after a live escalation found 2026-07-26 while running Spike B: a normal web port whose
/// JS ran `location.href = 'https://example.com'` navigated successfully AND kept `window.port42`,
/// and the foreign page called `ports.list()` and got the user's real port list back. Two separate
/// defects lined up — an inverted navigation policy, and a bridge scoped to the webview rather than
/// the origin. Either one alone would have been enough to stop it.
@Suite("Port origin sandbox")
struct PortOriginSecurityTests {

    // MARK: - The navigation allowlist (defence in depth)

    @Test("a port may load its own document")
    func ownDocumentAllowed() {
        #expect(PortNavigationBlocker.allows(URL(string: "http://port42.local/")))
        #expect(PortNavigationBlocker.allows(URL(string: "http://port42.local/anything#frag")))
        #expect(PortNavigationBlocker.allows(URL(string: "about:blank")))
        #expect(PortNavigationBlocker.allows(nil))   // nothing to judge
    }

    @Test("a port may NOT navigate to the open internet — the exact live escape")
    func foreignNavigationBlocked() {
        #expect(PortNavigationBlocker.allows(URL(string: "https://example.com")) == false)
        #expect(PortNavigationBlocker.allows(URL(string: "http://evil.test/x")) == false)
        // A lookalike host must not pass on a prefix/suffix match.
        #expect(PortNavigationBlocker.allows(URL(string: "https://port42.local.evil.test/")) == false)
        #expect(PortNavigationBlocker.allows(URL(string: "https://notport42.local/")) == false)
        // Non-http schemes are destinations too.
        #expect(PortNavigationBlocker.allows(URL(string: "file:///etc/passwd")) == false)
        #expect(PortNavigationBlocker.allows(URL(string: "data:text/html,<h1>x")) == false)
    }

    @Test("the rule judges the DESTINATION, never the navigation type")
    func destinationNotType() throws {
        // The bug was `navigationType == .other ? .allow : .cancel` — `.other` is script-initiated,
        // i.e. the hostile case, so the policy blocked humans and permitted pages. There is no
        // navigation type that means "safe"; where it is GOING is the only fact worth checking.
        // If this ever regresses, `allows` will have grown a navigationType parameter.
        let src = try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Views/PortWindowManager.swift"), encoding: .utf8)
        let text = try #require(src)
        // Non-comment lines only: the fixed code documents the old rule by quoting it, and a naive
        // contains() matches that quote and fails on the fix rather than on a regression.
        let live = text.split(separator: "\n").map(String.init).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("//") && !t.hasPrefix("///")
        }
        #expect(!live.contains { $0.contains("navigationType == .other ? .allow") },
                "the inverted type-based policy must not come back")
    }

    // MARK: - The origin pin (the load-bearing fix)

    @Test("the bridge names ONE origin, and it is the one every port document loads from")
    func originConstantMatchesLoader() throws {
        #expect(PortBridge.portOrigin == "port42.local")
        // Every loadHTMLString in the app must use it as the baseURL, or a port would be born on an
        // origin its own bridge refuses — the check and the loader have to agree by construction.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var loaders = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") where line.contains("loadHTMLString") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//") else { continue }
                // Spikes/probes load with baseURL: nil deliberately — they get no bridge either.
                if t.contains("baseURL: nil") { continue }
                loaders += 1
                #expect(t.contains("port42.local") || url.lastPathComponent.contains("Probe"),
                        "\(url.lastPathComponent) loads a port document off-origin: \(t)")
            }
        }
        #expect(loaders > 0, "the scan found no loaders; the walk is broken")
    }

    @Test("the input listener covers the three signals Spike C measured, not the two it guessed")
    func inputListenerCoversMeasuredSignals() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Port42Lib/Views/PortWindowManager.swift"), encoding: .utf8)
        // Measured live: keydown+pointerdown caught 8 of 11 real content changes. The misses were
        // dictation/IME (composition events) and context-menu paste (a paste event) — no key, no
        // pointer. `beforeinput` fired on all 11. Dropping any of the three reopens a hole someone
        // has already walked through.
        for ev in ["'keydown'", "'pointerdown'", "'beforeinput'"] {
            #expect(src.contains("addEventListener(\(ev), send, true)"),
                    "the port input listener must report \(ev)")
        }
        // And the trust check still guards all three: without it a port forges the human's presence
        // and, since R2, moves the activity token too.
        #expect(src.contains("e.isTrusted !== true"))
    }

    @Test("EVERY message handler is pinned — a partial fix is the same bug with fewer doors")
    func everyHandlerPinned() throws {
        func source(_ p: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Port42Lib/\(p)"), encoding: .utf8)
        }
        // The bridge: the verified escalation path.
        #expect(try source("Services/PortBridge.swift").contains("guard Self.isPortOrigin(message)"))

        // And every handler in the manager. Counting rather than naming: the four known ones are
        // port42/portInput/portConsole/portHeight, and a fifth added later must be pinned too. If
        // this count is ever LOWER than the number of `didReceive` implementations, one is unpinned.
        let mgr = try source("Views/PortWindowManager.swift")
        let handlers = mgr.components(separatedBy: "func userContentController(").count - 1
        let pins = mgr.components(separatedBy: "PortBridge.isPortOrigin(message)").count - 1
        #expect(handlers > 0, "the scan found no handlers; the matcher is broken")
        #expect(pins >= handlers,
                "\(handlers) message handlers but only \(pins) origin pins — one accepts foreign input")
    }
    // MARK: - P0 hardening: a foreign site gets no door, not a guarded one

    @Test("a BROWSER port attaches no bridge namespace and no bridge handler")
    @MainActor
    func browserPortGetsNoBridge() {
        let config = WKWebViewConfiguration()
        let bridge = PortBridge(appState: NSObject(), spaceId: nil, messageId: "b1")
        bridge.attach(to: config, foreignSite: true)

        // Nothing to find: no injected namespace, no message handler. The origin pin already
        // refused every message from a foreign site, so this changes no outcome — it removes the
        // door rather than trusting the bolt on it. The same class already bit once, when a web
        // port could navigate away and carry the bridge with it.
        #expect(config.userContentController.userScripts.isEmpty,
                "a foreign site must not receive the port42 namespace")
    }

    @Test("a WEB port still gets the bridge, because its own JS is the legitimate caller")
    @MainActor
    func webPortKeepsTheBridge() {
        let config = WKWebViewConfiguration()
        let bridge = PortBridge(appState: NSObject(), spaceId: nil, messageId: "w1")
        bridge.attach(to: config)
        #expect(!config.userContentController.userScripts.isEmpty,
                "a web port's document IS port42.local and needs the namespace")
    }
}
