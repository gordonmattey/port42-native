import Foundation

// MARK: - PortObject
//
// WHAT a permission is about. Slice-02 milestone A step 1
// (docs/membrane/slice-02-cross-instance.md §4, §10, CR5).
//
// **THE DESKTOP IS A PORT. PORT 0.** (GM, 2026-07-28.) Clipboard, filesystem, automation, notify,
// rest, screen and camera are not portless capabilities sitting outside the model; they are port 0's,
// port 0 being the Port42 window itself. One primitive, so `caller -> port -> action -> permission`
// holds with no exceptions.
//
// **The measurement that settled it.** The grant key was `portPerms.<grantee>.<spaceId ?? "global">`:
// a grantee and a SPACE and no object at all. Every grant in production is a port 0 capability, so
// the object was always the machine. Having no name, it left an empty slot, and the space slid into
// it. Two different questions had been sharing one key: a space was never scoping what is acted ON,
// it was scoping the context the actor acted IN.
//
// ```
// today     <grantee> x <space>             the object is implicit and unnamed
// after     <grantee> x <port> [x zone]     the object is named; the zone qualifies the ACTOR
// ```
//
// **Why the slot exists before anything can fill it.** No production path can name an object other
// than port 0 today, because every `PortPermission` case is a machine capability. The slot is built
// now because Part 0's OBJECT row is a seam: at slice-02 a grant becomes "peer B may act on MY
// port 0's clipboard", which is peer-qualified on both sides. Adding the slot after that lands as a
// migration across two instances rather than one. The tests therefore exercise a non-zero object
// deliberately, since production cannot.

/// The object a grant is about: a port, on some peer. `PortObject.machine` is port 0, this
/// instance's Port42 window.
///
/// Peer-qualified by construction, in the same grammar as the address (`port42://<peerID>/…`), so
/// the wire half adds a peer and no concept.
public struct PortObject: Equatable, Hashable {

    /// The peer that owns this object. nil = this instance. Written from day one for the same reason
    /// `ActorRef` was (`<peerID>/<principal>`): a noun that becomes peer-qualified later is a
    /// migration, and one that starts peer-qualified is a parameter.
    public let peerID: String?

    /// The port's key within that peer: `PortRef.key`, or `machinePortKey` for the window itself.
    public let portKey: String

    /// PRIVATE, in the discipline `Principal` established: an object arrives from a named factory,
    /// so what may be an object is decided in this file rather than at each call site.
    private init(peerID: String?, portKey: String) {
        self.peerID = peerID
        self.portKey = portKey
    }

    /// Port 0. The name of the machine's own port, which is what the old key was missing.
    public static let machinePortKey = "0"

    /// **PORT 0** — the Port42 window on THIS instance. The object of every machine capability, and
    /// therefore of all 144 grants that existed when the slot was introduced.
    public static let machine = PortObject(peerID: nil, portKey: machinePortKey)

    /// A specific port on this instance, keyed by `PortRef.key`.
    public static func port(_ key: String) -> PortObject {
        PortObject(peerID: nil, portKey: key)
    }

    /// Port 0 on another peer: "that machine".
    public static func remoteMachine(peerID: String) -> PortObject {
        PortObject(peerID: peerID, portKey: machinePortKey)
    }

    /// A specific port on another peer.
    public static func remotePort(peerID: String, portKey: String) -> PortObject {
        PortObject(peerID: peerID, portKey: portKey)
    }

    /// Is this object on this instance?
    public var isLocal: Bool { peerID == nil }

    /// The segment this object contributes to a grant key: `0` locally, `<peerID>/0` remotely.
    ///
    /// A `/` separator, never a `.`, so the key stays splittable on dots no matter what a peer id
    /// looks like.
    public var keySegment: String {
        guard let peerID else { return portKey }
        return "\(peerID)/\(portKey)"
    }
}

// MARK: - PortGrantKey

/// The grant key's grammar, and the one-time reap that cleared the objectless store.
public enum PortGrantKey {

    /// `portGrant.<grantee>.<object>.<zone>`
    public static let prefix = "portGrant"

    /// `portPerms.<grantee>.<zone>` — the objectless key. Nothing reads it; the reap deletes it.
    public static let legacyPrefix = "portPerms"

    /// The zone segment for a caller qualified by no zone (the gateway: Claude Code, curl). It keeps
    /// the word it has always had, because its meaning did not change: not in a space.
    public static let unzoned = "global"

    /// Build a grant key. Three parameters because the key has three parts, so a caller cannot read
    /// or write a grant without naming its object (pinned by `PortObjectGrantTests`, whose gate
    /// scans the whole source tree for a key built anywhere but here).
    public static func key(grantee: String, object: PortObject, zone: String?) -> String {
        let zoneSegment = (zone?.isEmpty == false) ? zone! : unzoned
        return "\(prefix).\(grantee).\(object.keySegment).\(zoneSegment)"
    }

    /// Dead defaults the reap also removes: the flag of the copy-forward migration this replaced,
    /// which never shipped.
    static let retiredKeys = ["portGrantObjectMigrated"]

    /// The one-shot default that records the reap as done.
    public static let reapFlag = "portGrantStoreReapedV1"

    /// **REAP, once. The grant store starts empty** (GM, 2026-07-29).
    ///
    /// Every objectless `portPerms.*` key is DELETED rather than migrated onto port 0, and nothing
    /// carries forward. This replaced a copy-forward migration, and the measurement is what changed
    /// the decision: of the 144 grants in production, **only 9 could ever fire again**. A grant is
    /// read with the caller's live zone, and 135 of them named a space that has been deleted, so
    /// they were unreachable rather than merely untidy. Migrating them faithfully would have been
    /// faithfully preserving nothing, and the permission manager would have opened on 135 rows
    /// describing a world that no longer exists.
    ///
    /// **What it costs, stated because it is what the user feels:** each companion asks once more
    /// per capability, in the space it is working in, and then never again. That is the same shape
    /// as D12's removal of the blanket pre-grant, and it lands in the same release.
    ///
    /// **What it discards, stated because deletion is not reversible:** the record of what had been
    /// granted to callers that named themselves over the WS door (`"Claude Code"`, `"Gemini CLI"`,
    /// `claude1`…`claude101`). That record is evidence for §1, so it is written down in the slice
    /// doc's §4 and dumped in full beside the production database before the reap ran.
    ///
    /// **Both prefixes go**, because neither the new key nor the migration it replaced has ever
    /// shipped: the only `portGrant.*` keys that can exist are ones the retired migration wrote on a
    /// dev instance. After this, a `portGrant.*` key can only mean a grant a human actually gave.
    ///
    /// **The flag is load-bearing, not an optimization.** A reap that ran on every launch would
    /// delete grants continuously, so the store could never accumulate the consent it exists to
    /// remember.
    ///
    /// Returns how many keys were removed.
    @discardableResult
    public static func reapGrantStore(in defaults: UserDefaults) -> Int {
        guard !defaults.bool(forKey: reapFlag) else { return 0 }

        var removed = 0
        for key in defaults.dictionaryRepresentation().keys {
            guard key.hasPrefix(legacyPrefix + ".") || key.hasPrefix(prefix + ".")
                    || retiredKeys.contains(key) else { continue }
            defaults.removeObject(forKey: key)
            removed += 1
        }

        defaults.set(true, forKey: reapFlag)
        return removed
    }
}
