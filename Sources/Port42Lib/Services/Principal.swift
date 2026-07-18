import Foundation

// MARK: - Principal
//
// Who is calling a bridge method. This replaces the label-shaped identity the gateway used: it
// authenticates a real `peer.ID`, then `AppState.onCallReceived` flattens it to "remote-<prefix>" and
// keys permissions on that string (todo: "the protocol already has an authenticated principal and
// throws it away"). A Principal carries a stable identity, so a permission becomes a statement about
// WHO, not about what a caller is called.
//
// Phase 0 defines the type and its bridge to the existing permission queue. `PermissionRequester`
// (added with the permission coordinator) is the accidental first draft of this; Phase 3 backs the
// `.peer` case with the gateway's authenticated `peer.ID` and makes `id` the permission key.

public struct Principal: Equatable {
    public enum Kind: String, Equatable {
        /// A port's JS. `id` is the port id.
        case port
        /// An in-app companion's tool use. `id` is the companion (createdBy) id.
        case companion
        /// A gateway caller (Claude Code, curl, an external agent). `id` is the authenticated
        /// `peer.ID` (Phase 3); today the label still flows in until that lands.
        case peer
    }

    /// Stable identity: permission coalescing and grant persistence key on this. nil-free by
    /// construction — a caller with no identity should not be built as a Principal.
    public let id: String
    /// What the human sees on a permission card ("echo", "Claude Code").
    public let displayName: String
    /// The space this caller acts in. nil = not in a space (the gateway) — its grant is global to
    /// this principal, which is different from "unpersistable" (what nil used to mean).
    public let spaceId: String?
    public let kind: Kind

    public init(id: String, displayName: String, spaceId: String?, kind: Kind) {
        self.id = id
        self.displayName = displayName
        self.spaceId = spaceId
        self.kind = kind
    }

    /// Bridge to the existing permission queue (`PermissionCoordinator`). Until Phase 3 promotes
    /// `PermissionRequester` into this type, a Principal produces one: the stable `id` is both the
    /// coalescing id and the grant key (`createdBy`), so the identity — not a display label — is what
    /// a grant is remembered against.
    public var permissionRequester: PermissionRequester {
        PermissionRequester(id: id, displayName: displayName, spaceId: spaceId, createdBy: id)
    }
}
