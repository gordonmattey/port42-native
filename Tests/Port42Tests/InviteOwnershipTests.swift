import Testing
import Foundation
@testable import Port42Lib

/// **Withdrawing an invite shows at once** (NAU-06).
///
/// Who may list and withdraw an invite is APP-01's rule (the maker or the person). What NAU-06 adds on
/// top: a withdrawal left the share pill counting the dead invite until something else refreshed it.
@Suite("Invite withdrawal refreshes sharing (NAU-06)")
@MainActor
struct InviteOwnershipTests {

    func makeInvite(_ w: ParityWorld, by creator: String, port: String) throws -> String {
        let id = UUID().uuidString
        try w.state.db.insertInvite(id: id, portKey: port, rights: [.see], nonceHash: UUID().uuidString,
                                    codeHash: nil, createdBy: creator, expiresAt: Date().addingTimeInterval(3600))
        w.state.refreshSharing()
        return id
    }

    @Test("withdrawing its own invite works, and the share pill stops counting it at once")
    func revokeRefreshesSharing() async throws {
        let w = try makeParityWorld()
        let mine = try makeInvite(w, by: w.principal.id, port: "pill-port")
        #expect(w.state.sharing["pill-port"]?.openInvites == 1)
        var refused: String?
        do { _ = try await w.state.runBridgeMethod("invite.revoke", principal: w.principal, args: BridgeArgs(["id": mine])) }
        catch let e as BridgeError { refused = e.code }
        #expect(refused == nil)
        #expect(w.state.sharing["pill-port"] == nil, "the pill still counts a withdrawn invite")
    }
}
