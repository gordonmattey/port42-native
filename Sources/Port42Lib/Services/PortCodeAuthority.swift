import Foundation

// MARK: - Port code authority (APP-07)
//
// WHO MAY REPLACE A PORT'S CODE. A port's JS runs as the port's principal: its creator for a
// companion-made port (P-260), otherwise the port itself, and with the grants its bridge carries.
// So `port.update`, `port.patch` and `port.restore` do not just change what a port shows. They
// choose the code that next runs with every grant that principal holds, and they persist it across
// restart. With no check, a caller holding nothing could rewrite a port that holds `.terminal` or
// `.screen` and borrow them. A remote guest holding `edit` reaches the same three verbs
// (RemoteAccess), which is NAU-02.
//
// THE RULE (GM, 2026-09-28, for 1.0.1). A port's code may be changed by:
// - the person;
// - the port's creator (its own grantee: the author, the author's terminal, the port itself);
// - any companion in the port's own space (`companionInSpace`): companions working in one space build
//   its ports together, and an imagine team's engineers must be able to edit the lead's port after
//   it has been granted the microphone.
// Anyone else (a remote guest, a script on the gateway, a port's page, a companion from another
// space) may change it only if they already hold every grant the port runs with: a port that holds
// nothing can be edited by anyone who can reach it, and a caller holding a superset gains nothing.
// A remote caller holds no machine grant here, so it is refused on any port that holds one.

@MainActor
extension AppState {

    /// Refuse a code write that would hand the writer grants it does not hold.
    ///
    /// `target` is looked up with `findPort(by:)`, the same udid-then-title match `updatePort` uses,
    /// so the port judged here is the port that gets written. A target with no panel is left to
    /// the verb, which answers `not_found`.
    func requireCodeAuthority(over target: String, by writer: Principal) throws {
        guard writer.kind != .human, let panel = portWindows.findPort(by: target) else { return }
        try requireCodeAuthority(over: panel.bridge, named: target, by: writer,
                                 doing: "replacing its code")
    }

    /// The same rule for a port reached through its bridge, for any verb that puts caller code
    /// into a port.
    func requireCodeAuthority(over bridge: PortBridge, named target: String, by writer: Principal,
                              doing act: String) throws {
        guard writer.kind != .human else { return }
        let authority = bridge.portPrincipal
        if writer.id == authority.id { return }
        if let space = bridge.spaceId, companionInSpace(writer) == space { return }

        // What the port's code runs with: its principal's live grants (APP-06 removed the copy).
        let runsWith = grants(grantee: authority.id, on: .machine, zone: authority.zone)
        let holds = grants(grantee: writer.id, on: .machine, zone: writer.zone)
        let missing = runsWith.subtracting(holds)
        guard !missing.isEmpty else { return }

        let names = missing.map(\.rawValue).sorted().joined(separator: ", ")
        throw BridgeError(
            code: .permissionDenied,
            message: "port '\(target)' runs with \(names), granted to \(authority.displayName), and "
                   + "\(act) would hand you those. Only its author, the person, a companion in its space, or a caller "
                   + "already holding them can change its code. Make your own port instead.",
            details: ["missing": names])
    }

    /// **The space a companion is working in**, or nil when the caller is not a companion
    /// (APP-07). An in-app companion acts in its principal's space; a companion in a Port42 terminal
    /// reaches the gateway under its terminal's client, and works in the space that terminal was
    /// spawned into (`terminalClientPanels`). A port's page, a script on the gateway and a remote
    /// caller are no companion, so they get the escalation rule.
    func companionInSpace(_ writer: Principal) -> String? {
        switch writer.kind {
        case .companion:
            return companion(actingAs: writer) == nil ? nil : writer.spaceId
        case .peer:
            guard companion(actingAs: writer) != nil else { return nil }
            // Bound to its spawn space by APP-15; otherwise found through its terminal's client.
            if let space = writer.spaceId { return space }
            guard let panelId = terminalClientPanels[writer.id] else { return nil }
            return portWindows.panels.first { $0.id == panelId }?.spaceId
        default:
            return nil
        }
    }
}
