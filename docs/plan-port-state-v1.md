# Plan: ports render by their size and shape (v1)

Status: proposed, 2026-09-29, reworked with GM the same day. The idea is the later-list entry "A port
shares its state, for the shapes where it is not drawn" (`plan-shell-only.md`, GM 2026-09-27) and
`docs/research/port-shape.md`. The aim is that you do not have to bring a port forward to know what it
is doing, and that the desktop lays ports out by the shape they want, not as rectangles of one size.

Two phases, each planned in full before it is built, each shipping on its own.

## The problem

- **A port looks the same at every size.** Shrunk to a peek (210x140) a page or terminal is a miniature
  too small to read, so the person brings it forward to learn whether it is working, stuck or done.
- **A hidden port is not drawn at all.** The hidden list and ⌘K give only its title.
- **Port42 drops what terminals tell it.** Ghostty reports a terminal's title, its working directory,
  each command that finishes (exit code and duration), progress bars, the bell and notifications.
  Port42's handler for these (`GhosttyApp.swift`, `action_cb`) is a stub that ignores them all.
- **Every port is born 620x440**, and nothing records whether it wants to be wide, tall or square.

## Phase A: a port renders by its size and shape

### Size tiers and orientation

Port42 puts every drawn port in a size tier and an orientation, from its on-screen size:

| Tier | When (on screen) | What shows |
|---|---|---|
| `card` | narrower than 320 or shorter than 200 | the port's state, not its content |
| `compact` | narrower than 560 or shorter than 360 | the content, laid out small |
| `full` | anything larger | the content |

| Orientation | When |
|---|---|
| `wide` | width at least 1.6 times the height |
| `tall` | height at least 1.33 times the width |
| `square` | between the two |

A peek is 210x140, so a peek is a `card` and shows the card straight away. Nothing about peeks is
special: any port drawn at card size renders its card, and grows back into its content when it is made
bigger. The thresholds live in one place and are tuned on Dev5.

The `presentation` event every web port already receives gains `tier` and `orientation` beside the
`w` and `h` it has, so a page does not have to invent its own breakpoints.

### What renders at each tier

**Terminals and browsers**: Port42 draws them, so Port42 draws their card. At `compact` and `full`
they show their live content as today.

**Web ports** choose:
- A page that draws its own card declares so (`shape.renders: ["card"]` in Phase B terms, or
  `port42.shape.set({renders: ["card"]})`). It gets the tier in the `presentation` event and renders
  itself.
- A page that does not gets Port42's card over it at `card` size, filled from its declared state and
  its console.
- At `compact` a page lays itself out small if it wants to, like a responsive site. `ports-context.txt`
  and the ports skill get a section on using `tier` and `orientation`.

### What a card says

A card shows the port's title, then up to five lines, laid out by orientation: a `wide` card runs its
lines as one strip, and a `tall` or `square` card stacks them. Declared lines come first, then what
Port42 knows:

- **A terminal:**
  - for a companion: working, waiting or idle, and for how long; what it is doing (the presence
    strip's activity summary); messages waiting for it;
  - the running command, or the title the program sets (Claude Code sets its task name);
  - the last command that finished: exit code (a failure stands out) and duration;
  - a progress bar when the program reports one (OSC 9;4);
  - the working directory, shortened;
  - the bell or a notification since the person last looked.
- **A browser:** the page title, the site, a load bar while loading, and whether it plays sound.
- **A web port:** error and warning counts from its console.

### Declaring state

`port.state.set` takes an ordered list of lines, each a label and a value, from a page
(`port42.state.set([{label: "doing", value: "building the join card"}])`) or an agent
(`port42 port.state.set port=<id> lines:=[...]`). `port.state.get` reads a port's lines, declared and
Port42's, so a lead sees its engineers without asking. Only the port or a caller that may write to it
can set its state, as for `port.update`. Capped at 5 lines and 80 characters a value; kept in memory,
since a port declares again when it runs.

### Unseen ports

The hidden list and ⌘K show each port's first line beside its title ("poller · last run 2m ago"),
and ⌘K searches the lines.

### Checks

- Tiers and orientation: a pure function from a size, tested at the thresholds; the `presentation`
  event carries both.
- Terminal: each Ghostty action (title, working directory, command finished, progress, bell) reaches the
  port's state, one test each through the handler, calibrated.
- Browser: title, URL and load progress reach the state.
- Rendering: a port at card size renders its card, and above it renders live content; a web port that
  declares it draws its own card gets no overlay.
- Registry: `port.state.set` and `port.state.get` with schemas, the generated references regenerated,
  refused without write access, the caps held.
- The hidden list and ⌘K show the first line, and ⌘K matches on it.
- ImagineTeamScenarioTests green. Live on Dev5: a web port declaring state, a companion working, a
  terminal running a failing command, a browser loading, each as a peek, a small tile, hidden and in ⌘K.

## Phase B: shapes

A port declares the shape it wants. Two things, independent of each other:

1. **Orientation**: `landscape`, `portrait`, `square` or `any`, optionally with an exact `ratio`. This
   matters for every kind of port: a dashboard can be a wide wall or a tall phone-like column, a chat
   is tall, a video is 16:9.
2. **Behavior**, which says how it resizes:
   - `columns`: width snaps to whole character columns, height to rows (terminals, logs);
   - `reading`: width capped at a comfortable line length (documents, chat, transcripts);
   - `fixed-ratio`: the ratio is kept when resized or focused (shaders, games, video, maps);
   - `free`: today's behavior.

Declared as `shape` on `port.create`, or later with `port42.shape.set({orientation: "portrait"})`.
Defaults by type: a terminal is `landscape` and `columns`; a browser `landscape` and `free`; a web
port `any` and `free`. When the person resizes a port, their size sticks, as a hand-placed position
does.

What the layout does with it:
- **Birth size** from the orientation, the behavior and the space free on the desktop, not 620x440.
- **Placement** looks for space of the right shape: a tall gap for `portrait`, a wide one for
  `landscape`.
- **Resizing** snaps `columns` and keeps a `ratio`.
- **Focus** keeps a `ratio` instead of filling the focus frame.
- **⌘L (arrange)** groups by shape: terminals in an even grid, portrait ports side by side as columns,
  a landscape port in the wide slot.

### Open questions for Phase B's plan

- A port that changes what it is declares again; check that this does not move the tile under the
  person.
- The smallest useful size per shape, and whether a port that cannot fit is better parked.
- A terminal's column width from its font size, so the snap is exact.

### Checks

- Pure layout tests: birth size per shape and area, placement by orientation, column snapping, ratio
  kept on resize and focus, ⌘L grouping.
- `shape` through the registry (schemas, generated references, refused without write access).
- Live on Dev5: a portrait web port is born tall and placed in a tall gap; a terminal snaps to columns;
  a shader keeps its ratio; ⌘L lays out a mixed desktop by shape.

## Not in v1

- State in the galaxy view.
- A terminal's git branch, and other facts Port42 does not track.
- Keeping declared state across a restart.
