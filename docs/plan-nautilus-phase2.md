# Nautilus Phase 2: arranging

Detailed plan for Phase 2 of `plan-shell-only.md`. Scenario served: 5. Written 2026-09-25 against
`nautilus` at `e8ea3df`, with Phase 1 complete and the harness at five of five.

## Goal

Ports stay where the person put them, a closed port can come back as itself, the rail keeps the
order it is given, and the background costs nothing when nobody can see it.

## Decided (GM, 2026-09-25)

1. **⌘L goes.** A birth already places without moving anything and off-screen ports are clamped back,
   so the only thing ⌘L still does is overwrite positions the person chose. The arrange button and
   the re-grid go with it.
2. **A closed port is found again in ⌘K**, under "Recently closed", newest first; agents reopen with
   `port.manage(id, "reopen")`.
3. **Closed ports are never purged automatically.** The ⌘K entry carries "delete forever".
4. **The ambient background pauses only when none of it can be seen:** the window hidden, minimized
   or fully occluded, or a wallpaper port drawn over it. It keeps running behind a focused port,
   which dims it but does not hide it. (This is the animated scene, not a port set as the wallpaper;
   a wallpaper port always runs.)

## What is measured

- **Arranging.** A birth places and moves nothing (`placeUnpositioned`); a resize clamps only what is
  off-screen. ⌘L, the chrome's arrange button and a dozen internal `bumpArrange` callers run
  `applyArrange`, which re-grids every port by creation order and overwrites hand positions.
  Positions are per desktop (v46).
- **Closing.** `PortWindowManager.close` tears down the surface and deletes the `port_panels` row. The
  port's versions survive in `port_versions` under its udid, and its chat survives until the next
  launch reaps it. The id is gone: anything subscribed to it, or holding it, is left pointing at
  nothing.
- **The rail.** Parked ports are listed in `panels` order (creation). A drop anywhere on the rail
  parks the port at the end. The `dockOrder` column exists and is always written nil.
- **The background.** `ShellBackground` is a `TimelineView` capped at 24 fps. Measured on Dev3,
  2026-07-29, idle: uncapped 27.4% of a core, 24 fps 9.6%. It never pauses, including behind a
  focused port, behind a wallpaper port, and with the window hidden.

## Steps

Each step is its own commit: suite green, harness five of five, plans updated.

### 2.1 ⌘L goes

- Remove ⌘L, the chrome's arrange button, `bumpArrange` and its internal callers, and
  `applyArrange`. Each caller is checked first: any that relies on a re-grid to place a port it just
  made moves to `placeUnpositioned`, which places without moving anything.
- Exposé stays: it spreads ports temporarily and writes nothing back.

*Gates:* no path re-grids ports that already have a position (a source scan that fails if
`applyArrange` or `bumpArrange` returns); a spawn, park, unpark and adoption each place only the new
port; the pure grid tests that covered `arrange` go with it.

### 2.2 Closing never destroys

- Close becomes archive: the surface is torn down and every acquisition released exactly as today,
  but the row stays, marked closed (migration v52 adds `closedAt`). A closed port is on no desktop,
  in no rail, and out of `ports.list` unless asked for (`include_closed`).
- Reopen restores it with the same id and udid on its home desktop, at its last position: a web
  port reloads its current version, a browser its URL, a terminal relaunches its command in its cwd.
  Its chat is kept, since it belongs to the port.
- Reached from ⌘K "Recently closed" and `port.manage(id, "reopen")` (decision 2). "Delete forever"
  is the only path that removes the row, its versions and its chat (decision 3).
- The launch reaps change meaning: the orphan-chat reap keeps chats of closed ports, and a port whose
  space is deleted is deleted with it.
- A reopened port keeps its activity token counter (it never rewinds), so a write composed against
  the pre-close state is still refused.

*Gates:* close then reopen returns the same id with its html and position; a subscriber holding the
id receives events again after reopen; a closed port is absent from the desktop, rail and default
`ports.list`; a pre-close token is refused after reopen; delete forever removes row, versions and
chat.

### 2.3 Parking places exactly

- The rail keeps an explicit order in `dockOrder`, per space. Dropping a port on the rail inserts it
  at the slot under the pointer; dragging a chip within the rail reorders it. Unparking leaves a gap
  that closes up.
- Existing parked ports get their current order written once on first read.

*Gates:* a drop at slot 1 of 3 lands at slot 1; a reorder persists across a restart; order is per
space.

### 2.4 The background costs nothing unseen

- The ambient background's `TimelineView` pauses (`paused:`) under decision 4, from one predicate on
  `ShellState` so every case goes through the same rule. Window occlusion comes from
  `NSWindow.occlusionState`.
- Measured before and after on Dev3 idle, with the same method as the 2026-07-29 sweep: the window
  visible (expected unchanged), a focused port (expected unchanged, it keeps running), a wallpaper
  port, and the window hidden.
  The figures go in this plan; no target is set before measuring.

*Gates:* the pause predicate is pure and tested for each condition; it is false for a visible
desktop and behind a focused port.

## Verify, live on Dev3

- The harness passes five of five after every step. Scenario 5 gains two checks: a closed port
  reopens with its id, and a park at a chosen slot holds across the restart it already does.
- GM tries each step on Dev3: drag and spawn with nothing moving; close and reopen from ⌘K; park
  into a slot; the background still moving behind a focused port.

## Not in this phase

The desktop's chat (deferred from Phase 1). Multi-display. The chrome as ports.
