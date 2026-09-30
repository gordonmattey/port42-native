# Plan: the rail gets out of the way (#192)

Status: DONE, 2026-09-29 (Gordon: "lock it in"). Commits d44feff, 8719ecc, 8474ab2; ships in the next release. Board card #192 (Gordon: a port under the rail is behind it and cannot be
resized; he wants that space for the port).

## The problem

The rail is 140 wide and always drawn over the right edge of the desktop. A tile that reaches under it
is hidden there and its right edge cannot be grabbed, so that strip of the screen is lost to the rail
even when nothing is running or paused.

## What it does

- **Folded by default to a thin edge** (12 points) along the right of the desktop. Tiles are placed up to
  that edge, and a tile under the folded rail is fully usable: click, resize, drag.
- **The edge shows what matters**: a red dot when a running port needs you (its card's dot is red), so
  folding never hides a problem.
- **It opens over the desktop** (140 wide, as today), at once, when the pointer touches the edge or sweeps
  quickly toward it (from 160 points out; a slow approach leaves it folded so a tile's edge beside it can
  be resized), for the whole of a tile drag so the drop zones are there, and for 4 seconds when a running
  port newly needs you. It folds the moment the pointer is off it (Gordon, trying it: open instantly,
  open ahead of a move to the edge, shut as soon as you are off it).
- Opening it covers tiles for the moment it is open; it never moves or resizes them.

## Not in this

- A setting to keep the rail always open (add it if it is missed).
- Zooming into a running port from the rail (#191, next).

## How it is checked

- Pure layout tests: the placement work area uses the folded width; the drop zones use the open width
  during a drag.
- A test that the edge's dot is red when any running port's card needs attention, and quiet otherwise.
- Live on Dev6: a tile dragged to the right edge stays resizable under the folded rail; resting on the
  edge opens it; dragging a tile opens it and each drop zone still works; a failing running port shows
  the red dot on the folded edge. Screenshots.
