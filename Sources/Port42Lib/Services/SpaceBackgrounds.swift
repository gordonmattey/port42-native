import Foundation

/// A space's background when its port was CLOSED: nothing live to re-parent, so Layer 0 mounts a fresh
/// copy from this stored HTML. A live background always uses `AppState.backgroundPorts`.
public struct ClosedBackground: Equatable {
    public let id: String
    public let html: String
}

// MARK: - Per-space backgrounds
//
// Each space has its own backdrop, or the ambient dreamscape when it has none (Gordon, 2026-09-30). A port
// is the backdrop of at most one space, since its one live surface can be mounted in only one place.
// App state, not a window's: with a window per display (#189) every window reads the backdrop of the
// space it shows (`ShellState.backgroundPortId`), and the API sets one with no window at all.
//
// The LIVE port set as a background is re-parented full-bleed as Layer 0, NOT reloaded. Background is a
// PRESENTATION of the port (like tiled/parked/focus), so moving to or from it is a position change, never
// a lifecycle change: the hoisted webview never remounts, so a running shader / JS state survives.

extension AppState {
    static let backgroundLegacyKey = "shell.backgroundPortId"   // the single global setting, before it was per space
    static let backgroundMapKey = "shell.backgroundPorts"       // space id → port id

    /// The space a port is the background of, if it is one (by panel id or udid).
    public func backgroundSpace(of port: String) -> String? {
        let ids = Set([port] + (portWindows.panels.first { $0.id == port || $0.udid == port }.map { [$0.id, $0.udid] } ?? []))
        return backgroundPorts.first { ids.contains($0.value) }?.key ?? backgroundHtmls.first { ids.contains($0.value.id) }?.key
    }

    private func persistBackgrounds() {
        var map = backgroundPorts
        for (sid, closed) in backgroundHtmls { map[sid] = closed.id }
        if map.isEmpty { UserDefaults.standard.removeObject(forKey: Self.backgroundMapKey) }
        else { UserDefaults.standard.set(map, forKey: Self.backgroundMapKey) }
    }

    /// Set (or clear, with nil) a space's background port. A live port MOVES to the background presentation
    /// (re-parent, no reload); a closed port falls back to a fresh HTML mount. The space's old backdrop
    /// returns to a tile. The ids are remembered so they restore next launch.
    public func setBackgroundPort(id: String?, in sid: String) {
        if let cur = backgroundPorts[sid],
           let panel = portWindows.panels.first(where: { $0.id == cur || $0.udid == cur }) {
            let staying = id.map { $0 == panel.id || $0 == panel.udid } ?? false
            if !staying { portWindows.setPresentation(id: panel.id, to: "tiled") }
        }
        guard let id else {
            backgroundPorts[sid] = nil
            backgroundHtmls[sid] = nil
            persistBackgrounds()
            return
        }
        if let panel = portWindows.panels.first(where: { $0.id == id || $0.udid == id }) {
            // One surface, one place: taking it from the space it was the backdrop of.
            if let other = backgroundSpace(of: panel.id), other != sid { backgroundPorts[other] = nil }
            portWindows.setPresentation(id: panel.id, to: "background")
            backgroundPorts[sid] = panel.id
            backgroundHtmls[sid] = nil
            persistBackgrounds()
            return
        }
        if let html = resolveBackgroundHtml(id: id) {
            backgroundPorts[sid] = nil
            backgroundHtmls[sid] = ClosedBackground(id: id, html: html)
            persistBackgrounds()
        }
    }

    /// A port's current HTML: live panel first, then the version store (so a closed port can still be a
    /// background).
    private func resolveBackgroundHtml(id: String) -> String? {
        if let panel = portWindows.panels.first(where: { $0.id == id || $0.udid == id }) { return panel.html }
        return (try? db.fetchPortHtml(udid: id)) ?? nil
    }

    /// Restore the backgrounds set in a previous session. A live port (persisted with the background
    /// presentation) is re-parented; a closed one falls back to stored HTML. The single global setting an
    /// older version saved becomes the background of the space its port lives in, read from the stored row
    /// since the ports may not be loaded yet at launch.
    public func restoreBackgrounds() {
        var map = (UserDefaults.standard.dictionary(forKey: Self.backgroundMapKey) as? [String: String]) ?? [:]
        if map.isEmpty, let old = UserDefaults.standard.string(forKey: Self.backgroundLegacyKey), !old.isEmpty {
            let home = portWindows.panels.first { $0.id == old || $0.udid == old }?.spaceId
                ?? ((try? db.fetchPortPanels()) ?? []).first { $0.id == old || $0.udid == old }?.spaceId
            if let sid = home ?? currentSpace?.id { map[sid] = old }
        }
        UserDefaults.standard.removeObject(forKey: Self.backgroundLegacyKey)
        for (sid, id) in map {
            if let panel = portWindows.panels.first(where: { $0.id == id || $0.udid == id }) {
                portWindows.setPresentation(id: panel.id, to: "background")   // keep it out of the grid
                backgroundPorts[sid] = panel.id
            } else if let html = resolveBackgroundHtml(id: id) {
                backgroundHtmls[sid] = ClosedBackground(id: id, html: html)
            }
        }
        persistBackgrounds()
        // At launch the ports load a moment after the shell appears: a background that fell back to its
        // stored HTML becomes the live port once it exists, so a running page is not a second copy.
        if !backgroundHtmls.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.adoptLoadedBackgrounds() }
        }
    }

    /// A closed-port fallback whose port has since loaded: the live port takes over.
    func adoptLoadedBackgrounds() {
        for (sid, closed) in backgroundHtmls {
            guard let panel = portWindows.panels.first(where: { $0.id == closed.id || $0.udid == closed.id }) else { continue }
            portWindows.setPresentation(id: panel.id, to: "background")
            backgroundPorts[sid] = panel.id
            backgroundHtmls[sid] = nil
        }
        persistBackgrounds()
    }
}
