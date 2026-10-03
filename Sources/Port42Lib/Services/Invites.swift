import Foundation
import CryptoKit

// MARK: - Invites (nautilus Phase 4, step 4.5; docs/design-phase4-relay.md "The invite")
//
// One invite per port (D10). A link names one port and grants that port only; port 0 and spaces are
// never invitable. The link is `https://tele.port42.ai/#<coupon>`: the coupon rides in the
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
    /// The guest handshakes this host accepts (GST-02, docs/design-gst02-guest-keys.md): 1 is a
    /// guest holding its seed, 2 a guest whose keys the page cannot read. Every invite made by this
    /// version says [1, 2]; a coupon without it (a host from before) means v1 only, and a guest on
    /// the new keys is told to ask for an updated link. `v` stays 1: today's guest page refuses any
    /// other, and ignores this field.
    public var noise: [Int]? = [1, 2]

    public static let pageURL = "https://tele.port42.ai/"

    /// base64url of the JSON, for a URL fragment.
    public var encoded: String {
        // Sorted keys: one invite is one link, whenever it is spelled out (it is kept to copy again).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The link to send: it opens the invite page, which offers Port42 or the browser.
    public var link: String { Self.pageURL + "#" + encoded }

    /// The coupon in an invite link (its fragment), or a bare coupon.
    /// The invite link in some text (a pasted line, a clicked URL): the web page's link or Port42's own
    /// `port42://invite#…`, carrying a coupon that decodes. nil for anything else.
    public static func inviteLink(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix(pageURL + "#") || t.hasPrefix("port42://invite#"), fromLink(t) != nil else { return nil }
        return t
    }

    public static func fromLink(_ link: String) -> InviteCoupon? {
        decode(link.split(separator: "#", maxSplits: 1).last.map(String.init) ?? link)
    }

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

    static func configuredRelays() -> [String] { GatewayProcess.relays() }

    /// What the port itself can do on this machine: the machine grants of the identity it runs as.
    /// A guest who drives the port can make it use them, so the creator is told before sharing.
    ///
    /// Read from the port's own principal (APP-06), the identity every call from its page is
    /// judged as: its creator for a companion-made port, and the port itself otherwise. Reading
    /// `createdBy` alone disclosed nothing for a port with no creator, which can hold grants too.
    func portMachineGrants(_ key: String) -> [PortPermission] {
        guard let panel = portWindows.panels.first(where: { $0.udid == key }) else { return [] }
        let runsAs = panel.bridge.portPrincipal
        return grants(grantee: runsAs.id, on: .machine, zone: runsAs.spaceId).sorted { $0.rawValue < $1.rawValue }
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
        guard Self.shareable(panel) else {
            throw BridgeError.badArg("only a web port can be shared: a terminal would let them type into your shell, "
                                     + "and a browser would let them act as you on the sites it is signed in to")
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
        refreshSharing()
        let coupon = InviteCoupon(host: host, relays: relays, port: key, rights: rights.map(\.rawValue),
                                  nonce: nonce, exp: Int(expires.timeIntervalSince1970),
                                  hostName: currentUser?.displayName ?? "Port42", portTitle: panel.title,
                                  code: requireCode)
        keepInviteLink(id: id, link: coupon.link, code: code)
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
        // A link lets in two keys, then it is used up (GM, 2026-09-27): the person who looked in the
        // browser first can still open it in their Port42. A key it already let in is not a use.
        let fresh = peer != row.redeemedBy && peer != row.redeemedAgainBy
        if fresh, row.redeemedAgainBy != nil {
            throw inviteError("used", "This invite has already been used. Ask for a new one.")
        }
        if fresh, row.redeemedBy != nil, row.rights.contains(.move) {     // a port moves once
            throw inviteError("used", "This port has already moved.")
        }
        if fresh, row.expiresAt < Date() {
            throw inviteError("expired", "This invite has expired. Ask for a new one.")
        }
        if fresh, let codeHash = row.codeHash {
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
        guard Self.shareable(panel) else {
            throw inviteError("gone", "That port cannot be shared.")
        }

        // Enrol, or re-enrol, this peer. A NEW invite is new consent, so a removed peer comes back on
        // one. Presenting an invite it already redeemed is not: that used to clear the revocation too,
        // so a peer removed in Settings was back on its next reconnect (APP-12).
        let typed = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typed.isEmpty ? "a guest" : String(typed.prefix(40))
        let existing = try db.client(peerKey: peer)
        if let existing, existing.revokedAt != nil, !fresh {
            throw inviteError("revoked", "You were removed from this port. Ask for a new invite.")
        }
        let id = existing?.id ?? ClientRegistry.slug("peer-\(name)-\(peer.prefix(8))")
        let label = existing?.name ?? peerLabel(name, peer: peer)
        try db.upsertPeerClient(id: id, name: label, peerKey: peer)
        if existing?.revokedAt != nil { try db.restoreClient(id: id) }   // fresh: a new invite
        // A move hands the port over: its page goes to them, it closes here (archived, so it can be
        // restored), and no right is granted, since nothing stays to reach.
        if row.rights.contains(.move) {
            guard row.redeemedBy == nil else { throw inviteError("used", "This port has already moved.") }
            let html = (try? db.fetchPortHtml(udid: row.portKey)).flatMap { $0 } ?? panel.html
            try db.markInviteRedeemed(id: row.id, by: peer)
            let closing = panel.id
            DispatchQueue.main.async { [weak self] in self?.portWindows.close(closing); self?.refreshSharing() }
            p42log("[invite] %@ moved to %@", panel.title, label)
            return .object(["moved": .bool(true), "title": .string(panel.title), "html": .string(html)])
        }
        let rights = remoteRights(of: peer, onPort: row.portKey).union(row.rights)
        grantRemoteRights(rights, to: peer, onPort: row.portKey)
        if fresh {
            if row.redeemedBy == nil { try db.markInviteRedeemed(id: row.id, by: peer) }
            else { try db.markInviteRedeemedAgain(id: row.id, by: peer) }
            refreshSharing()
            let shown = rights.map(\.rawValue).sorted().joined(separator: ", ")
            postSystemChatLine(key: row.portKey,
                               text: "\(label) joined from another machine (\(shown)). "
                                   + "To stop sharing, click 'shared' on the port.")
        }
        return .object(["port": .string(row.portKey), "title": .string(panel.title), "knownAs": .string(label),
                        "rights": .array(rights.map(\.rawValue).sorted().map { .string($0) }),
                        "token": .string(portInput.token(for: row.portKey))])
    }
}

// MARK: - The methods

@MainActor
func registerInviteMethods(into r: inout BridgeRegistry, appState: AppState) {
    r["invite.create"] = BridgeMethod(permission: nil, paramNames: ["port", "rights", "expiresIn", "requireCode"],
        description: "Make an invite link that lets one person on another machine open ONE port: in Port42 if they have it, otherwise in their browser. The link lets in two machines (say their browser, then their Port42) and is then used up. Returns { link, code?, id, expires, discloses }. rights: any of see, use, edit, wake_agents, fork (default see, use and wake_agents: remote wake, their companions may wake yours in this port's chat; fork lets them take a copy, which Port42 offers only when given; move hands the port over to whoever opens the link, once, and closes it here, asked every time). requireCode: a six-digit code they must type, sent to them another way. `discloses` lists what the port itself can do on this machine; whoever you let in can make it do so. Port 0 and spaces cannot be shared.",
        inputSchema: [
            "type": "object",
            "properties": [
                "port": ["type": "string", "description": "The port to share (id / udid / title)."],
                "rights": ["type": "array", "items": ["type": "string"],
                           "description": "see, use, edit, wake_agents, fork, move. Default see, use and wake_agents."] as [String: Any],
                "expiresIn": ["type": "integer", "description": "Seconds until the link stops working (default 7 days, at most 30)."],
                "requireCode": ["type": "boolean", "description": "Require a six-digit code, to send another way."],
            ] as [String: Any],
            "required": ["port"],
        ]) { p, args in
        let raw = (args.array("rights") as? [String]) ?? ["see", "use", "wake_agents"]
        var rights: [RemoteRight] = []
        for r in raw {
            guard let right = RemoteRight(rawValue: r) else {
                throw BridgeError.badArg("unknown right '\(r)': use see, use, edit, wake_agents, fork or move")
            }
            if !rights.contains(right) { rights.append(right) }
        }
        // Sharing hands a port to someone elsewhere, so an agent or client asks first, for each port
        // (Gordon, 2026-09-26): leave to share one port is not leave to share the next. The person
        // using Port42 is never asked on their own behalf.
        //
        // NAU-03: the card says WHAT is given (the rights) and what the port can reach here, and a
        // yes covers only that port with exactly those rights. `edit` and `move` are asked every
        // time and never remembered: one lets them change the code that runs here, the other hands
        // the port over.
        if p.kind != .human, let key = appState.resolvePortRef(try args.requireString("port"))?.key {
            let title = appState.portWindows.panels.first { $0.udid == key }?.title ?? key
            let detail = AppState.shareCardDetail(title: title, rights: rights,
                                                  reach: appState.portMachineGrants(key))
            guard try await appState.ensureShareGrant(AppState.shareObject(port: key, rights: rights),
                                                  detail: detail, for: p,
                                                  remember: !rights.contains(.edit) && !rights.contains(.move)) else {
                throw BridgeError.permissionDenied(PortPermission.share.rawValue)
            }
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
        description: "The invites this instance has made: id, port, rights, expiry, whether a code is required, and whether each is open, used, expired or withdrawn. A link lets in two machines (a move, one), so it stays open after the first: usedBy names the first and usedAgainBy the second, when it has let them in.",
        inputSchema: ["type": "object", "properties": [String: Any]()]) { p, _ in
        // APP-01: a caller sees only the invites it may manage.
        let rows = ((try? appState.db.allInvites()) ?? []).filter { appState.mayManage($0, by: p) }
        return .array(rows.map { row in
            let state = row.revokedAt != nil ? "withdrawn" : row.isUsedUp ? "used"
                : row.expiresAt < Date() ? "expired" : "open"
            var o: [String: BridgeValue] = [
                "id": .string(row.id), "port": .string(row.portKey), "state": .string(state),
                "rights": .array(row.rights.map { .string($0.rawValue) }),
                "expires": .int(Int(row.expiresAt.timeIntervalSince1970)), "code": .bool(row.codeHash != nil),
            ]
            if let by = row.redeemedBy { o["usedBy"] = .string(by) }
            if let by = row.redeemedAgainBy { o["usedAgainBy"] = .string(by) }
            return .object(o)
        })
    }

    r["invite.revoke"] = BridgeMethod(permission: nil, paramNames: ["id"],
        description: "Withdraw an invite that has not been used. To remove someone who already joined, remove them in Settings → Access.",
        inputSchema: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]) { p, args in
        let id = try args.requireString("id")
        // APP-01: only a caller that may manage it withdraws an invite; any other is not found, so
        // the refusal does not confirm the id.
        guard let row = ((try? appState.db.allInvites()) ?? []).first(where: { $0.id == id }),
              appState.mayManage(row, by: p) else {
            throw BridgeError.notFound("invite '\(id)'")
        }
        try appState.db.revokeInvite(id: id)
        // NAU-06: the share pill and panel read the open invites; a withdrawal must show at once,
        // not wait for something else to refresh them.
        appState.refreshSharing()
        return .object(["ok": .bool(true)])
    }

    // API parity, Phase E (docs/plan-api-parity.md): what the share panel does after the invite.
    // The caller must manage the port (the person, the port itself, or the maker of an invite for it).
    func sharedPort(_ p: Principal, _ args: BridgeArgs) throws -> String {
        let raw = try args.requireString("port")
        guard let key = appState.resolvePortRef(raw)?.key, appState.mayManage(sharingOf: key, by: p) else {
            throw BridgeError.notFound("port '\(raw)'")
        }
        return key
    }
    func sharedPeer(_ key: String, _ args: BridgeArgs) throws -> AppState.SharedPort {
        let peer = try args.requireString("peer")
        guard let row = appState.sharedPorts().first(where: { $0.portKey == key && ($0.peer == peer || $0.name == peer) }) else {
            throw BridgeError.notFound("anyone called '\(peer)' with that port shared")
        }
        return row
    }

    r["invite.shared"] = BridgeMethod(permission: nil, paramNames: ["port"],
        description: "Who a port is shared with now: each person's peer key, name and rights. A person who joined through an invite; invite_list shows the links.",
        inputSchema: ["type": "object", "properties": ["port": ["type": "string", "description": "The port (id / udid / title)."]], "required": ["port"]]) { p, args in
        let key = try sharedPort(p, args)
        return .array(appState.sharedPorts().filter { $0.portKey == key && !$0.rights.isEmpty }.map { s in
            .object(["peer": .string(s.peer), "name": .string(s.name), "removed": .bool(s.peerRemoved),
                     "rights": .array(s.rights.map { .string($0.rawValue) })])
        })
    }

    r["invite.setRights"] = BridgeMethod(permission: nil, paramNames: ["port", "peer", "rights"],
        description: "Change what one person a port is shared with may do: rights is the full set wanted, of use, edit, wake_agents, fork (see always stays; to remove someone use invite_stop). Taking rights away needs no card. Adding any asks the person first, every time for edit, as sharing does. Returns the rights now held.",
        inputSchema: [
            "type": "object",
            "properties": [
                "port": ["type": "string", "description": "The port (id / udid / title)."],
                "peer": ["type": "string", "description": "The person's peer key or name (from invite_shared)."],
                "rights": ["type": "array", "items": ["type": "string"], "description": "The full set wanted: use, edit, wake_agents, fork."] as [String: Any],
            ] as [String: Any],
            "required": ["port", "peer", "rights"],
        ]) { p, args in
        let key = try sharedPort(p, args)
        let who = try sharedPeer(key, args)
        var wanted: Set<RemoteRight> = [.see]
        for raw in (args.array("rights") as? [String]) ?? [] {
            guard let right = RemoteRight(rawValue: raw), right != .move else {
                throw BridgeError.badArg("unknown right '\(raw)': use use, edit, wake_agents or fork")
            }
            wanted.insert(right)
        }
        let held = Set(who.rights)
        let added = wanted.subtracting(held)
        guard wanted != held else { throw BridgeError.badArg("nothing to change: they already hold exactly those rights") }
        if !added.isEmpty, p.kind != .human {
            let list = RemoteRight.allCases.filter(added.contains)
            let detail = "Give \(who.name) more on '\(who.title)': " + AppState.shareCardDetail(title: who.title, rights: list, reach: appState.portMachineGrants(key))
            guard try await appState.ensureShareGrant(AppState.shareObject(port: key, rights: list) + "@" + who.peer,
                                                      detail: detail, for: p, remember: !added.contains(.edit)) else {
                throw BridgeError.permissionDenied(PortPermission.share.rawValue)
            }
        }
        appState.grantRemoteRights(wanted, to: who.peer, onPort: key)
        return .object(["ok": .bool(true), "rights": .array(wanted.map(\.rawValue).sorted().map { .string($0) })])
    }

    r["invite.stop"] = BridgeMethod(permission: nil, paramNames: ["port", "peer"],
        description: "Stop sharing a port with one person: their access goes, and the links they came in on are withdrawn. The port stays shared with anyone else. Taking access away needs no card.",
        inputSchema: [
            "type": "object",
            "properties": [
                "port": ["type": "string", "description": "The port (id / udid / title)."],
                "peer": ["type": "string", "description": "The person's peer key or name (from invite_shared)."],
            ],
            "required": ["port", "peer"],
        ]) { p, args in
        let key = try sharedPort(p, args)
        let who = try sharedPeer(key, args)
        appState.stopSharing(peer: who.peer, port: key)
        return .object(["ok": .bool(true), "stopped": .string(who.name)])
    }

    // A tile of someone else's port is the person's here. A caller other than the person asks every time.
    func mirrorTile(_ p: Principal, _ args: BridgeArgs) throws -> (tile: String, row: DatabaseService.RemotePortRow) {
        let tile = try args.requireString("tile")
        guard let row = appState.mirroredRemote(tile),
              appState.canRead(portInSpace: appState.portWindows.panels.first(where: { $0.id == tile })?.spaceId, by: p) else {
            throw BridgeError.notFound("a shared-with-you port '\(tile)'")
        }
        return (tile, row)
    }

    r["remote.leave"] = BridgeMethod(permission: nil, paramNames: ["tile"], toolExposed: false,
        description: "Leave a port someone shared with you: its tile closes here and this instance forgets it. The host's grant is theirs to remove; a new invite brings it back. Anyone but the person is asked first, every time.",
        inputSchema: ["type": "object", "properties": ["tile": ["type": "string", "description": "The tile's id (from ports_list: a port with a mirrors entry)."]], "required": ["tile"]]) { p, args in
        let (tile, row) = try mirrorTile(p, args)
        if p.kind != .human {
            guard try await appState.ask(.changeSharing, from: p, detail: "Leave '\(row.title)', shared by \(row.hostName): its tile closes and you need a new invite to get it back") else {
                throw BridgeError.permissionDenied(PortPermission.changeSharing.rawValue)
            }
        }
        appState.leaveRemotePort(tile: tile)
        return .object(["ok": .bool(true)])
    }

    r["remote.setWake"] = BridgeMethod(permission: nil, paramNames: ["tile", "on"], toolExposed: false,
        description: "Whether a mention in the host's chat of a port shared with you may wake your own companions here. Turning it on by anyone but the person asks first, every time; turning it off never does.",
        inputSchema: [
            "type": "object",
            "properties": [
                "tile": ["type": "string", "description": "The tile's id (from ports_list)."],
                "on": ["type": "boolean", "description": "true to let them wake your companions."],
            ],
            "required": ["tile", "on"],
        ]) { p, args in
        let (tile, row) = try mirrorTile(p, args)
        guard let on = args.bool("on") else { throw BridgeError.badArg("on is true or false") }
        if on, p.kind != .human, !row.wakes {
            guard try await appState.ask(.changeSharing, from: p, detail: "Let a mention in \(row.hostName)'s chat of '\(row.title)' wake your companions here") else {
                throw BridgeError.permissionDenied(PortPermission.changeSharing.rawValue)
            }
        }
        appState.setMirrorWakes(tile: tile, on)
        return .object(["ok": .bool(true), "wakes": .bool(on)])
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

    /// Invites not used up, withdrawn or expired. One key in is not used up: the link still lets in a
    /// second, so it stays listed and copyable (it vanished after the browser opened it, GM 2026-09-27).
    public func openInvites() -> [DatabaseService.InviteRow] {
        ((try? db.allInvites()) ?? []).filter { $0.revokedAt == nil && !$0.isUsedUp && $0.expiresAt > Date() }
    }

    /// Stop sharing one port with one peer; its other ports stay shared. The links they came in on for
    /// this port are withdrawn too: a link lets a key it already let in back in, so leaving one open
    /// would let them straight back.
    public func stopSharing(peer: String, port: String) {
        for row in (try? db.allInvites()) ?? [] where row.portKey == port && row.revokedAt == nil
            && (row.redeemedBy == peer || row.redeemedAgainBy == peer) {
            try? db.revokeInvite(id: row.id)
        }
        grantRemoteRights([], to: peer, onPort: port)
        refreshSharing()
    }

    public func withdrawInvite(id: String) {
        try? db.revokeInvite(id: id)
        refreshSharing()
    }

    /// What copying an unused invite again gives the person: its link, with its code under it when it
    /// has one. Only the person reaches this, from the app: `invite.list` never returns a link, so an
    /// agent cannot get one without the per-port card.
    public func inviteMessage(id: String) -> String? {
        guard openInvites().contains(where: { $0.id == id }) else { return nil }
        return Self.isTestProcessStore ? Self.testInviteLinks[id] : Port42AuthStore.shared.inviteLink(id: id)
    }

    func keepInviteLink(id: String, link: String, code: String?) {
        let message = code.map { "\(link)\ncode: \($0)" } ?? link
        if Self.isTestProcessStore { Self.testInviteLinks[id] = message } else { Port42AuthStore.shared.saveInviteLink(message, id: id) }
    }

    /// Links of invites no longer open (used, withdrawn, expired) are forgotten.
    func forgetClosedInviteLinks() {
        let open = Set(openInvites().map(\.id))
        for row in (try? db.allInvites()) ?? [] where !open.contains(row.id) {
            if Self.isTestProcessStore { Self.testInviteLinks[row.id] = nil } else { Port42AuthStore.shared.deleteInviteLink(id: row.id) }
        }
    }

    static var isTestProcessStore: Bool { ClientRegistry.isTestProcess }
    static var testInviteLinks: [String: String] = [:]

    /// Rebuild `sharing` from the rights and invites tables.
    func refreshSharing() {
        forgetClosedInviteLinks()
        var out: [String: PortSharing] = [:]
        for s in sharedPorts() where !s.rights.isEmpty { out[s.portKey, default: PortSharing()].people.append(s) }
        for i in openInvites() { out[i.portKey, default: PortSharing()].openInvites += 1 }
        sharing = out
        // Reachable through the relays only while something is shared or an invite could still be
        // redeemed (GW-16): every install used to register at launch and stay registered.
        let host = !out.isEmpty
        if host != relayHosting {
            relayHosting = host
            // Leaving: give the last notice (an `access` event) a moment to cross before the relays go.
            if !host, relayLeaveDelay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + relayLeaveDelay) { [weak self] in
                    guard let self, !self.relayHosting else { return }
                    self.onRelayHosting(false)
                }
                return
            }
            onRelayHosting(host)
        }
    }

    /// What the sharing pill in a tile's chrome says, if anything: a port of this instance that is
    /// shared or has an invite out, or a tile mirroring someone else's port.
    public func sharePill(tile id: String, key: String?) -> SharePill? {
        if let m = mirrorStatus[id] { return m.ended ? .ended(host: m.hostName) : .theirs(host: m.hostName, online: m.online) }
        guard let key, let s = sharing[key], !s.people.isEmpty || s.openInvites > 0 else { return nil }
        return .shared(people: s.people.count, invites: s.openInvites)
    }

    /// Give or take one right from one machine on one port. `see` is what sharing is, so it stays;
    /// taking everything is `stopSharing`.
    public func setRemoteRight(_ right: RemoteRight, _ on: Bool, peer: String, port: String) {
        guard right != .see else { return }
        var rights = remoteRights(of: peer, onPort: port)
        if on { rights.insert(right) } else { rights.remove(right) }
        grantRemoteRights(rights, to: peer, onPort: port)
    }
}

// MARK: - Accepting an invite, and reaching a port on another instance (nautilus Phase 4, 4.6)

extension AppState {

    /// Redeem an invite made by another instance, as this instance, and remember the port. Returns
    /// the port's address: `port42://<host>/<port>`.
    /// Whether a port can be shared with another machine: a web port only. A terminal is this machine's
    /// shell (`use` would type into it, `see` would read everything it prints) and a browser is signed in
    /// as this person, so neither is ever handed to someone elsewhere.
    static func shareable(_ panel: PortPanel) -> Bool { panel.portType == "web" }

    /// The name a newly enrolled instance is shown by here (4.6c, Gordon): the name it gave, unless this
    /// person or another instance already goes by it, when it gains the first four characters of its
    /// peer id. Fixed at enrolment, so a label people have seen never changes, and the first to take a
    /// name keeps it plain.
    func peerLabel(_ name: String, peer: String) -> String {
        let taken = Set(((try? db.allClients()) ?? []).filter { $0.kind == .peer && $0.peerKey != peer }
                            .map { $0.name.lowercased() })
            .union([currentUser?.displayName.lowercased()].compactMap { $0 })
        return taken.contains(name.lowercased()) ? "\(name) \(peer.prefix(4))" : name
    }

    /// The name this instance gives when it joins another: the machine's own name if the person set one
    /// in Settings, else theirs.
    var joiningName: String {
        let set = (UserDefaults.standard.string(forKey: Self.machineNameKey) ?? "").trimmingCharacters(in: .whitespaces)
        return set.isEmpty ? (currentUser?.displayName ?? "a Port42") : set
    }
    static let machineNameKey = "PORT42_MACHINE_NAME"

    /// The grant object for sharing one port: a local port's key, or `<peer>/<port>` for one elsewhere.
    static func shareObject(port: String) -> String { "share:" + port }

    /// The grant object for sharing one port WITH these rights (NAU-03). The rights are part of the
    /// key, so a yes to "see" is not a yes to "see, use, wake_agents": any other set asks again.
    static func shareObject(port: String, rights: [RemoteRight]) -> String {
        shareObject(port: port) + "#" + rights.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// What the share card says (NAU-03): the port, what the person on the other machine could do
    /// with it, and what the port itself can reach here, since they can make it use that.
    static func shareCardDetail(title: String, rights: [RemoteRight], reach: [PortPermission]) -> String {
        let can = RemoteRight.allCases.filter(rights.contains).map { right -> String in
            switch right {
            case .see:        return "see it"
            case .use:        return "use it and post in its chat"
            case .edit:       return "change its code, which then runs on this machine"
            case .wakeAgents: return "wake your agents from its chat"
            case .fork:       return "take a copy"
            case .move:       return "take it over (it closes here)"
            }
        }
        let reachLine = reach.isEmpty
            ? "It reaches nothing else on this machine."
            : "It can use \(reach.map(\.rawValue).joined(separator: ", ")) on this machine, "
              + "and whoever you let in can make it do so."
        return "Share '\(title)' with another machine. They could \(can.joined(separator: ", ")). \(reachLine)"
    }

    /// Ask a caller to share a port or open one (see `invite.create`, `invite.accept`). A yes is kept
    /// for `object` unless `remember` is false, when it is asked every time (NAU-03: edit, move).
    func ensureShareGrant(_ object: String, detail: String, for p: Principal,
                          remember: Bool = true) async throws -> Bool {
        if remember, (try? db.grants(grantee: p.id, object: object, zone: ""))?.contains(.share) == true { return true }
        guard try await ask(.share, from: p, detail: detail) else { return false }
        if remember { try? db.saveGrants([.share], grantee: p.id, object: object, zone: "") }
        return true
    }

    func acceptInvite(_ linkOrCoupon: String, code: String?) async throws -> (address: PortAddress, title: String, rights: [RemoteRight], moved: String?) {
        guard let c = InviteCoupon.fromLink(linkOrCoupon) else { throw BridgeError.badArg("that is not an invite link") }
        if c.host == localPeerID { throw BridgeError.badArg("that invite is for a port on this instance") }
        var args: [String: Any] = ["nonce": c.nonce, "name": joiningName]
        if let code, !code.isEmpty { args["code"] = code }
        let out = try await door.remoteCall(to: c.host, relays: c.relays, method: "invite.redeem", args: args)
        let o = out as? [String: Any] ?? [:]
        let title = (o["title"] as? String) ?? c.portTitle
        // A move: the port is now this instance's own, made from the page it sent; nothing is mirrored.
        if o["moved"] as? Bool == true, let html = o["html"] as? String {
            guard let space = currentSpace?.id else { throw BridgeError(code: .wrongState, message: "no space to put the port in") }
            let made = createPort(type: "web", title: title, html: html, command: nil, cwd: nil, systemPrompt: nil,
                                  spaceId: space, createdBy: nil, createdByName: nil)
            guard let id = made["id"] as? String else { throw BridgeError.badArg(made["error"] as? String ?? "the port could not be made here") }
            return (PortAddress(peerID: localPeerID, spaceId: nil, portId: id), title, [], id)
        }
        let rights = ((o["rights"] as? [String]) ?? c.rights).compactMap(RemoteRight.init(rawValue:))
        try db.upsertRemotePort(.init(peerKey: c.host, portKey: c.port, title: title, rights: rights,
                                      relays: c.relays, hostName: c.hostName))
        if let knownAs = o["knownAs"] as? String {
            try db.setRemotePortKnownAs(peerKey: c.host, portKey: c.port, knownAs: knownAs)
        }
        return (PortAddress(peerID: c.host, spaceId: nil, portId: c.port), title, rights, nil)
    }

    /// Where a port reference lives, when it is not here: the instance that holds it and its own id
    /// there. One layer for every reference (Gordon, 2026-09-26: addressing inside an instance is the
    /// same as across them): `port42://<other>/<id>` names that instance's port, and a tile mirroring a
    /// port on another instance, named by its id, its title or `port42://<this>/<tile>`, is that port.
    /// nil for a port on this instance.
    func remotePort(for ref: String) -> (peer: String, port: String)? {
        let addr = PortAddress.parse(ref)
        if let addr, let peer = addr.peerID, peer != localPeerID { return (peer, addr.portId) }
        guard let local = resolvePortRef(addr?.portId ?? ref), let tile = local.id ?? local.messageId,
              let row = mirroredRemote(tile) else { return nil }
        return (row.peerKey, row.portKey)
    }

    /// If a local caller names a port that lives on ANOTHER instance, the call to forward: that
    /// instance, the port's id there, and the argument that named it. nil for a port here, for a
    /// remote caller (never forwarded on), and for a method that does not act on a named port.
    func remoteTarget(_ method: String, principal: Principal, args: BridgeArgs) -> (peer: String, port: String, param: String)? {
        guard principal.kind != .remote, case .port(let param, _) = RemoteAccess.reach(method),
              let raw = args.string(param), let target = remotePort(for: raw) else { return nil }
        // Your tile is a window onto the port (Gordon, 2026-09-26): what the window shows stays here.
        // Named by the tile, these read this copy; named by the port's address, they go to the port.
        if Self.windowMethods.contains(method), PortAddress.parse(raw)?.peerID.map({ $0 != localPeerID }) != true {
            return nil
        }
        return (target.peer, target.port, param)
    }

    /// The space of the tile that mirrors a port on another instance here (nil if it has no tile).
    func mirrorTileSpace(peer: String, port: String) -> String? {
        let links = (try? db.remotePortTiles()) ?? [:]
        guard let tile = links.first(where: { $0.value.peerKey == peer && $0.value.portKey == port })?.key else { return nil }
        return portWindows.panels.first { $0.id == tile }?.spaceId
    }

    /// What a tile shows, as opposed to the port it shows: its page, its console, its code, whether it
    /// is on screen. `port.exec` and `presentation` are never sent to another instance anyway.
    static let windowMethods: Set<String> = ["port.getDom", "port.console", "port.exec", "presentation"]

    /// Forward a call to the instance that holds the port, through its relays.
    /// Who a local caller is, as another instance is told (4.6c). A companion in a terminal calls
    /// through the CLI as a client, and is known as a companion here by its name, as `routeChat`
    /// knows it; so the other instance applies the same rule: a companion's post wakes only whom it names.
    func remoteActor(for p: Principal) -> RemoteActor? {
        switch p.kind {
        case .human, .companion: return RemoteActor(id: p.id, name: p.displayName, kind: p.kind)
        case .peer:
            if let c = companions.first(where: { $0.displayName.lowercased() == p.displayName.lowercased() }) {
                return RemoteActor(id: c.id, name: c.displayName, kind: .companion)
            }
            return RemoteActor(id: p.id, name: p.displayName, kind: .peer)
        case .port: return RemoteActor(id: p.portId ?? p.id, name: p.displayName, kind: .port)
        default: return nil
        }
    }

    func forwardRemote(_ method: String, to target: (peer: String, port: String, param: String), args: BridgeArgs,
                       as caller: Principal? = nil,
                       onStream: (@MainActor (Any) -> Void)? = nil) async throws -> BridgeValue {
        guard let row = ((try? db.remotePorts()) ?? []).first(where: { $0.peerKey == target.peer }) else {
            throw BridgeError.notFound("no invite from that instance: accept one first")
        }
        var forwarded = args.dictionary
        forwarded[target.param] = target.port
        let tile = ((try? db.remotePortTiles()) ?? [:]).first { $0.value.peerKey == target.peer && $0.value.portKey == target.port }?.key
        do {
            let out = try await door.remoteCall(to: target.peer, relays: row.relays, method: method, args: forwarded,
                                                actor: caller.flatMap(remoteActor(for:)), onStream: onStream)
            // Every answer from the host carries its token: keep it for this tile's reads.
            if let tile, let token = (out as? [String: Any])?["token"] as? String { mirrorHostTokens[tile] = token }
            return BridgeValue.fromJSONObject(out)
        } catch let e as BridgeError {
            if let tile, let current = e.details["current"] { mirrorHostTokens[tile] = current }
            // A host with nothing left to share leaves its relays, so "not connected" is also what stopping
            // sharing looks like from here: say both (two agents, finding 5).
            if e.code == BridgeErrorCode.hostOffline.rawValue {
                throw BridgeError(code: .hostOffline,
                                  message: "\(row.hostName)'s Port42 is not reachable: it is offline, or it no longer shares this port with you",
                                  details: e.details)
            }
            throw e
        }
    }
}

@MainActor
func registerAcceptMethods(into r: inout BridgeRegistry, appState: AppState) {
    r["invite.accept"] = BridgeMethod(permission: nil, paramNames: ["link", "code", "remoteWake", "companions"],
        description: "Accept an invite someone sent you: this instance joins their port, which opens here as a tile. Returns { address, title, rights, tile }. Then call methods on the port by its address or the tile's id. remoteWake (default true): a mention of one of your companions in that port's chat wakes it here, on your model; the tile's chrome can turn it off later. companions: names of your companions to bring onto the tile; only companions brought onto it act on it, and each is told what it is.",
        inputSchema: [
            "type": "object",
            "properties": [
                "link": ["type": "string", "description": "The invite link (https://tele.port42.ai/#…)."],
                "code": ["type": "string", "description": "The six-digit code, if the invite needs one."],
                "remoteWake": ["type": "boolean", "description": "Let their chat wake your companions for this port (default true)."],
                "companions": ["type": "array", "items": ["type": "string"], "description": "Your companions to bring onto the tile (by name)."] as [String: Any],
            ],
            "required": ["link"],
        ]) { p, args in
        // Joining connects this machine to someone else's, so an agent or client asks first, for each
        // port it would open.
        // Remote wake (Gordon, 2026-09-26): each side decides for its own companions when it agrees to
        // share, on by default. Accepting is where this side decides, so it is said on the card.
        let remoteWake = args.bool("remoteWake") ?? true
        if p.kind != .human, let c = InviteCoupon.fromLink(try args.requireString("link")) {
            let wake = remoteWake ? ". Their companions can wake yours in its chat (remote wake)" : ""
            guard try await appState.ensureShareGrant(AppState.shareObject(port: "\(c.host)/\(c.port)"),
                                                  detail: "Open '\(c.portTitle)' from \(c.hostName)\(wake)", for: p) else {
                throw BridgeError.permissionDenied(PortPermission.share.rawValue)
            }
        }
        let joined = try await appState.acceptInvite(try args.requireString("link"), code: args.string("code"))
        if let moved = joined.moved {
            return .object(["moved": .bool(true), "title": .string(joined.title), "port": .string(moved), "tile": .string(moved)])
        }
        if let peer = joined.address.peerID {
            try? appState.db.setRemotePortWakes(peerKey: peer, portKey: joined.address.portId, wakes: remoteWake)
        }
        // The port appears here as a tile that mirrors the host's.
        let tile = try? await appState.openRemoteTile(peer: joined.address.peerID ?? "", port: joined.address.portId)
        var out: [String: BridgeValue] = ["address": .string(joined.address.canonical), "title": .string(joined.title),
                                          "rights": .array(joined.rights.map { .string($0.rawValue) })]
        if let tile {
            out["tile"] = .string(tile)
            let names = Set(((args.array("companions") as? [String]) ?? []).map { $0.lowercased() })
            let chosen = appState.companions.filter { names.contains($0.displayName.lowercased()) }
            appState.bringOnto(tile: tile, companions: chosen)
            if !chosen.isEmpty { out["companions"] = .array(chosen.map { .string($0.displayName) }) }
        }
        return .object(out)
    }
}
