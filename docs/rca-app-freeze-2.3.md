# RCA: app freeze — 100% CPU, every port grey (backlog 2.3)

*Status: **CAUSE CONFIRMED (2026-07-24).** A live 100% CPU spin was sampled straight into
`ConversationContent.body.getter` at the scroll-offset preference loop (`ConversationContent.swift:311–325`).
See CONFIRMED directly below. The prior 07-22 analysis (cause open, background-port retraction) is kept
after it for the record. Test in Port42Dev (:4243) only.*

## CONFIRMED (2026-07-24): the ConversationContent scroll-offset preference loop

**Trigger.** GM created a new space; the app hung entering it. `:4243` process at **99.4% CPU, state R
(running, not deadlocked)**, on the main thread. `sample` pinned the hot path to
`ConversationContent.body.getter` → nested closures at lines **314, 312, 292** — the scroll-offset
GeometryReader/preference machinery.

**The loop (`ConversationContent.swift:311–325`).**
- `GeometryReader` (311–315) publishes `ScrollOffsetKey` = the content-bottom `maxY`.
- `.onPreferenceChange(ScrollOffsetKey)` (321–325) writes `scrollContentBottom` and calls `updateNearBottom()`.
- A `guard abs(scrollContentBottom - contentBottom) > 2` is meant to damp it. But when the content's
  bottom **keeps moving** — heavy, variable-height inline ports still rendering/animating, plus the
  `scrollToBottom` nudges from the `onChange` handlers (326–352) — `maxY` never settles within 2pt, the
  guard never trips, the preference recomputes every frame, `body` re-evaluates forever, and the main
  thread pins. Empty space stays healthy (nothing variable, the offset settles); a loaded space spins.
  Exactly the 07-22 "empty healthy / non-empty hangs" pattern, now with a mechanism.

This confirms the **preference-loop hypothesis** the 07-22 doc had re-elevated, and closes the
"background port is the cause" thread for good.

**Fix plan (break the feedback cycle):**
1. Decouple the offset read from layout-affecting state — `onPreferenceChange` should only feed the
   "scroll to bottom" *decision*, never anything that re-lays-out the content it measures. Audit
   `updateNearBottom()` / `isNearBottom` for anything that changes content height.
2. Debounce/coalesce — act on only the trailing offset per runloop tick; drop `scrollToBottom` while the
   offset is still moving.
3. Replace the tight 2pt delta guard with a settle timer (act once the offset has held stable for N ms),
   since content legitimately resizes as ports load.
4. Stabilize inline-port heights — a port that resizes after first layout feeds the loop; give inline
   ports a measured height and grow only on explicit content change.
5. Regression guard — instrumentation that flags if `ConversationContent.body` evaluates more than K
   times with no state change, so this can't silently return.

**Recovery (operational).** A 100% main-thread render spin does not unwind — force-quit and relaunch;
parked/persisted ports come back.

## RETRACTION (2026-07-22): "background port is the cause" was WRONG

The "confirmed" A/B below was **contaminated** and its conclusion does not hold. Proof: `restoreBackgroundPort()`
(`ShellState.swift:123`) reads the background assignment **only** from `UserDefaults[shell.backgroundPortId]`.
After clearing that key, a fresh launch rendered NO background port (dreamscape fallback) — and `testing`
**still hung**. So the background port is not the trigger.

Why the A/B lied: the tests ran on **live spaces** (`testing`, `fundemos`) with **16 ambient `claude`
companion CLIs** + push loops mutating state between runs, plus **three** background-persistence sources
(`shell.backgroundPortId`, panel `isBackground`, panel `presentation`) I toggled inconsistently. repro3
(hang) vs repro4 (healthy) differed for some uncontrolled reason, not the background flag. Lesson (mine,
mirroring the session-handoff feedback): do not A/B on contaminated live state; control the variables.

The attempted fix (moving scroll geometry out of `@State`, deferring the `onAppear` writes) also did
**not** stop the hang and was **reverted** — it addressed a mechanism that isn't the driver.

## What is actually solid

- empty space (0 panels) → healthy (re-confirmed repeatedly).
- `testing` (3 panels: chat + a native terminal + a parked web port, 7 messages, NO background) → hangs.
- `fundemos` → hangs.
- Same signature every time: main thread in a deep (~12 nested frame-layout cycles, ~429-char stack)
  non-terminating `ConversationContent.body` layout transaction.
- 16 ambient companion CLIs are running — the contamination source, and a live suspect (continuous
  re-render of a space that has companions).

## Open next step: a CONTROLLED experiment (not live spaces)

Quiet the ambient CLIs so nothing mutates state, then either build up from the empty space one element at
a time (one web port → one terminal → one companion → N messages) or bisect `testing`'s saved panels
(remove one, relaunch, find which removal restores health). Each a clean launch, one variable.

## SUPERSEDED — contaminated "confirmed" A/B (kept for the record, do not trust)

Deterministic startup repro: the app hangs while rendering a space that contains a **background port**.

| Condition | Result |
|---|---|
| app opens to an empty space | healthy (~7% CPU, gateway ok) |
| app opens to `testing` (has 1 `presentation='background'` port) | **hang** (101% CPU, gateway timeout, same sample signature) |
| app opens to `testing` with that port flipped `background`→`parked` | healthy (~1% CPU) |

The only variable between hang and healthy was that one port's `presentation` flag ⇒ **the background
port is the trigger.** Every hang sample is the same: main thread in a single non-terminating
`ConversationContent.body` layout transaction (`explicitAlignment` ×1200-1450, `ScrollOffsetKey`/
`VisibleBottomKey` preference machinery, `ChatEntry` copies).

**Mechanism (reconciled with the sample):** `ConversationContent` has a
GeometryReader → preference (`ScrollOffsetKey`/`VisibleBottomKey`) → `onPreferenceChange` → `@State`
→ relayout loop, normally damped by a `>2` guard. A **live port whose layout is entangled with the
conversation** — a background port re-parented behind it (b569002), or a freshly inline-activated port —
shifts the measured geometry by more than 2px every pass, so the guard never latches: preference change
→ deep relayout (the expensive `explicitAlignment` recursion) → new geometry → preference change → 100%
CPU. This re-elevates the preference-loop hypothesis (previously demoted): the reduce itself is cheap
(cold in the sample), but each pass it triggers is a deep, expensive relayout (the hot path). One
mechanism explains both the sample's hot frames and its "cold preference reduce."

**Reconciliation with the original fundemos hang:** fundemos had no background port; there my
freshly-created inline-auto-activating port supplied the per-pass geometry shift (transiently), then that
state was saved. testing's background port supplies it **permanently** (every launch) ⇒ the deterministic
repro. Same loop, two different live-port drivers.

**The synth was a red herring for this repro.** The confirmed trigger is the background port in `testing`
(id `46A02961`, titled "port"), not the SHARED SYNTH (which lives in fundemos). The relentless
`port_push` loop was real but incidental to the startup hang (the host hangs before the loop can reach
it).

**Background-assignment persistence (matters for the fix + un-poisoning):** the background port is
recorded in THREE places — `shell.backgroundPortId` in UserDefaults (`com.port42.dev`, the master),
the panel `isBackground` bool, and the panel `presentation='background'` text. Editing only
`presentation` does NOT stick: on the next launch the shell reads `shell.backgroundPortId` and
re-backgrounds the port (observed: testing went healthy then re-hung after the panel-only edit). To
durably un-poison, clear `shell.backgroundPortId` (and `isBackground`/`presentation`). The fix must also
reckon with this as the authoritative source.

**Note:** fundemos also hangs (no background port there) via a different live-port driver (a freshly
inline-activated port and/or the resumed synth push loop) — same `ConversationContent` loop. So the class
fix (damp/break the loop) is required, not just handling background ports.

**Dev usable via a safe space:** opening an empty space (no background port active) is healthy; that is
the current recovery. Background ports and the live diagram port (in fundemos) are not safe to open until
the fix lands.

---


This is backlog item **2.3** ("app froze mid-demo, every port grey", previously undiagnosed). It
recurred on 2026-07-22 and was captured.

---

## How we got here (the sequence)

1. Ongoing work: the Port42 protocol local bus, Phase L0 (see `plan-port42-protocol-local-bus.md`).
2. Cleared the fundemos chat (surfaced the shared-gateway-store note now in `summer2026-todo.md`).
3. Rendered an architecture diagram **as a web port**, created over the dev bridge:
   `curl :4243 → port.create` into fundemos, on dev instance **pid 35837** (`~/port42-build/
   Port42Dev.app`, built 2026-07-22 09:29, up ~2h24m).
4. The host went to **101% CPU** and stopped answering the gateway; a follow-up `port.manage(close)`
   returned `timeout waiting for host response`. Killed on GM's instruction after the sample was taken.

## Symptom

Main thread pinned at ~100% CPU (process state `R`), bridge calls time out, UI would be grey/unclickable
(the "blocked main actor" signature from the 2.3 write-up). Not a crash, not a deadlock-idle.

## Evidence

### 1. Stack sample (`scratchpad/hang-sample.txt`, `sample 35837 5`)

The main thread is in **one single, non-terminating SwiftUI layout transaction**, not many passes:

- `explicitAlignment` × **1293**, `sizeThatFits` × 339, `childPlacement` × 65 in one stack — a ~339-level
  recursion through `.frame()` alignment resolution (`GraphHost.runTransaction` → `AG::Subgraph::update`
  → `ViewLayoutEngine.sizeThatFits` → `_ZStackLayout`/`_FrameLayout`/`explicitAlignment` → recurse).
- Rooted in **`ConversationContent.body`** (a `closure #2`, i.e. inside the `LazyVStack` `ForEach`);
  `LazyLayoutViewCache.updateItemPhases` present.
- Deep in the same stack: **`GraphHost.startTransactionUpdate` → `AG::Graph::value_set` →
  `NSHostingView.requestUpdate` → `setNeedsUpdate`**, and `_AppearanceActionModifier.MergedBox.update()`
  → a closure → **`outlined destroy of (String?, String?)`** in Port42Dev. That is an `.onAppear`
  firing during the layout pass and writing state (`pendingPortActivationId` is a `String?`), i.e. a
  **re-entrant graph update mid-layout**.
- The scroll preference reduces (`ScrollOffsetKey`/`VisibleBottomKey`) appear at **2 samples each** —
  bystanders, not the hot path. (This refuted an early "preference feedback loop" guess.)

Reads: the app process main thread, **not** a WebContent process (so a port's HTML/JS complexity is not
the layout cost), **not** the gateway.

### 2. The call log (`~/port42-build/Port42Dev.log`)

- Every call is logged as `[sync] received call from local-http: <method> (id=...)`. **The curl call is
  logged** — my `port.create` is call #2512.
- In the last 2000 log lines: **1971 `port_push`, 1 `space.current`, 1 `port.create` (mine).** A
  **relentless `port_push` loop from `local-http` every ~3.14s**, running ~1.7 hours. My create was one
  event out of ~2000.
- A ~3s push loop into a port for over an hour is consistent with a **sequencer driving the SHARED SYNTH**
  (GM's "the synth built up a bunch of shit in its buffer"). 14+ `claude` CLIs are running; the loop is
  one of them (or a loop-engine).

### 3. What was actually open (Port42Dev DB, fundemos)

- **11 messages** — a *light* chat (it had just been cleared). Refutes "heavy accumulated conversation."
- **13 port panels:** 9 parked web ports (VOICE ROOM, OPEN WATER, THE BUS ×2, DRY LAND · CATS,
  ATELIER 3D, ATELIER, PORT42 // Control Room, **SHARED SYNTH**), 2 tiled native terminals (Maker,
  Critic), 1 tiled chat, and my tiled diagram port.

## Hypotheses (ranked; status marked)

1. **[LEADING — sample-backed] Re-entrant SwiftUI update storm from `@State` writes during layout in
   `ConversationContent`.** The port-activation `.onAppear` (`ConversationContent.swift:286-298`) flips
   `cachedActivePortIDs` (swaps a row small→large size-class) and clears `appState.pendingPortActivationId`
   (an `@EnvironmentObject` write) **during** the layout pass; that re-dirties the graph and nests
   transactions. Reachable via the inline-auto-activate path a web `port.create` uses (commit `784d4bf`,
   2026-06-30). Supported by the sample (re-entrancy frames + the `String?` destroy + the single deep
   pass). Not threshold-gated (it hung a *light* chat).
2. **[STRONG — log-backed, target unconfirmed] The SHARED SYNTH driven by a relentless ~3s push loop.**
   1971 pushes/2000 lines over ~1.7h. If the loop targets the synth (very likely, unconfirmed — the
   target is not logged), it drives continuous re-render/height churn of an active inline port, which can
   feed the layout. Note: the hang is **Swift-side layout**, so a WebContent audio buffer is not the
   *direct* cause; the link would be continuous re-render, not the buffer itself.
3. **[AMPLIFIER, not the sink] `ScrollOffsetKey` preference + `.defaultScrollAnchor(.bottom)` geometry
   loop.** Real, but only diverges when content height changes per pass, and the sample shows it cold.
4. **[REFUTED] Port-height width-coupling oscillation.** The tile constrains only height; webview width
   comes from the chat column (no height→width→reflow cycle), plus rAF/threshold/A-B-A JS guards and
   `>1px` native guards. Prior fix documented at `PortWindowManager.swift:1155-1162`.
5. **[REFUTED] Recent regression.** No commit in ~2 weeks touches the hang path; suspect code is March
   (scroll tracker) / June 30 (port-activation `onAppear`). The hung binary ran current code (built today),
   so it is a latent bug in current code, not a fresh one.
6. **[REFUTED] Accumulation of chat rows.** 11 messages = light.
7. **[REFUTED as a factor] My port being "exotic."** ~9KB, flexbox/grid, one click listener, no
   `ResizeObserver`; and the hang is Swift-layout, not the port's WebContent.

**Retires 2.3's two prior guesses:** the permission hang was already fixed (`00053d7`) and nothing in the
stack is permission-related; accumulation-of-conversation is refuted by the DB state.

## Confirmed vs open

- **Confirmed:** the hang is a non-terminating SwiftUI layout transaction on the main thread rooted in
  `ConversationContent`, with re-entrant graph updates from mid-layout state writes; a relentless
  `port_push` loop was running the whole time; the chat itself was light.
- **Open:** whether the trigger is (1) the create's inline-activation re-entrancy or (2) the synth loop
  (or their interaction); and whether the loop's target is actually the synth.

## Blind spots in the current evidence (what to instrument)

- The `[sync] received call` line records method + call id but **not the target port or the data** — so
  the loop's target is not provable from the log.
- The gateway's verbose `RECV … data=` line (which carries the target) is **not captured** anywhere.
- Receipt logging is on the WS read path, so the log continuing past my create does **not** prove the
  main thread was alive after it; the hang onset time is not pinned.
- Nothing logs the host-side layout/re-entrancy.

## Plan (GM: reproduce first, then the other research)

**Step 1 — reproduce (first; no build).** Relaunch dev; run the scenario deliberately: the steady
`port_push` loop into the synth, then ± a `port.create` injected mid-loop; watch CPU and `sample` on
stall. Decides the split:
- loop alone hangs it → synth/loop accumulation (hyp 2), independent of the create;
- only loop + create hangs it → the create × active-loop interaction (hyp 1 × 2).
Precondition: identify and control the push loop (one of the running `claude` CLIs / a loop-engine) so
the repro is deliberate, not ambient.

**Step 2 — instrument + rerun (needs one build; gated on the demo window).** Choice points, cheapest
signal first:
1. `port_push` target + per-port counter (confirms the synth + rate).
2. Main-thread stall watchdog that auto-`sample`s on >2s (the sanctioned 2.3 tool; precedent:
   `LLMStreamCollector`'s max-duration watchdog) — makes every freeze self-document.
3. Layout re-entrancy counter in `ConversationContent` (names the triggering row).
4. Port-activation write log + per-port height-report oscillation counter.

**Step 3 — fix (only after the mechanism is confirmed).** Candidates: move the `onAppear` writes off the
layout pass (`.task`/`DispatchQueue.main.async`); avoid the mid-layout size-class flip; damp/break the
preference loop; bound the synth's runtime state; rate-limit `port_push`.

## FIX APPLIED (2026-07-22, pending live A/B)

`ConversationContent.swift` — break the self-triggered relayout loop (macOS-14-safe; the macOS-15
scroll-offset APIs are unavailable at `.v14`):
- Moved the high-frequency scroll geometry out of `@State` into a reference holder `ScrollTracker`
  (`latestContent`/`latestVisible`). Mutating a reference held in `@State` does not re-render, so the
  per-frame preference stream no longer re-lays-out the message list.
- `refreshNearBottom()` replaces `updateNearBottom()`: writes `@State` (`isNearBottom`) ONLY when the
  bool flips (rare; does not change content height), so it cannot re-drive the loop.
- Deferred the row `.onAppear` port-activation writes (`cachedActivePortIDs` flip +
  `pendingPortActivationId` clear) off the layout pass via `DispatchQueue.main.async`, killing the
  mid-layout re-entrancy the sample showed.

This targets the loop itself, so it retires BOTH drivers (the background port and the inline-activated
port). Validation gate: build, point at `testing` (background port still armed) → must stay healthy;
then `fundemos` → healthy. Note the background assignment persists in `shell.backgroundPortId`
(UserDefaults) + panel `isBackground` — clearing only `presentation` does not un-poison.

## Artifacts

- Sample: `scratchpad/hang-sample.txt`
- Call log: `~/port42-build/Port42Dev.log` (last `port.create` = call #2512)
- Backlog: `summer2026-todo.md` 2.3, `backlog-review-2026-07-20.md` item 2.3
