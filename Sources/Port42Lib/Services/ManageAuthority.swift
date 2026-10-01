import Foundation

// MARK: - Who may manage shares (APP-01)
//
// `invite.list` and `invite.revoke` declared no permission and checked no target, so any local caller
// (a port's JS, an in-app companion, a spawned session a prompt can steer) could read every invite and
// withdraw anyone's share.
//
// Invites follow the port's authority, the same rule as a code write (APP-07): the person, the caller
// who made the invite, or the port's own principal. (`space.delete` is APP-11's.)

@MainActor
extension AppState {

    /// May `p` see or withdraw this invite?
    func mayManage(_ invite: DatabaseService.InviteRow, by p: Principal) -> Bool {
        if p.kind == .human { return true }
        guard p.kind != .remote else { return false }
        if invite.createdBy == p.id { return true }
        let panel = portWindows.panels.first { $0.udid == invite.portKey || $0.id == invite.portKey }
        return panel?.bridge.portPrincipal.id == p.id
    }

    /// Who may see and change what a port is shared with (API parity, Phase E). Same shape as an invite's
    /// authority: the person, the port itself, or a caller that made an invite for it.
    func mayManage(sharingOf portKey: String, by p: Principal) -> Bool {
        if p.kind == .human { return true }
        guard p.kind != .remote else { return false }
        if portWindows.panels.first(where: { $0.udid == portKey || $0.id == portKey })?.bridge.portPrincipal.id == p.id { return true }
        return ((try? db.allInvites()) ?? []).contains { $0.portKey == portKey && $0.createdBy == p.id }
    }
}
