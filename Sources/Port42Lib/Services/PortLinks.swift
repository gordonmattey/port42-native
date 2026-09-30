import AppKit

// MARK: - Port links (#213)
//
// A link to a port is its address (PortAddress): `port42://space/<spaceId>/<portId>` for a port on
// this machine (`_` for "wherever it is"), `port42://<peer>/<portId>` for one shared from another.
// Opening one takes the person to that port, from a link clicked in another port or anywhere macOS
// hands Port42 a port42:// URL (a chat, a note, a browser).
//
// Before this, a port42:// link clicked in a port did nothing: the navigation blocker cancels
// everything that is not the port's own document, and the app's deep-link handler knew invites and
// imagine links only, logging every port address as "Unhandled deep link".

/// Where a port link points.
public enum PortLinkTarget: Equatable {
    /// A port on this machine, by its id or udid.
    case local(String)
    /// A port on another machine, by that machine's peer id and its port id there.
    case remote(peer: String, port: String)

    /// The target of a port42:// URL, or nil when it is not a port address (an invite, an imagine
    /// link). An address naming this machine is local.
    public static func of(_ url: URL, localPeerID: String?) -> PortLinkTarget? {
        guard let addr = PortAddress.parse(url.absoluteString) else { return nil }
        if let peer = addr.peerID, peer != localPeerID { return .remote(peer: peer, port: addr.portId) }
        return .local(addr.portId)
    }
}

extension AppState {
    /// Take the person to the port a link names. Returns false when the URL is not a port address or
    /// names no port this machine knows (a remote port needs an accepted invite, so a link cannot
    /// open a tile onto a port nobody shared).
    @discardableResult
    public func openPortLink(_ url: URL) -> Bool {
        switch PortLinkTarget.of(url, localPeerID: localPeerID) {
        case .local(let port)?:
            return revealPort(port)
        case .remote(let peer, let port)?:
            guard ((try? db.remotePorts()) ?? []).contains(where: { $0.peerKey == peer && $0.portKey == port }) else {
                p42log("[Port42] Port link to a remote port with no invite: %@", port)
                return false
            }
            Task { @MainActor in
                if let tile = try? await self.openRemoteTile(peer: peer, port: port) { _ = self.revealPort(tile) }
            }
            return true
        case nil:
            return false
        }
    }

    /// Show a local port and zoom into it: go to its space (waking it if resting), bring it back if
    /// it is closed, running off the desktop or parked, then focus it. The port's id or udid; a title
    /// is not an address, so a link never lands on a port that merely shares a name.
    @discardableResult
    func revealPort(_ idOrUdid: String) -> Bool {
        var panel = portWindows.panels.first { $0.id == idOrUdid || $0.udid == idOrUdid }
        if panel == nil, let closed = portWindows.closedPortId(idOrUdid), portWindows.reopen(closed) {
            panel = portWindows.panels.first { $0.id == closed }
        }
        guard let panel else {
            p42log("[Port42] Port link to no known port: %@", idOrUdid)
            return false
        }

        // Stay here when the port is shown here too; otherwise go to its home space.
        let here = currentSpace?.id
        let shownHere = here != nil && (panel.spaceId == here || panel.pinnedEverywhere || panel.adoptedSpaceIds.contains(here!))
        if !shownHere, let sid = panel.spaceId, let space = spaces.first(where: { $0.id == sid }) {
            if space.isResting { wakeAndEnterSpace(space) } else { selectSpace(space) }
        }

        if panel.isBackground { _ = portWindows.restore(panel.id) }
        if panel.presentation == "parked" { portWindows.unpark(id: panel.id) }
        if let app = NSApp { app.activate(ignoringOtherApps: true) }   // a link from outside the app; nil under a test runner
        if let shell {
            shell.placeUnpositioned(area: shell.lastDesktopArea)
            shell.bringToFront(panel.id)
            shell.zoom = .focus(panel.id)
        }
        return true
    }
}
