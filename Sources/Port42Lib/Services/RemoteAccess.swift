import Foundation

// MARK: - RemoteAccess
//
// WHAT A CALLER FROM ANOTHER MACHINE MAY REACH (nautilus Phase 4, step 4.1; docs/plan-nautilus-phase4.md
// decision 5).
//
// A local caller is authorized by capability: a permission card asks the person at this machine, and
// every port method is open to any enrolled client. That is tolerable when the caller is already a
// process on this Mac. It is not tolerable for a guest on the other side of a relay, who would then
// list, read, drive and run JS in every port on the desktop.
//
// So a remote caller is DENIED BY DEFAULT, and this table is the whole of what it can reach, in one
// place, so the remote surface can be read in one screen. A method missing from the table is
// `.never`, and `RemoteAccessTests` fails until every registry method is classified, so a new method
// cannot become remotely reachable (or silently unreachable) without someone deciding which.
//
// A remote caller holds RIGHTS on a port, not machine capabilities. It can never raise a permission
// card: every method it can reach declares no permission, and the gate runs before the card.

/// A right a remote caller holds on one port. Stored in the `grants` table as the permission, with
/// the port's key as the object and no zone.
public enum RemoteRight: String, CaseIterable, Equatable, Hashable {
    /// The port's source, rendered page, console and live events.
    case see
    /// Input and chat: push to it, and read and post in its chat.
    case use
    /// Change the port itself: update, patch, restore, rename.
    case edit
    /// The caller's chat posts wake the host's companions (@mentions and chat membership).
    case wakeAgents = "wake_agents"
}

/// How a method is reachable from another machine.
public enum RemoteReach: Equatable {
    /// Acts on the port named by the argument `param`, and needs `right` on it.
    case port(param: String, right: RemoteRight)
    /// Lists ports; the body shows a remote caller only the ports it holds a right on.
    case listing
    /// Not reachable from another machine.
    case never
}

public enum RemoteAccess {

    /// Every registry method, classified. Grouped by why.
    public static let table: [String: RemoteReach] = [
        // `see`: reading a port and watching it.
        "port.getHtml": .port(param: "id", right: .see),
        "port.history": .port(param: "id", right: .see),
        "port.getDom": .port(param: "id", right: .see),
        "port.console": .port(param: "id", right: .see),
        "port.subscribe": .port(param: "id", right: .see),
        "chat.read": .port(param: "port", right: .see),

        // `use`: input to the port and talk in its chat. Every write carries CAS.
        "port.push": .port(param: "id", right: .use),
        "chat.post": .port(param: "port", right: .use),

        // `edit`: changing the port itself.
        "port.update": .port(param: "id", right: .edit),
        "port.patch": .port(param: "id", right: .edit),
        "port.restore": .port(param: "id", right: .edit),
        "port.rename": .port(param: "id", right: .edit),

        "ports.list": .listing,

        // NEVER, on the port a guest was given. `port.exec` runs JS inside the host's page as that
        // port's own principal, so it would borrow the port's grants. Arranging, archiving, deleting
        // and reopening are the host's layout, not the port's content.
        "port.exec": .never,
        "port.manage": .never,
        "port.move": .never,
        "port.position": .never,
        "port.close": .never,
        "port.reopen": .never,
        "port.delete": .never,
        "port.create": .never,

        // NEVER: the calling port acting on itself. A guest running a copy of a port in its browser
        // is not that port; the host's copy publishes, titles and describes itself.
        "port.publish": .never,
        "port.setTitle": .never,
        "port.setCapabilities": .never,
        "port.info": .never,
        "presentation": .never,

        // NEVER: this machine (port 0) and the people and agents on it.
        "terminal.exec": .never,
        "rest.call": .never,
        "clipboard.read": .never,
        "clipboard.write": .never,
        "fs.pick": .never,
        "fs.read": .never,
        "fs.write": .never,
        "fs.list": .never,
        "fs.mkdir": .never,
        "notify.send": .never,
        "automation.runAppleScript": .never,
        "automation.runJXA": .never,
        "screen.capture": .never,
        "screen.windows": .never,
        "screen.displays": .never,
        "screen.stream": .never,
        "screen.stopStream": .never,
        "screen.record": .never,
        "screen.record.start": .never,
        "screen.record.stop": .never,
        "screen.record.status": .never,
        "camera.capture": .never,
        "camera.stream": .never,
        "camera.stopStream": .never,
        "audio.capture": .never,
        "audio.stopCapture": .never,
        "audio.speak": .never,
        "audio.play": .never,
        "audio.stop": .never,
        "browser.open": .never,
        "browser.navigate": .never,
        "browser.capture": .never,
        "browser.text": .never,
        "browser.html": .never,
        "browser.execute": .never,
        "browser.close": .never,
        "help": .never,
        "user.get": .never,
        "whoami": .never,
        "space.current": .never,
        "space.list": .never,
        "space.create": .never,
        "space.delete": .never,
        "space.switchTo": .never,
        "space.setWorkingDirectory": .never,
        "companions.list": .never,
        "companions.get": .never,
        "companions.create": .never,
        "companions.watch": .never,
        "companions.unwatch": .never,
        "companions.watches": .never,
        "imagine.start": .never,
        "imagine.budget": .never,
        // Invites are made and managed here; a guest redeems at the remote door, not through these.
        "invite.create": .never,
        "invite.list": .never,
        "invite.revoke": .never,
        "invite.accept": .never,

        // NEVER for now: storage keys on the caller, so a guest would read its own empty bucket, not
        // the port's. Settled with the browser lane (4.7), which is where a port's storage calls first
        // arrive from a guest.
        "storage.get": .never,
        "storage.set": .never,
        "storage.delete": .never,
        "storage.list": .never,
    ]

    /// How `method` (canonical) is reachable remotely. Absent means never.
    public static func reach(_ method: String) -> RemoteReach {
        table[method] ?? .never
    }
}

// MARK: - The gate

extension AppState {

    /// A remote caller's rights on one port, by the port's key.
    public func remoteRights(of grantee: String, onPort key: String) -> Set<RemoteRight> {
        (try? db.remoteRights(grantee: grantee, portKey: key)) ?? []
    }

    /// The ports a remote caller holds any right on, by key.
    public func remotePorts(of grantee: String) -> Set<String> {
        (try? db.remotePorts(grantee: grantee)) ?? []
    }

    /// Set a remote caller's rights on one port. An empty set revokes them.
    public func grantRemoteRights(_ rights: Set<RemoteRight>, to grantee: String, onPort key: String) {
        try? db.saveRemoteRights(rights, grantee: grantee, portKey: key)
    }

    /// The port a remote caller names, by its exact id. No title matches and no aliases: a guest names
    /// the port it was given, and a title that happens to match another port must not resolve to it.
    func remotePortKey(_ raw: String) -> String? {
        guard let key = resolvePortRef(raw)?.key, key == raw else { return nil }
        return key
    }

    /// **The remote gate**, run by both dispatchers before the permission gate. A local caller passes
    /// untouched. A remote one reaches only what `RemoteAccess` lists, only on a port it holds the
    /// right on. Refusals do not say whether the port exists, so a guest cannot probe for others.
    func authorizeRemote(_ method: String, principal p: Principal, args: BridgeArgs) throws {
        guard p.kind == .remote else { return }
        switch RemoteAccess.reach(method) {
        case .listing:
            return
        case .never:
            throw BridgeError(code: .notGranted,
                              message: "\(method) is not available to a caller on another machine. "
                                     + "Your invite covers one port: reading it, using it or editing it.")
        case .port(let param, let right):
            guard let raw = args.string(param), let key = remotePortKey(raw),
                  remoteRights(of: p.id, onPort: key).contains(right) else {
                throw BridgeError(code: .notGranted,
                                  message: "\(method) needs '\(right.rawValue)' on the port you name, and "
                                         + "your invite does not give it. Ask the host for an invite "
                                         + "with that right.",
                                  details: ["right": right.rawValue])
            }
        }
    }
}

// MARK: - Per-caller secret grants

extension AppState {

    /// The grant object for a named secret. Not a port: a secret is something a caller may USE in
    /// `rest.call` without ever seeing its value, granted per caller.
    static func secretObject(_ name: String) -> String { "secret:\(name)" }

    /// May this caller use this named secret? Asks the person once, by a card that names the secret,
    /// and remembers the answer. A remote caller never gets here: `rest.call` is never reachable from
    /// another machine.
    func ensureSecretGrant(_ name: String, for p: Principal) async -> Bool {
        let object = Self.secretObject(name)
        if (try? db.grants(grantee: p.id, object: object, zone: ""))?.contains(.rest) == true {
            return true
        }
        guard await permissions.request(.rest, from: p,
                                        detail: "Use your secret '\(name)' in its web requests") else {
            return false
        }
        try? db.saveGrants([.rest], grantee: p.id, object: object, zone: "")
        return true
    }
}
