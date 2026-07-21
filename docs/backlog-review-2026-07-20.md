# Backlog review + ranked sequence (2026-07-20)

**STATUS 2026-07-21 — Tier 0 complete; Tier 1.1 complete (verified live).** All of Tier 0 shipped: 0.1
peek→tile, 0.2 gateway-outlives-app, 0.3 parked-AI suspend (was already done), 0.4 bridge-rejects + CSP
+ truncation, 0.5 the exhaustive mic/speech teardown (both root causes, verified live — the retain
cycle AND the owner-resolution-on-authz-id defect; spec `docs/plan-exhaustive-port-teardown.md`),
0.6 recency-sorted ⌘K (MRU + persisted). **Tier 1.1 (ports know their presentation state) shipped**
across 5 commits (spec `docs/plan-port-presentation-state.md`): the pure model + `presentation()`
getter + the `presentation` event/DOM alias, the debounced emit funnel, the `isSuspended`-re-keyed-to-
`!visible` defense (option A: gates new model calls, does not cancel in-flight), the port-authoring
discipline, and a live pass in Port42Dev (rAF freezes when hidden, one event per transition, no storm).
**Tier 1.2 (webview eviction) is DEFERRED (GM, 2026-07-21):** not a problem at current port counts, so
it waits until live-webview count / idle CPU actually bites. It is not abandoned: the full plan and all
four signed-off decisions (flat ~50-webview cap, lazy create-on-mount, web/browser-only, remount
self-heal) are captured in `docs/plan-webview-eviction.md`, so it is a clean pickup when the accumulation
returns. **Now building: 3.6 (drag-reorder spaces in the galaxy).**

## Freshness sweep (2026-07-21) — corrected statuses

The 07-20 list was substantially stale. A six-cluster audit verified every open item against code + git:

- **RESOLVED (were listed open):** 2.1 permission overlay (`00053d7`), 1.3 ports-scoped-to-space,
  3.2 ports.list JSON parity (`7167377`), 3.5 llms.txt publish (`24b5c79`), 3.7 port.position /
  screen.displays, and the whole **Principal / tool-use unification** (shipped v0.5.47) — which unblocks
  the Tier-4 cluster.
- **PARTIAL:** 1.4 (unread count already cached; the *waiting-for-input* signal remains), 3.1 (space
  names normalize to dashes; *companion* names still accept internal whitespace), Tier-4 AI-edit-a-port
  (companions.invoke base landed, chrome affordance open), sync CLI invoke (LLM sync done, command-
  companion over turnComplete remains), port parking / never-close (version store done, UI missing).
- **DROPPED:** 2.6 mention routing — GM: not a bug. 1.5 dock/gallery of ports — GM: not needed, removed.
- **Genuinely OPEN:** 2.2 blanking (the deferred 1.2 lazy-load would fix it), 2.3 freeze watchdog,
  2.4 screen.stream pointer, 2.5 fossil member row + name collisions, 2.7 stream-continuation dangle,
  3.3 port_versions retention, 3.4 terminal streaming (onFlush), 3.6 drag-reorder spaces (IN PROGRESS),
  Tier-4 port URL / teleport.

**Recover a port from history (refined, GM 2026-07-21):** per-space, keyword-**searchable LIST** (not a
gallery) of that space's port history. Substrate exists (`port_versions` keeps everything;
`port.history` / `port.restore` work); missing = the searchable-list UI + making close archive-not-
destroy. Space-specific, so **not the galaxy** — placement candidates: the View Menu, or a dropdown on
the space pill at the top of the space. Supersedes the old 1.5 framing.

Source: `docs/summer2026-todo.md`, every OPEN item. Ranked against the north star: **improve the
experience and remove friction.** Not raw feature value.

Sizing is **relative complexity only** (XS < S < M < L < XL), not time. XS = localized, one seam.
XL = north star / new subsystem. Impact is friction-removed for the user (or for us building).

Items already shipped (per the handoff + FIXED/RESOLVED markers) are excluded: the reply-post bug,
per-space working directory + picker, auto-register CLI companions, per-(space,companion) UUIDv5
session-id, `companions.list` scoping, `port.exec` async, `ports.list` space scoping, background-port
restart, the 6+1 test failures. Where I'm unsure an item is fully closed I say so.

---

## The two through-lines GM's own notes keep drawing

Before the ranking: two themes recur across a dozen separate bug write-ups, and they are the
highest-leverage work because fixing the *class* stops the next instance costing a debugging round.

1. **"Nothing releases what it acquired."** Mic/speech leak on close, gateway outlives the app,
   parked ports keep billing the model, webview registry never evicts, `port_versions` never evicts.
   Same disease: teardown that only runs on the happy path is not teardown.

2. **"The platform hides its failures."** JS bridge never rejects, CSP blocks are silent, permission
   prompt renders off-screen and hangs, `terminal.exec` truncation undocumented, the frame lies.
   Same disease: a correct refusal with no legible signal reads as a broken product.

The Tier 0 list below is mostly these two classes, because they are cheap and each one has already
cost real time or money.

---

## Tier 0 — cheap, high-impact friction removers (do first)

| # | Item | Size | Why it ranks here |
|---|------|------|-------------------|
| 0.1 | **New port in the current space peeks instead of tiling** (the flagged item) | XS | Localized to `handlePortCreated`. Reverses a deliberate "attention-beat" choice GM now rejects. Pure friction removal on the core loop. Verdict + plan below. |
| 0.2 | **Gateway outlives the app** | XS–S | Pipe-EOF in the child (~5 lines Go): the gateway exits when the app dies by any means, including SIGKILL. Kills the "every `/call` hangs forever after a crash" trap that has burned real debugging time. Add reap-on-launch + fail-fast on no-app. |
| 0.3 | **Parked/backgrounded ports keep running their AI** | S–M | Costs real subscription money, twice over. Park = suspend: deliver a presentation event AND have the shell halt looping `ai.complete` for invisible ports. Depends on / motivates 0.4-pair. |
| 0.4 | **JS bridge never rejects + surface CSP violations + document `terminal.exec` truncation** | S | The legibility class. `call()` should reject on `{error}` so every port's `try/catch` stops being decoration; `ai.complete`'s special-case folds into the base. Listen for `securitypolicyviolation`. Document the 50KB cap. Three cheap fixes, one theme. |
| 0.5 | **Closing a port leaks its mic / speech recognition forever** | S–M | Privacy + a permanently-burned core. `close()` must release *everything* the port acquired (audio/camera/screen streams), tracked per-`PortBridge`. Also exposes app-side stops so a resource is never stoppable only from the dead port's JS. |
| 0.6 | **Recency-sorted ⌘K (empty query = MRU)** | XS–S | Daily switching friction. The recency signal already exists (`lastReadDates`); persist it (UserDefaults or a `lastVisitedAt` column) and sort the empty-query branch. One method touched. |

Rationale for the tier: 0.2 and 0.4 and 0.5 stop *future* debugging rounds, not just the current
bug. 0.3 stops a live dollar leak. 0.1 and 0.6 are the two cheapest wins on the everyday loop.

---

## Tier 1 — the "desktop doesn't melt, and a space is a real place" spine

These share a theme and reinforce each other. Sequence after Tier 0 because two of them (eviction,
presentation-state) are the load-bearing prerequisites the chrome-is-ports north star and every
always-on port depend on.

| # | Item | Size | Why |
|---|------|------|-----|
| 1.1 | **Ports must know their presentation state** | M | The enabling primitive for idle. `pushEvent("port42:presentation", …)` on every state change + shell-side throttle of invisible ports. The shell already knows the state; it just never tells the port. Unblocks 0.3's cooperative half and caps how many ports a person can have. |
| 1.2 | **Webview registry never evicts** — DEFERRED (GM 2026-07-21) | M | CPU scales with ports-ever-created (measured: 88 live WebContent procs at 101 ports, ~90% CPU idle). Keep the working set mounted, evict the rest, re-mount on return. **Deferred until it is a problem** (fine at current counts). Plan + signed-off decisions ready in `docs/plan-webview-eviction.md`; trigger to revisit = live-webview count or idle CPU actually bites. Pairs with 1.1: evict what isn't needed, idle what's kept. |
| 1.3 | **Ports scoped to space** | M | Keystone for the space-as-place story. Persist `spaceId` as the scoping key for what's shown; switch the visible set on space change; decide cross-space behavior. The dock view and richer rows both need this data model. |
| 1.4 | **Richer space rows / ambient activity** | M | "Where am I needed?" across spaces; `waiting-for-input` is the highest-value signal. Best impact-per-effort of the space-experience items per the 06-27 ranking. Must derive from cached/observed state, not per-render DB queries (the SidebarView render-storm pattern). |
| ~~1.5~~ | ~~A different dock / gallery view of ports~~ — REMOVED (GM: not needed) | — | Superseded by "recover a port from history" (a per-space searchable list), see the freshness-sweep note above. |

---

## Tier 2 — bugs that need diagnosis or a confirm-first pass

Higher uncertainty; each needs an RCA or a repro before it's a clean build. Ranked by impact.

| # | Item | Size | Note |
|---|------|------|------|
| 2.1 | ~~**Permission prompt lost when a port pops in + one guided permission flow**~~ — RESOLVED | M | **Already fixed (commit `00053d7`), verified by GM in daily use.** `PermissionCoordinator` + a single shell-level `ShellPermissionOverlay` (ShellView zIndex ~220, above every tile/overlay) replaced the per-caller render sites, so the card can no longer render inside a chat tile. Re-requestable: a deny resolves one call as false with no permanent grant=false cache, so the next call re-asks. Guided flow: `systemFollowUp` narrates the macOS dialog chain (mic → speech, etc.). The RCA of the original bug lives in `PermissionCoordinator.swift`. Item was stale on this list. |
| 2.2 | **Ports restore blank (the blanking bug)** | M | Root cause diagnosed: eager `loadHTMLString` on a detached webview during a stalled startup. Fix = load-on-attach + verify/self-heal via the nav delegate + a recovery command. Same disease as background-vanish (assume-success-never-verify). |
| 2.3 | **App froze mid-demo, every port grey** | ? | Undiagnosed, ship-blocking, no diagnostic captured. Do NOT build a fix; first ship a DEBUG watchdog that samples on a >2s main-thread stall so the next freeze names its blocker. Likely the permission hang (2.1) or accumulation (1.2) — so 2.1 + 1.2 may retire it. |
| 2.4 | **screen.stream glitches the pointer** | M | Undiagnosed after a full bisect; feature can't be called stable. Next diagnostic named in the doc: a handler that drops every frame (no processing) to isolate buffer-holding on the sample queue. |
| 2.5 | **Stale label-identity member row + qualified-name collisions** | S–M | A fossil `remote-http-cal` member row renders in every member list; `@echo` is ambiguous across an LLM and a CLI companion. One-time cleanup + a naming decision. Adjacent to the whitespace-in-names item. |
| ~~2.6~~ | ~~Auto-register companion: tighten mention routing~~ — NOT A BUG (GM 2026-07-21) | — | GM: the routing behavior is not a bug. Dropped. |
| 2.7 | **Stream continuation dangles on silent engine death** | S | Hardening residual from the cancel-hang RCA. Collector-level deinit guard / max-duration timeout so no engine misbehavior leaks a pending JS promise. |

---

## Tier 3 — DX / polish / small consistency

| # | Item | Size | Note |
|---|------|------|------|
| 3.1 | **Disallow whitespace in space + companion names** | S | Sharp silent-breakage papercut. Investigate what actually breaks first (token-vs-label confusion), then validate at the input boundary. |
| 3.2 | **`ports.list` JSON consistency + capabilities parity** | XS–S | `ports.list` returns a text blob; `terminal.list` returns JSON; a terminal port reports `[]` vs `["terminal"]` across the two. Align on JSON, one capabilities source. |
| 3.3 | **`port_versions` stamps every update (auto-saves, not checkpoints)** | S | Debounce same-caller rapid saves + a retention policy. Same never-evicts theme as 1.2. Investigate the chat port at 371 saves. |
| 3.4 | **Native terminal output-streaming bridge (`onFlush`)** | S–M | Mechanism ~90% present (`onFlush` is discarded today). `terminal_stream(id, on|off)` → batched clean-line posts; guard TUIs. Turns a build/tail into live space content. |
| 3.5 | **Publish the generated API reference as a static `llms.txt`** | S | Exporter builds the registry in memory, renders `generateAPIReference`, writes the file + a freshness-gate test (committed == generated). Publishable artifact like the DMG. |
| 3.6 | **Drag-reorder spaces in the galaxy** | S–M | Needs a persistent `sortIndex` (append migration) that then drives `⌘1…9`. Pairs with 0.6 as the two switching axes. |
| 3.7 | **`port.position` / `screen.displays` "Unknown tool"** | XS | Likely already resolved (the ports.list sweep verified these serve from the registry); confirm over the live gateway and either close or fix the reference. |
| 3.8 | **Resize cursor on tile edges / corners** | XS | Pointer stays the default arrow while dragging a tile's edge or corner to resize. Swap to the directional resize cursor (`NSCursor.resize*` / `⤢`) on hover + during a resize drag, per edge/corner, so the affordance reads. Cursor-only polish on the tile drag handles. |
| 3.9 | **Screen recording: continuous video + audio** | M | Today `screen.capture` = one PNG and `screen.stream` = pushed frames; add a `screen.record` (start/stop) that writes a continuous **video file with audio** (system audio and/or mic). ScreenCaptureKit path: `SCRecordingOutput` (macOS 15+) or an `AVAssetWriter` fed from the existing `SCStream` plus an audio tap. Shares the `SCStream` plumbing with `screen.stream`, so it also touches the 2.4 pointer-glitch surface. GM idea 2026-07-21. |

---

## Tier 4 — architectural collapses + north stars (sequence deliberately, not now)

These are large and several gate on one shared piece of work: **a principal in the protocol layer**
(who is calling, carried end to end, backed by the gateway's authenticated `peer.ID`). Storage
sharing, MCP-per-viewer, a port URL, teleport, and shared-port safety are all the same identity
question. Doing the principal work once unlocks the cluster; doing any one of them without it mints
another inconsistent calling path.

- **Principal / API-tool-use unification** (L) — the spine under the cluster below. Not a user
  feature; the thing that makes the cluster safe and non-duplicative.
- **Swim *is* a space** (L) — collapse the `swim-<id>` special-case; relationship memory becomes
  space-scoped. Steer current work toward space generality so the collapse is a deletion.
- **Companion-global epistemic memory** (M–L) — re-key creases/fold to `companionId`; migration
  merges per-space rows. A companion is one being across spaces. Note: tension with "swim is a
  space" (space-scoped) — settle the axis before either migration.
- **AI-edit a port from its chrome** (M) — the natural *first real slice* of the unification
  (`invokeCompanion` shared base). Good candidate to pull forward as the concrete driver.
- **Synchronous agentic-CLI invoke from ports** (M) — call/await for command companions; reuses the
  `turnComplete` signal already wired.
- **Chrome is ports too** (L, wedge = background-as-port v2 at M) — background-always-a-port removes
  the native/port fork. Load-bearing prereqs are 1.1 + 1.2 (an always-on port must not burn CPU).
- **Port parking: exact placement + never truly close** (M) — closing = archive, not destroy. The
  reopen surface is the **per-space searchable port-history LIST** (refined 2026-07-21, see the
  freshness-sweep note); the version store already keeps everything, only the list UI + close=archive
  are missing. Placement: View Menu or a space-pill dropdown, not the galaxy.
- **A port has a URL** / **port teleport** / **publish a port as a website** (M–L each) — all ride
  the principal work + the browser-as-third-caller shim. Route 1 (gateway reverse-proxy) is the
  low-lift proof.
- **MCP as a port capability (viewer's credentials)** (L) — per-(principal, server) grants; belongs
  in the Go gateway. Gates on principal.
- **Adopt agent-comms standards (ACP + friends)** (L) — map remote agents to `AgentConfig`, reuse
  routing/member rows.
- **Browser port type** (L) / **WebRTC in browser ports** (L) — largest additive builds.
- **Migrate injected context → installable skills** (M–L) — moves ~1100 lines of prompt context to
  on-demand skills that travel to any agent.
- **Live media plane (WebRTC P2P)** (XL) / **Pluggable primitives + Hermes** (XL) / **Computer-use
  operator loop** (M–L) / **Native ports = actors** (concept) / **GUI shell boot-into + modes** (L)
  — the platform north stars. Real, but above the friction-removal push.

---

## Recommended sequence

**Warm-up (Tier 0, in order):** 0.1 peek fix → 0.2 gateway-outlives-app → 0.4 bridge-rejects +
legibility → 0.5 mic-leak teardown → 0.3 parked-ports-stop-billing → 0.6 recency ⌘K.

Rationale: 0.1 is the flagged quick win and a clean re-entry. 0.2/0.4/0.5 each retire a *class* of
future debugging. 0.3 needs a sliver of the presentation-event work, so it bridges into Tier 1.

**Then the spine (Tier 1):** 1.1 presentation-state → 1.2 eviction (together: the desktop stops
melting) → 1.3 ports-scoped-to-space → 1.4 richer rows → 1.5 dock view. This is the "a space is a
real place, and it doesn't cook the CPU" arc, and it de-risks the chrome-is-ports north star.

**Slot in when their prerequisite is met:** 2.1 permission overlay early (it's a ship-blocker and
probably retires 2.3); 2.2 blanking bug alongside 1.2 (same probe); 3.4 terminal-stream and 3.5
llms.txt as cheap standalone wins between larger items.

**The one blocker to name:** the whole Tier 4 cluster (storage sharing, MCP, port URL, teleport,
shared-port safety) is gated on **the principal work**. If any of those is a near-term priority for
GM, the principal/unification slice is the thing to schedule first, and **AI-edit-a-port-from-chrome
(Tier 4) is the cheapest concrete driver for it.** Otherwise Tier 4 stays parked behind the friction
push.

---

## The flagged item, weighed explicitly

**Item:** a new port created in the CURRENT space peeks instead of just showing up; gate the peek on
`port.spaceId != currentSpace`.

**Verdict: take it, first, as Tier 0.1.** It is pure friction removal on the core loop and GM has
already made the call.

**Size: XS.** The trigger is one function, `ShellState.handlePortCreated` (ShellState.swift:208).

**What the code shows (this is the nuance to weigh):**
- The current behavior is *deliberate*, not a bug of omission. The comment at :204-207 says same-space
  births peek on purpose: "a peek is a live surface with an attention beat… a same-space port renders
  in PEEK state until its entry clears, then settles into the grid." GM's item **reverses that design
  decision.** Worth a one-line confirm that we're overturning the attention-beat intent, not just
  patching a leak.
- There is *already* a suppression path: `userSpawnedPortIds` (:199-202) stops a peek for ports the
  user spawned from the dock/⌘K. So the real remaining gap is **companion-created / programmatic ports
  landing in the current space** — those are what still peek. The fix generalizes that existing
  suppression to "any port whose `spaceId == currentSpace`."

**The one thing to verify before calling it done:** that a same-space port which *skips* the peek
still gets tiled/arranged correctly. Today the peek → `keepPeek(arrange:)` path is what places some
ports; confirm the direct-to-tile path arranges without depending on the peek→keep flow. There is
likely a `handlePortCreated` same-space test asserting the old behavior — update it to assert
same-space → tile, other-space → peek.

**Recommendation:** gate at :208 on current space; route same-space births straight to a tile;
keep the peek strictly for `spaceId != currentSpace`. Confirm arrangement + update the test. Clean XS.
