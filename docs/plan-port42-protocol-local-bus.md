# Plan: the Port42 protocol, proven locally (the address + Notify bus)

*2026-07-22. Status: **PLANNED**, no code. Read-level architecture spike done (four traces, cited
below). This is the build plan for proving the bus/actor contract **inside one instance** before any
transport. Test only in Port42Dev (:4243). Full plan per phase; nothing built until reviewed.*

Related: `membrane/bus-architecture.md` (the six-facet contract, the working spec), `port42-rfc.txt`
(UERP, the address + verb north star), `membrane/slice-02-cross-instance.md` (the same contract over
libp2p, deferred), `plan-api-unification.md` + `plan-phase3-principal.md` (the two shipped layers this
stands on).

---

## 1. The slice in one line

> A port is an **addressable actor**: you resolve it by `port42://` address, send it a query, and
> subscribe to its stream — uniformly across web, terminal, and browser ports, **all within one
> instance**. When this is green, cross-instance is a prefix on the address plus a transport swap; the
> contract does not change.

This proves bus-architecture keystones **#1 address** and **#3 unified subscription** locally, with the
**#2 right-of-way lease** as a fast-follow. Transport (libp2p vs the current WebSocket gateway) is out
of scope here by design: the whole point of proving it local-first is that the contract is
location-transparent, so transport slots under a proven contract instead of being co-designed with it.

## 2. Where the stack already is (the two shipped layers this rides on)

The protocol is a four-layer stack; the bottom two shipped, so the shape is right at the app-contract
level:

- **Message layer (SHIPPED, `plan-api-unification.md`).** One registry, one impl per method, one
  `BridgeValue` shape, reached identically by every caller through the single choke point
  `AppState.runBridgeMethod(name, principal, args, pregrant) -> BridgeValue` (`BridgeDispatcher.swift:25`).
  A streaming twin `runBridgeStream` (`:56`) already produces >1 output per call.
- **Identity layer (SHIPPED, `plan-phase3-principal.md`).** An authenticated principal carried end to
  end; grants key on `principal.id`. `Principal` already carries `portId` (the specific live port) and
  `spaceId` (`Principal.swift:15`), and its doc comment states `portId` exists "for owner resolution
  (event routing)". `portId` is deliberately excluded from `==` so it never splits a grant bucket.

**Four of six bus facets already run** (per `bus-architecture.md`): Query in (`push`/`exec`/`patch`/
`getHtml`), Stream out (per-type, see §4), Temporal (`history`/`restore`), local Address (bare id). The
three gaps are exactly this slice: a real cross-addressable **Address**, unified **Subscription**, and
**right-of-way**.

## 3. The architecture decision (settled by the spike)

**Shape (A): the bus is a thin layer around the existing registry, not a rewrite of it.** Rejected shape
(B) — reframing every registry method as a Query/Update actor mailbox — is unnecessary. Evidence:

- Dispatch keys on a **string name**, and the target port is passed as an ordinary `id` **argument**
  resolved inside the method body (`BridgeDispatcher.swift:25`, method bodies in `BridgeMethods.swift`).
  There is no addressing layer between caller and method today — that absence is the seam.
- So an **address resolver slots between the dispatcher and the method bodies** without touching the
  registry contract. It consolidates a real fragmentation the spike found (§3.1).
- The Notify path **reuses the `BridgeStreamMethod` dispatcher + adapter pattern** (`BridgeRegistry.swift:74`),
  generalized on two axes (§3.2).

### 3.1 The address resolver consolidates three scattered id→port tables

`id→port` resolution is fragmented today, which is also why a bare `id` is polymorphic (UDID **or**
terminal name **or** title):

| Resolver | Backing table | Match semantics | Callers |
|---|---|---|---|
| `webView(_ id:)` (`BridgeMethods.swift:110`) | `portWindows.webViews` / `findInlineBridge` | UDID exact | `port.exec`, web `port.push` |
| `resolveTerminalController(idOrName:)` (`AppState.swift:2760`) | `terminalControllers` | fuzzy id-or-companion-name | terminal `port.push` |
| `findPort(by idOrTitle:)` (`PortWindowManager.swift:765`) | `panels` | UDID exact, then title | `port.manage` |

Routing between them exists only in `PortPushRoute.classify` (`PortPushRoute.swift:13`), and only for
`push`. The resolver's real job: **one `resolve(address) -> PortRef` over all three tables**, with a
`PortRef` that names which surface it is (web / terminal / browser) so the Query and Notify paths branch
once, in one place, instead of per method.

### 3.2 The Notify fan-out reuses BridgeStreamMethod

`BridgeStreamMethod` already solves the hard parts of a Notify stream: unified auth/dispatch, per-surface
`yield` fan-out (port JS → `_tokenCallback`; gateway → chunked; tool-use → collect), cancellation via a
tracked `Task`, and terminal value/error semantics. Two generalizations turn it into a bus:

1. **Typed event, not a bare token.** `yield` carries `String` today; a Notify carries a typed envelope
   `{ topic, kind, payload }` so web dicts, terminal line-batches, and browser nav events all fit one
   shape.
2. **1:N, not 1:1.** Today one call → its own callback. A Notify needs a subscriber registry keyed by
   topic. The `bus.*` mechanism already uses a `port:{portId}` topic convention (`BridgeMethods.swift:1104`),
   so the topic key exists; what's missing is an **in-memory** fan-out (there is no general
   `PassthroughSubject`/observer registry in Services today beyond the single `portCreated` subject —
   `PortWindowManager.swift:110`).

## 4. Across ports: the three publish attach points (the "particularly terminal and browser" answer)

Each port type has a concrete, already-present seam to publish its native stream into the Notify bus.
None forces a pixel/video fallback.

- **Web** — `pushEvent → port42._emit` (`PortBridge.swift:389`). JS-side listener fan-out already exists
  (`_emit` walks `_listeners[event]`, `PortBridge.swift:486`). Native side has no fan-out; add a native
  publish alongside the JS inject. Inbound channels stay the three handlers (`port42`/`portHeight`/
  `portConsole`).
- **Terminal** — the preserved no-op `onFlush` at `GhosttyTerminalController.swift:129` (`{ _ in }`).
  `TerminalOutputProcessor.onFlush` emits **batched, ANSI-stripped, deduped clean lines** (a `String`),
  on a path **parallel to rendering** (the Ghostty PTY tee feeds both). Replace the no-op with a publish.
  **This also cashes out open item 3.4** (native terminal output-streaming bridge). Two caveats to carry
  into the design: it is batched/debounced (prompt-detect / 3s quiet / 8KB), not a live byte stream; and
  the only TUI guard today is a coarse claude/gemini name check (`CompanionPostGate.hooksCapable`) — there
  is **no alt-screen probe**, so streaming an ad-hoc `vim`/`htop` in a non-hooks terminal would emit
  redraw garbage. The bus must gate terminal Notify behind that guard and document the limit.
- **Browser** — already emits structured `browser.load/redirect/error` via `pushEvent` (`BrowserBridge.swift:334/373/391`).
  It is a **WKWebView we own** (`.nonPersistent()` data store), so richer streams (DOM, console, network)
  are reachable by adding `WKScriptMessageHandler`/observers later; nothing forces pixels. **The
  integration gap:** the headless `BrowserBridge` has the query + stream, but the **visible tiled browser
  port** (`portType == "browser"`, `ShellDesktop.swift:870`) is a *different* WKWebView with no
  `browser.*` interface wired to it. Making the on-screen browser an addressable actor = connecting the
  tile to the `BrowserBridge` query/stream plumbing. This is the one genuinely new sub-build in the browser
  path.

## 5. The RFC reconciled to the working contract

The RFC (`port42-rfc.txt`) is a mock-IETF memo from mid-2025. Keep the spine, drop the theater. This is
the durable-vs-evolve split so the address grammar we build to is decided:

**Durable (build to these):**
- Address grammar `port42://[type]/[id]/[path]`. For a running port, the local form is
  `port42://space/<spaceId>/<portId>` (the `<peerID>` instance segment is the cross-instance prefix,
  added later). Reuse the existing `URLComponents` host-switch parser convention (`SpaceInvite.parse`
  `SpaceInvite.swift:56`, `AgentInvite.parse` `AgentInvite.swift:55`); add a port-addressing host, which
  is net-new (today the host axis is only `{agent, space, openclaw}`).
- The five verbs Query / Response / Update / Subscribe / Notify — they already map onto the shipped bridge
  verbs (verb map in `bus-architecture.md`).
- Location transparency and temporal addressing (already live as `history`/`restore`).

**Evolve or drop:**
- The binary wire format (RFC Figure 2) — the live bus is JSON; keep it JSON.
- The proof-of-work DHT discovery — deferred; slice-02 already softens it to mDNS→Kademlia.
- The seven entity types — reconcile to what shipped (`context`≈`space`; `content`/`relation`/`temporal`
  partly = creases/fold/history), do not preserve verbatim.
- IANA "reassign port 42" — flavor, not a constraint.

Treat `bus-architecture.md`'s six-facet contract as the working spec; treat the RFC as the address+verb
north star.

## 6. The build, in phases (address + subscription first, lease fast-follow)

### Phase L0 — the address resolver (keystone #1) — CONSOLIDATE variant (GM, 2026-07-22)

**STATUS: SHIPPED (2026-07-23), verified live.** `PortAddress` + `PortResolution` + `PortAddressTests`
(13 green) landed; `AppState.resolvePortRef` gathers the live candidate lists and calls the one
resolution rule; all nine by-id methods (`push`/`exec`/`getHtml`/`history`/`manage`/`update`/`patch`/
`restore`/`move`) route through it. Live-verified in Port42Dev: web+terminal push, and `getHtml`/`update`
now resolve by **title/name**, not just UDID (parity preserved for UDIDs). All ten by-id methods
(the nine above + `rename`) route through the resolver; `PortPushRoute` is deleted (precedence lives in
`PortResolution`); `BridgeResolverGateTests` is the source-scan invariant that keeps it that way.
Commits `0a2fc9d`, `e40a0ae`, `7833704`, `682e21a`. **L0 DONE.** **Next keystone: L1 (unified
Subscribe→Notify).**

**Decision (GM 2026-07-22):** consolidate, not minimal. L0 makes the scattered id→port lookups callers
of one resolver, because the resolver must span all of them to resolve any address anyway, and the
fragmentation is the actual cause of the polymorphic-id ambiguity.

#### The fragmentation being removed (spike-confirmed)

A bare `id` today means any of: a panel UDID, a `webViews` panelId key, a terminal companion-name, a
port title (exact **or** fuzzy `contains`), or a `PortBridge.messageId` — across five lookup paths with
different match semantics:

| Path | Backing | Match | Callers |
|---|---|---|---|
| `webView(id)` (`BridgeMethods.swift:110`) | `portWindows.webViews` / `findInlineBridge` | exact id / messageId | `port.exec`, web `port.push` |
| `resolveTerminalController` (`AppState.swift:2760`, pure rule `resolveTerminalId` `:2747`) | `terminalControllers` | id-hit → exact name → `contains` | terminal `port.push` |
| `findPort(by:)` (`PortWindowManager.swift:765`) | `panels` | udid → title exact → title `contains` | `port.manage`, `port.move` |
| `updatePort(idOrTitle:)` (`PortWindowManager.swift`) | `panels` (same scan, inlined) | udid → title exact → `contains` | `port.update` |
| DB (`db.fetchPortHtml(udid:)` / `fetchPortVersions`) | `port_panels` / `port_versions` | udid exact | `port.getHtml`, `port.history`, `port.restore` |

#### The design (pure rule + thin wrapper, mirrors `resolveTerminalId`) — reviewed 2026-07-22

Two new pure, headless-testable files (no live objects), plus one thin `AppState` wrapper. **The
architecture review (2026-07-22) changed this design in four load-bearing ways; the code as landed
reflects the reviewed version:**

**(a) Identity is a triple, not a single id — the review's headline.** A port carries `id` (panel id,
the `webViews` key), `udid` (the stable/DB key), and, for a `port` fence, a `messageId`; `webViews` is
keyed by `panel.id` and `id != udid` for post-migration ports. A `PortRef` that returned one string
would break the accessor keyed on a different member (a real `port.exec`/`push` regression). So `PortRef`
carries all three; each method body uses the member its accessor needs.

**(b) The DB probe is lazy.** Passing an eager `dbUdids` set would force loading every udid from the DB
on every resolve. Instead `dbHas: (String) -> Bool` is called at most once, only after the live tables
miss — the common path (push/exec) never touches the DB.

**(c) The name-match rule is owned by the resolver.** `AppState.resolveTerminalId` now forwards to
`PortResolution.terminalMatch`, so the pure resolver no longer reaches up into `AppState` (dependency
direction fixed) and there is one terminal-matching rule.

**(d) DB-only kind is `.unknown`, not a guessed `.web`.** A DB-only ref's surface kind isn't verifiable;
`kind` says so rather than lying.

```swift
// PortAddress.swift — the address grammar (pure). `_` is the reserved nil-space placeholder, so
// canonical ∘ parse is identity for a bare-id alias too (round-trip fixed).
public struct PortAddress: Equatable {
    public let spaceId: String?    // nil = current/any space (a bare-id local alias); renders/parses as `_`
    public let portId: String
    public static func parse(_ s: String) -> PortAddress?   // port42://space/<spaceId>/<portId>
    public var canonical: String                            // port42://space/<spaceId or _>/<portId>
}

// PortResolution.swift — the resolution RULE (pure) + its result
public enum PortSurfaceKind: String, Equatable { case web, terminal, browser, unknown }
public struct PortCandidate: Equatable {   // a live panel's full identity, fed to the resolver
    public let id: String; public let udid: String; public let messageId: String?
    public let title: String; public let portType: String?
}
public struct PortRef: Equatable {
    public let kind: PortSurfaceKind
    public let spaceId: String?
    public let id: String?          // panel.id / webViews key / management key; terminal key for .terminal
    public let udid: String?        // DB / versions key
    public let messageId: String?   // inline web bridge key
}
public enum PortResolution {
    public static func terminalMatch(_ idOrName: String,
                                     candidates: [(id: String, name: String)]) -> String?
    // Precedence: terminal → panel(id|udid|messageId|title) → inline → DB-only. Pure; unit-tested.
    public static func resolve(_ idOrAddress: String,
                               terminals: [(id: String, name: String)],
                               panels: [PortCandidate],
                               inlineMessageIds: Set<String>,
                               dbHas: (String) -> Bool) -> PortRef?
}
```

`AppState.resolvePortRef(_ idOrAddress:) -> PortRef?` (the thin wrapper, to be added in the post-demo
pass) gathers the live candidate lists — `terminalControllers` → (id, companionName); `panels` →
`PortCandidate(id, udid, messageId, title, portType)`; inline `PortBridge.messageId`s not backed by a
panel; and a lazy `db.portExists(udid:)` closure — and calls `PortResolution.resolve`. A bare string
becomes `PortAddress(spaceId: nil, portId: s)`, so **UDID/name/title stay working as short local
aliases, no break**.

Browser kind: a `PortCandidate` with `portType == "browser"` resolves `.browser`; else `.web`. (The
headless `BrowserBridge` sessions are addressed by their own `sessionId`, a separate axis from port
units — out of L0 scope; noted in §4's browser gap.)

#### Rewiring the method bodies (the consolidation)

Each by-id method calls `resolvePortRef` and switches on `.kind`, fetching the concrete handle by the
identity member its accessor keys on (the triple from fix (a)):

- `port.push` → `resolvePortRef(id)`; `.terminal` → `controller.sendRaw` (via `ref.id`); `.web`/
  `.browser` → `dispatchEvent` on `webViews[ref.id] ?? findInlineBridge(by: ref.messageId)`; `.unknown`
  → `notFound`. **Deletes** the `resolveTerminalController` + `webView` + `PortPushRoute.classify` triad
  at the call site (precedence now lives in `PortResolution`).
- `port.exec` → require `.web`/`.browser` → webview via `ref.id`/`ref.messageId`.
- `port.manage`, `port.move` → operate on `ref.id` (the panel/management key) directly — no second
  `findPort` scan.
- `port.update` → route through the resolver (`ref.id`/`ref.udid`), drop the inline panel scan in
  `updatePort`.
- `port.getHtml`, `port.history`, `port.restore` → use `ref.udid` for the DB read.

`PortPushRoute` is subsumed (its precedence moves into `PortResolution`) — keep the file as a thin
re-export or delete it once nothing imports it; the existing `PortPushRouteTests` port to
`PortResolutionTests`.

#### Making the consolidation an invariant, not a convention (review fix)

The resolver being a shared helper means nothing *prevents* a sixth method from hitting a table
directly. Add a source-scan gate (the pattern `BridgeCloseOutTests` already uses): assert no
`BridgeMethods`/`ToolExecutor` body references `portWindows.webViews[`, `findPort(`, or
`resolveTerminalController(` outside `resolvePortRef`. That turns "one resolver" from a hope into a
checked invariant, matching the strength of the dispatch choke point this builds on.

#### Deeper follow-up (not L0): unify identity to one canonical id

L0 surfaces the full identity triple so the rewire is regression-free, but the underlying fragmentation
(a port has three coexisting ids; `webViews` keyed by `panel.id`; defensive `id||udid||messageId`
matching scattered across the codebase) remains. The real fix is one canonical identity with the others
derived, so `webViews`/panels/DB key on the same thing. That is a larger, separate change (call it
**L0.5**); L0 does not block on it, and carrying the triple is the correct interim.

#### Sequencing under the demo constraint (GM prepping a demo, 2026-07-22)

- **Now (safe, additive, zero build):** land `PortAddress.swift`, `PortResolution.swift`, and
  `PortAddressTests.swift` — new files, no live path touched, the running dev bundle is unaffected (file
  writes don't rebuild it). The pure rule is fully unit-testable.
- **After the demo (needs a build + GM's say-so):** add `AppState.resolvePortRef`, rewire the method
  bodies above, run `swift test` + the live cross-path check in Port42Dev. Held until GM clears the demo
  window, because it requires `./build.sh` (which kills the running dev instance) and a `swift test`
  compile.

**Test gate (Swift Testing, headless).** All landed, unrun (held for the post-demo build).
`PortAddressTests`: parse/round-trip of a real address; the **nil-space `_` round-trip** (canonical ∘
parse is identity); a bare id is not an address; rejects foreign scheme / space-invite form / wrong
segment count / wrong host. `PortResolutionTests`: terminal by id and fuzzy name (canonicalizes to id);
**terminal wins over web**; a panel resolves by **id, udid, messageId, and title while surfacing the full
identity triple** (the regression case — matching by udid still yields `panel.id`, the `webViews` key); a
`portType:"browser"` panel → `.browser`; an inline-only bridge → `.web` with only a `messageId`; a
DB-only udid → **`.unknown`, probed lazily** (and the live path does NOT touch the DB); unknown → nil; a
full address carries its space. Post-rewire, add the **source-scan invariant gate** above. Command:
`swift test --filter PortAddress` / `--filter PortResolution`.
**Done when:** one resolver backs all by-id methods; the five old lookups are callers of it, not parallel
paths; the precedence + identity-triple tests are green; the source-scan gate holds.

#### Sequencing note (review, 2026-07-22)

The prerequisite L1 (Notify) and L2 (lease) actually share is a **stable port identity**, which already
exists (`udid`), not the alias-consolidation. So L0-consolidate is worthwhile cleanup but not a hard
blocker for L1/L2: if a demo timeline is tight, L1 (the felt "a port streams, many watch") can be taken
on the existing `udid` with L0-consolidate running alongside. The plan's earlier "everything hangs off
L0" overstated it; identity is the real shared dependency. Relatedly, `Principal.portId` (the caller's
self-address) is a bare id while `PortRef` is the target address — L1/L2 will want one address notion, so
consider `Principal` vending its own `PortAddress` when L1 lands.

### Phase L1 — unified Subscribe → Notify (keystone #3) — detailed (2026-07-23)

**STATUS: SHIPPED (2026-07-23), verified live.** `NotifyBus` (in-memory 1:N, `NotifyBusTests` 4 green),
`port.subscribe` (a `BridgeStreamMethod`; end-to-end `PortSubscribeTests` green: subscribe → publish →
yield → cancel unsubscribes), and two producer taps: `port.push` ("push") and the terminal `onFlush`
("terminal.output", threaded through `GhosttyTerminalController` — **ships backlog 3.4**, non-hooks
tools only). **All four producer taps in:** `port.push` ("push"), terminal `onFlush`
("terminal.output"), web `portConsole` ("console" — also the console-as-Notify roadmap item), and
`PortBridge.pushEvent` (browser `load`/`redirect`/`error` + filedrop/presentation). So all three port
types stream. **Per-surface delivery shipped:** `port42.port.subscribe(id, onEvent)` in the port JS
bridge (`PortBridge.swift`) predicts the callId, registers a `_tokenCallback` that parses each
`{topic, kind, payload}` envelope, and delivers it to `onEvent`; the returned promise carries a
`.cancel()` that unsubscribes. Same token-callback machinery as `ai.complete`.

**Live-verified (2026-07-23):** two separate web ports in Port42Dev. Port A's own page script called
`port42.port.subscribe(B, e => …)`; three `port.push` calls to B were received by A in order with
correct parsed payloads (`{seq:1}`, `{seq:2}`, `{seq:3}`), topic `port:<B>`, kind `push`. Also
verified driving `subscribe` through `port.exec` (subscribe then `port.push`, envelope arrives) —
`exec` is a valid subscriber surface too. **L1 done.**

**One real constraint — do not `return` a subscribe stream from `port.exec`.** `callAsyncJavaScript`
auto-awaits the returned value; the subscribe promise resolves only on cancel, so `return
port42.port.subscribe(...)` would hang the exec task forever. **Enforced (2026-07-23):**
`PortExecJS.run` now bounds every exec body with a timeout (`PortExecJS.defaultTimeoutSeconds`, 30s)
and throws `PortExecError.timedOut` with guidance pointing at the long-lived-promise cause, so a bad
return fails fast and frees the task instead of leaking it. Correct usage: start the stream, keep the
handle in a variable, return a plain value — `var s = port42.port.subscribe(id, fn); return "ok";`.
The carveout JS comment states the rule at the call site.

**`port.exec` contract footgun (not a bus limitation):** `PortExecJS.wrapBody` treats a bare
expression as `return (<expr>)`. A multi-statement one-liner with no explicit `return` and no
newline — e.g. `foo(); 42` — becomes `return (foo(); 42)`, a **syntax error** reported as the opaque
"A JavaScript exception occurred". This has nothing to do with the bridge or promises (`1+1; 42`
fails identically). Any multi-statement `exec` body must use an explicit `return` or newlines.
`PortExecJSTests` pins this shape (and the timeout message). Candidate hardening: have `wrapBody`
split on `;`/newlines and only wrap the final segment, or detect multi-statement input and require the
caller's `return`.

A port is an actor that emits a stream; L1 makes that stream subscribable by many, over one path.

**NotifyBus (in-memory, 1:N).** On `AppState`: `notifySubscribers: [String: [Int: (String) -> Void]]`
(topic → subscriber id → deliver). Topic = `port:<portId>` (the existing `bus.*` convention).
- `publishNotify(topic:, kind:, payload:)` — encode `{topic, kind, payload}` as one JSON string and
  deliver to every subscriber of the topic. No subscribers → cheap no-op (the common case).
- `subscribeNotify(topic:, deliver:) -> Int` and `unsubscribeNotify(id:, topic:)`.

**The Notify envelope.** `{ "topic": <string>, "kind": <string>, "payload": <json> }` — one shape for
every port type. It rides the existing `String` `yield` of `BridgeStreamMethod` (yield the JSON string),
so the stream contract is unchanged; each adapter delivers an envelope to its surface (port JS → an
event callback, gateway → a chunk, tool-use → collect).

**`port.subscribe` (a `BridgeStreamMethod`).** Resolves the target via `resolvePortRef`, subscribes to
`port:<udid>` with `deliver = yield`, then awaits cancellation (mirrors `ai.complete`'s continuation +
`withTaskCancellationHandler`); on cancel/close it unsubscribes and returns. So render / an agent /
persist each open a `port.subscribe` and receive the SAME Notify stream — one publish, many subscribers.

**Three publish attach points.**
- **Terminal (first slice — also cashes out backlog 3.4):** `GhosttyTerminalController.swift:129` —
  replace the `onFlush { _ in }` no-op with `publishNotify(topic: "port:<id>", kind: "terminal.output",
  payload: <clean line batch>)`, behind the existing `hooksCapable` guard (no alt-screen probe; the
  documented limit for ad-hoc TUIs).
- **Web (follow-up):** tap the native receipt of the port's `pushEvent` / height / console and republish
  to `port:<id>`.
- **Browser (follow-up):** route `browser.load/redirect/error` to `port:<id>` (pairs with the
  console-as-Notify roadmap item).

**Sequencing.** (1) NotifyBus + `port.subscribe` + the terminal tap — proves the 1:N bus end to end and
ships terminal output streaming. (2) Web attach point. (3) Browser attach point + console-as-Notify.

**Test gate.** Unit: `publishNotify` → N subscribers each receive the envelope; unsubscribe stops
delivery; publish with zero subscribers is a no-op. Live in Port42Dev: `port.subscribe` a terminal, run
a command, receive `terminal.output` envelopes; two concurrent subscribers both receive.

### Phase L1 follow-on — `port42.publish`: a port emits its own state (consumer-symmetry fix)

**Why (proven live 2026-07-23).** Open Synth is a port built to be driven by peers: it accepts a defined
`port.push` input contract (cells, op, lane register) and anyone pushing plays the canvas. Its input
side was already a proper interface. Its output side was not. The only way to read the synth's current
state was `port.exec(id, 'return OPENSYNTH.getState()')` — an agent reaching into the port's JS to pull
state, a path no human render and no remote peer has. That is the one place an AI consumer does not use
a port the way every other consumer does (GM caught it).

**Live proof of the target model (Port42Dev, no rebuild).** A heartbeat emitter was injected into Open
Synth that publishes `getState()` on its own topic every 2.5s (bootstrap via `port.push(self, {kind:
'state', state})`, since the push tap already publishes on the port's topic). A separate SYNTH MONITOR
port then read the synth's full live state through `port42.port.subscribe` alone — the five existing
lanes, params, and live drives — with zero `exec` on the synth. Claude then joined as a peer: registered
a lane and drove cells entirely through `port.push`, and the monitor reflected the new `claude` lane off
the bus. State flowed synth → NotifyBus → subscribe → consumer; input flowed through the push contract.
The `exec(getState)` asymmetry was closed in the running instance.

**The primitive to ship.** `port42.publish(kind, payload)` — a port emits its OWN application state on
its own Notify topic, a first-class signal distinct from `port.push` (which is input INTO a port).
- **JS surface:** a carveout in the `port42` bridge (`PortBridge.swift`): `port42.publish(kind, payload)`.
- **Native:** publishes `{topic: "port:<self-messageId>", kind, payload}` on `NotifyBus`, the topic being
  the CALLING port's own id (the `PortBridge`'s `messageId`, the same source `pushEvent` already uses).
  No target argument — a port can only publish as itself.
- **Retires the workaround:** replaces the push-to-self heartbeat and, with it, the `exec(getState)`
  hydration path. A port publishes its state; consumers subscribe. Same contract for human render, agent,
  and remote peer.
- **Fifth producer tap** alongside push / terminal / console / browser, and the first one owned by the
  port's own application code rather than a native surface event.

**Sequencing.** An L1 follow-on; needs an app build (touches `PortBridge.swift`), so it lands in a build
cycle, before or alongside L2. Bake the emitter into Open Synth's source at the same time and retire the
injected bootstrap.

### Phase L2 REVISED — state tokens for correctness, the lease for presence (GM, 2026-07-26)

**The built L2 conflated two problems.** Stale writes are a CORRECTNESS problem; who is driving is a
COORDINATION problem. One time-based lock was doing both, badly — which is why the TTL had no
principled value, and why justifying it reached for LLM latency on a bus whose writers are scripts,
ports and peers as much as companions.

#### The rule

**Every port exposes a monotonic state token. A write carries the token it was composed against; if
the port has moved, the write is rejected and the error carries the current token.** No holder, no
timer. Correct whether the writer thought for 3ms or 3 hours, and identical locally and across
instances — which a lock can never be, because clocks do not agree between peers.

A rejected write is self-correcting: the conflict response carries `current`, so a naive caller does
push → conflict → push-with-token → success. One extra round trip, once.

#### The token follows the WRITE SHAPE, not the port type

| Shape | Port type | Token | Why |
|---|---|---|---|
| **Mutate** | web | the existing version number | `update`/`patch` replace content, so writers genuinely clobber. CAS essential. |
| **Position-sensitive append** | terminal | **input sequence** — every byte delivered from ANY source (human keystrokes, `inject`, `push`) | Input only appends, but WHERE matters: text landing mid-line corrupts it, and a stray newline executes it. |
| **Plain append** | chat | message count (context only) | Messages never clobber: both exist, order is the only question, and that is not corruption. **Chat needs no CAS.** |
| **External** | browser | committed-navigation counter | We do not own the page. Staleness means "the page you read is gone" — weaker, and honestly so. |

**Why input sequence and not output sequence for a PTY:** a redrawing TUI (claude's own UI, htop)
emits constantly, so an output token moves every frame and every write fails — protection too noisy
to use. Input sequence means exactly "has anyone typed into this since I looked", and redraw does
not perturb it. It also catches the dangerous case precisely: your keystrokes bump the sequence, so
a companion's write composed before you started typing is stale, without blocking it for 30 seconds
because you once touched the port.

**Presentation is not a type.** Inline/tiled/parked/background are positions of the same port and do
not change write semantics, so they do not touch the token. **A new port type must declare its
shape** — same discipline as `writesTarget`, so a future type cannot arrive with no answer to "what
does staleness mean here?".

#### What happens to the lease

**It stays, demoted to presence.** It records and broadcasts and displays who is driving; it stops
refusing writes. That removes the TTL-as-correctness problem entirely (the remaining TTL is display
freshness — when the chip should fade). Presence is worth keeping on its own terms: it is what makes
a companion's work visible, and it is what a remote peer will want to see in slice-02.

**The one place a token is REQUIRED, not optional:** streams. A token-less write to a terminal is
unguarded against the half-typed-line splice, and that case can execute something you did not type.
Everywhere else a missing token means last-write-wins, which is today's behaviour and breaks nothing.

#### What of the built work survives

Almost all of it. L2.a's registry, L2.c's broadcast, L2.d/d.2's claim paths and L2.e's header all
serve presence unchanged. L2.b changes from `throw` to `record`. The new work is the token layer
(L2.f) and, for terminals, the input counter — which the `onHumanInput` hook from L2.d.2 already
half-provides.

**Also still owed from the L2.d.2 finding:** the web claim must move to the native event monitor.
`isTrusted` stops accidental synthesis but a port can shadow it on an event it dispatches, so it is
a speed bump, not a boundary. Presence being advisory lowers the stakes of that hole — a forged
claim then misleads a human rather than blocking a companion — but it does not close it.

### Phase L2 — right-of-way lease (keystone #2) — detailed (2026-07-24, SUPERSEDED ABOVE)

**STATUS: BUILT END TO END (L2.a–L2.e, 2026-07-24/25), full suite 1065 green. Only LIVE
VERIFICATION is left — every step's automated gate passes; none of it has been seen running.**

**Keystone #2 is closed in code.** Two local drivers cannot double-write: a companion's write to a
port the human is driving is refused by name, focus and native interaction both claim, the holder
rides the port's own Notify topic, and the tile header shows it when someone else is driving.
What remains is L2's manual column (a live human-vs-companion contention run) and, when it lands,
the same mechanism over the wire in slice-02.

| Step | State |
|---|---|
| L2.a pure lease | SHIPPED — `PortLease.swift`, `PortLeaseTests` (11) |
| L2.b dispatch gate | SHIPPED — `BridgeMethod.writesTarget` + `claimWrite`, `PortLeaseGateTests` |
| L2.c holder broadcast | SHIPPED — `kind:"holder"` on `port:<id>`, change-only |
| L2.d human principal | SHIPPED — `Principal.Kind.human`, zoom-to-focus claims |
| **L2.d.2 interaction claims** | SHIPPED — typing/clicking in a surface claims it (`ClaimThrottle`) |
| L2.e holder in the header | SHIPPED — subscribes to `holder` envelopes; shows only when it is SOMEONE ELSE |

#### L2.d.2 — interaction claims the pen (added 2026-07-25, GM)

§L2.4's honest limit is now closed on the human's side. The signal is not *keystrokes* but **input
reaching the surface**: keydown and pointerdown, both intent to ACT. Hover does not count (a mouse
crossing the desktop is not driving) and **scroll deliberately does not** — scrolling is READING,
and claiming on it would block a companion mid-write exactly while the user watches it work.

Reported by the surfaces, since none of it reaches the bridge: `GhosttyInputView.onHumanInput` for
terminals, and an injected keydown/pointerdown listener reporting through a `portInput` handler for
web ports (the same shape as console and height; the handler holds a closure, not the manager, so it
cannot become a retain path). Throttled ~5s per port by `ClaimThrottle`, because typing fires per
keystroke against a 30s TTL.

**Still open, deliberately:** the *uninvented gesture* GM raised — asking for a pen someone else
holds. That is a REQUEST (the knock in §L2.3), a different need from "who is driving now", which is
an observable fact. Kept separate rather than collapsed into one motion.

#### What building it taught us (integrate before L2.e)

1. **`focusKeyboard` was the wrong seam, exactly as the review suspected.** Keyboard focus also
   follows the MOUSE (hover raises a tile and hands it the keyboard), so acquiring there would let a
   mouse dragged across the desktop seize the pen from every companion it passed over, for a full
   TTL each. The claim hangs off the ZOOM transition instead: zooming into a unit is deliberate,
   hovering is not.
2. **Implicit acquisition is validated, not just argued.** The full suite went green with the gate
   live and **no existing test or flow needed a change** — the acceptance clause held on the first
   run, which is the evidence that a write-to-acquire model does not disturb single-driver use.
3. **`check` denies, never evicts — and that turned out to be the important property.** It is what
   lets the human's focus-claim be safe: focusing a port a companion is mid-write on leaves the
   companion driving. A "focus wins" rule would have made every glance a seizure.
4. **A write verb that no-ops on an unknown id exists** (`port.rename` resolves and shrugs), so
   "unresolvable targets are not gated" had to be asserted as *never `port_busy`* rather than as
   *throws notFound*. Worth knowing before relying on any write verb's error for control flow.
5. **L2.e cannot read the lease directly.** `LeaseRegistry` is a plain value on `AppState`, not
   `@Published`, so a header observing it would not update. It should SUBSCRIBE to the `holder`
   envelopes on `port:<id>` — which is the protocol-correct path anyway, and makes the header just
   another subscriber rather than a special case. Doing that first is what stops L2.e from becoming
   a reason to make lease state observable.

**Not built (deferred from §L2.3):** the explicit `port.lease({id, action:"take"|"release"})` verbs.
The implicit path carries the whole model today; the knock is only needed once a human wants to ask
for a pen a companion is holding, which is L2.e's UI question.

**Do.** A per-port holder ("who holds the pen") keyed on `Principal.id`, gating the Update verbs at
the dispatch seam. The holder is broadcast on the port's own Notify topic, so every surface already
watching the port learns who is driving with no side channel. Explicit handoff, pessimistic — no
CRDT, no OT (matching slice-02's deliberate choice, and for the reason in §L2.6).

#### L2.1 Where the gate lives — declare it, don't scatter it

`runBridgeMethod` (`BridgeDispatcher.swift:25`) is the ONE choke point every caller passes through,
and it already gates `method.permission` there. The lease is the same shape of decision, so it goes
in the same place and is DECLARED THE SAME WAY: `BridgeMethod` gains

```swift
/// The paramName carrying the port this method WRITES to. nil = a read (never gated).
let writesTarget: String?      // e.g. "id" for push/exec/patch/update
```

Registry-declared, like `permission`, so a new write verb cannot silently escape the gate — the
existing `BridgeParamConsistencyTests` source-scan can assert the write verbs all declare it.

**Gated (Update):** `port.push`, `port.exec`, `port.patch`, `port.update`, `port.rename`,
`port.move`, `port.restore`, `port.manage` (destructive actions).
**Never gated (Query/Temporal):** `port.getHtml`, `port.history`, `port.info`, `port.position`,
`port.subscribe`, `ports.list`. Reading is not driving.

#### L2.2 The lease itself — pure, headless, time-injected

New `Sources/Port42Lib/Services/PortLease.swift`, modelled on the pure-state discipline the shell
uses (`ShellState`'s statics, `PortPlacement`): no AppState, no clock of its own.

```swift
struct Lease: Equatable { let holder: String; let holderName: String; let expires: Date }
struct LeaseRegistry {                      // value type, one per app
    mutating func check(port: String, principal: String, now: Date) -> LeaseDecision
    mutating func release(port: String, principal: String)
    mutating func handoff(port: String, from: String, to: String, now: Date)
}
enum LeaseDecision { case granted(Lease), refreshed(Lease), denied(byName: String, until: Date) }
```

`now` is passed in, never read inside: expiry is the one behaviour that is miserable to test against
a real clock, and it is the behaviour most likely to be wrong.

#### L2.3 Acquisition — implicit, because nothing may break today

A write against a FREE port acquires the lease for its principal. A write by the CURRENT holder
refreshes the TTL. A write against a port held by someone else is rejected with a `BridgeError`
naming the holder. TTL ~30s, refreshed by use.

This ordering matters: implicit acquisition means every single-driver flow that works today keeps
working unchanged, and the lease only becomes visible at the moment there IS contention — which is
exactly when a user wants to know about it. A design that required an explicit `take` first would
break every existing port, script and companion on day one.

Explicit verbs come with it for the deliberate cases: `port.lease({id, action:"take"|"release"})`,
where `take` on a held port is a REQUEST (a knock the holder can answer), not a seizure.

#### L2.4 The honest limit: native input is not a bridge write

A human typing into a Ghostty terminal port, or clicking inside a webview, does **not** pass through
`runBridgeMethod`. Keystrokes go straight to the surface. So the lease cannot see local human input,
and a naive implementation would let a companion hold the pen while the human types underneath it —
the exact double-write the keystone exists to prevent, invisible to the mechanism meant to catch it.

**Resolution: focus acquires the lease for the human.** `portWindows.focusKeyboard(on:)` already
exists as the single seam for "the keyboard now belongs to this unit" (⌘\` cycling, ⌘↓, hover, tile
click all funnel through it). Hooking lease acquisition there unifies the informal right-of-way the
shell already has with the formal one the protocol needs, instead of running two ideas of "who is
driving" side by side. It also makes the felt behaviour correct: click a port, you hold the pen, and
a companion's write is rejected while you are in it.

#### L2.5 Broadcast — reuse the port's own topic

On every holder CHANGE (not on refresh — that would spam):
`notifyBus.publish(topic: "port:<id>", kind: "holder", payload: {holder, holderName, until})`.
Anything already subscribed to the port sees it: the tile header, another instance's mirror, an
agent deciding whether to wait. This is why L1 had to land first.

#### L2.6 Why reject rather than queue (GM asked, 2026-07-24)

A queued write is a STALE write: composed against the port as it was, applied against a port that
moved, with the author gone. That is the same failure that ruled out optimistic merge. A rejection
bounces back while the author still holds the context that produced it. It is worse with an agent in
the mix, which is the real case: a companion writes in bulk, fills the queue, and the flush lands on
the human as a jump nobody authored. And a queue is a scheduler — ordering policy, persistence,
per-waiter TTL, dead-waiter handling, progress/cancel UI. The lease is one fact: who holds it.

A queue is a POLICY OVER the lease and can be added later without touching the write path; it is not
a primitive that can be retrofitted underneath one. The thing usually wanted is not a queue anyway,
it is a knock (`take` → holder answers → handoff), which L2.3 provides.

#### L2.7 Cross-instance forward-compat — SETTLED (`decision-identity-model.md`, 2026-07-24)

The blocker is answered. Identity is three axes, not one: **person** (the `AppUser` P256 key),
**instance** (the libp2p PeerID, a per-device key signed by the person key), and **actor** (the
`Principal` — a human, a companion, a port). The lease holds an ACTOR.

**What that fixes here:** `Lease.holder` is a **qualified principal**, `<peerID>/<principalId>`,
with the local peer as the empty prefix — the same shape as slice-02's port address
(`port42://<peerID>/space/<id>/<portId>`). So the local lease is the DEGENERATE FORM of the remote
lease, not a different object, and cross-instance stays the prefix the plan claims it is.

Write holder strings peer-qualified from L2.a. It is one line now and a migration later.

#### L2.8 Code review of the seams (read 2026-07-24, before writing any L2 code)

**Confirmed — the design holds:**
- **Every write verb takes `id` as its first param.** `push(id,data)`, `exec(id,js)`,
  `patch(id,search,replace)`, `update(id,html)`, `rename(id,title)`, `move(id,x,y)`,
  `restore(id,version)`, `manage(id,action)`. So `writesTarget` is uniformly `"id"` and the
  declaration is mechanical, not a per-method judgement.
- **`runBridgeMethod` is genuinely the only choke point** (`BridgeDispatcher.swift:25`) and already
  does exactly this shape of gate for `permission` (`:34-43`). The lease check slots in beside it.
- **Remote callers already produce principals.** `ToolExecutor.swift:148/164` builds
  `Principal(kind: .peer)` for gateway/synced callers, so the holder being an actor rather than a
  connection is already true on the existing transport.

**Two findings that CHANGE the plan:**

1. **There is no human principal.** `Principal.Kind` is `port | companion | peer` — the local human
   typing has no principal at all, because until now nothing needed one (permissions are asked OF
   the human, not authorized FOR them). L2.d cannot "acquire for the human principal" until one
   exists. **Decision needed:** add `case human` with `id = AppUser.id`. It is small, but it is a
   change to the identity type the whole authorization layer keys on, so it is called out rather
   than slipped in. This is also the first place `AppUser`'s identity is used for anything
   (`decision-identity-model.md` predicted it would need to become real).

2. **A companion-made port authorizes AS its creator.** `PortBridge.portPrincipal.id` is
   `createdBy ?? messageId` (`PortBridge.swift:117-126`) — deliberate (P-260), and documented: `id`
   is shared across every port that creator made, while `portId` names the specific port and is
   excluded from `==` so it never splits a grant bucket. **Consequence for the lease:** keyed on
   `id`, two ports made by the same companion are the SAME holder and can never contend with each
   other. **That is the right default** (the actor is the companion, not each surface it spawned)
   and it keeps the lease consistent with grants, but it must be a stated choice: keying on
   `portId ?? id` instead would make each port its own driver and immediately diverge from how every
   permission in the app is bucketed.

**Reviewed:** the write-verb registry declarations and their params; `runBridgeMethod`'s gate site;
`Principal` and its three kinds; `PortBridge.portPrincipal`; `ToolExecutor`'s principal
construction; `NotifyBus.publish` and the four existing producer taps; `focusKeyboard(on:)`
(`PortWindowManager.swift:147` — the single seam, async-dispatched, with a special case for the
SwiftUI chat unit).

**NOT reviewed (do before the step that touches each):** whether any UI-driven write reaches
`runBridgeMethod` at all or bypasses it (L2.d depends on the answer); the terminal write path
(`port.push` → `controller.sendRaw`) and whether a lease denial there needs a visible surface;
browser ports; and parked/inline/background presentations, where "who is driving" may be meaningless
and the gate should probably no-op.

#### Build order + the gate at each step

Every step is shippable alone and green before the next starts.

| Step | Build | Automated gate | Manual gate (Dev3) |
|---|---|---|---|
| **L2.a** | `PortLease.swift`: `Lease`, `LeaseRegistry`, `LeaseDecision`. Pure, time-injected, no app changes. | `swift test --filter PortLease` — acquire when free; deny when held by another; the holder's write refreshes; expiry frees (inject `now`); explicit release; handoff moves the holder; release by a non-holder is a no-op. | none (headless) |
| **L2.b** | `writesTarget` on `BridgeMethod`, the eight declarations, the dispatcher check. | The pure tests still green + a dispatcher test: A holds, B's `push` throws a `BridgeError` naming A; A's own `push` succeeds; a READ by B succeeds (reads are never gated). Extend the `BridgeParamConsistencyTests` source-scan so a new write verb without `writesTarget` fails the suite. | Existing single-driver flows unchanged: a companion still makes and drives a port end to end. **This is the regression that matters** — if anything needed changing, implicit acquisition is wrong. |
| **L2.c** | Notify broadcast on holder CHANGE (not refresh). | A holder change publishes exactly one `{kind:"holder"}` envelope on `port:<id>`; a refresh publishes none. | Subscribe a second port to the first and watch the holder envelope arrive. |
| **L2.d** | `Principal.Kind.human` + `focusKeyboard` acquires for it. | Focusing a unit yields a human-held lease for that port; focusing away does not steal a lease held by someone else. | **The one that makes it real:** focus a port, have a companion write to it, the write is rejected and the human keeps driving. Then hand off and the companion proceeds. |
| **L2.e** | Holder in the tile header (a name — "gordon holds this" — not a lock icon). | none (pure visual) | Two drivers, the header names the right one, and it clears when the lease expires. |

**Done when:** two local drivers never double-write, both see the holder, and **no existing
single-driver flow needed a change** — the last clause is the real acceptance test of the implicit
acquisition design.

## 7. Local acceptance (Port42Dev :4243)

Address a real running port by `port42://space/<s>/<p>`; send it `getHtml`/`patch` by that address and it
executes through the existing bridge; subscribe and receive Notify deltas as it changes; do it for a web,
a terminal, and a browser port; (L2) two local drivers contend and neither double-writes. All inside one
instance.

## 8. Staging to cross-instance (what changes, what does not)

When the local slice is green, cross-instance is additive:
- **Address:** prefix `port42://<peerID>/space/<s>/<p>`. The resolver gains a "not-local → route to peer"
  branch; local resolution is unchanged.
- **Transport:** swap the local Notify fan-out for a wire (the current WebSocket gateway relay first, as a
  low-lift proof on substrate we already run; libp2p/gossipsub later to chase the sovereignty
  hole-punch number, per slice-02). The contract — address, Query/Update, Subscribe/Notify, lease — does
  not change.
- **Lease:** the per-port holder becomes the cross-wire ownership lease (slice-02's per-port right-of-way).

This is why local-first is the correct sequencing: it retires the contract risk (does the actor model
generalize across port types?) with zero transport risk, and leaves the transport bet (P2P sovereignty
vs. relay) to be measured on its own, later.

## 9. Doc debt flagged (not fixed here)

`CLAUDE.md` and `docs/bridge-architecture-and-mcp.md` still describe `browser_*` + `rest_call` as
hand-written holdouts in a `ToolDefinitions.swift`. That file is gone; browser methods are in the unified
registry (`BridgeMethods.swift:403-485`), schemas generate from the registry
(`AppState.generatedToolDefinitions()` `AppState.swift:936`). Correct these when convenient.
