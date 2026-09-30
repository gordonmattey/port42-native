import AppKit

// MARK: - Port42 as the default web browser (docs/plan-default-browser.md)

/// Links from other apps: an http or https link opens as a browser port on the space the person is in
/// (Gordon, 2026-09-30).
public enum WebLink {
    /// Whether a link that arrived from outside is a web page for a browser port. Pure.
    public static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host?.isEmpty == false
    }

    /// Whether Port42 is the browser macOS opens web links with now.
    @MainActor public static var isDefault: Bool {
        guard let current = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return current.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// The browser macOS opens web links with now, by name.
    @MainActor public static var currentDefaultName: String? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Ask macOS to make Port42 the default browser. macOS shows its own prompt, once per scheme.
    @MainActor public static func makeDefault() async {
        for scheme in ["http", "https"] {
            try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
        }
    }
}

@MainActor
extension AppState {
    /// Open a web link from another app as a browser port on the current space, in front. One that
    /// arrives before setup is done waits (`openHeldWebLinks`), as an imagine link does.
    func openWebLink(_ url: URL) {
        if let app = NSApp { app.activate(ignoringOtherApps: true) }     // nil under a test runner
        guard isSetupComplete, !isOnboarding, let space = currentSpace else {
            heldWebLinks.append(url)
            return
        }
        let r = createPort(type: "browser", title: url.host, html: url.absoluteString, command: nil, cwd: nil,
                           systemPrompt: nil, spaceId: space.id, createdBy: nil, createdByName: nil)
        if let id = r["id"] as? String,
           let panel = portWindows.panels.first(where: { $0.id == id || $0.udid == id }) {
            portWindows.bringToFront(panel.id)
            shell?.bringToFront(panel.id)
        }
    }

    /// The links that arrived before setup was done, once it is.
    func openHeldWebLinks() {
        guard isSetupComplete, !isOnboarding, currentSpace != nil, !heldWebLinks.isEmpty else { return }
        let links = heldWebLinks
        heldWebLinks = []
        links.forEach(openWebLink)
    }
}
