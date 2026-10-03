import Foundation

// MARK: - Port code provenance (NAU-02)
//
// WHOSE CODE A PORT IS RUNNING. A port authorizes as its creator (P-260), so its code runs with the
// creator's machine grants. A guest on another machine holding `edit` can replace that code. APP-07
// refuses the write while the port holds a grant, but it judges only that moment: a grant the
// creator is given later, or a card the guest's code raises in the creator's name, would still hand
// the guest what the creator holds on this machine.
//
// So the write is recorded. Once a remote caller has written a port's code, the port runs as itself
// with nothing inherited (`PortBridge.codeChangedBy`, `Principal.forPortBridge`), and every card it
// raises says who changed it. Only a FULL replacement by the person or by the port's own creator
// makes the code theirs again; a patch or a restore may keep what the guest wrote.

@MainActor
extension AppState {

    /// Record a write to a port's code, before it is applied, so the save that follows persists it.
    func recordCodeWrite(to target: String, by writer: Principal, replacesAll: Bool) {
        guard let panel = portWindows.findPort(by: target) else { return }
        if writer.kind == .remote {
            panel.bridge.codeChangedBy = writer.displayName
        } else if writer.crossSpaceTarget != nil {
            // #238: a port in another space with `edit` is an outsider to this port's grants, as a
            // guest is, so its code runs as itself from now on.
            panel.bridge.codeChangedBy = crossSpaceReader(writer)?.title ?? writer.displayName
        } else if replacesAll, panel.bridge.codeChangedBy != nil,
                  writer.kind == .human || (panel.createdBy.map { $0 == writer.id } ?? false) {
            panel.bridge.codeChangedBy = nil
        }
    }
}
