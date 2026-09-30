# Plan: zoom into a running port (#191)

Status: planned, 2026-09-29, waiting on Gordon's go. Board card #191 (Gordon: "zoom into running ports and
pop them up, and then zoom out will pop them back in").

## The problem

A running port (in the rail's Running section) has one action today: a click shows it, which puts it back
on the desktop as a tile for good. To glance at one, or answer it, you have to show it and then drag it
back into the rail.

## What it does

- **Click a Running card: the port pops up**, zoomed to focus, as a peek does. It is live: type into the
  terminal, click the page.
- **Zoom out (⌘↑, Esc, pinch, or clicking the space pill): it pops back into Running**, in the slot it
  came from. Nothing else on the desktop moves.
- **Keep it on the desktop**: while it is popped up, Keep in its title bar makes it an ordinary tile, as
  Show is today.
- A popped-up port in another space takes you to that space first, as Show does now.

## Not in this

- Popping up a Paused port (a paused port is slowed; Show stays its action).
- Several popped up at once. Popping another replaces the first, which goes back to its slot.

## How it is checked

- State tests: a click leaves the port running (hidden) with a zoom on it; zoom out returns it to its old
  slot; Keep makes it a tile; popping a second returns the first.
- Live on Dev6: pop up a running terminal, type into it, zoom out, and it is back in its slot; Keep one and
  it stays. Screenshots.

## Decision for Gordon

1. How to keep a popped-up port on the desktop. Recommendation: a Keep button in its title bar, the same
   word peeks use. The alternative is dragging the card out of the rail onto the desktop, which also
   needs the rail's cards to become draggable.
