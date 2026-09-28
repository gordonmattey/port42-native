import Foundation

// MARK: - Port read scope (APP-10)
//
// WHO MAY LOOK AT A PORT. The read verbs (`ports.list`, `port.getHtml`, `port.history`,
// `port.getDom`, `port.console`) are ungated by design: reading is not driving, so they move no
// token and ask no permission. But "ungated" had quietly also meant "unscoped". Any port's JS, or
// an in-app companion steered by a prompt injected into synced chat, could enumerate every port in
// every space and read its source, its live DOM and everything it printed. That is step 2 of the
// local zero-grant chain (docs: Security Audit port, Chain 2).
//
// The rule is the one APP-09 states for chat: a caller reads what is in the space it acts in.
// A port and an in-app companion carry that space on their principal, so a port in another space
// is invisible to them, and a refused read answers `not_found` rather than confirming the port
// exists. A caller with no space is not "everywhere": it sees only ports that have no space either.
//
// NOT SCOPED HERE: `.human` (the person owns every space), `.peer` and `.remote`. A gateway
// principal carries no space (`Principal.peer`), and a spawned session's client is not yet bound to
// the space it was spawned in, so there is nothing to scope a peer to without inventing one; that
// binding is APP-15, and this rule takes it up when it lands. A caller on another machine is
// already confined by RemoteAccess to the ports it holds a right on, before any body runs.

@MainActor
extension AppState {

    /// The space a port lives in, or nil when no record names one.
    ///
    /// Looked up rather than read off `ref.spaceId`, which `resolvePortRef` fills only for a
    /// `port42://space/…` address. Live panels first (terminal and web tiles alike are panels), then
    /// an inline bridge, then the stored panel row for a port with no live surface.
    func portSpaceId(_ ref: PortRef) -> String? {
        if let s = ref.spaceId { return s }
        let keys = Set([ref.id, ref.udid, ref.messageId].compactMap { $0 })
        if let panel = portWindows.panels.first(where: {
            keys.contains($0.id) || keys.contains($0.udid) || $0.messageId.map(keys.contains) == true
        }) {
            return panel.spaceId
        }
        if let mid = ref.messageId ?? ref.id, let bridge = findInlineBridge(by: mid) {
            return bridge.spaceId
        }
        if let udid = ref.udid { return try? db.fetchPortSpaceId(udid: udid) }
        return nil
    }

    /// May this caller see a port that lives in `spaceId`? The one rule, shared by the listing and
    /// the by-id reads so the two can never disagree about what a caller can see.
    func canRead(portInSpace spaceId: String?, by principal: Principal) -> Bool {
        switch principal.kind {
        case .human, .peer, .remote:
            return true
        case .port, .companion:
            // Equality of optionals on purpose: a caller acting in no space sees only ports in no
            // space, never "everywhere".
            return spaceId == principal.spaceId
        }
    }

    /// Resolve `id` for a READ, refusing a port outside the caller's scope as if it did not exist.
    func requireReadablePort(_ id: String, by principal: Principal) throws -> PortRef {
        guard let ref = resolvePortRef(id), canRead(portInSpace: portSpaceId(ref), by: principal) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        return ref
    }
}
