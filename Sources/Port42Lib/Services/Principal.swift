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
        /// THE LOCAL HUMAN. `id` is `AppUser.id`. Added for right-of-way (L2.d): until the lease,
        /// nothing needed to authorize FOR the person — permissions are asked OF them — so the
        /// person had no principal at all. A lease holder must be able to be the human, or a
        /// companion could hold the pen on a port its owner is sitting in.
        /// (First real use of `AppUser`'s identity; see docs/decision-identity-model.md.)
        case human
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

    /// PRIVATE, and the point of I1.2 (`plan-port42-protocol-local-bus.md` §B).
    ///
    /// A memberwise init taking any `String` cannot refuse a bad identity, and both live holes I1.1
    /// measured are exactly that: a heap address handed in as an identity, and a SHARED id inherited
    /// as if it were an authored one. Neither is visible at a construction site, so no amount of care
    /// at the call sites would have caught them. Every identity now comes from a named factory below,
    /// which puts all identity POLICY in this file where a reviewer can see it at once and I1.3/I1.4
    /// can change it in one place.
    ///
    /// Enforced by `PrincipalConstructionTests` scanning the whole package, tests included.
    private init(id: String, displayName: String, spaceId: String?, kind: Kind, portId: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.spaceId = spaceId
        self.kind = kind
        self.portId = portId
    }

    // MARK: - Surfaces
    //
    // One factory per surface a caller can arrive from. These take an identity the caller already
    // has; the two POLICY factories further down are the ones that decide an identity, and they are
    // where the known defects live.

    /// A port's JS, when the authorizing identity is already known.
    public static func port(id: String, displayName: String, spaceId: String?,
                            portId: String? = nil) -> Principal {
        Principal(id: id, displayName: displayName, spaceId: spaceId, kind: .port, portId: portId)
    }

    /// An in-app companion's tool use.
    public static func companion(id: String, displayName: String, spaceId: String?) -> Principal {
        Principal(id: id, displayName: displayName, spaceId: spaceId, kind: .companion)
    }

    /// A gateway caller (Claude Code, curl, an external agent). `spaceId` is nil for the gateway,
    /// whose grants are global to the principal rather than scoped to a space.
    public static func peer(id: String, displayName: String, spaceId: String? = nil) -> Principal {
        Principal(id: id, displayName: displayName, spaceId: spaceId, kind: .peer)
    }

    /// THE LOCAL HUMAN. `id` is `AppUser.id`.
    public static func human(id: String, displayName: String, spaceId: String?) -> Principal {
        Principal(id: id, displayName: displayName, spaceId: spaceId, kind: .human)
    }

    // MARK: - Policy: deciding an identity that was not given
    //
    // The two factories below RESOLVE an identity rather than accept one, and both currently resolve
    // it wrongly in a way I1.1 measured. They are deliberately separate from the surfaces above so
    // the defect has a name and one home.

    /// The identity a port's bridge authorizes as. THREE RUNGS, and two of them are known defects.
    ///
    /// 1. `createdBy` — a port acts as its creator (GM 2026-07-19, P-260): one grant bucket per author
    ///    per space, one storage namespace with its companion. Correct when the creator IS an author.
    ///    **DEFECT (I1.3):** a gateway-created port has `createdBy == "local-http"`, which is not an
    ///    author but every local process, so all such ports in a space share one bucket. Dev3 already
    ///    persists an `automation` grant in one. This rung LOOKS attributed, which is why a source
    ///    scan never found it.
    /// 2. `messageId` — a human-created port keys on its own id. Sound.
    /// 3. `instanceFallback` — **DEFECT (I1.4):** in practice a heap address, from the two sites that
    ///    pass no id at all (`ensureChatPort`, the ambient background port). It changes every launch,
    ///    so a grant can never restore, and an address is reused after dealloc, so a grant can
    ///    transfer to an unrelated object. Named as a parameter rather than computed here so the rung
    ///    is greppable and the caller cannot pretend it is an identity.
    public static func forPortBridge(createdBy: String?, messageId: String?, instanceFallback: String,
                                     title: String?, spaceId: String?) -> Principal {
        Principal(id: createdBy ?? messageId ?? instanceFallback,
                  displayName: createdBy ?? title ?? "a port",
                  spaceId: spaceId, kind: .port,
                  // The port's OWN id, carried separately from the authz `id` (which is the creator
                  // for a companion-made port). Owner resolution keys on this so event routing and
                  // teardown find THIS port, not the creator's shared bucket (backlog 0.5).
                  portId: messageId)
    }

    /// The identity an in-app companion's tool call authorizes as.
    ///
    /// **The `nil` branch is UNREACHABLE and is deleted in I1.5.** `ToolExecutor` has one production
    /// construction site (`AppState.swift:139`) passing a non-optional `AgentConfig.id`, every test
    /// site passes a real id, and the I1.1 probe recorded zero hits across a full session. It is kept
    /// for this step only so I1.2 changes structure without changing behavior. Both plans led with
    /// this string as the headline identity defect; it never fired.
    public static func forCompanionTool(createdBy: String?, createdByName: String?,
                                        spaceId: String?) -> Principal {
        Principal(id: createdBy ?? "anonymous-tool-caller",
                  displayName: createdByName ?? createdBy ?? "a companion",
                  spaceId: spaceId, kind: .companion)
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
