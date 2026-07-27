import Foundation

// MARK: - PortResolution
//
// The one rule that turns a port address (or a bare-id alias) into a concrete port reference, replacing
// the five scattered id→port lookups the spike found (docs/plan-port42-protocol-local-bus.md, Phase L0).
// It is a PURE function over plain value inputs — no live objects — so it is unit-tested headless.
// `AppState.resolvePortRef` is the thin wrapper that gathers the live candidate lists and calls this.
//
// Precedence is stated once here (terminal → panel → inline → DB-only), subsuming `PortPushRoute.classify`
// (terminal wins over web), which was the only place any of this was named before, and only for `push`.
//
// IDENTITY IS A TRIPLE, NOT A SINGLE ID. A port carries `id` (panel id — the `webViews` key and the
// management key), `udid` (the stable/versions/DB key), and, for an inline `port` fence, a
// `messageId`. `webViews` is keyed by `panel.id`, the DB by `udid`, and `id != udid` for any port
// created after the udid backfill migration. So a resolver that returned one string would break the
// accessor that keys on a different member. `PortRef` therefore carries all three; each method body
// uses the member its accessor needs. This is the actual consolidation — one identity, surfaced whole.

/// Which surface a resolved port is, so the Query and Notify paths branch once, in one place.
public enum PortSurfaceKind: String, Equatable {
    case web
    case terminal
    case browser
    /// A known port with no live surface to classify (e.g. DB-only: minimized/closed but still
    /// addressable for getHtml/history/restore, which key on `udid`). Honest about what we didn't verify.
    case unknown
}

/// A live port panel's full identity, as fed to the resolver. Plain values so resolution stays pure.
public struct PortCandidate: Equatable {
    public let id: String           // panel.id — the webViews key and the panel-management key
    public let udid: String         // the stable / port_versions / DB key
    public let messageId: String?   // inline PortBridge.messageId, if this port has one
    public let title: String
    public let portType: String?    // "browser" ⇒ .browser, else .web

    public init(id: String, udid: String, messageId: String?, title: String, portType: String?) {
        self.id = id
        self.udid = udid
        self.messageId = messageId
        self.title = title
        self.portType = portType
    }
}

/// A resolved port: its kind, its space, and the identity members each accessor needs (populated per
/// kind — a consumer uses the one its lookup keys on).
public struct PortRef: Equatable {
    public let kind: PortSurfaceKind
    public let spaceId: String?
    public let id: String?          // panel.id / webViews key / management key; terminal-controllers key for .terminal
    public let udid: String?        // DB / versions key
    public let messageId: String?   // inline web bridge key

    public init(kind: PortSurfaceKind, spaceId: String?, id: String?, udid: String?, messageId: String?) {
        self.kind = kind
        self.spaceId = spaceId
        self.id = id
        self.udid = udid
        self.messageId = messageId
    }

    /// The most specific identifier we resolved, for logs and error messages.
    public var describedId: String { id ?? udid ?? messageId ?? "?" }

    /// THE per-port key — the Notify topic id, the activity-token key and the presence key, all of
    /// which must be the same string or they are silently talking about different ports.
    ///
    /// Defined ONCE here because it was previously written three times and three ways
    /// (`udid ?? id`, `udid ?? id ?? <caller's raw string>`, twice), and none of them handled
    /// `messageId`. Two consequences, both live until 2026-07-26:
    ///
    /// - An INLINE-only port (a `port` fence before adoption) has nil `id` AND nil `udid`, so the
    ///   dispatcher's key was nil and its whole write block — token bump, presence, CAS — was
    ///   skipped. A real, writable surface with no staleness protection at all.
    /// - The `?? <raw string>` fallbacks keyed the Notify topic on whatever the caller passed, which
    ///   can be a TITLE, so a publisher and a subscriber agreed only when they happened to use the
    ///   same alias.
    ///
    /// nil only when a ref carries no identity at all, which resolution cannot produce.
    public static func key(_ ref: PortRef) -> String? {
        ref.udid ?? ref.id ?? ref.messageId
    }

    /// Convenience for call sites that hold a ref.
    public var key: String? { PortRef.key(self) }
}

public enum PortResolution {

    /// The one terminal id/name matching rule (id-hit → exact name → contains). Owned here so the
    /// resolver and `AppState.resolveTerminalId` share ONE rule (that method now forwards to this),
    /// fixing the earlier wrong-direction dependency (the pure resolver reaching up into AppState).
    public static func terminalMatch(_ idOrName: String,
                                     candidates: [(id: String, name: String)]) -> String? {
        if candidates.contains(where: { $0.id == idOrName }) { return idOrName }             // id-hit
        let q = idOrName.lowercased()
        if let m = candidates.first(where: { $0.name.lowercased() == q }) { return m.id }     // exact name
        if let m = candidates.first(where: { $0.name.lowercased().contains(q) }) { return m.id } // contains
        return nil
    }

    /// Resolve `idOrAddress` (a `port42://space/<s>/<p>` address, or a bare udid/name/title alias) to a
    /// `PortRef`, or nil if no live/known port matches.
    ///
    /// - Parameters:
    ///   - terminals: `(id, name)` per native terminal (`terminalControllers` → id + companionName).
    ///   - panels: full identity per port panel (id, udid, messageId, title, portType).
    ///   - inlineMessageIds: inline `PortBridge.messageId`s not backed by a panel (a `port` fence
    ///     before adoption).
    ///   - dbHas: a LAZY existence probe for the DB-only case, called at most once and only after the
    ///     live tables miss — so a resolve never eagerly loads the whole udid set (the common path,
    ///     push/exec, never touches the DB).
    public static func resolve(_ idOrAddress: String,
                               terminals: [(id: String, name: String)],
                               panels: [PortCandidate],
                               inlineMessageIds: Set<String>,
                               dbHas: (String) -> Bool) -> PortRef? {
        let addr = PortAddress.parse(idOrAddress) ?? PortAddress(spaceId: nil, portId: idOrAddress)
        let needle = addr.portId
        let space = addr.spaceId

        // 1. Terminal — wins over web (matches PortPushRoute). `id` is the terminal-controllers key.
        if let tid = terminalMatch(needle, candidates: terminals) {
            return PortRef(kind: .terminal, spaceId: space, id: tid, udid: nil, messageId: nil)
        }

        // 2. Panel — id | udid | messageId exact, then title exact, then title contains. Carries the
        //    full identity so each accessor uses the right key (webViews by id, DB by udid).
        if let p = matchPanel(needle, panels) {
            let kind: PortSurfaceKind = (p.portType == "browser") ? .browser : .web
            return PortRef(kind: kind, spaceId: space, id: p.id, udid: p.udid, messageId: p.messageId)
        }

        // 3. Inline-only web bridge (a `port` fence not yet backed by a panel).
        if inlineMessageIds.contains(needle) {
            return PortRef(kind: .web, spaceId: space, id: nil, udid: nil, messageId: needle)
        }

        // 4. DB-only — a known udid with no live surface. Kind is not determinable ⇒ .unknown. Lazy:
        //    probed last, only when the live tables missed.
        if dbHas(needle) {
            return PortRef(kind: .unknown, spaceId: space, id: nil, udid: needle, messageId: nil)
        }

        return nil
    }

    /// Panel match precedence: any exact identity (id | udid | messageId), then title exact
    /// (case-insensitive), then title contains — the union of what `findPort(by:)` and the web/inline
    /// lookups matched, now in one place.
    static func matchPanel(_ needle: String, _ panels: [PortCandidate]) -> PortCandidate? {
        if let p = panels.first(where: { $0.id == needle || $0.udid == needle || $0.messageId == needle }) {
            return p
        }
        let q = needle.lowercased()
        if let p = panels.first(where: { $0.title.lowercased() == q }) { return p }
        return panels.first(where: { $0.title.lowercased().contains(q) })
    }
}
