import Foundation
import CryptoKit

// MARK: - Invites (nautilus Phase 4, step 4.5; docs/design-phase4-relay.md "The invite")
//
// One invite per port (D10). A link names one port and grants that port only; port 0 and spaces are
// never invitable. The link is `https://port42.ai/invite.html#<coupon>`: the coupon rides in the
// fragment, which a browser never sends to a server. It carries no standing access, only a one-time
// nonce. Redeeming it enrols the redeemer's key as a `peer` client and grants the port with the
// invite's rights; the nonce is then spent. An invite can also require a six-digit code, sent to the
// guest another way, so a forwarded link grants nothing without it.
//
// The table holds only hashes of the nonce and the code, so it cannot be used to redeem anything.

/// What an invite link carries.
public struct InviteCoupon: Codable, Equatable {
    public var v = 1
    public let host: String         // the host instance's peer id
    public let relays: [String]     // where the host can be reached
    public let port: String         // the port's key
    public let rights: [String]     // RemoteRight values
    public let nonce: String        // one-time, base64url
    public let exp: Int             // expiry, unix seconds
    public let hostName: String
    public let portTitle: String
    public let code: Bool           // a code must be typed to redeem

    public static let pageURL = "https://port42.ai/invite.html"

    /// base64url of the JSON, for a URL fragment.
    public var encoded: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The link to send: it opens the invite page, which offers Port42 or the browser.
    public var link: String { Self.pageURL + "#" + encoded }

    public static func decode(_ s: String) -> InviteCoupon? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b) else { return nil }
        return try? JSONDecoder().decode(InviteCoupon.self, from: data)
    }
}

extension AppState {

    /// How long an invite lasts unless the creator says otherwise, and the longest it may last.
    static let inviteDefaultLife: TimeInterval = 7 * 24 * 3600
    static let inviteMaxLife: TimeInterval = 30 * 24 * 3600
    /// Wrong codes before an invite is dead.
    static let inviteCodeTries = 5

    static func inviteHash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func randomBase64URL(bytes n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func randomCode() -> String {
        var n: UInt32 = 0
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &n)
        return String(format: "%06d", n % 1_000_000)
    }

    /// The relays this instance is reachable through: the same list its gateway registers on.
    var inviteRelays: [String] { relayList() }

    static func configuredRelays() -> [String] {
        (UserDefaults.standard.string(forKey: "PORT42_RELAYS") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// What the port itself can do on this machine: the machine grants of the identity it runs as.
    /// A guest who drives the port can make it use them, so the creator is told before sharing.
    func portMachineGrants(_ key: String) -> [PortPermission] {
        guard let panel = portWindows.panels.first(where: { $0.udid == key }), let author = panel.createdBy,
              !author.isEmpty else { return [] }
        return grants(grantee: author, on: .machine, zone: panel.spaceId).sorted { $0.rawValue < $1.rawValue }
    }

    func inviteError(_ reason: String, _ message: String) -> BridgeError {
        BridgeError(code: .inviteInvalid, message: message, details: ["reason": reason])
    }

    // MARK: Creating

    struct CreatedInvite {
        let id: String
        let coupon: InviteCoupon
        let code: String?
        let discloses: [PortPermission]
    }

    func createInvite(port: String, rights: [RemoteRight], life: TimeInterval, requireCode: Bool,
                      by p: Principal) throws -> CreatedInvite {
        if port == PortChat.desktopKey || port == PortObject.machinePortKey {
            throw BridgeError.badArg("port 0 is this machine itself and is never shared")
        }
        if spaces.contains(where: { $0.id == port }) {
            throw BridgeError.badArg("an invite shares one port, not a space")
        }
        guard let key = resolvePortRef(port)?.key,
              let panel = portWindows.panels.first(where: { $0.udid == key }) else {
            throw BridgeError.notFound("port '\(port)'")
        }
        guard let host = localPeerID else {
            throw BridgeError(code: .wrongState, message: "this instance has no peer id yet; its gateway has not started")
        }
        let relays = inviteRelays
        guard !relays.isEmpty else {
            throw BridgeError(code: .wrongState,
                              message: "no relay is configured, so nobody could reach this port. Set PORT42_RELAYS.")
        }
        guard !rights.isEmpty else { throw BridgeError.badArg("an invite must give at least one right") }

        let nonce = Self.randomBase64URL(bytes: 16)
        let code = requireCode ? Self.randomCode() : nil
        let id = UUID().uuidString
        let expires = Date().addingTimeInterval(min(max(life, 60), Self.inviteMaxLife))
        try db.insertInvite(id: id, portKey: key, rights: rights, nonceHash: Self.inviteHash(nonce),
                            codeHash: code.map(Self.inviteHash), createdBy: p.id, expiresAt: expires)
        let coupon = InviteCoupon(host: host, relays: relays, port: key, rights: rights.map(\.rawValue),
                                  nonce: nonce, exp: Int(expires.timeIntervalSince1970),
                                  hostName: currentUser?.displayName ?? "Port42", portTitle: panel.title,
                                  code: requireCode)
        return CreatedInvite(id: id, coupon: coupon, code: code, discloses: portMachineGrants(key))
    }

    // MARK: Redeeming (at the remote door, before the caller is enrolled)

    /// Redeem an invite for `peer`, whose key the gateway has attested. Enrols it and grants the port.
    func redeemInvite(peer: String, args: [String: Any]) throws -> BridgeValue {
        guard let nonce = args["nonce"] as? String, !nonce.isEmpty,
              let row = try db.invite(nonceHash: Self.inviteHash(nonce)) else {
            throw inviteError("unknown", "This invite is not one this instance made.")
        }
        if row.revokedAt != nil {
            throw inviteError("revoked", "This invite was withdrawn by the person who sent it.")
        }
        if let by = row.redeemedBy, by != peer {
            throw inviteError("used", "This invite has already been used. Ask for a new one.")
        }
        if row.redeemedBy == nil, row.expiresAt < Date() {
            throw inviteError("expired", "This invite has expired. Ask for a new one.")
        }
        if row.redeemedBy == nil, let codeHash = row.codeHash {
            let given = (args["code"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard ClientRegistry.constantTimeEquals(Self.inviteHash(given), codeHash) else {
                let tries = try db.bumpInviteCodeTries(id: row.id)
                if tries >= Self.inviteCodeTries {
                    try db.revokeInvite(id: row.id)
                    throw inviteError("locked", "Too many wrong codes; this invite no longer works.")
                }
                throw inviteError("wrong_code", "That code is not right.")
            }
        }
        guard let panel = portWindows.panels.first(where: { $0.udid == row.portKey }) else {
            throw inviteError("gone", "The port this invite was for is no longer there.")
        }

        // Enrol, or re-enrol, this peer. A new invite is new consent, so a removed peer comes back.
        let typed = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typed.isEmpty ? "a guest" : String(typed.prefix(40))
        let existing = try db.client(peerKey: peer)
        let id = existing?.id ?? ClientRegistry.slug("peer-\(name)-\(peer.prefix(8))")
        try db.upsertPeerClient(id: id, name: existing?.name ?? name, peerKey: peer)
        let rights = remoteRights(of: peer, onPort: row.portKey).union(row.rights)
        grantRemoteRights(rights, to: peer, onPort: row.portKey)
        if row.redeemedBy == nil {
            try db.markInviteRedeemed(id: row.id, by: peer)
            let shown = rights.map(\.rawValue).sorted().joined(separator: ", ")
            postSystemChatLine(key: row.portKey,
                               text: "\(existing?.name ?? name) joined from another machine (\(shown)). "
                                   + "Remove them in Settings → Access.")
        }
        return .object(["port": .string(row.portKey), "title": .string(panel.title),
                        "rights": .array(rights.map(\.rawValue).sorted().map { .string($0) }),
                        "token": .string(portInput.token(for: row.portKey))])
    }
}

// MARK: - The methods

@MainActor
func registerInviteMethods(into r: inout BridgeRegistry, appState: AppState) {
    r["invite.create"] = BridgeMethod(permission: nil, paramNames: ["port", "rights", "expiresIn", "requireCode"],
        description: "Make an invite link that lets one person on another machine open ONE port: in Port42 if they have it, otherwise in their browser. Returns { link, code?, id, expires, discloses }. rights: any of see, use, edit, wake_agents (default see and use). requireCode: a six-digit code they must type, sent to them another way. `discloses` lists what the port itself can do on this machine; whoever you let in can make it do so. Port 0 and spaces cannot be shared.",
        inputSchema: [
            "type": "object",
            "properties": [
                "port": ["type": "string", "description": "The port to share (id / udid / title)."],
                "rights": ["type": "array", "items": ["type": "string"],
                           "description": "see, use, edit, wake_agents. Default see and use."] as [String: Any],
                "expiresIn": ["type": "integer", "description": "Seconds until the link stops working (default 7 days, at most 30)."],
                "requireCode": ["type": "boolean", "description": "Require a six-digit code, to send another way."],
            ] as [String: Any],
            "required": ["port"],
        ]) { p, args in
        // Sharing hands a port to someone elsewhere, so an agent or client asks first. The person
        // using Port42 is never asked on their own behalf.
        if p.kind != .human {
            guard await appState.ensurePermission(.share, for: p) else {
                throw BridgeError.permissionDenied(PortPermission.share.rawValue)
            }
        }
        let raw = (args.array("rights") as? [String]) ?? ["see", "use"]
        var rights: [RemoteRight] = []
        for r in raw {
            guard let right = RemoteRight(rawValue: r) else {
                throw BridgeError.badArg("unknown right '\(r)': use see, use, edit or wake_agents")
            }
            if !rights.contains(right) { rights.append(right) }
        }
        let life = TimeInterval(args.int("expiresIn") ?? Int(AppState.inviteDefaultLife))
        let made = try appState.createInvite(port: try args.requireString("port"), rights: rights, life: life,
                                             requireCode: args.bool("requireCode") == true, by: p)
        var out: [String: BridgeValue] = [
            "id": .string(made.id), "link": .string(made.coupon.link),
            "expires": .int(made.coupon.exp), "rights": .array(made.coupon.rights.map { .string($0) }),
            "discloses": .array(made.discloses.map { .string($0.rawValue) }),
        ]
        if let code = made.code { out["code"] = .string(code) }
        return .object(out)
    }

    r["invite.list"] = BridgeMethod(permission: nil,
        description: "The invites this instance has made: id, port, rights, expiry, whether a code is required, and whether each is open, used (by which peer), expired or withdrawn.",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { _, _ in
        let rows = (try? appState.db.allInvites()) ?? []
        return .array(rows.map { row in
            let state = row.revokedAt != nil ? "withdrawn" : row.redeemedBy != nil ? "used"
                : row.expiresAt < Date() ? "expired" : "open"
            var o: [String: BridgeValue] = [
                "id": .string(row.id), "port": .string(row.portKey), "state": .string(state),
                "rights": .array(row.rights.map { .string($0.rawValue) }),
                "expires": .int(Int(row.expiresAt.timeIntervalSince1970)), "code": .bool(row.codeHash != nil),
            ]
            if let by = row.redeemedBy { o["usedBy"] = .string(by) }
            return .object(o)
        })
    }

    r["invite.revoke"] = BridgeMethod(permission: nil, paramNames: ["id"],
        description: "Withdraw an invite that has not been used. To remove someone who already joined, remove them in Settings → Access.",
        inputSchema: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]) { _, args in
        try appState.db.revokeInvite(id: try args.requireString("id"))
        return .object(["ok": .bool(true)])
    }
}

// MARK: - For Settings → Access

extension AppState {

    /// One port shared with one peer, as the manager shows it.
    public struct SharedPort: Identifiable, Equatable {
        public let id: String
        public let peer: String
        public let name: String
        public let portKey: String
        public let title: String
        public let rights: [RemoteRight]
        public let peerRemoved: Bool
    }

    /// Every port shared with another machine, by peer and port.
    public func sharedPorts() -> [SharedPort] {
        let rows = (try? db.allRemoteRights()) ?? []
        let byPair = Dictionary(grouping: rows, by: { "\($0.grantee)|\($0.portKey)" })
        return byPair.keys.sorted().compactMap { pair in
            guard let first = byPair[pair]?.first else { return nil }
            let client = try? db.client(peerKey: first.grantee)
            let title = portWindows.panels.first { $0.udid == first.portKey }?.title ?? "a port that is gone"
            return SharedPort(id: pair, peer: first.grantee, name: client?.name ?? "someone",
                              portKey: first.portKey, title: title,
                              rights: (byPair[pair] ?? []).map(\.right).sorted { $0.rawValue < $1.rawValue },
                              peerRemoved: client?.isActive == false)
        }
    }

    /// Invites not yet used, withdrawn or expired.
    public func openInvites() -> [DatabaseService.InviteRow] {
        ((try? db.allInvites()) ?? []).filter { $0.revokedAt == nil && $0.redeemedBy == nil && $0.expiresAt > Date() }
    }

    /// Stop sharing one port with one peer; its other ports stay shared.
    public func stopSharing(peer: String, port: String) {
        grantRemoteRights([], to: peer, onPort: port)
    }

    public func withdrawInvite(id: String) {
        try? db.revokeInvite(id: id)
    }
}
