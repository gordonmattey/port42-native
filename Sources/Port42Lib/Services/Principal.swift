import Foundation

// MARK: - Principal
//
// Who is calling a bridge method. This replaces the label-shaped identity the gateway used: it
// authenticates a real `peer.ID`, then `AppState.onCallReceived` flattens it to "remote-<prefix>" and
// keys permissions on that string (todo: "the protocol already has an authenticated principal and
// throws it away"). A Principal carries a stable identity, so a permission becomes a statement about
// WHO, not about what a caller is called.
//
// Phase 3 finished the promotion: `PermissionRequester` (the accidental first draft that rode the
// permission coordinator) is gone, and the coordinator takes a Principal directly. One caller
// identity, one type; `id` is the coalescing key AND the grant key, display never is.

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
    /// The calling port's OWN stable id (PortBridge.messageId), when the caller is a port; nil
    /// otherwise. Distinct from `id`: `id` is the AUTHORIZATION identity — a companion-created port
    /// authorizes AS its creator (P-260), so `id` is shared across every port that creator made and
    /// cannot point at one specific port. `portId` names the specific live port, so owner resolution
    /// (event routing + the mic-leak teardown, backlog 0.5) can find the exact bridge for a port
    /// whose createdBy differs from its own id. NOT part of identity: coalescing and grants key on
    /// `id` (see `==`), so this never splits a grant bucket.
    public let portId: String?

    public init(id: String, displayName: String, spaceId: String?, kind: Kind, portId: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.spaceId = spaceId
        self.kind = kind
        self.portId = portId
    }

    /// Identity is the authz tuple only — `portId` is deliberately excluded, so a port carrying its
    /// own id never appears "different" for permission coalescing, which keys on this.
    public static func == (lhs: Principal, rhs: Principal) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName
            && lhs.spaceId == rhs.spaceId && lhs.kind == rhs.kind
    }

    /// The stable id a local (unauthenticated) gateway caller is given. A local `curl` has no client
    /// identity, so every local process shares this one principal — grants persist against it instead
    /// of re-prompting per call. Set by the gateway (`HandleHTTPCall`); mirrored here so the host and
    /// display code agree on the string. A remote WS peer keeps its authenticated `senderId` instead.
    public static let localGatewayID = "local-http"

    /// Human label for a gateway caller's stable id, for permission cards and attribution rows. The id
    /// is the permission key; this is display only. A peer with no friendlier name shows its id.
    public static func gatewayDisplayName(for senderId: String) -> String {
        senderId == localGatewayID ? "Local (gateway)" : senderId
    }

    /// What "Allow" will actually do, in the human's words, on the permission card. A grant is a
    /// statement about this principal in this space (nil space = global to this principal), and the
    /// card says so — the old code silently wrote a grant the human was never shown the scope of.
    public var scopeDescription: String {
        if let spaceId, !spaceId.isEmpty {
            _ = spaceId
            return "Allow for \(displayName) in this space — future ports it makes won't ask again."
        }
        return "Allow for \(displayName) everywhere — it isn't in a space, so this applies globally."
    }
}
