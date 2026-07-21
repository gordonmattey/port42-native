# Webview eviction — the working set (Tier 1.2)

Spec and step plan for backlog 1.2. The webview registry never evicts: every port ever created holds a
live `WKWebView` (one WebContent process each) until it is closed. Measured: 88 WebContent processes at
101 ports, ~90% idle CPU. 1.2 keeps only the working set mounted, evicts the rest, and re-mounts on
return. It is the actuator for the `visible` signal 1.1 produced; 1.1 idles what is kept, 1.2 removes
what is not.

## Problem and goal

`PortWindowManager.webViews: [String: WKWebView]` is created **eagerly** at port birth
(`createPortWebView`, 7 call sites) and removed **only on close** (`destroyWebView`). So the process
count scales with ports-ever-created, not with what is on screen. A person who has opened 101 ports
over a session carries ~88 live WebContent processes, none of which idle (1.1 fixes the idle half for
the kept set) and none of which are released (this item).

Goal: a bounded working set of mounted webviews. Keep every visible port plus a small MRU margin;
evict the rest by tearing down their WebContent process while preserving the port (panel + bridge +
persisted HTML); re-create on return to visible. This caps live process count at roughly "what fits on
the desktop plus a margin," independent of how many ports exist. It is the load-bearing constraint
under "the desktop IS live ports."

## What exists today (the seams)

| Piece | Where | Role |
|---|---|---|
| `webViews: [String: WKWebView]` | `PortWindowManager` | the registry; created once, never evicts |
| `createPortWebView(for:)` | `PortWindowManager:834` | builds config + handlers + `FileDropWebView`, `loadHTMLString`, stores `webViews[id]`. Called EAGERLY at create/restore (7 sites) |
| `destroyWebView(_:)` | `PortWindowManager:901` | removes the `port42` handler (0.5 retain-cycle fix) + user scripts, `removeFromSuperview`, drops all per-port dicts. The CLOSE path |
| `hostView(for:)` | `PortWindowManager:121` | returns the persistent `webViews[id]` / `terminalViews[id]`; the one thing a tile mounts |
| `ShellPortHost` | `ShellDesktop:914` | reparents that view into a container (the mount); `updateNSView` deliberately does not reclaim |
| `PortRenderProbe` | `Services/PortRenderProbe.swift` | DEBUG blanking guard: asserts `makeNSView` ran **once per port lifetime**, the view always has a window, and stays in its container |
| `presentation.visible` | 1.1 | the tier-0 keep/evict input |

## The model: keep set, evict set (signed off 2026-07-21)

Eviction is **invisible**: it drops a port's WebContent process but changes nothing the user can see.
The port stays exactly where it is (tiled off-desktop, parked, backgrounded), looks identical, and
rebuilds silently on return. Eviction is not parking and parking is not eviction; a parked port is a
strong eviction *candidate* (it is not visible), but the two are orthogonal.

The policy is a **flat cap on mounted web/browser webviews, GM-set at ~50**:

- **Keep mounted** = every `visible:true` web/browser port, plus recently-visible hidden ports, up to
  the cap.
- **Evict** = the least-recently-visible hidden web/browser ports once the mounted count exceeds the
  cap, LRU first, down to the cap.
- **A minimum dwell** (a webview younger than ~10s, or hidden for under ~5s, is never evicted) kills
  thrash on a quick galaxy glance or a one-tick hide.

Consequence, by design: **under the cap, nothing is evicted.** At normal port counts the mounted set
is well under 50, so eviction never fires and there is zero remount latency in everyday use. The cap is
a safety valve for the accumulation case (100+ ports), not a mechanism the user feels. The lazy-create
(cold-start bound) and remount self-heal (blanking fix) still land regardless of whether eviction ever
triggers. A flat cap (not a screen-derived `K`) is what GM chose: deterministic, and it bounds the
metric that hurt (live process count) directly.

## The mechanism

### 1. Lazy create-on-mount (the shared fix with the blanking RCA 2.2)

Today the webview is built eagerly at port birth and mounted later. Eviction inverts this: a webview
exists only while the port is in the keep set. So creation moves from eager to **lazy**:

- `hostView(for:)` (or a new `ensureHostView(for:)`) builds the webview on demand the first time a
  kept port needs to mount, instead of `createPortWebView` firing at birth for every port.
- This directly retires the blanking RCA (2.2): "eager `loadHTMLString` on a detached webview during a
  stalled startup." Load-on-mount means the document loads into a webview that is about to be attached,
  never into a detached one during startup churn.

The 7 eager `createPortWebView` call sites collapse to the lazy ensure path. Restore-from-DB no longer
builds a webview for an off-desktop or parked port; it builds panel + bridge only, and the webview
appears when (if) the port enters the keep set.

### 2. Evict (drop the process, keep the port)

A new `evictWebView(id)`, distinct from `destroyWebView` (close):

- Runs the same webview teardown `destroyWebView` already does (remove the `port42` handler and user
  scripts — the 0.5 retain-cycle fix — `removeFromSuperview`, drop `webViews[id]` and the per-port
  handler dicts).
- Calls `bridge.releaseAcquisitions()` (0.5) so an evicted port holds no mic/camera/screen/browser
  streams while it has no surface — it cannot use them with no webview, and re-mount re-requests them.
- **Keeps the `PortPanel` and `PortBridge` alive** (unlike close, which removes the panel). The bridge
  survives with `webView == nil`, so `pushEvent` / heartbeats no-op harmlessly (they already guard on
  `webView?`).
- Persists the panel's HTML first if needed (see Persist-before-evict).

The distinction is the whole point: close removes the port; evict removes only its process.

### 3. Re-mount (create on return to visible)

When an evicted port returns to `visible:true`, the 1.1 pipeline fires (same publishers). The eviction
evaluator recomputes the keep set, the port is back in it, and the lazy `ensureHostView` rebuilds its
webview: `createPortWebView` runs again, `setWebView`, `loadHTMLString(panel.html)`. The port
re-initializes from its persisted HTML and re-registers its bridge.

### 4. Persist-before-evict

An evicted port re-mounts by reloading `panel.html` — its last saved document — not its live DOM/JS
state (that died with the process). So live state must be checkpointed before eviction. Two layers:

- **The port's job** (Step 5 of 1.1, already shipped in the manual): on the `background` /
  not-visible event, persist via `port42.storage` / `port.update` before the webview is dropped.
- **The platform's job:** eviction reads the port's latest persisted HTML (the version store already
  keeps it), so a well-behaved port re-mounts clean. A port that did not persist re-mounts to its last
  saved HTML — degraded, not blank.

## The blanking-bug guard: production self-heal, then probe bookkeeping

The thing that matters is a production guarantee that a remounted port never comes back blank. Two
layers, only the first user-facing:

- **Production remount self-heal (the guarantee, signed off).** On remount, the nav delegate fires
  `didFinish` when the document loads (1.1 already hooks it). If a remounted webview's load does not
  finish, or it paints blank, within N runloop turns, reload it once. This is a real in-app safety net
  and is exactly the "verify / self-heal via the nav delegate" fix that closes the blanking bug (2.2).
  It ships in the app, independent of DEBUG.
- **DEBUG probe bookkeeping (mechanical).** `PortRenderProbe`'s invariant is "`makeNSView` ran exactly
  once per port lifetime; >1 ⇒ the blanking bug." Eviction remakes the view on purpose, so the probe
  needs a per-port **mount epoch** (incremented on evict) and the invariant becomes "once per epoch":
  within one mount lifetime the view is still never remade (the real guard), and an eviction is a
  sanctioned epoch boundary. No user impact; it only keeps the existing test instrument from screaming
  false failures. The "Port Units — cycle" harness gains an evict→remount leg.

## Identity and edge cases

- **Terminal ports** (Ghostty) hold a stateful PTY (scrollback, running process); tearing it down loses
  the session. v1 does NOT evict terminals — they are a fixed, usually-small count and not the
  WebContent-process cost. Only web/browser ports evict. (Decision: confirm.)
- **Browser ports** carry navigation state (current URL, history). Evicting reloads `panel.html` = the
  last URL; in-page state is lost. Acceptable, same as a web port; the URL is preserved.
- **An in-flight AI stream** on a port that becomes evictable: the 1.1 re-key already suspends new
  calls when not visible; `releaseAcquisitions` on evict cancels any in-flight stream (`suspendAI`),
  consistent with option A (evict is a stronger state than "hidden," and a port with no process cannot
  hold a stream).
- **The inline-in-chat host** (`ConversationContent:1119` reads `webViews[id]`) must tolerate a nil
  webview for an evicted inline port and trigger the same lazy ensure when the card scrolls into view.
  (Inline visibility is the 1.1 v1-deferred scroll case; until wired, an inline port stays in the keep
  set while its chat is open.)
- **Adoption / reparent** (a port shown on multiple desktops) resolves through the same `visible`
  computation; a port visible on ANY current desktop is kept.
- **Focus/keyboard** (`focusKeyboard(on:)`) already tolerates a missing host view (falls back). A
  just-remounted port gets its window on attach, then keyboard focus.
- **Eviction must never race a mount:** the evaluator runs after the 1.1 sync settles (debounced), and
  evict is deferred a runloop turn so it never tears down a view mid-attach.

## Dovetail with 1.1 and the never-evicts class

1.1 delivers `visible` and idles the kept set; 1.2 consumes `visible` and evicts the unkept set. They
are the signal and the actuator of the same working-set model. This is also the third instance of the
"nothing releases what it acquired" class (mic/speech leak 0.5, gateway-outlives-app 0.2): the registry
acquires a process per port and never releases it. Eviction is the release path, and `evictWebView`
funnels through the same 0.5 teardown so it cannot re-open the retain-cycle leak.

## Decisions (signed off 2026-07-21)

1. **Policy: flat cap of ~50 mounted web/browser webviews, LRU-evict beyond, plus a min-dwell.** SIGNED
   OFF. Eviction is invisible (not parking). Under the cap nothing evicts, so everyday use is unchanged;
   the cap is a safety valve for the accumulation case. A flat cap, not a screen-derived `K`.
2. **Lazy create-on-mount.** SIGNED OFF. Retires the blanking RCA (2.2) in the same change, bounds cold
   start (restore builds no webviews), and is the natural re-mount seam. The 7 eager `createPortWebView`
   sites collapse to one lazy ensure path.
3. **Web/browser evict; terminals always kept in v1.** SIGNED OFF (follows from evict-is-invisible: a
   terminal's cost is a live PTY, and silently dropping it would kill a running shell, which is not
   invisible). Terminal eviction, if ever needed, is a separate PTY-snapshot effort.
4. **Production remount self-heal + mechanical probe bookkeeping.** SIGNED OFF. The self-heal (nav
   `didFinish` verify + reload-once on blank) is the shipped blanking guarantee and the 2.2 fix; the
   `PortRenderProbe` mount-epoch re-frame is mechanical, no user impact.

## Implementation steps, with testing at each step

Each step builds and runs green before the next. Test in Port42Dev only, exact suite names. The pure
keep/evict policy is unit-tested; the mount/evict/remount lifecycle is verified live (the blanking
guard is inherently a live/probe property).

### Step 1: the pure keep/evict policy
- A pure `WebviewWorkingSet.plan(visible:[id], mru:[id], mounted:[id], cap:K) -> (keep:Set, evict:Set,
  mount:Set)`, headless like `presentationDeltas`.
- **Test (`WebviewEvictionTests`):** all-visible → keep all, evict none; hidden beyond the cap → LRU
  evicted; a returning port → in `mount`; margin absorbs a one-tick hide; deterministic.

### Step 2: lazy create-on-mount
- Move `createPortWebView` behind an `ensureHostView(for:)`; restore/create build panel + bridge only;
  the webview is built on first mount. Point the mount path (`ShellPortHost` via `hostView`) at it.
- **Test:** a restored off-desktop port has no `webViews[id]` until it enters the keep set; entering it
  builds exactly one; `BridgePortsTests` / `PortWindowLifecycleTests` still green (creation moved, not
  removed).

### Step 3: evict + the evaluator
- `evictWebView(id)` (0.5 teardown + `releaseAcquisitions`, keep panel/bridge); a debounced evaluator
  that runs after the 1.1 sync, computes `WebviewWorkingSet.plan`, and evicts/mounts accordingly.
- **Test:** evicting drops `webViews[id]` and the per-port handler dicts but keeps the panel + bridge;
  `pushEvent` to an evicted port no-ops without crash; the evaluator evicts exactly the plan's set.

### Step 4: the blanking guard under eviction
- Mount-epoch counter (increment on evict); re-frame `PortRenderProbe` to "once per epoch" + the
  post-remount window/not-blank sweep; add an evict→remount leg to the "Port Units — cycle" harness.
- **Test:** live in Port42Dev — the cycle harness drives evict→remount 10× and reports PASS (view gets
  a window, not blank, one make per epoch). Calibration: point it at a deliberately broken remount,
  expect FAIL.

### Step 5: live verification + the process-count win
- Live in Port42Dev: create N ports across spaces; confirm live `WebContent` process count tracks the
  keep set (not N); switch spaces / park and watch processes drop; return and watch a clean remount
  (not blank), the 0.5 leak stays fixed (no handler regrowth), and no emit/rebuild storm.

## Risks and rollback

- **Blanking regression.** The whole risk surface. Mitigated by lazy load-on-mount + the re-framed
  probe + the live cycle. The probe is the gate.
- **Rebuild thrash** (evict then immediately remount). Mitigated by the MRU margin + the debounced
  evaluator; the margin size is the tuning knob.
- **State loss on evict** for a port that did not persist. Mitigated by the port-authoring discipline
  (persist on `background`) and re-mount from the last saved HTML (degraded, never blank).
- **Rollback.** Steps are independent. Lazy creation (2) ships without eviction (3). Eviction reverts
  by making the evaluator keep everything (evict set always empty) — back to today's behavior with the
  lazy-load blanking fix retained.
