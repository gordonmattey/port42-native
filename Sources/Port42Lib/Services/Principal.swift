import Foundation

// MARK: - Principal
//
// Who is calling a bridge method. A Principal carries a stable identity, so a permission becomes a
// statement about WHO, not about what a caller is called. A gateway caller's identity comes from the
// credential it presented, verified in `AppState.resolveGatewayCaller` and nowhere else; a caller
// from another machine is `.remote`, keyed on the peer key the gateway authenticated.
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
        /// A gateway caller on THIS machine (Claude Code, curl, an external agent). `id` is the
        /// client id its credential names, verified by the app.
        case peer
        /// A caller on ANOTHER machine, through a relay (nautilus Phase 4). `id` is its peer key,
        /// authenticated by the transport and attested to the app. Denied by default: it reaches only
        /// the ports it holds rights on (`RemoteAccess`), and never raises a permission card.
        case remote
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
    /// **The zone this caller's grants live in** (APP-15). ONE rule for every surface: the space
    /// the actor was made to work in, nil only for an actor that belongs to no space (a client the
    /// person paired or installed). A port, a companion and the person act in `spaceId`, so their
    /// zone is that. A terminal Port42 spawned reaches us through the gateway with no `spaceId`, but
    /// it was spawned INTO a space, and that space is its zone. Before this the child's grants landed
    /// in the global zone under its own `child-…` id while its companion's landed in the space, so
    /// one companion was asked twice for one capability.
    public let zone: String?
    /// The calling port's OWN stable id (PortBridge.messageId), when the caller is a port; nil
    /// otherwise. Distinct from `id`: `id` is the AUTHORIZATION identity — a companion-created port
    /// authorizes AS its creator (P-260), so `id` is shared across every port that creator made and
    /// cannot point at one specific port. `portId` names the specific live port, so owner resolution
    /// (event routing + the mic-leak teardown, backlog 0.5) can find the exact bridge for a port
    /// whose createdBy differs from its own id. NOT part of identity: coalescing and grants key on
    /// `id` (see `==`), so this never splits a grant bucket.
    public let portId: String?
    /// On a `.remote` caller: who on that instance made the call, as that instance claims (4.6c). The
    /// instance is proven; the actor is its word. Never part of identity: rights are the instance's.
    public let actor: RemoteActor?

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
    private init(id: String, displayName: String, spaceId: String?, kind: Kind, portId: String? = nil,
                 actor: RemoteActor? = nil, zone: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.spaceId = spaceId
        self.kind = kind
        self.portId = portId
        self.actor = actor
        self.zone = zone ?? spaceId
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

    /// A caller on another machine. `peer` is its peer key and the grantee; `displayName` is the
    /// name it was enrolled under. Its grants are rights on ports, never machine capabilities.
    public static func remote(peer: String, displayName: String) -> Principal {
        Principal(id: peer, displayName: displayName, spaceId: nil, kind: .remote)
    }

    /// This remote caller, acting as `actor` on its instance. Any other caller is returned unchanged:
    /// only a call from another instance says who there made it.
    public func acting(as actor: RemoteActor?) -> Principal {
        guard kind == .remote else { return self }
        return Principal(id: id, displayName: displayName, spaceId: spaceId, kind: kind, actor: actor)
    }

    /// What Port42 recorded when it SPAWNED a terminal: whose it is and which space it went into.
    /// A gateway caller carries only its client id, so this is how a child is recognized as its
    /// companion rather than as a stranger (APP-15).
    public struct SpawnBinding: Equatable {
        /// The companion (AgentConfig.id) the terminal belongs to; nil for an ad-hoc terminal.
        public let companionId: String?
        public let spaceId: String
        public init(companionId: String?, spaceId: String) {
            self.companionId = companionId
            self.spaceId = spaceId
        }
    }

    /// The identity a verified LOCAL gateway client authorizes as (APP-15).
    ///
    /// **One stable grantee.** A companion's terminal authorizes as the COMPANION, the same id its
    /// in-app tool use and the ports it creates already key on (P-260), so one grant covers all
    /// three. An ad-hoc terminal and a client the person paired stay themselves.
    ///
    /// **One zone rule.** A spawned terminal's zone is the space it was spawned into; a paired
    /// client's is nil (global).
    ///
    /// **And one space.** A spawned terminal also ACTS in its spawn space (`spaceId`), exactly as its
    /// companion's tool use does: storage, a new port, a chat post and every "your space" default
    /// land there. Found live (slice-02 milestone A): with `spaceId` nil, a companion's terminal was
    /// refused `storage.set … shared` with "storage requires space context" while `whoami` named its
    /// space. A paired or installed client acts in no space, as before.
    public static func forGatewayClient(clientId: String, displayName: String,
                                        spawn: SpawnBinding?) -> Principal {
        let companion = spawn?.companionId.flatMap { $0.isEmpty ? nil : $0 }
        return Principal(id: companion ?? clientId, displayName: displayName,
                         spaceId: spawn?.spaceId, kind: .peer, zone: spawn?.spaceId)
    }

    /// THE LOCAL HUMAN. `id` is `AppUser.id`.
    public static func human(id: String, displayName: String, spaceId: String?) -> Principal {
        Principal(id: id, displayName: displayName, spaceId: spaceId, kind: .human)
    }

    // MARK: - Policy: deciding an identity that was not given
    //
    // The factories below RESOLVE an identity rather than accept one. They are deliberately separate
    // from the surfaces above so identity policy has a name and one home, which is what let I1.3 and
    // I1.4 be one-line changes here instead of sweeps across call sites.

    /// Is this id SHARED by callers who are not the same actor?
    ///
    /// **There are none left** (slice-02 half two, 5b). `local-http` was the only one: every local
    /// process reaching the gateway was the same principal, because none of them authenticated. That
    /// was sound FOR THE GATEWAY and was never a decision about ports, which is how it leaked into
    /// `port.create` (I1.3) — and it is how `"Claude Code"`, `"Gemini CLI"` and `claude1`…`claude101`
    /// came to hold standing grants in production, each naming itself whatever it liked.
    ///
    /// A gateway caller is now enrolled and named, so it is an author like any other. The function
    /// stays because rung 1 of `forPortBridge` asks a real question — "is this creator an actual
    /// author" — and a future shared id would have to answer it here, in one place, rather than being
    /// discovered at a call site.
    public static func isSharedIdentity(_ id: String) -> Bool {
        false
    }

    /// The identity a port's bridge authorizes as. Three rungs, in order.
    ///
    /// 1. `createdBy` — a port acts as its creator (GM 2026-07-19, P-260): one grant bucket per author
    ///    per space, one storage namespace with its companion. **Only when the creator IS an author.**
    ///    A SHARED creator is skipped (I1.3, GM 2026-07-27): a gateway-created port had
    ///    `createdBy == "local-http"`, which is not an author but every local process, so all such
    ///    ports in a space pooled into one bucket and Dev3 accumulated an `automation` grant in it.
    ///    This rung LOOKED attributed, which is why a source scan never found it.
    /// 2. `messageId` — the port's own id. A human-created port keys on this, and so does a port whose
    ///    creator was shared: it authorizes as ITSELF.
    /// 3. `instanceFallback` — a stable id supplied by the caller (I1.4). It was a heap address until
    ///    the three sites that pass no id of their own started supplying one. Named as a parameter
    ///    rather than computed here so the rung is greppable and a caller cannot pretend an address is
    ///    an identity.
    ///
    /// **`createdBy` remains the PROVENANCE record either way** (stored on the panel, shown by
    /// `ports.list`, used to resolve a port's AI model). Only the authorization identity changes, so
    /// "who made this" and "what it may do" stop being the same field.
    public static func forPortBridge(createdBy: String?, messageId: String?, instanceFallback: String,
                                     title: String?, spaceId: String?,
                                     codeChangedBy: String? = nil) -> Principal {
        // I1.3: inherit the creator's identity only when the creator is an actual author.
        // NAU-02: and only while the code is still theirs. Code a caller on another machine wrote is
        // not the creator's, so the port authorizes as ITSELF (rung 2), holding nothing inherited.
        let author = codeChangedBy == nil ? createdBy.flatMap { isSharedIdentity($0) ? nil : $0 } : nil
        return Principal(
            id: author ?? messageId ?? instanceFallback,
            // The card must name whoever the grant is ABOUT. When the port authorizes as itself,
            // naming its creator would ask the human to grant to "Local (gateway)" while the grant
            // actually lands on one port, which is the opposite of informed consent. A port whose
            // code someone elsewhere changed says so, or the card would read as the creator's ask.
            displayName: author
                ?? codeChangedBy.map { "\(title ?? "a port") (code changed by \($0))" }
                ?? title ?? "a port",
            spaceId: spaceId, kind: .port,
            // The port's OWN id, carried separately from the authz `id` (which is the creator for a
            // companion-made port). Owner resolution keys on this so event routing and teardown find
            // THIS port, not the creator's shared bucket (backlog 0.5).
            portId: messageId)
    }

    /// The identity an in-app companion's tool call authorizes as.
    ///
    /// **I1.5 removed a `?? "anonymous-tool-caller"` fallback here, as dead rather than as fixed.**
    /// Both the plan and the register led with that string as THE identity defect: two sites sharing
    /// one id, pooling their grants. It never fired. `ToolExecutor` has one production construction
    /// site (`AppState.swift:139`) passing a non-optional `AgentConfig.id`, every test site passes a
    /// real id, and the I1.1 probe recorded zero hits across a full session.
    ///
    /// `createdBy` is non-optional here BY DESIGN. A caller that cannot name its companion now fails
    /// to compile rather than silently minting a shared identity, so the hole cannot be reopened by
    /// someone reintroducing an optional at the call site.
    public static func forCompanionTool(createdBy: String, createdByName: String?,
                                        spaceId: String?) -> Principal {
        Principal(id: createdBy,
                  displayName: createdByName ?? createdBy,
                  spaceId: spaceId, kind: .companion)
    }

    /// Identity is the authz tuple only — `portId` is deliberately excluded, so a port carrying its
    /// own id never appears "different" for permission coalescing, which keys on this.
    public static func == (lhs: Principal, rhs: Principal) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName
            && lhs.spaceId == rhs.spaceId && lhs.kind == rhs.kind && lhs.zone == rhs.zone
    }

    /// `localGatewayID` ("local-http") IS DELETED (slice-02 half two, 5b).
    ///
    /// It was the pooled identity every local process collapsed into, and deleting it rather than
    /// gating it is deliberate: keeping the constant through a transition would seed the new field
    /// with exactly the kind of value it exists to eliminate. A gateway caller now arrives with a
    /// verified client id or does not arrive at all.
    ///
    /// `gatewayDisplayName` went with it. A caller's display name is now fixed at MINT TIME and read
    /// from its client row, so nothing has to guess a label from an id — which is what that function
    /// existed to do, and why an anonymous card said "Local (gateway)".

    /// What "Allow" will actually do, in the human's words, on the permission card.
    ///
    /// **It names the OBJECT** (slice-02 A.3). A grant is a statement about this principal, acting
    /// on a named port, optionally qualified by a zone — and until step 1 the object had no name at
    /// all, so the card could not say what was being granted access TO. Machine capabilities belong
    /// to port 0, whose name is the app's own name, which is why this reads "in Port42" rather than
    /// in an invented word like "desktop".
    ///
    /// **It also says how to undo it**, which it could not honestly do before: until step 2 there
    /// was nowhere to go and a grant was permanent and invisible from the moment it was given.
    public var scopeDescription: String {
        let where_ = (zone?.isEmpty == false)
            ? "in Port42, while working in this space"
            : "in Port42, everywhere"
        return "Allow for \(displayName) \(where_). Take it back any time in Settings → Access."
    }
}

/// Who on another instance made a call it sent here (nautilus Phase 4, 4.6c): the person there, one of
/// its companions, a client or a port. Built only from a usable claim; long fields are cut.
public struct RemoteActor: Equatable {
    /// What another instance may say its actor is. Never `.remote`: an actor is someone ON that instance.
    public static let kinds: Set<Principal.Kind> = [.human, .companion, .peer, .port]
    public let id: String
    public let name: String
    public let kind: Principal.Kind

    public init?(id: String, name: String, kind: Principal.Kind) {
        guard !id.isEmpty, !name.isEmpty, Self.kinds.contains(kind) else { return nil }
        self.id = String(id.prefix(128))
        self.name = String(name.prefix(64))
        self.kind = kind
    }

    /// A claim as the wire carries it: nil unless every field is usable.
    public init?(wireId id: String?, name: String?, kind: String?) {
        guard let id, let name, let k = kind.flatMap(Principal.Kind.init(rawValue:)) else { return nil }
        self.init(id: id, name: name, kind: k)
    }

    var wire: [String: String] { ["id": id, "name": name, "kind": kind.rawValue] }
}
