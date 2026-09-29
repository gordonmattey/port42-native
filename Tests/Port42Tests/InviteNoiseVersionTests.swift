import Testing
import Foundation
@testable import Port42Lib

/// **An invite says which guest handshakes its host accepts** (GST-02).
///
/// A guest whose keys the page cannot read speaks handshake v2, which only an updated host accepts.
/// The invite is how a guest learns that: new invites say "noise": [1, 2], and one without the field
/// is from a host that speaks v1 only.
@Suite("Invite handshake versions (GST-02)")
struct InviteNoiseVersionTests {

    let host = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"

    @Test("a new invite advertises v1 and v2, and keeps v: 1 for guest pages already out there")
    func newInviteAdvertisesBoth() throws {
        let coupon = InviteCoupon(host: host, relays: ["wss://r/v1"], port: "P", rights: ["see"], nonce: "n",
                                  exp: 0, hostName: "h", portTitle: "t", code: false)
        var b = coupon.encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        let data = try #require(Data(base64Encoded: b))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["noise"] as? [Int] == [1, 2])
        #expect(json["v"] as? Int == 1, "today's guest page refuses any coupon whose v is not 1")
        #expect(InviteCoupon.decode(coupon.encoded)?.noise == [1, 2])
    }

    @Test("an invite from before (no noise field) still decodes, and means v1 only")
    func oldInviteDecodes() throws {
        let old: [String: Any] = ["v": 1, "host": host, "relays": ["wss://r/v1"], "port": "P", "rights": ["see"],
                                  "nonce": "n", "exp": 0, "hostName": "h", "portTitle": "t", "code": false]
        let data = try JSONSerialization.data(withJSONObject: old)
        let b64 = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let coupon = try #require(InviteCoupon.decode(b64))
        #expect(coupon.noise == nil)
    }
}
