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
}
