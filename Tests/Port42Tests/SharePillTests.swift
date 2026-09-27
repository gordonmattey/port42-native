import Testing
import Foundation
@testable import Port42Lib

/// Nautilus Phase 4, step 4.6b: the sharing pill in a tile's chrome (Gordon chose it, 2026-09-26). One
/// word says whose a port is and who else is in it, and follows every invite and right as it changes.
@Suite("Sharing pill (Phase 4, 4.6b)")
@MainActor
struct SharePillTests {

    @Test("what the pill says")
    func labels() {
        #expect(SharePill.shared(people: 2, invites: 0).label == "shared · 2")
        #expect(SharePill.shared(people: 1, invites: 3).label == "shared · 1")
        #expect(SharePill.shared(people: 0, invites: 1).label == "invite sent")
        #expect(SharePill.shared(people: 0, invites: 2).label == "2 invites sent")
        #expect(SharePill.theirs(host: "Ada", online: true).label == "Ada's")
        #expect(SharePill.theirs(host: "Ada", online: false).label == "Ada's · offline")
        #expect(ShareWords.rights([.see, .use, .edit]) == "see, use and edit")
        #expect(ShareWords.rights([.see]) == "see")
    }

    @Test("the pill follows the port: nothing, an invite out, someone in, their rights, then nobody")
    func followsSharing() async throws {
        let t = InviteTests()
        let w = try t.world()
        let tile = try #require(w.state.portWindows.panels.first { $0.udid == w.p }?.id)
        #expect(w.state.sharePill(tile: tile, key: w.p) == nil, "a port nobody shares has a pill")

        let made = try await t.create(w)
        #expect(w.state.sharePill(tile: tile, key: w.p) == .shared(people: 0, invites: 1))

        _ = try await t.remote(w, as: InviteTests.ada, "invite.redeem", ["nonce": try t.coupon(made).nonce, "name": "Ada"])
        #expect(w.state.sharePill(tile: tile, key: w.p) == .shared(people: 1, invites: 0), "the pill missed Ada joining")

        w.state.setRemoteRight(.edit, true, peer: InviteTests.ada, port: w.p)
        #expect(w.state.remoteRights(of: InviteTests.ada, onPort: w.p).contains(.edit))
        #expect(w.state.sharing[w.p]?.people.first?.rights.contains(.edit) == true, "the panel shows stale rights")
        w.state.setRemoteRight(.see, false, peer: InviteTests.ada, port: w.p)
        #expect(w.state.remoteRights(of: InviteTests.ada, onPort: w.p).contains(.see), "see was taken, leaving a share nobody can see")

        w.state.stopSharing(peer: InviteTests.ada, port: w.p)
        #expect(w.state.sharePill(tile: tile, key: w.p) == nil, "the pill stayed after sharing stopped")

        let again = try await t.create(w)
        w.state.withdrawInvite(id: try #require(again["id"] as? String))
        #expect(w.state.sharePill(tile: tile, key: w.p) == nil, "a withdrawn invite still shows")
    }

    @Test("one click copies the link, and the code under it when the invite has one")
    func copiedMessage() {
        #expect(ShareBox.message(.init(link: "L", code: nil, discloses: [])) == "L")
        #expect(ShareBox.message(.init(link: "L", code: "123456", discloses: [])) == "L\ncode: 123456",
                "the code was left out of the one-click copy")
    }

    @Test("an invite link is recognised whether clicked or pasted, and nothing else is")
    func recognisesInviteLinks() throws {
        let link = RemotePortTests().invite()
        let fragment = try #require(link.split(separator: "#", maxSplits: 1).last.map(String.init))
        #expect(InviteCoupon.inviteLink(in: link) == link)
        #expect(InviteCoupon.inviteLink(in: "  \(link)\n") == link, "a pasted link with spaces around it was missed")
        #expect(InviteCoupon.inviteLink(in: "port42://invite#\(fragment)") == "port42://invite#\(fragment)")
        #expect(InviteCoupon.inviteLink(in: "https://example.com/invite.html#\(fragment)") == nil, "another site's link was taken as an invite")
        #expect(InviteCoupon.inviteLink(in: InviteCoupon.pageURL + "#not-a-coupon") == nil)
        #expect(InviteCoupon.inviteLink(in: "chart") == nil, "an ordinary ⌘K search was taken as an invite")
    }

    @Test("a tile of someone else's port says whose; leaving closes it and forgets the port here")
    func theirsAndLeaving() async throws {
        let rt = RemoteTileTests()
        let (state, gw) = try rt.world()
        rt.host(gw, html: { "<p>x</p>" })
        let tile = try await rt.accept(state)
        #expect(state.sharePill(tile: tile, key: nil) == .theirs(host: "Gordon", online: true))
        state.leaveRemotePort(tile: tile)
        #expect(state.mirroredRemote(tile) == nil && state.mirrorStatus[tile] == nil)
        #expect(!state.portWindows.panels.contains { $0.id == tile }, "the tile stayed open")
        #expect(try state.db.remotePorts().isEmpty, "the port was not forgotten")
    }
}
