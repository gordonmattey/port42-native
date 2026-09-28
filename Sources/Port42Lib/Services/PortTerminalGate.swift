import Foundation

// MARK: - The terminal-target gate (APP-03, APP-04)
//
// `terminal.exec` has always required `.terminal`. `port.push` and `port.subscribe` declared no
// permission, and both reach a terminal through its port: push types raw keystrokes into the shell,
// subscribe streams everything it prints. A local caller holding zero grants could therefore do
// through the port what the terminal verbs refuse it, which made the `.terminal` gate decorative.
//
// The capability a call needs depends on WHAT it targets, so it cannot live in the static
// `permission` field. It is declared per verb (`terminalTarget`, the param naming the port) and
// enforced here, once, from the dispatcher, before any token moves. `port.create` already gates on
// its `type` argument the same way.
//
// A caller on another machine is not asked: it can never raise a permission card, and it reaches a
// port only through a right the person granted on that port when sharing it (`RemoteAccess`), which
// has already been checked by the time this runs.

extension AppState {

    /// Whether a call naming a port of this kind needs `.terminal`.
    ///
    /// A standing read (a subscription) also gates `.unknown`: a DB-only port may be a terminal that
    /// is not running yet, and a subscription opened now keeps streaming once it respawns. A one-shot
    /// write to `.unknown` is already refused with `no_surface`, so it is not asked for a grant it
    /// could never use.
    nonisolated static func terminalTargetNeedsGrant(_ kind: PortSurfaceKind?, standing: Bool) -> Bool {
        switch kind {
        case .terminal: return true
        case .unknown:  return standing
        default:        return false
        }
    }

    /// Refuse a local call whose declared target is a terminal unless the caller holds `.terminal`
    /// on THAT terminal, or on the whole machine (APP-02). A yes to one terminal is kept for that
    /// terminal only.
    func requireTerminalTarget(_ param: String?, args: BridgeArgs, principal: Principal,
                               pregrant: Set<PortPermission>, standing: Bool) async throws {
        guard principal.kind != .remote, let param, let raw = args.string(param) else { return }
        let ref = resolvePortRef(raw)
        guard Self.terminalTargetNeedsGrant(ref?.kind, standing: standing) else { return }
        let key = ref?.key ?? raw
        let name = terminalControllers[key]?.config.companionName ?? raw
        guard try await ensurePermission(.terminal, for: principal, on: .port(key),
                                     detail: "Type into and read the terminal '\(name)'",
                                     pregrant: pregrant) else {
            throw BridgeError.permissionDenied(PortPermission.terminal.rawValue)
        }
    }
}
