import Foundation

// MARK: - Bridge dispatch (Phase 2)
//
// The single path every calling surface runs a bridge method through: resolve an alias, look up the
// one implementation, permission-gate it via the coordinator (keyed by the principal), run it. An
// adapter's only remaining job is to build a Principal and render the returned BridgeValue for its
// surface. This is what makes "one base impl, thin calling paths" true by construction instead of by
// assertion — a method's behavior and its permission live in exactly one place.

@MainActor
extension AppState {

    /// True when the registry can handle this name (canonical dotted or a `files.*` alias). An adapter
    /// uses this to decide whether to take the new path or fall back to its old switch (which still
    /// serves the live-only families not yet extracted).
    public func bridgeHandles(_ canonicalOrAlias: String) -> Bool {
        bridgeRegistry[resolveBridgeAlias(canonicalOrAlias)]?.wired == true
    }

    /// Run a bridge method by canonical name. Permission is checked against the principal's grants
    /// (plus any `pregrant`, e.g. the gateway's "Always Allow" settings); a needed-but-ungranted
    /// permission prompts via the coordinator and persists on grant. Returns the method's BridgeValue,
    /// or throws a BridgeError (unknown method / permission denied / whatever the body threw).
    public func runBridgeMethod(_ canonicalOrAlias: String,
                                principal: Principal,
                                args: BridgeArgs,
                                pregrant: Set<PortPermission> = []) async throws -> BridgeValue {
        let canonical = resolveBridgeAlias(canonicalOrAlias)
        guard let method = bridgeRegistry[canonical] else {
            throw BridgeError(code: "unknown_method", message: "Unknown method: \(canonical)")
        }

        if let perm = method.permission {
            var granted = companionPermissions(createdBy: principal.id, spaceId: principal.spaceId)
                .union(pregrant)
            if !granted.contains(perm) {
                let ok = await permissions.request(perm, from: principal)
                if !ok { throw BridgeError.permissionDenied(perm.rawValue) }
                granted.insert(perm)
                saveCompanionPermissions(granted, createdBy: principal.id, spaceId: principal.spaceId)
            }
        }

        // RIGHT-OF-WAY (L2). A write needs the pen for its target. Sits beside the permission gate
        // because it is the same shape of decision at the same choke point, and after it because
        // a permission prompt is about the CALLER while the lease is about the TARGET — asking for
        // access to something you then cannot write to would be the wrong order of questions.
        if let targetParam = method.writesTarget, let raw = args.string(targetParam) {
            try claimWrite(on: raw, by: principal)
        }

        return try await method.run(principal, args)
    }

    /// The local human as a principal (L2.d). nil before setup completes.
    var humanPrincipal: Principal? {
        guard let user = currentUser else { return nil }
        return Principal(id: user.id, displayName: user.displayName,
                         spaceId: currentSpace?.id, kind: .human)
    }

    /// FOCUSING a unit is the human saying "I am driving this", so it takes the pen.
    ///
    /// Why focus and not `focusKeyboard`: keyboard focus also follows the MOUSE (hover raises a
    /// tile and hands it the keyboard), and acquiring on hover would let a mouse dragged across the
    /// desktop seize the pen from every companion it passed over, for the whole TTL. Zooming into a
    /// unit is deliberate; hovering is not.
    ///
    /// Never steals: `check` denies rather than evicts, so focusing a port a companion is mid-write
    /// on leaves that companion holding it. The denial is not an error here — it just means the
    /// human is looking at something someone else is driving, which they are allowed to do.
    ///
    /// HONEST LIMIT (§L2.4): this makes the human's claim visible and blocks companion writes while
    /// they hold it. It cannot make the reverse true — native keystrokes into a terminal or webview
    /// never reach the bridge, so a human typing into a port a companion holds is still invisible
    /// to the lease. Closing that needs input to route through the bus, which is not this phase.
    func claimFocusForHuman(portId: String) {
        guard let human = humanPrincipal else { return }
        NSLog("[Port42:lease] path=focus port=%@", portId)
        try? claimWrite(on: portId, by: human)
    }

    /// The human INTERACTED with a port's surface — typed into it, clicked in it (L2.d.2). This is
    /// the signal that makes the lease tell the truth: a bridge write is not the only way to drive a
    /// port, and until now native input was invisible to right-of-way, so a companion could write
    /// into a terminal you were typing in.
    ///
    /// What counts is intent to ACT: keydown and pointerdown. Deliberately NOT hover (a mouse
    /// crossing the desktop is not driving) and NOT scroll — scrolling is READING, and claiming on
    /// it would block a companion from continuing exactly while you watch it work.
    ///
    /// Throttled per port: typing fires this per keystroke, and re-claiming a lease you already
    /// hold is noise.
    func humanInteracted(with portId: String) {
        guard humanPrincipal != nil else { return }
        guard humanClaimThrottle.allow(port: portId, now: Date()) else { return }
        NSLog("[Port42:lease] path=input port=%@", portId)
        claimFocusForHuman(portId: portId)
    }

    /// Take (or refresh) the pen on a port for this principal, or throw naming who holds it.
    ///
    /// Keyed on the SAME id the port's Notify topic uses (`ref.udid ?? ref.id`), so the holder
    /// broadcast and the lease can never disagree about which port they mean. An unresolvable
    /// target is deliberately NOT gated: the method's own `notFound` is the better error, and a
    /// lease on a port that does not exist is a lock on nothing.
    func claimWrite(on rawId: String, by principal: Principal) throws {
        guard let ref = resolvePortRef(rawId), let key = ref.udid ?? ref.id else { return }
        let actor = ActorRef(principal: principal.id)
        switch portLeases.check(port: key, actor: actor, name: principal.displayName, now: Date()) {
        case .granted(let lease):
            NSLog("[Port42:lease] GRANT %@ → %@ (%@)", key, lease.holderName, lease.holder.description)
            // The holder CHANGED. Broadcast on the port's own topic — the thing already streaming
            // its output is the thing that says who is driving it, so every surface watching the
            // port (a tile header, another instance's mirror, an agent deciding whether to wait)
            // learns for free and no side channel exists to fall out of sync. Refresh is silent:
            // publishing per keystroke would drown the topic in non-news.
            notifyBus.publish(topic: "port:\(key)", kind: "holder",
                              payload: ["holder": lease.holder.description,
                                        "holderName": lease.holderName,
                                        "until": lease.expires.timeIntervalSince1970])
            return
        case .refreshed:
            // Deliberately silent, like the broadcast: a refresh fires per keystroke (throttled to
            // ~5s) and logging it would bury the grants, which are the events that mean something.
            return
        case .denied(let held):
            throw BridgeError(code: "port_busy",
                              message: "'\(held.holderName)' is driving this port right now. "
                                     + "Ask them to hand it over, or wait for them to finish.")
        }
    }

    /// True when the streaming registry can handle this name (item 8).
    public func bridgeStreamHandles(_ canonicalOrAlias: String) -> Bool {
        bridgeStreamRegistry[resolveBridgeAlias(canonicalOrAlias)] != nil
    }

    /// Run a streaming bridge method: same permission-gating as `runBridgeMethod`, but the body yields
    /// tokens via `yield` before returning the final value. A thrown `BridgeError` propagates (the
    /// adapter renders it as a reject, not a resolved `{error}`).
    public func runBridgeStream(_ canonicalOrAlias: String,
                                principal: Principal,
                                args: BridgeArgs,
                                pregrant: Set<PortPermission> = [],
                                yield: @escaping @MainActor (String) -> Void) async throws -> BridgeValue {
        let canonical = resolveBridgeAlias(canonicalOrAlias)
        guard let method = bridgeStreamRegistry[canonical] else {
            throw BridgeError(code: "unknown_method", message: "Unknown streaming method: \(canonical)")
        }
        if let perm = method.permission {
            var granted = companionPermissions(createdBy: principal.id, spaceId: principal.spaceId)
                .union(pregrant)
            if !granted.contains(perm) {
                let ok = await permissions.request(perm, from: principal)
                if !ok { throw BridgeError.permissionDenied(perm.rawValue) }
                granted.insert(perm)
                saveCompanionPermissions(granted, createdBy: principal.id, spaceId: principal.spaceId)
            }
        }
        return try await method.run(principal, args, yield)
    }
}
