# Plan: ports show their state and have shapes (v1)

Status: proposed, 2026-09-29. GM has decided that peeks become state cards, that a tile becomes a
card at the peek size, and that shape classes are in v1. The idea is the later-list entry "A port
shares its state, for the shapes where it is not drawn" (`plan-shell-only.md`, GM 2026-09-27), and the
shape classes come from `docs/research/port-shape.md`. The aim is that you do not have to bring a port
forward to know what it is doing, and that the desktop arranges ports by what they are, not as
rectangles of one size.

Two phases, each planned in full before it is built. Each ships on its own.

## The problem

- **A peek is a shrunken window.** At 210x140 a page or terminal is too small to read, so the person
  brings it forward to find out whether it is working, stuck or finished.
- **A hidden port is not drawn at all.** The hidden list and ⌘K give only its title.
- **Port42 drops what terminals tell it.** Ghostty reports a terminal's title, its working directory, each
  command that finishes (exit code and duration), progress bars, the bell and notifications. Port42's
  handler for all of these (`GhosttyApp.swift`, `action_cb`) is a stub that ignores them.
- **Every port is born 620x440**, whatever it is: cramped for a dashboard, arbitrary for a terminal,
  wrong for a document.

## Phase A: state, and peeks as cards

### What each kind of port shows

A card shows the port's title, then up to five lines. The lines depend on the kind of port.

**A terminal** shows what Port42 knows, with nothing to declare:
- a companion's terminal: working, waiting or idle, and for how long; what it is doing (the activity
  summary the presence strip shows); messages waiting for it;
- the running command or the terminal's title (the program sets it, e.g. Claude Code's task name);
- the last command that finished: its exit code (a failure stands out) and how long it took;
- a progress bar when the program reports one (OSC 9;4), as a bar on the card;
- the working directory, shortened (`~/port42-native`);
- the bell or a notification since the person last looked.

**A browser** shows its page title, the site (host), a load bar while it loads, and whether it is
playing sound.

**A web port** shows the lines it declares with `port.state.set`, then Port42's own: error and warning
counts from its console.

Every kind can also declare lines, and a declared line comes first. A companion's terminal can say
"progress: 3 of 5" as well as Port42 showing that it is working.

### The declaring call

`port.state.set` takes an ordered list of lines, each a label and a value.
- From a page: `port42.state.set([{label: "doing", value: "building the join card"}])`.
- From an agent: `port42 port.state.set port=<id> lines:=[...]`.
- `port.state.get` reads a port's lines (declared and Port42's), so a lead can see its engineers
  without asking.
- Only the port itself, or a caller that may write to the port, can set its state, as for `port.update`.
- Capped at 5 lines and 80 characters a value. Kept in memory: a port declares again when it runs.

### Where it shows

- **Peeks are cards,** always (GM). Clicking a card does what clicking a peek does today.
- **A tile at or below the peek size is a card.** Today the smallest tile (220x160) is just above it, so
  in practice this is peeks. It applies automatically if tiles can shrink further later.
- **The hidden list and ⌘K** show each port's first line beside its title ("poller · last run 2m
  ago"), and ⌘K searches the lines too.

### Web ports that draw themselves by size

A web port already gets its on-screen size in the `presentation` event. `ports-context.txt` and the
ports skill get a short section on switching to a compact layout below a width, like a responsive site.

### Checks

- Registry tests: `port.state.set` and `port.state.get` declared with schemas, the generated references
  regenerated, refused for a caller without write access, the caps held.
- Terminal: Ghostty's title, working directory, command-finished and progress actions reach the port's
  state; a test per action through the handler, calibrated.
- Browser: title, URL and load progress reach the state.
- Cards: a peek renders the card; a tile above the peek size renders live content.
- Hidden list and ⌘K show the first line, and ⌘K matches on it.
- ImagineTeamScenarioTests green. Live on Dev5: a web port declaring state, a companion working, a
  terminal running a failing command, a browser loading, each as a peek, hidden and in ⌘K.

## Phase B: shape classes

A port declares what shape it is, from a small closed set, the way it declares capabilities. The layout
uses it; nothing measures the content.

| Class | For | Layout |
|---|---|---|
| `columns` | terminals, logs | width snaps to whole columns, height to rows |
| `aspect` | a shader, a game, a video, a map | its width-to-height ratio is kept when resized or focused |
| `reading` | a document, a chat, a transcript | narrow and tall: width capped at a comfortable line length |
| `dense` | a dashboard, a CRM, a table | wide; placed in the widest free space |
| `free` | no opinion | today's behavior |

- **Where the class comes from,** in order: the person's resize (it sticks, as a hand-placed position
  does), what the port declares (`shape` on `port.create`, or `port42.shape.set("aspect", {ratio: 16/9})`
  later), what its type implies (terminal: `columns`; browser and web: `free`).
- **Birth size** is set by the class and the space free on the desktop, not one constant.
- **Placement** looks for the kind of space the class wants: a full-height gap for `reading`, width for
  `dense`.
- **Resizing** snaps a `columns` port to whole columns and keeps an `aspect` port's ratio.
- **Focus** keeps an `aspect` port's ratio instead of filling the focus frame.
- **⌘L (arrange)** groups by class: terminals in an even grid, reading ports in a column, a dense port
  in the wide slot.

### Open questions for Phase B's plan

- A port that changes what it is (a generative page that becomes a dashboard) declares again. Check that
  this does not move the tile under the person.
- The smallest useful size per class, and whether a `dense` port that cannot fit is better parked.
- The column width for a terminal, from its font size, so the snap is exact.

### Checks

- Pure layout tests: birth size per class and area, placement by class, column snapping, ratio kept
  on resize and focus, ⌘L grouping.
- The class is declared through the registry (schemas, generated references, refused without write
  access).
- Live on Dev5: a terminal snaps to columns; a shader keeps its ratio; ⌘L lays out a mixed desktop by
  class.

## Not in v1

- State in the galaxy view.
- A terminal's git branch, and other facts Port42 does not track.
- Keeping declared state across a restart.
