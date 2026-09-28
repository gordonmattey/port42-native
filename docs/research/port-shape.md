# Ports have shapes, and the layout does not know it

Against `nautilus` at `51eab10`, 2026-09-26. A design note. Sibling to the layout work in
`docs/design-shell-layout.md`, which fixed *when* tiles move; this is about *what shape they should
be*.

## The goal is not tiling, it is not switching

Every window manager optimizes for arranging windows. That is the wrong objective, and it is why both
of the big ones feel like work: macOS gives you Stage Manager, multiple desktops, drag-and-drop and a
few fixed grids; Windows gives you richer snap layouts and more of them. Both leave you switching,
because both are arranging containers whose contents they cannot see.

Port42's objective is the opposite one: **you should not have to bring something forward to know what
it is doing**. Peeks exist for exactly this. So the layout's measure of success is not how neat the
grid looks, it is how rarely you reach for something that is already open.

That reframing has a concrete consequence. A layout that is tidy but hides the thing you are watching
has failed, and a layout that is uneven but keeps the shader, the log and the chat all visible has
succeeded.

## What the system knows today: nothing

- `port.create` accepts `type`, `html`, `url`, `command`. **No size, no shape, no intent.**
- Every port is born `defaultTileSize`, 620x440 (`PortPlacement.swift:65`), whatever it contains.
- A port can declare `capabilities` about itself, but nothing about its geometry.
- A terminal sizes in pixels, although its natural unit is columns and rows. The code notes the
  mismatch: "ghostty_surface_set_size takes PIXELS (width_px, height_px), NOT cols/rows"
  (`GhosttyTerminalView.swift:159`).

One size for everything was the right call for placement, because placement needed a number and
arguing about per-type constants would have stalled it. It is the wrong long-term answer, because
620x440 is fine for a shader, cramped for a CRM, arbitrary for a terminal and useless for a document.

## The proposal: a port declares intent, not size

A small closed vocabulary, declared the way capabilities are declared. The author knows what the
thing is; the layout never has to guess.

| Class | Means | Layout behavior |
|---|---|---|
| `columns` | character-grid content | width quantizes to cells (80, 100, 120 columns are meaningful), height to rows |
| `aspect` | a shader, a game, a video, a map | ratio is locked; resize preserves it |
| `reading` | a document, a chat, a transcript | comfortable line length caps the width; height is what it wants, full height is the ideal |
| `dense` | a CRM, a dashboard, a table | needs width; below a threshold it is not cramped, it is a different design |
| `free` | no opinion | today's behavior |

Three sources, in precedence order: the **port declares** it, the **type implies** a default (terminal
to `columns`, browser to `free`), and the **user overrides** by resizing, which should stick the way
`userPlaced` will make a hand position stick.

## What changes in the layout

Small changes, because the placement work already reads occupancy.

- **`place()` scores gaps against intent, not just area.** A `reading` port looks for a full-height
  gap before a large square one. A `dense` port looks for width. Today the largest gap wins for
  everyone, which is right when nothing is known and wrong once something is.
- **Birth size becomes a function of class and available space**, not a constant. A `reading` port
  born on a 1626x931 work area should be tall and narrow, not 620x440.
- **Resize quantizes or locks.** Dragging a terminal snaps to whole columns, which is what makes a row
  of terminals look deliberate instead of approximate. Dragging a shader keeps its ratio.
- **⌘L groups by class instead of dealing one uniform grid.** Terminals in a grid of equal cells,
  readings in a column, the one `dense` port in the wide slot. That is a tidy that respects what
  things are, which is the difference between an arrangement and a shuffle.

## The trap to avoid

**Do not infer shape by measuring the content.** Reading the DOM to decide a tile's size is tempting
and it is a race: the content changes, the measurement chases it, the tile twitches, and the user
loses trust in a layout that moves on its own. That is the same failure the arrange work just
removed, arriving through a different door. Declaration is stable. Measurement is not.

## Why this is the actual differentiator

An operating system's window manager cannot know that this window is a document and that one is a
shader. It arranges rectangles because rectangles are all it has. Port42 does know, because the
content is a port and a port can say what it is.

So "better window management" is not the pitch and should not be. Every OS is already trying that and
the ceiling is low. The pitch is that **the surfaces describe themselves, so the desktop can arrange
meaning instead of rectangles**. Stage Manager cannot get there from where it stands, and neither can
snap layouts.

## Open

- **Does a class survive a port's content changing?** A generative port that becomes a dashboard was
  declared as something else five minutes ago. Probably the author redeclares; worth confirming that
  redeclaring is cheap and does not move the tile under the user.
- **What is the minimum useful size per class**, and what happens below it? A `dense` port on a small
  window may be better parked than shown.
- **Does intent replace `defaultTileSize` or refine it?** A default per class is still a constant,
  just five of them.
- **How does this interact with focus?** A focused unit already takes 0.78 x 0.8 of the area
  (`ShellPlacement.focusRect`). An `aspect` port focused should probably keep its ratio rather than
  fill that box.
