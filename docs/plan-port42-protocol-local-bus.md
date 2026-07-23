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
now resolve by **title/name**, not just UDID (parity preserved for UDIDs). Commits `0a2fc9d`, `e40a0ae`,
`7833704`. **Small follow-ups:** a source-scan invariant gate; route `port.rename`; delete the now-unused
`PortPushRoute`. **Next keystone: L1 (unified Subscribe→Notify).**

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

### Phase L1 — unified Subscribe → Notify (keystone #3)

**Do.** Add the typed Notify envelope `{ topic, kind, payload }` and an in-memory 1:N subscriber registry
keyed on the `port:{portId}` topic convention. Generalize the `BridgeStreamMethod` `yield` to carry the
envelope. Wire the three publish attach points (§4): web native publish alongside `_emit`; terminal
`onFlush` no-op → publish (behind the `hooksCapable` guard); browser `load/redirect/error` → publish.
Expose `subscribe(port42://…)` as a stream method so render, an agent-observer, and persist are all
subscribers to one stream.

**Test gate.** One publish, N subscribers each receive it (the fan-out). Each port type's attach point
produces a well-formed envelope (web dict, terminal line-batch, browser nav event). Terminal publish is
suppressed for a `hooksCapable` companion. Unsubscribe stops delivery; a torn-down port stops publishing
(ties to the teardown discipline, backlog 0.5). Command: `swift test --filter Notify` (+ a live
multi-subscriber check in Port42Dev).
**Done when:** a real running port of each type is subscribable, one publish reaches many local
subscribers, and the envelope shape is uniform.

### Phase L2 — right-of-way lease (keystone #2, fast-follow)

**Do.** A per-port holder ("who holds the pen") keyed on `Principal.id`, gating the Update verbs
(`push`/`exec`/`patch`/`update`) at the resolver seam. Human UI and a companion are two local drivers;
the lease arbitrates; the holder is broadcast on the port's Notify topic so both surfaces show it. Local
focus generalizes into the holder. Explicit handoff, pessimistic (no CRDT/OT) — matching slice-02's
deliberate choice.

**Test gate.** Two local principals contend; only the holder's Update applies; a non-holder Update is
rejected; handoff changes the holder and emits a Notify. Command: `swift test --filter Lease` (+ live
human-vs-companion contention on one port).
**Done when:** two local drivers never double-write and both see the holder.

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
