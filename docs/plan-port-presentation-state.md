# Ports must know their presentation state (Tier 1.1)

Spec and step plan for backlog 1.1. The shell already knows a port's state (tiled / parked /
backgrounded / focused / peeking / off-desktop); it never tells the port. A port therefore cannot
idle, because it has no signal to idle on. This delivers that signal, defines the shell-side defense
for ports that ignore it, and lays the tier that 1.2 (webview eviction) consumes.

**Sign-off status (2026-07-21):** GM approved all four decisions as recommended (re-key `isSuspended`
to `!visible`; include `inline` as a distinct sixth state and defer inline scroll-visibility; keep the
`port42:presentation` DOM alias; include `reason`), and approved the abstraction decision below:
presentation **consumes the one desktop-membership + peek-index decision** ShellState already makes
for placement, rather than running a second precedence ladder that mirrors `PortPlacement.placement`.
See "Level of abstraction, interface, and invariants" and "Decisions" for the settled positions.

## Problem and goal

Four animated ports as tiles cooked the CPU (todo 2274): each ran an unconditional 60fps
`requestAnimationFrame` loop even while peeking at 210px, backgrounded, or on another space's
desktop. The bridge pushes `audio.*`, `browser.*`, `camera.frame`, `screen.frame` and nothing about
the port's own presentation. The information exists (`panel.isBackground`, `panel.presentation`, the
peek entry, `shell.zoom`) and is already observed for rendering; it is simply never delivered.

Goal, two halves (todo 2290):
1. **Tell the port.** A `presentation` event on every state change, plus a getter for the initial
   read, so a well-behaved port pauses its loop when not visible and drops fidelity when small.
2. **Defend anyway.** The shell suspends and (via 1.2) evicts ports it knows are invisible, so a port
   that lies or ignores the signal still cannot melt the machine.

This caps how many live ports a person can have, which is the load-bearing constraint under the
"desktop IS live ports" thesis.

## What "presentation state" is today (the scattered inputs)

There is no single field. The real state is a composite the shell computes across two objects:

| Input | Where it lives | Meaning |
|---|---|---|
| `panel.isBackground` | `PortPanel` (PortWindowManager) | off the desktop, view unmounts |
| `panel.presentation` | `PortPanel` | `"tiled"` / `"parked"` / `"inline"` |
| `panel.spaceId`, `adoptedSpaceIds` | `PortPanel` | which desktop stages it |
| `shell.zoom` | `ShellState` | `.galaxy` / `.space` / `.focus(id)` |
| `shell.peekingPorts` | `ShellState` | peeking on the current desktop (rail preview) |
| `shell.openDMSpaceIds`, `appState.currentSpace` | ShellState / AppState | is this the current desktop |

`ShellState` already reads all of these to build `desktopTilePanels` and `contextItems`. It is the
natural computing authority, and it already carries the `PortPlacement.placement` precedence
(`focused > peek > tiled`, off-desktop invisible) that the desktop renders. The port-facing model
must derive from those same inputs so the reported state can never disagree with what is on screen,
exactly as `desktopTilePanels` is the one predicate the render, arrange, and focus paths all share.

## The model the port receives

One value, GM's contract (todo 2291) with two clarifying additions (`reason`, and `inline` as a
sixth state, both flagged for sign-off below):

```
PortPresentation {
  state:   "focused" | "tiled" | "peek" | "parked" | "background" | "inline"
  visible: bool          // is this port's surface actually on screen right now
  w: int, h: int         // current on-screen content size in points (0 when not visible)
  reason?: string        // optional transition cause: "space-switch" | "focus" | "park" | ...
}
```

Two axes, deliberately separated:

- **`state`** is the port's placement/mode. A port scales fidelity to it (focused = full,
  tiled = normal, peek = thumbnail).
- **`visible`** is the single authoritative "render your pixels now" bool. A port gates its rAF loop
  on this. `visible` is NOT `state != "background"`: an off-desktop tile and a galaxy-zoomed tile are
  `state:"tiled", visible:false`, and a non-focused tile behind the focus backdrop is
  `state:"tiled", visible:false` because the backdrop (`backdropZ` 11_900) covers it.

### The mapping (precedence, first match wins)

Encoded as a pure static function that **consumes the shared desktop-membership + peek-index
decision** (the same one that feeds `PortPlacement.placement`) and layers the richer visibility gates
on top. It does not re-scan panels with a parallel ladder:

1. `isBackground` → `background`, visible **false**
2. `presentation == "parked"` → `parked`, visible **false**
3. `presentation == "inline"` → `inline`, visible **true** (v1 conservative; scroll-based visibility
   is a follow-up, see Decisions)
4. tiled, **not** on the current desktop (not in `desktopTilePanels`, not peeking here) → `tiled`,
   visible **false** (off-desktop: another space)
5. tiled, on the current desktop — the zoom rung decides occlusion for **both tiles and peeks**,
   because the focus backdrop (`backdropZ` 11_900) sits above the peek rail (`peekZ` 10_500) and every
   tile:
   - `zoom == .galaxy` → `peek`/`tiled` (its mode), visible **false** (the desktop is not shown)
   - `zoom == .focus(thisId)` → `focused`, visible **true** (focus wins over a peek)
   - `zoom == .focus(otherId)` → `peek`/`tiled` (its mode), visible **false** (behind the backdrop)
   - `zoom == .space` → peeking → `peek` visible **true**; else `tiled` visible **true**

   Refinement found building Step 1: the draft marked `peek` as unconditionally visible, but a peek is
   occluded by a focus backdrop and hidden in galaxy exactly as a tile is. So `peek` visibility is
   zoom-gated too (visible only at `.space`). This is the concrete "presentation.visible is strictly
   richer than `PortPlacement.visible`" case — placement gives a peek a rect regardless of zoom.

`w,h`: the on-screen content size for the resolved state (focus card size, tile `panel.size`, or the
`peekSize` 210x140); `0,0` when not visible. This is the "scale particle/geometry counts to tile
size" signal (todo 2305) and is complementary to the existing `viewport.resize` event (which fires on
an actual DOM resize).

## Level of abstraction, interface, and invariants

This section is the design contract the steps below implement. It fixes where the model lives, what
the port can rely on, and what must always hold.

### Level of abstraction

Presentation is a **derived view-model value**, a sibling of `PortPlacement.placement` and
`contextItems`, not a stored fact. It lives in `ShellState` because that is the one object that joins
the two authorities:

- **Panel facts** (owned by `PortWindowManager`, on `PortPanel`): `presentation`
  (`tiled`/`parked`/`inline` — mutually exclusive), `isBackground`, `spaceId`, `adoptedSpaceIds`,
  `size`. `inline` is a single mode, not an overlay: a port is inline OR tiled OR parked, and dock-back
  is an explicit `inline → tiled` transition.
- **Shell facts** (owned by `ShellState` + `AppState`): `zoom`, `peekingPorts`, `openDMSpaceIds`,
  `currentSpace`.

`ShellState` **computes**; `PortBridge` is a dumb delivery pipe (it cannot compute this — it does not
know zoom/peek/currentSpace). Presentation is never persisted and never stored as a second field,
because a stored copy could disagree with the render.

**Consume the shared membership decision, do not mirror it.** ShellState already decides, once per
render pass, "is this panel off-desktop / a peek (and which slot) / a plain tile" — the same decision
that feeds `PortPlacement.placement`. Presentation reuses that single decision rather than re-scanning
panels with a parallel precedence ladder. It cannot reuse `placement.visible` directly, because the
two `visible` notions differ: `placement.visible` means "has a nonzero rect on the desktop," whereas
`presentation.visible` is strictly richer — it additionally requires the desktop is shown
(`zoom != .galaxy`), nothing covers the port (not behind another port's focus backdrop), and (inline)
the card is on screen. So presentation is a **thin gate layer on top of the shared membership
decision**, not a second implementation of it.

### Interface (two surfaces, one source)

Port-facing (JS), the stable contract a port author codes against:

- `await port42.presentation()` → `{state, visible, w, h, reason?}` for this port. Always answerable,
  no race.
- `port42.on('presentation', cb)` → the same shape on every transition. `port42:presentation` DOM
  `CustomEvent` alias for parity with `port42:filedrop`.

Internal (Swift), one of each:

- **One pure function** `ShellState.presentation(for:zoom:currentDesktop:peeks:)`, `nonisolated`,
  headless-testable.
- **One emit funnel** `syncPresentation()`: build snapshot for live-web-bridge panels, diff vs
  `lastPresentation`, push deltas. Read-only over `@Published` state.
- **One trigger**: the debounced merged Combine pipeline over the five publishers. No per-call-site
  emits.
- The getter routes through the **same pure function**, so getter and last event cannot disagree.

### Invariants (what must always hold)

1. **Derived, never stored.** The mapping lives in exactly one function; nothing persists a copy.
2. **`visible == true` implies the webview is mounted and uncovered on screen** at that instant.
   Presentation is a pure function of the same inputs the desktop render reads, in the same authority,
   so it cannot contradict the screen.
3. **No feedback.** `syncPresentation` mutates nothing observed, so it cannot retrigger its own
   pipeline.
4. **Fixed inventory.** Every placement mode has a case; the inventory test fails when a new mode is
   added without a mapping (the teardown discipline).
5. **Getter equals last event** (same function, same live state).
6. **Non-web ports excluded.** Terminal (Ghostty) and SwiftUI chat panels carry no rAF and no JS
   listener surface; they are skipped in the snapshot.
7. **Contract stability.** Ports gate *correctness* on `visible` and size on `w,h`; `state` is an
   advisory fidelity hint. This makes future `state` additions (e.g. splitting inline-visible from
   inline-hidden) additive and non-breaking.

### Component interaction

```
PortWindowManager.$panels ─┐
ShellState.$zoom ──────────┤
ShellState.$peekingPorts ──┤ merge, debounce 50ms
ShellState.$openDMSpaceIds ┤──► syncPresentation()
AppState.$currentSpace ────┘       build (pure fn per panel) → diff vs lastPresentation
                                   └─► panel.bridge.pushEvent("presentation", delta) → port JS
   port42.presentation()  ◄── same pure fn (getter path)

consumers of `visible`:  isSuspended = !visible (0.3) · heartbeat skips !visible · 1.2 evicts on !visible
```

## The event contract (JS surface)

Consistent with the dominant idiom (`port42.on('message', …)`, `audio.transcription`,
`companion.activity`), all delivered through the existing `_emit` / `_listeners` registry:

```js
// initial read at startup (no race — see below)
const p = await port42.presentation();   // {state, visible, w, h}

// updates on every change
port42.on('presentation', (p) => {
  if (!p.visible) cancelAnimationFrame(raf);   // idle
  else if (p.state === 'focused') runFull();
  else runReduced(p.w, p.h);                    // small: cap fps / dpr / particle count
});
```

- **Event name.** Push via `pushEvent("presentation", …)`, surfaced as `port42.on('presentation',…)`.
  GM's note writes the wire name as `port42:presentation`; the `port42.` namespace is already implied
  by the `on` registry, so the delivered name is `presentation`. A `window` `CustomEvent` alias named
  `port42:presentation` is added for parity with `port42:filedrop`, at ~3 lines, for ports that
  prefer DOM events. (Sign-off item: keep both, or registry only.)
- **The initial-delivery race.** JS listeners register after the document loads, so a single fire on
  creation can be missed. Two mechanisms cover it: (a) `port42.presentation()`, a client-answerable
  bridge call returning the current snapshot for this port (the bridge computes via
  `state.shell.presentation(for: messageId)`); and (b) an explicit emit on the webview's nav
  `didFinish`, after `bridgeJS` is injected. The getter is the robust one; the didFinish emit covers
  ports that only use `on`.

## The computing authority and the one emit seam

A single funnel, so "someone added a state transition and forgot to emit" is impossible by
construction (the same philosophy as the teardown fixed inventory).

- **Pure function.** `ShellState.presentation(for panel:, zoom:, currentDesktop:, peeks:) ->
  PortPresentation`, `nonisolated`, headless-testable like `PortPlacement.placement` and
  `contextItems`. It consumes the shared membership + peek-index decision and layers the visibility
  gates on top; it encodes nothing that duplicates the placement ladder.
- **Snapshot + diff + push.** `ShellState.syncPresentation()`:
  1. Build `[portId: PortPresentation]` for every panel that owns a live web bridge (skip terminals
     and chat ports; see Edge cases).
  2. Diff against `lastPresentation` (a stored `[String: PortPresentation]`).
  3. For each changed port, `panel.bridge.pushEvent("presentation", delta)`.
  4. Store the new snapshot.
  `syncPresentation` only READS shell/app state and pushes JS; it never mutates an observed
  `@Published`, so it cannot feed back into its own trigger.
- **Reactive trigger.** A merged, debounced (~50ms) pipeline drives `syncPresentation`, subscribing
  to every input that can change a port's presentation:
  - `$zoom` (focus / galaxy / space)
  - `$peekingPorts` (peek in / out)
  - `$openDMSpaceIds` (a surfaced foreign desktop)
  - `appState.portWindows.$panels` (presentation / isBackground / adoption / space move / new port /
    closed port — one publisher covers the whole panel side)
  - `appState.$currentSpace` (desktop switch)
  This mirrors the existing `notifSink` / `portSink` Combine sinks already on `ShellState`. Debounce
  coalesces bursts (arrange, cycle burst, the space-switch cascade) into one settled emit per port.

The reactive pipeline is the primary and only required trigger. No per-call-site sprinkling of
`syncPresentation()` (that is exactly the fragility the teardown work removed). The transient
render-only states (`cycleBoostId`, `cycleFlashId`, `exposeActive`, an in-progress `isDraggingTile`)
are deliberately NOT inputs: they are not real presentation changes, and folding them in would spam
emits. Size changes mid-drag are emitted on drag-end (the `updateTileFrame` persist point), not per
frame.

## Every input / emit trigger (the fixed inventory)

| Transition | Fires via |
|---|---|
| park / unpark | `panels` (presentation) |
| background / restore | `panels` (isBackground) |
| focus in / out / cycle-focus swap | `$zoom` |
| galaxy in / out | `$zoom` |
| peek raised / previewed / evaporated / kept | `$peekingPorts` (+ `panels` on keep→adopt) |
| space switch | `$currentSpace` |
| surface / detach a DM or foreign chat | `$openDMSpaceIds` |
| move a port to another space | `panels` (spaceId) |
| adopt / unadopt | `panels` (adoptedSpaceIds) |
| new port created | `panels` (append) + didFinish initial emit |
| port closed | `panels` (removal) — snapshot drops it, no push needed |
| tile resized | `panels` (size), emitted on drag-end |

A `PortPresentationTests` inventory test asserts the pure function's output for each state so a new
placement mode fails the suite until its mapping is added.

## Shell-side throttle policy (defend anyway)

Two classes of lever. The point of the split: the native levers work on a port that ignores or lies
about the signal; the cooperative lever needs the port's help but gets the real win (a paused rAF).

**Native, no cooperation required:**
- **AI suspend.** Today `isSuspended = isBackground || presentation == "parked"` and is enforced in
  the stream registry guard plus `suspendAI()` on park/background (0.3, shipped). Recommended: re-key
  `isSuspended` to `!presentation.visible`, so an off-desktop or galaxy-hidden tile also stops
  billing the model, from one source of truth. (Sign-off item: this changes 0.3 behavior for
  off-desktop ports; see Decisions.)
- **Heartbeat / event feed.** `pushHeartbeatToBridges` (every 5s) and periodic pushes skip
  not-visible ports, so a hidden port's JS is not woken needlessly.
- **Eviction (1.2).** The only lever that actually stops an uncooperative port's rAF is unmounting
  its webview. That is 1.2, which 1.1 unblocks (below). Until 1.2 lands, an uncooperative animated
  port on the current desktop still runs; the honest statement is that 1.1 delivers the cooperative
  signal and the AI-spend defense, and 1.2 delivers the hard rAF defense.

**Cooperative (the whole point):**
- On `visible:false` a well-behaved port cancels its rAF loop and pauses timers; on
  `state:"background"` it also persists-before-unmount (relevant to the shader-state-loss bug, todo
  2240, where a backgrounded WebGL port loses its context on detach and cannot snapshot first because
  it was never told). The reference-implementation ports (first-party templates) honor this, and the
  port-side discipline goes in the port-authoring skill (todo 2303): pause on `!visible`, drop to
  15-30fps when small/unfocused, cap `devicePixelRatio`, scale geometry to `w,h`.

## Dovetail with 0.3

0.3 already made park/background stop the model (native enforcement via `isSuspended` + `suspendAI`).
Its cooperative half was blocked on this signal: the shell can cancel a model call, but only the port
can cancel its own rAF loop, and it needs a signal to do so. 1.1 delivers that signal. If
`isSuspended` is re-keyed to `!visible` (recommended), 0.3's enforcement and 1.1's model share one
computation, and the dollar leak closes for off-desktop ports too, not only parked/backgrounded ones.

## Unblocks 1.2 (webview eviction)

1.2 keeps a working set mounted and evicts the rest, re-mounting on return (todo 2210). It needs
exactly what 1.1 produces:

- **The keep/evict tier.** `visible` is the tier-0 input. Keep-mounted = every `visible:true` port
  plus a small MRU margin (recently-focused / peeked); evictable = the rest (off-desktop, galaxy,
  long-parked, long-backgrounded).
- **The re-mount trigger.** When an evicted port returns to `visible:true`, the same pipeline fires;
  1.2 re-creates its webview and the port re-initializes.
- **Persist-before-evict.** The `background` / not-visible event lets a port checkpoint its state
  (via `port42.storage` or `port.update`) before its webview is dropped, so re-mount restores clean
  rather than blank. This is the platform half of the shader-state-loss fix.

1.1 is the signal layer; 1.2 is the actuator. Building 1.1 first means 1.2 consumes a stable
`visible` signal instead of re-deriving desktop membership. The eviction path must still be pointed at
the `PortRenderProbe` so a remounted port comes back clean once (the blanking-bug guard); that is
1.2's test obligation, noted here only as the seam.

## Identity and edge cases

- **Stable key.** Presentation is keyed on `panel.bridge.messageId` (== port id / panel udid at every
  registration site), the same stable id the teardown work adopted. Delivery uses the live `bridge`.
- **Terminal ports** host a Ghostty surface, no WKWebView; `pushEvent` no-ops on a nil `webView`.
  They are skipped in the snapshot (they cannot run rAF; native throttling does not apply). No crash.
- **Chat ports** (`isChatPort`) render via SwiftUI, no arbitrary JS; skipped for the same reason.
- **Inline ports** live in the chat scroll; true visibility depends on scroll position, which the
  chat view knows via `onAppear`/`onDisappear` of the inline host. v1 reports `state:"inline",
  visible:true` (conservative — never wrongly idles a visible port). Wiring scroll visibility is a
  scoped follow-up (see Decisions).
- **Dedup precedence** follows `PortPlacement`: a port both tiled (home) and peeking (adopted preview)
  resolves to `peek`, matching what `contextItems` renders (peek state wins).
- **Focus teardown.** When a focused port closes, `exitFocusIfGone` drops zoom to `.space`; the
  `panels` + `$zoom` publishers fire and the remaining tiles flip `focused`/covered → `tiled`
  visible. The closed port simply leaves the snapshot.

## Decisions (signed off 2026-07-21)

0. **Abstraction: consume the shared membership decision, do not mirror `PortPlacement.placement`.**
   SIGNED OFF. Presentation reuses the one desktop-membership + peek-index decision ShellState already
   makes and layers the richer visibility gates on top; no parallel precedence ladder. See "Level of
   abstraction, interface, and invariants."
1. **Re-key `isSuspended` to `!visible`.** SIGNED OFF. Closes the model-spend leak for off-desktop and
   galaxy-hidden tiles from one source of truth. Cost accepted: a tiled "worker" port on another
   space's desktop stops billing when you switch away (a genuinely always-on worker is the separate
   background-as-port concept, not a normal tile).
2. **Include `inline` as a distinct sixth state; defer inline scroll-visibility.** SIGNED OFF.
   `inline` is one mutually-exclusive value of `panel.presentation`, not an overlay (a port is inline
   OR tiled OR parked). v1 reports `inline`/visible:true; chat-scroll visibility is a scoped follow-up.
3. **Keep the `port42:presentation` DOM `CustomEvent` alias** alongside `port42.on('presentation')`.
   SIGNED OFF (parity with `port42:filedrop`, ~3 lines).
4. **Include the `reason` field.** SIGNED OFF. Optional transition cause for debug/analytics.

## Implementation steps, with testing at each step

Each step builds and runs green before the next. Test in Port42Dev only, exact suite names.

**Unit vs live boundary (set once, honestly).** Everything pure is unit-tested: the mapping, the
diff, the defense predicates. Two things are NOT deterministically unit-testable and are verified live
in Step 5 instead: the 50ms debounced Combine trigger (timing) and the actual `pushEvent`
JS delivery (`webView?.evaluateJavaScript` no-ops headlessly with no webView, so a spy would observe
nothing). The design consequence, applied below: every decision `syncPresentation` makes is a **pure
returnable value** tested directly, following the repo's own precedent (`PortPushRoute.classify` in
`PortPushDispatchTests`), never observed through a real push.

### Step 1: the pure model and function — DONE (19 tests, `Port Presentation — mapping (Step 1)` green)
- `PortPresentation` (`Sources/Port42Lib/Services/PortPresentation.swift`): `state`/`visible`/`w`/`h`/
  `reason`, a size-based init that forces `0,0` when not visible, `jsonObject` wire shape, `with(reason:)`
  for the Step 3 diff site, `State: CaseIterable` for the inventory test.
- Two `nonisolated` statics on `ShellState`: the primitive pure core
  `presentation(id:isBackground:mode:size:zoom:onDesktop:isPeeking:area:)` (headless like
  `ShellPlacement.placement`, no AppState), and the `presentation(for panel:zoom:item:area:)`
  convenience that consumes the shared `contextItems` decision (`item == nil` ⇒ off-desktop,
  `item.peek != nil` ⇒ peek).
- Tests (`PortPresentationTests`): six states, precedence (bg > parked > inline; focus > peek), zoom
  occlusion for tiles AND peeks, `w,h == 0,0` when hidden, `reason` nil from the mapping, `jsonObject`
  shape, the `CaseIterable` fixed-inventory switch, and the convenience forwarding.
- **Test (`PortPresentationTests`):** each of the six states from synthetic inputs; precedence
  (background over parked over inline over focus); off-desktop and galaxy → visible false; non-focused
  tile during a focus → visible false; `w,h` per state; a "not visible → 0,0" assertion. Pure, no
  window. Pins invariants #2 (via same-inputs purity), #4 (fixed inventory), #7.

### Step 2: the JS surface — DONE (`Port Presentation — getter & dispatch (Step 2)` green, full set 66/66)
- `ShellState.lastDesktopArea` (set by `ShellDesktop`'s GeometryReader `onAppear`/`onChange`) so the
  getter/sync can size a focused card headlessly.
- `ShellState.presentation(forPortId:)` — resolves the panel by its own id (keyed like
  `owningPortBridge`), reads live `contextItems`/`zoom`, returns the pure mapping (nil if unknown).
- The `presentation` registry method (`BridgeMethods.swift`): `permission: nil`, `toolExposed: false`
  (a port asking about itself, not a companion tool), forwards `principal.portId ?? principal.id`,
  falls back to a visible tile for an unknown port. Reachable as `port42.presentation()` via the
  generic JS dispatch (no per-method JS binding needed).
- The `presentation` EVENT already rides the existing `on`/`_emit`; added only the 3-line
  `port42:presentation` DOM `CustomEvent` alias in `_emit`, parity with `port42:filedrop`.
- **Tests:** `presentation(forPortId:)` == the pure mapping (invariant #5), nil for unknown, tracks a
  focus, the registry dispatch returns the same snapshot, unknown → visible-tile fallback.
- **Two pre-existing/inventory gates updated:** the `BridgeParamConsistencyTests` method-count sanity
  (was ALREADY red at HEAD — 67 vs 66, a parser miscount of `r["error"]`; now 68 with `presentation`
  added, comment corrected) and the `llms.txt` freshness gate (regenerated; `presentation()` now
  documented in the public reference).

### Step 3: the emit seam (pure diff + push) — DONE (`Port Presentation — funnel (Step 3)` green; 34 presentation tests, 75 shell/port regression tests green)
- Pure (`PortPresentation.swift`): `presentationDeltas(prev:next:)` (diff, sorted-by-id, drops closed
  ports) and `transitionReason(from:to:)` (coarse cause: appear / the new state / shown-hidden / resize).
- `ShellState` (`lastPresentation` `private(set)`, reason-nil baseline): `presentationSnapshot()` builds
  the map for web ports only (terminal + chat excluded); `syncPresentation()` = snapshot → deltas →
  `pushEvent` → store. Reads observed state, writes only the non-`@Published` snapshot, so no feedback.
- The trigger: a merged, 50ms-debounced Combine pipeline in `init` over `$zoom`, `$peekingPorts`,
  `$openDMSpaceIds`, `portWindows.$panels`, `appState.$currentSpace` — the sole trigger, no per-site sync.
- Initial-read belt-and-braces: `PortBridge.emitCurrentPresentation()` fired from the webview's nav
  `didFinish` (new `PortView` delegate method), for on-only ports; the getter remains the robust path.
- **Tests:** `presentationDeltas` (park = one delta, unchanged = [], appear/shown/hidden/resize reasons,
  closed = none, deterministic order) pins invariants #1, #3; snapshot web-only scope; `syncPresentation`
  idempotency; a live park = one delta. The debounced trigger and real `pushEvent` are live-verified in
  Step 5.

### Step 4: shell-side defense — DONE (`Port Presentation — defense (Step 4)` green; AI + streaming suites green)
- `ShellState.isVisible(_ panel:)` — the shared visibility computation.
- `isSuspended` re-keyed to `!shell.isVisible(panel)` (decision 1), so an off-desktop or galaxy-hidden
  tile also stops billing the model. Guarded: falls back to the panel-mode keying when no shell is
  wired (headless/tests), which is why the AI suites (no `ShellState`) are unaffected.
- `PortPresentation.shouldHeartbeat(_:)` pure predicate + `pushHeartbeatToBridges` skips not-visible
  ports (resolved via `shell?.presentation(forPortId:)`).
- **Scope note (behavior):** the re-key gates NEW model calls only. In-flight streams are still
  cancelled solely on the park/background transition (`suspendAI`), so glancing at the galaxy or
  focusing a sibling does not kill a running generation — it only blocks starting a new one while hidden.
- **Tests:** `isSuspended` false for a visible tile; true for galaxy-hidden, off-desktop, parked, and
  `aiPaused`; `shouldHeartbeat` false when not visible, true when visible or unknown. A test-lifetime
  note: `state.shell` is weak (the app's `ShellView` owns it), so tests hold the `ShellState` with
  `withExtendedLifetime`. Re-ran `Bridge — streaming contract` + `Bridge — ai service` for regression.

### Step 5: port-side discipline and reference ports
- Update the first-party animated templates (three.js / shader) to gate rAF on `visible` and scale to
  `w,h`; add the discipline section to the port-authoring skill.
- **Test:** live in Port42Dev — an animated port logging its rAF tick and listening for
  `presentation`. Park → the tick stops and `{state:"parked",visible:false}` arrives; background →
  same; focus → `{state:"focused",visible:true,w,h}`; switch space → the off-desktop port receives
  visible:false. Confirm no emit storm (a bounded log count across a space-switch). For the shader,
  the 0.3 gate still holds: zero new `port_versions` while parked.

## Risks and rollback

- **Emit storms / feedback.** Mitigated by diff-then-push, the ~50ms debounce, and `syncPresentation`
  reading-not-mutating observed state. The spy test in Step 3 pins "no emit when unchanged."
- **Initial-delivery race.** Covered by the getter plus the didFinish emit.
- **Behavior change from re-keying `isSuspended`** (decision 1). Behind sign-off; revertible to the
  park/background-only keying without touching the signal layer.
- **Rollback.** Steps are independent. The signal layer (1-3) ships without the defense (4-5); the
  defense reverts without removing the signal. The whole set reverts to "ports are never told."

## Relationship

Third instance of the session's shape (todo 2286): the system knows, nothing exposes the knowing —
the bus remembers every closed port but exposes no reopen; the shell knows visibility but never tells
the port. This delivers the knowing. It is the load-bearing primitive for idle, the enabling half of
0.3's cooperation, and the signal 1.2 evicts on. Pairs with the shader-state-loss fix (a backgrounded
port that can finally persist-before-unmount).
