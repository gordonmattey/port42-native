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
// SCOPED BY APP-15: a terminal Port42 spawned is bound to its spawn space, and reads that space
// (see the `.peer` case below). A companion, in the app or in its terminal, also reads the spaces the
// person made it a member of (`isMember`, GM 2026-09-29). NOT SCOPED: `.human` (the person owns every space), a client the
// person paired or installed (no space), and `.remote`, already confined by RemoteAccess to the
// ports it holds a right on, before any body runs.

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
        case .human, .remote:
            return true
        case .peer:
            // APP-15: a terminal Port42 spawned reads the space it was spawned into, whether it
            // authorizes as its companion or as itself. A child whose binding is gone (its terminal
            // closed) reads no space rather than everywhere. A client the person paired or
            // installed keeps machine-wide reads, which is a product call and left as it was.
            if let zone = principal.zone { return spaceId == zone || isMember(principal, of: spaceId) }
            return clientRegistry.client(id: principal.id)?.kind == .child ? spaceId == nil : true
        case .port:
            // Equality of optionals on purpose: a caller acting in no space sees only ports in no
            // space, never "everywhere".
            return spaceId == principal.spaceId
        case .companion:
            return spaceId == principal.spaceId || isMember(principal, of: spaceId)
        }
    }

    /// A companion also reads the spaces the person made it a member of (GM, 2026-09-29): a lead in
    /// one space coordinates a team in another, and the membership is the person's decision. A plain
    /// terminal or a port's page belongs to no space but its own.
    /// The spaces a companion is a member of, in the order the person sees them.
    public func memberSpaces(of companionId: String) -> [Space] {
        let ids = (try? db.spaceIds(ofAgent: companionId)) ?? []
        return spaces.filter { ids.contains($0.id) }
    }

    func isMember(_ principal: Principal, of spaceId: String?) -> Bool {
        guard let spaceId, let companion = companion(actingAs: principal) else { return false }
        return (try? db.spaceIds(ofAgent: companion.id).contains(spaceId)) ?? false
    }

    /// The space a chat belongs to (APP-09): nil for the desktop's chat (port 0, which is in no
    /// space), the space itself for a space's chat, and the port's space for a port's chat.
    func chatSpaceId(_ key: String) -> String? {
        if key == PortChat.desktopKey { return nil }
        if spaces.contains(where: { $0.id == key }) { return key }
        return resolvePortRef(key).flatMap(portSpaceId)
    }

    /// Resolve a chat for a READ, by the same rule as a port (APP-09): a port or companion reads
    /// only the chats of the space it acts in, and a refusal is `not_found`, as for a missing chat.
    func requireReadableChat(_ port: String, by principal: Principal) throws -> String {
        guard let key = chatKey(for: port),
              canRead(portInSpace: chatSpaceId(key), by: principal) else {
            throw BridgeError.notFound("port '\(port)' (a chat belongs to port 0, a space, or a port)")
        }
        return key
    }

    /// Resolve `id` for a READ, refusing a port outside the caller's scope as if it did not exist.
    func requireReadablePort(_ id: String, by principal: Principal) throws -> PortRef {
        guard let ref = resolvePortRef(id), canRead(portInSpace: portSpaceId(ref), by: principal) else {
            throw BridgeError.notFound("port '\(id)'")
        }
        return ref
    }
}
