# Plan: the rail gets out of the way (#192)

Status: built on Dev6, 2026-09-29, for Gordon to try (hover and drag need a person). Board card #192 (Gordon: a port under the rail is behind it and cannot be
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
- **It opens over the desktop** (140 wide, as today) when the pointer rests on the edge, and while a tile
  is being dragged, so the Paused, Running and trash drop zones are there when you need them. It folds
  again shortly after the pointer leaves or the drag ends.
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
