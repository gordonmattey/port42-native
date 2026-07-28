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

        #if DEBUG
        // I1.1 (plan §B). Recorded BEFORE the permission gate, so a call that is about to be
        // denied still counts as a caller — the question is who reaches the dispatcher without an
        // identity, not who succeeds. The grants are read here because this is the one place that
        // knows the bucket a synthetic id is already sharing.
        ActorProbe.dispatch(method: canonical, principal: principal,
                            grants: companionPermissions(createdBy: principal.id,
                                                         spaceId: principal.spaceId))
        ActorProbe.anyDispatch(surface: principal.kind.rawValue)
        #endif

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

        // AFTER the permission gate, which DOES refuse: a prompt is about the CALLER, and there is
        // no point recording a driver or moving a port's token for a call about to be denied.
        let token = try applyWriteSideEffects(writesTarget: method.writesTarget, args: args,
                                              principal: principal)

        return withToken(token, try await method.run(principal, args))
    }

    /// A WRITE'S SIDE EFFECTS, for BOTH dispatchers (I2 · C5).
    ///
    /// Extracted so the one-shot and streaming paths cannot diverge. Before C5 the streaming
    /// registry had no `writesTarget` at all: a streaming write verb would have moved no token,
    /// checked no CAS and recorded no presence, and nothing would have said so. Nothing escaped in
    /// practice, because all three streaming methods happen to be reads, but "happens to be" is the
    /// property this seam exists to replace.
    ///
    /// ONE resolve, shared. `resolvePortRef` is the only part of this that is not free (it rebuilds
    /// the terminal and panel tables per call and can probe the DB when the live ones miss, Spike A
    /// finding A1), and the CAS check, the token bump and the presence record all key off the same
    /// `PortRef.key`, so resolving more than once would double the expensive half for nothing.
    ///
    /// Throws `stale_write` when CAS refuses. Callers must run this BEFORE the body.
    ///
    /// RETURNS the token this write produced, or nil for a read. The caller merges it into the
    /// response so a writer never has to re-read the port just to write again — see
    /// `withToken(_:_:)`.
    @discardableResult
    func applyWriteSideEffects(writesTarget: String?, args: BridgeArgs, principal: Principal) throws -> String? {
        if let targetParam = writesTarget, let raw = args.string(targetParam),
           let key = portKey(for: raw) {
            // CAS (R3). A writer may declare the state it composed against. If the port has moved
            // since, the write is REFUSED — the first thing in this phase that refuses anything, and
            // the replacement for the lock R1 removed.
            //
            // Checked BEFORE the bump, or a write would invalidate the very token it is being
            // judged against. An ABSENT token still succeeds: that is today's last-write-wins
            // behaviour, so nothing that works now breaks, and CAS is opt-in until R5 makes it
            // mandatory for the one surface that cannot tolerate a splice.
            if let expected = args.string(PortActivity.expectParam) {
                let current = portInput.token(for: key)
                guard expected == current else {
                    // The error CARRIES `current`. Without it a caller only learns that it lost,
                    // not what to compose against — so the retry would be a guess, and a naive
                    // caller could never converge. With it: write → conflict → write, once.
                    throw BridgeError(
                        code: PortActivity.staleCode,
                        message: "This port has changed since you read it. Re-read it and retry.",
                        details: ["current": current, "expected": expected])
                }
            }
            // CORRECTNESS (R2). Bumped BEFORE the body runs, deliberately: `method.run` is async and
            // can suspend, so a token read mid-write would be read against a port already moving.
            // A body that then throws leaves a bump for a write that did not land — which costs a
            // concurrent writer one self-correcting retry, and never admits a stale write. Wrong in
            // the safe direction is the only acceptable way to be wrong here.
            // I2 · C2.2 — through the seam's door. One call now does both: the token moves and, since
            // this write HAS a principal, presence records with it. They can no longer be wired
            // separately, which is the point.
            let outcome = portInput.received(PortInput(
                port: key, kind: .programmatic,
                actor: ActorRef(principal: principal.id), actorName: principal.displayName,
                trust: .principal))
            broadcastDriverChange(outcome.driverChanged, port: key)
            return outcome.token
        }
        return nil
    }

    /// Merge the token a write produced into its response.
    ///
    /// Done here, ONCE, rather than in each of the eight write verbs — the same reasoning as the
    /// central `acceptingExpect()` injection: a write verb added tomorrow reports its token by
    /// construction instead of by its author remembering.
    ///
    /// Why it matters beyond tidiness: without it, a caller that has just written holds a token it
    /// knows is stale and must re-read the port before writing again. That is a round trip we were
    /// forcing for nothing, and it is what made "require a token" look expensive. With it, a writer
    /// writes continuously and each response refreshes what it holds.
    ///
    /// A non-object result (a bare string, an array) is returned untouched: there is nowhere to put
    /// the token without changing its shape, and silently reshaping a result would break callers.
    func withToken(_ token: String?, _ value: BridgeValue) -> BridgeValue {
        guard let token, case .object(var o) = value else { return value }
        o[PortActivity.tokenKey] = .string(token)
        return .object(o)
    }

    /// The local human as a principal (L2.d). nil before setup completes.
    var humanPrincipal: Principal? {
        guard let user = currentUser else { return nil }
        return Principal.human(id: user.id, displayName: user.displayName,
                               spaceId: currentSpace?.id)
    }

    /// FOCUSING a unit is the human saying "I am driving this", so it records them as the driver.
    ///
    /// Why focus and not `focusKeyboard`: keyboard focus also follows the MOUSE (hover raises a
    /// tile and hands it the keyboard), so recording on hover would name whoever's mouse crossed the
    /// desktop as the driver of every port it passed over. Zooming into a unit is deliberate;
    /// hovering is not. That reasoning survives the demotion — the cost changed from "seizes the pen
    /// from a companion" to "misreports who is driving", and both are wrong.
    ///
    /// Nothing is blocked either way (R1): a companion writing to a port you are focused on still
    /// writes, it just stops being named as the driver until its next write.
    func recordHumanFocus(portId: String) {
        guard let human = humanPrincipal else { return }
        NSLog("[Port42:presence] path=focus port=%@", portId)
        recordDriving(on: portId, by: human)
    }

    /// The human INTERACTED with a port's surface — typed into it, clicked in it (L2.d.2). This is
    /// the signal that makes presence tell the truth: a bridge write is not the only way to drive a
    /// port, and native input reaches no dispatcher, so without this the chrome would name a
    /// companion as the driver of a terminal you are typing into.
    ///
    /// What counts is intent to ACT: keydown and pointerdown. Deliberately NOT hover (a mouse
    /// crossing the desktop is not driving) and NOT scroll — scrolling is READING, and claiming on
    /// it would block a companion from continuing exactly while you watch it work.
    ///
    /// TWO SIGNALS, ONE EVENT, AND THE THROTTLE APPLIES TO NEITHER OF THEM UNCONDITIONALLY.
    ///
    /// The activity bump fires on EVERY input. Throttling it would be a correctness hole, not a
    /// tuning choice: a companion's write composed 4 seconds ago would pass CAS against a port you
    /// have typed thirty characters into, which is precisely the splice R5 exists to stop. Native
    /// input reaches no dispatcher, so this hook is load-bearing for the guarantee (finding 4).
    ///
    /// The presence record throttles a REFRESH and never a TAKEOVER. The throttle was written when
    /// this was a 30s lock, where its argument was "re-claiming a lease you already hold is noise" —
    /// true then, false after R1. Under last-driver-wins you do NOT still hold it: a companion's
    /// write took presence from you, so your next keystroke is a genuine change and dropping it
    /// leaves the chrome naming someone who stopped. GM caught this live — a companion writing every
    /// 2s against a 5s throttle meant the human could never win the chip back.
    ///
    /// So: already the driver → throttled, because that IS just a refresh. Anyone else, or nobody →
    /// recorded immediately. That restores the throttle's original intent instead of tuning its
    /// interval, which would only have moved the race rather than removed it.
    ///
    /// The bump does NOT require an identity, while the record does: the port changed whether or not
    /// we know who the person is, and pre-setup there is nobody to attribute it to.
    ///
    /// The id is already the port key (the surfaces report `panel.udid`), so the driver lookup is
    /// one dict read. Only the branch that actually records pays for a resolve — this runs per
    /// keystroke, and `resolvePortRef` is the one part of the path that is not free (Spike A, A1).
    func humanInteracted(with portId: String) {
        let human = humanPrincipal
        #if DEBUG
        if human == nil {
            // I1.1: a mutation with NOBODY to attribute it to. No `Principal` site would ever show
            // this one, because the path builds no principal at all. Counted so the construction
            // sites are not mistaken for the whole set of ways a write reaches a port unattributed.
            ActorProbe.inputWithoutIdentity(port: portId)
        }
        // Kept for the live presence log, which reads as a stream of takeovers.
        let alreadyDriving = human.map { portInput.driver(of: portId, now: Date())?.ref
                                         == ActorRef(principal: $0.id) } ?? false
        #endif

        // I2 · C2.2 — one call. The bump, the throttle and the record were three separate steps here
        // and the seam now owns the ordering between them, which is what stops a future edit from
        // throttling the token by accident. `actor: nil` when there is no human is not a special
        // case: it is the honest statement that the port changed and we do not know who.
        let outcome = portInput.received(PortInput(
            port: portId, kind: .gesture,
            actor: human.map { ActorRef(principal: $0.id) }, actorName: human?.displayName,
            trust: .native))

        #if DEBUG
        if human != nil {
            NSLog("[Port42:presence] path=input port=%@ takeover=%d", portId, alreadyDriving ? 0 : 1)
        }
        #endif
        broadcastDriverChange(outcome.driverChanged, port: portId)
    }

    /// A PROGRAMMATIC write reached a port's surface without passing the dispatcher (R2b).
    ///
    /// The surface is the boundary, not the API. `port.push` and a companion's `@mention` reach a
    /// terminal by different routes, and a paste, a file drop, the startup command and the first-run
    /// prefill reach it by no route at all — none of them touch `runBridgeMethod`. Counting at the
    /// one place the text actually enters the pty is what makes the token's guarantee structural
    /// instead of a list someone has to keep up to date (finding 7).
    ///
    /// Presence is deliberately NOT recorded here: this fires for writes the app itself makes at
    /// spawn time (startup command, prefill), and naming the app as the driver of a port the user
    /// just opened would be a lie. The bridge seam records presence for writes that have a principal.
    ///
    /// The id is already the port key, so no resolve — this is on a per-keystroke-burst path.
    /// A BROWSER port went somewhere new (I2 · C3).
    ///
    /// A navigation replaces the entire document, so it is the largest content change a port can
    /// undergo and the one a stale write most needs to be refused against. Before this, the only
    /// hook was the tile's address bar: typing a URL counted, and clicking a link, going back,
    /// reloading, or any script-initiated navigation did not.
    ///
    /// No actor: a navigation can be caused by the human clicking a link or by the page's own
    /// script, and the two are indistinguishable at this seam. Claiming the human drove it when a
    /// script did would be the same forgery `isTrusted` exists to stop, so this counts the change
    /// and names nobody. R7 is where a native claim could make that distinction.
    func browserNavigated(port portId: String, to url: URL) {
        portInput.received(PortInput(port: portId, kind: .navigation(url),
                                     actor: nil, trust: .native))
    }

    func surfaceWrote(port portId: String) {
        // I2 · C2.2. `actor: nil` is what keeps presence out of this path: it fires for writes the
        // app itself makes at spawn time, and naming the app as the driver of a port the user just
        // opened would be a lie. Under the seam that is not a rule anyone has to remember, it falls
        // out of there being nobody to name.
        portInput.received(PortInput(port: portId, kind: .programmatic, actor: nil, trust: .native))
    }

    /// The ONE key every per-port table uses: the port's Notify topic id (`PortRef.key`).
    /// Presence, the activity token and the broadcast all key off this, so none of them can
    /// disagree about which port they mean. nil for an unresolvable target.
    func portKey(for rawId: String) -> String? {
        guard let ref = resolvePortRef(rawId) else { return nil }
        return PortRef.key(ref)
    }

    /// Resolve, then record. For the callers that hold a raw id rather than a key; the dispatch
    /// seam does its own resolve so it can share one with the token bump.
    ///
    /// An unresolvable target records NOTHING: presence on a port that does not exist would name a
    /// driver of nothing, and would then be shown against whatever later claimed that id.
    func recordDriving(on rawId: String, by principal: Principal) {
        guard let key = portKey(for: rawId) else { return }
        recordDriving(port: key, by: principal)
    }

    /// Record this principal as the one driving a port, and broadcast the change. NEVER refuses:
    /// R1 demoted right-of-way to presence, so this reports a fact rather than arbitrating one.
    /// I2 · C2.2: this is the FOCUS path, and it goes through `presenceClaimed`, not `received`.
    ///
    /// Focusing a port changes nothing about its contents, so its token must NOT move. `received`
    /// bumps unconditionally by design, so routing focus through it would invalidate every reader's
    /// token on a click and cost concurrent writers spurious `stale_write` retries. The seam has two
    /// entry points because it owns two guarantees and a focus touches exactly one.
    func recordDriving(port key: String, by principal: Principal) {
        let driver = portInput.presenceClaimed(port: key,
                                               actor: ActorRef(principal: principal.id),
                                               name: principal.displayName)
        broadcastDriverChange(driver, port: key)
    }

    /// Announce a driver change on the port's own topic. nil = a refresh, which is silent by design:
    /// publishing per keystroke would drown the topic in non-news.
    ///
    /// The thing already streaming a port's output is the thing that says who is driving it, so
    /// every surface watching the port (a tile header, another instance's mirror, an agent deciding
    /// whether to wait) learns for free and no side channel exists to fall out of sync.
    func broadcastDriverChange(_ driver: Driver?, port key: String) {
        guard let d = driver else { return }
        NSLog("[Port42:presence] DRIVING %@ → %@ (%@)", key, d.name, d.ref.description)
        notifyBus.publish(topic: "port:\(key)", kind: "driver",
                          payload: ["driver": d.ref.description,
                                    "driverName": d.name,
                                    "until": d.expires.timeIntervalSince1970])
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
        #if DEBUG
        ActorProbe.dispatch(method: canonical, principal: principal,
                            grants: companionPermissions(createdBy: principal.id,
                                                         spaceId: principal.spaceId),
                            streaming: true)
        ActorProbe.anyDispatch(surface: principal.kind.rawValue)
        #endif
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
        // I2 · C5 — the SAME function the one-shot path runs. Streaming is not a second dispatch
        // with its own rules; a write is a write whichever registry serves it.
        let token = try applyWriteSideEffects(writesTarget: method.writesTarget, args: args,
                                              principal: principal)

        return withToken(token, try await method.run(principal, args, yield))
    }
}
