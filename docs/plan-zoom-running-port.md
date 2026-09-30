# Plan: zoom into a running port (#191)

Status: built on Dev6, 2026-09-29, for Gordon to try. Board card #191 (Gordon: "zoom into running ports and
pop them up, and then zoom out will pop them back in").

## The problem

A running port (in the rail's Running section) has one action today: a click shows it, which puts it back
on the desktop as a tile for good. To glance at one, or answer it, you have to show it and then drag it
back into the rail.

## What it does

- **Hover a Running card and click its magnifier: the port pops up**, zoomed to focus, as a peek does.
  It has the keyboard, so you can type into it. A click on the card itself still shows it (keeps it).
- **Zoom out (⌘↑, Esc, pinch, or clicking the space pill): it pops back into Running**, in the slot it
  came from. Nothing else on the desktop moves.
- **A click on it in zoom view keeps it** as an ordinary tile (Gordon). The same now holds for a peek you
  zoomed into: a click keeps it, and zooming out without one sends it back.
- A popped-up port in another space takes you to that space first, as Show does now.

## Not in this

- Popping up a Paused port (a paused port is slowed; Show stays its action).
- Several popped up at once. Popping another replaces the first, which goes back to its slot.

## How it is checked

- State tests: a click leaves the port running (hidden) with a zoom on it; zoom out returns it to its old
  slot; Keep makes it a tile; popping a second returns the first.
- Live on Dev6: pop up a running terminal, type into it, zoom out, and it is back in its slot; Keep one and
  it stays. Screenshots.

## Decided

1. Keeping is a click, as for peeks, not a button (Gordon, 2026-09-29).
