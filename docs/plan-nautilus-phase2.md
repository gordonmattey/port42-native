# Nautilus Phase 2: arranging

Detailed plan for Phase 2 of `plan-shell-only.md`. Scenario served: 5. Written 2026-09-25 against
`nautilus` at `e8ea3df`, with Phase 1 complete and the harness at five of five.

## Goal

Ports stay where the person put them, a closed port can come back as itself, the rail keeps the
order it is given, and the background costs nothing when nobody can see it.

## Decisions for GM

Each step below is buildable on its recommendation; these are the calls that change what gets built.

1. **What ⌘L does to a hand-placed port.** Recommended: ⌘L grids the ports nobody placed and leaves
   hand-placed ones where they are, laying the rest around them; ⇧⌘L re-grids everything and forgets
   the hand placements. Alternative: ⌘L re-grids everything and nothing is remembered (today).
2. **Where a closed port is found again.** Recommended: a "Recently closed" section at the bottom of
   the ⌘K switcher, newest first, and `port.manage(id, "reopen")` for agents. Alternative: a closed
   section in the park rail.
3. **Whether closed ports are ever purged.** Recommended: never automatically; the ⌘K entry carries a
   "delete forever" action. Alternative: purge after a fixed age.
4. **When the background pauses.** Recommended: when the window is fully occluded or minimized, when
   a port is set as the wallpaper, and while a port is focused (the backdrop covers the desktop).
   Not when the app is merely inactive, since the background is still on screen then.

## What is measured

- **Arranging.** A birth places and moves nothing (`placeUnpositioned`); ⌘L runs `applyArrange`, which
  re-grids every tile on the desktop by creation order and overwrites hand positions. Positions are
  per desktop (v46). Nothing records that a position was chosen by hand.
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

### 2.1 Hand-placed ports stay put

- A port records, per desktop, that its position was chosen by hand. A drag or resize commit sets it;
  placement, clamping and ⌘L do not. Stored beside the per-desktop positions (migration v52).
- ⌘L lays out only the ports not placed by hand, treating hand-placed rects as occupied, so the grid
  flows around them. ⇧⌘L clears the flags on this desktop and re-grids everything (decision 1).
- `port.move` from an agent counts as placed by hand: a caller that chose a spot meant it.

*Gates:* ⌘L leaves a hand-placed tile's origin unchanged and places the rest without overlapping it;
⇧⌘L moves it and clears the flag; the flag is per desktop; it survives a restart.

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

- The `TimelineView` pauses (`paused:`) under decision 4's conditions, from one computed predicate on
  `ShellState` so every case goes through the same rule. Window occlusion comes from
  `NSWindow.occlusionState`.
- Measured before and after on Dev3 idle, with the same method as the 2026-07-29 sweep: the window
  visible and uncovered (expected unchanged), a focused port, a wallpaper port, and the window hidden.
  The figures go in this plan; no target is set before measuring.

*Gates:* the pause predicate is pure and tested for each condition, and false for an uncovered,
visible desktop.

## Verify, live on Dev3

- The harness passes five of five after every step. Scenario 5 gains three checks: ⌘L leaves a
  hand-placed port where it is, a closed port reopens with its id, and a park at a chosen slot holds
  across the restart it already does.
- GM tries each step on Dev3: drag, ⌘L, ⇧⌘L; close and reopen from ⌘K; park into a slot; watch the
  background pause behind a focused port.

## Not in this phase

The desktop's chat (deferred from Phase 1). Multi-display. The chrome as ports.
