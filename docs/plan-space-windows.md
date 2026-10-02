# Plan: space windows (#189, changed from "one space per display")

Status: built on `rc/1.0.7` and checked by Gordon on two displays, 2026-10-01. Gordon, testing #189 on two displays: the second display's
window could not be moved ("whats the downside?"), and agreed: the window is the unit, not the display,
so several spaces can be open on one screen.

## The model

- A **space window** is a view onto one space, besides the main window. Any number, on any screen.
- Each remembers its own **screen, position and size**. Dragging it to another screen moves it there, and
  it reopens there next launch.
- A space is in **one window at a time** (a port has one live surface). Picking, in one window, a space
  another window shows swaps the two, as before. The same space live in two windows is phase 1b.
- It looks and behaves like the main window in windowed mode: titled with the title hidden, no traffic
  lights, movable, resizable (`ShellMode.restoreWindow`'s look).

## What changes

1. `DisplayMap` (display → space) becomes `SpaceWindowMap`: a list of `{id, space, display, frame}`.
   Pure, tested without hardware. The old map migrates: each display's space becomes a window filling that
   screen's visible frame.
2. Opening: the space card's "Show on <display>" opens a window on that display (the window that already
   shows the space moves there; the main window, if it shows it, takes a free space as today). New:
   "Open in a new window", on the main window's screen.
3. Closing: ⌘W, or the card's "Close this window" (any screen) or "Stop showing on <display>", closes the
   window and forgets it. A display
   unplugged closes its windows but keeps them, so they return when it is plugged back in.
4. Moving and resizing are recorded as they happen (window move, resize and screen-change notifications).
5. The galaxy marker says "on <screen>" for a space in a window on another screen, and "in another window"
   for one on the same screen.
6. Restore at launch: every remembered window on a connected screen opens with its frame, kept inside that
   screen's visible frame.

7. File → New Window (⇧⌘N): with a window open, a new window opens in its galaxy with no space of its own
   until the person picks one; it never makes a space. Picking a space another window shows moves it here,
   and that window waits in its galaxy. With no window open, it brings the main window back (as do the Dock
   icon, Window → Port42 Window ⌘0, and a launch that restores none). A galaxy pick acts on the window it
   is made in.

## Not in this

The same space in two windows (phase 1b). Window tabs. Per-window zoom memory across launches.

## Checked by

Pure tests of the map (open, move, close, swap, migration, frame clamp); the existing window tests; the
full suite; then Gordon on two displays.
