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
            throw BridgeError(code: .unknownMethod, message: "Unknown method: \(canonical)")
        }

        #if DEBUG
        // I1.1 (plan §B). Recorded BEFORE the permission gate, so a call that is about to be
        // denied still counts as a caller — the question is who reaches the dispatcher without an
        // identity, not who succeeds. The grants are read here because this is the one place that
        // knows the bucket a synthetic id is already sharing.
        ActorProbe.dispatch(method: canonical, principal: principal,
                            grants: grants(grantee: principal.id, on: .machine,
                                           zone: principal.spaceId))
        ActorProbe.anyDispatch(surface: principal.kind.rawValue)
        #endif

        if let perm = method.permission {
            guard await ensurePermission(perm, for: principal, pregrant: pregrant) else {
                throw BridgeError.permissionDenied(perm.rawValue)
            }
        }

        // AFTER the permission gate, which DOES refuse: a prompt is about the CALLER, and there is
        // no point recording a driver or moving a port's token for a call about to be denied.
        let key = try applyWriteSideEffects(writesTarget: method.writesTarget, args: args,
                                            principal: principal)

        // The token is read AFTER the body, never before. See `tokenAfter(_:)`.
        let value = try await method.run(principal, args)
        try failIfErrorResult(value, method: canonical)
        return withToken(tokenAfter(key), value)
    }

    /// **Does this principal hold this permission — asking, and remembering the answer.**
    ///
    /// The one implementation of the permission gate, extracted because a SECOND caller appeared:
    /// `port.create` gates on its `type` argument (creating a terminal IS using the terminal), and
    /// the obvious way to write that — calling `permissions.request` in the method body — asks the
    /// human EVERY TIME, because the request path prompts and the *dispatcher* was the only thing
    /// that persisted the answer. `screen.record`'s in-body `.microphone` ask has exactly that shape
    /// and exactly that flaw.
    ///
    /// OBJECT = port 0. Every capability gated here is a machine capability (clipboard, filesystem,
    /// terminal, screen, …), which is precisely what port 0 names. A grant about a specific port
    /// becomes expressible at slice-02's wire half; nothing local produces one yet.
    func ensurePermission(_ perm: PortPermission, for principal: Principal,
                          pregrant: Set<PortPermission> = []) async -> Bool {
        var granted = grants(grantee: principal.id, on: .machine, zone: principal.spaceId)
            .union(pregrant)
        if granted.contains(perm) { return true }
        guard await permissions.request(perm, from: principal) else { return false }
        granted.insert(perm)
        saveGrants(granted, grantee: principal.id, on: .machine, zone: principal.spaceId)
        return true
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
    /// RETURNS the port's key, or nil for a read. **Not the token** — the caller reads that after
    /// the body has run, because a write's own effects land during the body. See `tokenAfter(_:)`.
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
                        code: .staleWrite,
                        message: "This port has changed since you read it. Re-read it and retry.",
                        details: ["current": current, "expected": expected])
                }
            }
            // R5 (GM 2026-07-27): A WRITE MUST SAY WHAT IT COMPOSED AGAINST.
            //
            // Opt-in CAS asked for discipline from the WRONG PARTY. Supplying a token protected you
            // from writing over someone else; whether YOUR work survived depended on the OTHER
            // caller supplying one. A careless writer clobbered a careful one and the careful one
            // could not defend itself. Almost nobody supplied a token, because nothing required it.
            //
            // GM's framing is what made this simple: PRESENCE IS PROVEN THROUGH THE TOKEN, and
            // humans hold one too, under the hood. When you type, your keystroke IS what moves the
            // token, so you hold the current one by construction — not exempt, just standing where
            // it is minted. An agent is not at the surface, so it fetches one. One rule, no surface
            // carve-out, no special case for people.
            //
            // So the rule is: you must have LOOKED at the port before writing to it. A caller with
            // no token has, by definition, not looked.
            //
            // NOT the lease R1 removed. That refused you regardless and you could not argue with it;
            // a holder could vanish and leave a port stuck, which is why it could never cross the
            // wire. This refuses only a caller who declined to declare state, and hands them the
            // answer in the error, so one retry always converges. Nobody is ever blocked.
            //
            // R1's REASONING survives whole. R1's slogan ("presence refuses nothing") does not, and
            // `PortPresenceGateTests` is rewritten to the amended contract rather than deleted.
            guard args.string(PortActivity.expectParam) != nil else {
                throw BridgeError(
                    code: .tokenRequired,
                    message: "This write must say what it composed against. Send the port's `token` "
                           + "— every write, `ports.list` and `port.create` return one.",
                    details: ["current": portInput.token(for: key)])
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
            return key
        }
        return nil
    }

    /// The port's token AFTER a write's body has run — the value the caller gets back.
    ///
    /// **MEASURED DEFECT, fixed 2026-07-27.** This used to return the token from the pre-body bump,
    /// and on a terminal that value was stale before the caller ever saw it. A `port.push` moves the
    /// counter three times: once here at the dispatch seam, then twice more at the pty funnel (R2b)
    /// as the text and the newline enter the surface. Live in Dev3: a push answered `:2` while the
    /// port stood at `:4`, so **threading the returned token was refused every single time.**
    ///
    /// That broke R5's central promise, the one that made "every write must carry a token"
    /// affordable: *no extra round trips, because every write returns a token*. On terminals it cost
    /// a re-read per write, or a `stale_write`.
    ///
    /// The bump stays where it is. It is the general guarantee — a `port.exec` on a web port has no
    /// surface funnel behind it, so nothing else would count that write at all — and it stays BEFORE
    /// the body so a suspending body cannot be composed against mid-write. Only the READ moved, to
    /// where the answer is true: the port's state after your write, rather than after the dispatcher
    /// noticed it.
    ///
    /// Counting a terminal write more than once is harmless in itself, because a `seq` is opaque and
    /// only has to be monotonic and to move when the port changes. Reporting a number that was
    /// already wrong is not.
    ///
    /// One case this does NOT fix, and it is stated rather than hidden: `port.create` returns before
    /// a terminal has spawned, so the startup command's bump lands after the response. A caller
    /// re-reads once after create, or threads from its first write.
    func tokenAfter(_ key: String?) -> String? {
        guard let key else { return nil }
        return portInput.token(for: key)
    }

    /// A body that REPORTED a failure instead of throwing one becomes a thrown, coded error.
    ///
    /// **MEASURED 2026-07-28: ~90 device-bridge failures are built as `["error": "…"]` dictionaries**
    /// (Screen, Camera, Audio, Browser, Automation, Notification, Clipboard, ScreenRecorder), and
    /// every one of them reaches a caller through `return .fromJSONObject(result)` — as a SUCCESS.
    /// Not merely uncoded: a caller that catches sees nothing thrown, a caller that checks `code`
    /// finds none, and a caller that asks "did it work" is told yes. `screen.capture` with no display
    /// available answered exactly like a capture that worked.
    ///
    /// Fixed HERE rather than at the ninety sites, because the ninety share one boundary and each
    /// would otherwise need its own signature change and its own judgment. The code comes from the
    /// method's FAMILY (`BridgeErrorCode.forMethod`), which is the only thing derivable without
    /// guessing at a message.
    ///
    /// NARROW ON PURPOSE: only when `error` holds a String AND the object carries no other data. A
    /// payload that merely mentions an error — `browser.error` events carry `sessionId`, `url` and
    /// `error` together — is data, not a failure, and must keep flowing. Those travel as events
    /// rather than method results, so they do not pass here at all; the check is belt and braces.
    func failIfErrorResult(_ value: BridgeValue, method: String) throws {
        guard case .object(let o) = value,
              case .string(let message)? = o["error"],
              o.keys.allSatisfy({ $0 == "error" || $0 == "code" }) else { return }
        // A body that NAMED its code wins over the family default: the family is what you can derive
        // without knowing anything, and the site knows more. "screen recording permission denied" is
        // a permission failure the user can fix, not a device that broke.
        if case .string(let named)? = o["code"], !named.isEmpty {
            throw BridgeError(rawCode: named, message: message)
        }
        throw BridgeError(code: BridgeErrorCode.forMethod(method), message: message)
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
    /// A NON-OBJECT result is wrapped as `{value, token}` rather than returned bare.
    ///
    /// This used to return a scalar untouched, on the reasoning that there was nowhere to put the
    /// token and reshaping would break callers. **R5 turned that into a hole.** Every write must
    /// carry a token, so a write whose response has no room for one forces the caller to re-read the
    /// port before its next write — and `port.exec` returns a scalar whenever the JS does, which is
    /// the common case and the verb agents use most. Measured in Dev3: `port.exec` answered a bare
    /// `1`, with no token anywhere in the response.
    ///
    /// Reshaping IS a break, and it was taken deliberately while adoption is near zero (GM,
    /// 2026-07-27), the same call as the `expect` → `token` rename: the cost of this change only
    /// rises with every generated port that bakes the old shape in.
    func withToken(_ token: String?, _ value: BridgeValue) -> BridgeValue {
        guard let token else { return value }
        if case .object(var o) = value {
            o[PortActivity.tokenKey] = .string(token)
            return .object(o)
        }
        return .object(["value": value, PortActivity.tokenKey: .string(token)])
    }

    /// The local human as a principal (L2.d). nil before setup completes.
    var humanPrincipal: Principal? {
        guard let user = currentUser else { return nil }
        return Principal.human(id: user.id, displayName: user.displayName,
                               spaceId: currentSpace?.id)
    }

    // FOCUS USED TO CONFER PRESENCE, AND STOPPED AT STEP 3 (GM, 2026-07-27).
    //
    // `recordHumanFocus` recorded the human as a port's driver on zoom, without moving its token —
    // deliberately, since focusing a tile changes nothing about its contents. Once the driver is
    // DERIVED from whoever moved the token last, that claim asserts presence while proving nothing,
    // and it is the only thing that needed a second door into the seam.
    //
    // What changes for a person: zooming into a port with the keyboard or a header double-click, and
    // then not touching it, leaves the chip naming the companion that is writing. That is true.
    // Clicking or typing INSIDE the surface still names you, through `humanInteracted` below, which
    // is how most focus arrives anyway.

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

    /// Announce a driver change on the port's own topic. nil = a refresh, which is silent by design:
    /// publishing per keystroke would drown the topic in non-news.
    ///
    /// The thing already streaming a port's output is the thing that says who is driving it, so
    /// every surface watching the port (a tile header, another instance's mirror, an agent deciding
    /// whether to wait) learns for free and no side channel exists to fall out of sync.
    func broadcastDriverChange(_ driver: Driver?, port key: String) {
        guard let d = driver else { return }
        NSLog("[Port42:presence] DRIVING %@ → %@ (%@)", key, d.name, d.ref.description)
        notifyBus.publish(topic: "port:\(key)", kind: PortEventKind.driver.wire,
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
            throw BridgeError(code: .unknownMethod, message: "Unknown streaming method: \(canonical)")
        }
        #if DEBUG
        ActorProbe.dispatch(method: canonical, principal: principal,
                            grants: grants(grantee: principal.id, on: .machine,
                                           zone: principal.spaceId),
                            streaming: true)
        ActorProbe.anyDispatch(surface: principal.kind.rawValue)
        #endif
        if let perm = method.permission {
            // The SAME function the one-shot path runs. Streaming is not a second set of rules.
            guard await ensurePermission(perm, for: principal, pregrant: pregrant) else {
                throw BridgeError.permissionDenied(perm.rawValue)
            }
        }
        // I2 · C5 — the SAME function the one-shot path runs. Streaming is not a second dispatch
        // with its own rules; a write is a write whichever registry serves it.
        let key = try applyWriteSideEffects(writesTarget: method.writesTarget, args: args,
                                            principal: principal)

        let value = try await method.run(principal, args, yield)
        try failIfErrorResult(value, method: canonical)
        return withToken(tokenAfter(key), value)
    }
}
