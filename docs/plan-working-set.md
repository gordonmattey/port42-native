# Plan: The working set — Rest/Wake spaces · ⌘` port cycling · ⌘⌥Tab space switcher

*2026-07-14, spec'd with gordon (all four forks his calls: fully-silent rest, MRU cycling,
hold-release HUD, Rest/Wake naming). Status: **PLANNED** — not started.*

Three daily-driving features with one theme: controlling what's in front of you. The galaxy
stops being "every space ever"; the keyboard cycles ports and spaces without leaving the flow.

---

## A. Rest / Wake — the working set

Every space is either in the **working set** (galaxy front, ⌘1–9, switcher, peeks live) or
**at rest** (off the front, no index, fully silent). "Archive" is the wrong word — a rested
space is alive-but-dormant: sync continues underneath, nothing is lost, it just can't reach
for your attention.

### Data
- `spaces.restedAt` — nullable timestamp, **migration v40** (append-only, per convention).
  nil = working. Timestamp (not bool) so the shelf can sort by recency of resting.

### Behavior
- **Galaxy:** the front grid renders working spaces only. A dim, collapsed **shelf** row at
  the bottom ("N resting") expands to the rested worlds, each with its quiet unread count.
  Clicking a resting world wakes it + enters it.
- **Fully silent:** `ShellState.refreshNotifications` (chat peeks) and `handlePortCreated`
  (port-birth peeks) skip rested spaces entirely. Unread counts still accumulate — visible
  only inside the expanded shelf.
- **Indexes:** ⌘1–9 and the space switcher (C) cover the working set only, in working-set
  order. **⌘K** always finds rested spaces, labeled "resting"; selecting one wakes + enters.
- **Affordance:** the space settings card (long-press its galaxy world) gains **"Rest this
  space"**; on a rested space the same slot reads **"Wake"**.
- **Guards:**
  - Resting the *current* space lands you in the most recent working space (MRU stack, C).
  - ~~The last working space cannot be rested.~~ REVERSED (GM, 2026-07-14, during Tier C):
    any working space may rest, including the last — an all-rested galaxy is an empty front
    with a full shelf, and resting the space you're in (with no other working) keeps you in it.

## B. ⌘` port cycling

Cycle the current desktop's units without touching the mouse.

- **Order: MRU by `z`** (the z-stamp is already the recency signal) — one tap bounces
  between the two hot ports, like macOS ⌘\`. **⇧⌘\`** reverses.
- **Scope:** tiles only (chat included). No peeks, no parked, no backgrounded.
- **At `.space`:** raise + select the next unit (`bringToFront`) with a brief accent flash
  so the landing is visible.
- **At `.focus`:** swap which unit is focused, in place — no zoom-out bounce. (Free under
  the port-units model: focus is a geometry state; changing the focused id resizes the next
  unit's own view.)
- **Cycle stability:** naive MRU re-sorts on every raise (A and B just swap ranks 1↔2, so a
  third tap can't reach C). During a cycling *burst* (chords < ~1s apart) the order is
  snapshotted at the first tap and walked; the burst commits one MRU update when it ends.

### The yield wrinkle (load-bearing)
Today `shouldYieldKey` hands **every** key to a focused terminal/webview — ⌘` would die
exactly when it's most useful (you're typing in a terminal). Introduce **shell-global
chords** — ⌘\`, ⇧⌘\`, ⌘⌥Tab (+ ⌘Tab under takeover) — that bypass the editor yield in the
key monitor. Everything else (plain keys, Esc, all other ⌘-combos) keeps today's yield
behavior; ports never lose a keystroke they currently receive.

## C. ⌘⌥Tab space switcher

The app-switcher gesture, for spaces.

- **Hold ⌘⌥ → HUD**: a horizontal strip of world orbs (mini galaxy rendering: accent orb +
  name), **MRU order** — most recent space first. Tab advances, ⇧Tab reverses, releasing ⌘
  commits to the highlighted space, Esc cancels. Rested spaces excluded.
- **MRU stack:** `ShellState` keeps a session recency stack of visited space ids, pushed on
  every space change (selectSpace/jumpToSpace/switcher/⌘K), seeded from spaces order at
  launch. Also consumed by A's "rest the current space" guard.
- **Release detection:** the shell's local monitors gain `.flagsChanged` (today: magnify,
  mouseMoved, keyDown) to see the ⌘ key-up while the HUD is open.
- **⌘Tab under takeover:** when fullscreen takeover is ON, add `.disableProcessSwitching`
  to the kiosk presentation options — macOS stops eating ⌘Tab and the same switcher answers
  it. Windowed mode leaves ⌘Tab to macOS; ⌘⌥Tab works in both.
- **Platform risk (the one open question):** `.disableProcessSwitching` behavior needs live
  validation under our takeover setup. Degrades gracefully — if it's unreliable, ⌘Tab stays
  with macOS and ⌘⌥Tab covers both modes; nothing else in the feature depends on it.

---

## Gates

- **Tier A (headless):**
  - rest/wake round-trip persists (v40 column); rested space absent from working-set
    queries; wake restores.
  - silence: `refreshNotifications` + `handlePortCreated` produce no peek for a rested
    space; unread still accumulates.
  - guards: last-working-space refuses rest; resting the current space selects the MRU
    working space.
  - cycle order: MRU-by-z next/prev math incl. the burst snapshot (pure function).
  - switcher MRU stack: push/dedupe/seed; rested excluded.
  - shell-global chord classification (pure: chord × editor-focused → shell vs yield).
- **Tier C (gordon):** shelf feel in the galaxy (collapse/expand, quiet counts, wake+enter);
  ⌘` from *inside* a focused terminal; focus-rung cycling feel; HUD hold-release timing;
  ⌘Tab under takeover; ⌘K wake path.

## Sequencing

Three independent commits, in order: **A (rest/wake) → B (port cycle) → C (switcher)**.
B lands the shell-global-chord mechanism that C reuses; C's MRU stack is also consumed by
A's current-space guard, so A ships with a minimal recency fallback (first working space)
that C upgrades.
