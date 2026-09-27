import Foundation
import AppKit

/// `port42://imagine?line=<idea>&from=<site>` (asked by growth for port42.ai's "Imagine this" cards,
/// 2026-09-27): open the imagine box with the idea filled in. It never starts a team: any web page can
/// fire this link, so a click on a site must not spend the person's model quota or open a space. The
/// person presses Enter.
public struct ImagineLinkRequest: Equatable {
    public let line: String
    /// Where the link came from, shown under the box ("from port42.ai"). Informational only.
    public let from: String?

    public static let maxLine = 300
    public static let maxFrom = 60

    /// The request a link carries, or nil when it is not an imagine link or carries no idea.
    /// Control characters become spaces, the idea is cut to `maxLine`, unknown parameters are ignored.
    public static func parse(_ url: URL) -> ImagineLinkRequest? {
        guard url.scheme?.lowercased() == "port42", url.host?.lowercased() == "imagine",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func clean(_ s: String, max: Int) -> String {
            let spaced = String(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
            let squeezed = spaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            return String(squeezed.prefix(max))
        }
        let line = clean(items.first { $0.name == "line" }?.value ?? "", max: maxLine)
        guard !line.isEmpty else { return nil }
        let from = items.first { $0.name == "from" }?.value.map { clean($0, max: maxFrom) }.flatMap { $0.isEmpty ? nil : $0 }
        return ImagineLinkRequest(line: line, from: from)
    }
}

@MainActor
extension AppState {
    /// Open the imagine box for a link, or hold it while the first run is still under way: it opens
    /// once the person has landed on their desktop (`openHeldImagineLink`).
    func openImagineLink(_ req: ImagineLinkRequest) {
        if let app = NSApp { app.activate(ignoringOtherApps: true) }     // nil under a test runner
        guard isSetupComplete, !isOnboarding, let shell else { heldImagineLink = req; return }
        shell.imagineLink = req
        shell.showImagine = true
    }

    /// The held link, once the first run is over. A no-op when nothing is held or it is not over yet.
    func openHeldImagineLink() {
        guard let req = heldImagineLink, isSetupComplete, !isOnboarding else { return }
        heldImagineLink = nil
        openImagineLink(req)
    }
}
