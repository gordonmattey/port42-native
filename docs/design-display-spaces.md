# Spaces on several displays (#189)

Design for showing a different Port42 space on each connected display: the person arranges which
space is on which screen, and each screen shows its own space at the same time. The same person and
the same Port42; not sharing. Not built.

- **Status:** proposal. The model is GM's (2026-09-29): "multi displays hardware, so when you arrange
  you can have multiple spaces on multiple screens, so its space to desktop display mapping." Free
  floating windows per space are out. GM's decisions (2026-09-29): a port in two spaces is live on
  every display that shows it, and an agent that names no space works in the space on the display the
  person is using.
- **Base:** read against `main` at `ccaa8a5`. Nothing built or run.
- **Related:** the later list's "spaces across several displays" (live media plane).

## How it works today

- One window: a single `WindowGroup` (Port42App.swift) hosting one `ShellView`, which creates one
  `ShellState`. `ShellMode.applyShellWindow` (ShellMode.swift:69) styles it: the takeover fills one
  display and hides the Dock and menu bar through `NSApp.presentationOptions`, which is app-wide.
- One current space: `AppState.currentSpace` means two things at once, the space on screen and the
  default space for anything that names none (an API caller without `space_id`, `/imagine`, invites,
  the imagine box, new ports from the dock).
- Per-space already: tile positions (per desktop, v46), adoption (`adoptedSpaceIds`), pins, each
  space's chat. These carry over unchanged.
- Nothing knows about displays. The only screen reads are `NSScreen.main` (VoiceHUD) and a terminal
  asking which screen its window is on (GhosttyTerminalView.swift:222).
- One place at a time: a port's live surface (a WKWebView, or a Ghostty terminal view) is a single
  AppKit view, so it can be in one window at a time.

## Proposal

### A display shows a space

- Port42 keeps a **display map**: display to space. A display is named by its stable UUID
  (`CGDisplayCreateUUIDFromDisplayID`), which survives reboots and reconnection; its current name
  (`NSScreen.localizedName`) is what the person sees.
- Each mapped display gets one shell window on that display, with the takeover applied per window
  (full display, no title bar). The window is the display's; the person does not move or resize it.
- `ShellState` gains `spaceId`: the space its display shows. Everything a window draws (desktop, rail,
  peeks, space chat, zoom, focus) reads its own `ShellState`, not `appState.currentSpace`.
- A space is on at most one display. Putting a space on a display that another display is showing
  swaps the two.

### Arranging

- **The galaxy is the arranger.** Zooming out on any display shows the galaxy there; picking a space
  puts it on this display (a swap if it is on another one). This is today's gesture, now per display.
- **Settings → Displays** shows the connected displays as a row of screens, each with its space, and
  lets the person drag a space onto a screen. It also has "Use one display only", which returns to
  today's single window on the main display.
- ⌘K on a space: brings it to the display it is on, or puts it on the display the pointer is on.
- A display with no space mapped shows nothing from Port42 until the person picks one from its
  galaxy. A new display is not filled automatically.

### Displays coming and going

- **Unplugged:** its window closes, its space keeps running (as a space you switched away from does
  today), and the map keeps the entry. Its ports stay reachable from the galaxy on any other display.
- **Plugged back in:** the display's window comes back on the same space, unless that space is now
  on another display, in which case it shows nothing until the person picks.
- **At launch:** each connected display that has a map entry opens on its space. With no entries,
  the main display shows the last space, as today.

### What is shared, and where it shows

- `AppState.currentSpace` becomes the space of the key display (the display with the window the
  person last clicked or typed in). Every "default space" path keeps working and follows the person,
  agents included (GM): as today, where it is the space the person is in.
- App-level overlays (a permission card, the imagine box, the share box, Settings, voice) show on the
  key display.
- The Dock and menu bar: the takeover hides them app-wide, as today. How the takeover behaves on the
  second display with the macOS setting "Displays have separate Spaces" on and off is not measured
  yet; phase 2 measures it and Settings → Displays says what the person needs, if anything.
- Peeks: a peek for activity in space B is raised on every display not showing B. A display showing B
  needs no peek.
- A port adopted or pinned into two spaces that are on screen at the same time is live on both
  displays (GM). See "One port, live on two displays" below.
- The API: `space.switchTo` puts the space on the key display. A display-aware call is phase 3.

## One port, live on two displays

A port's live surface is one AppKit view, so a port on two displays needs a second live view of the
same port. The two views are the same port: one identity, one set of grants, one storage, one chat,
one console.

- **Web port:** a second WKWebView loading the same code. `PortBridge` holds one web view today
  (`PortBridge.swift:10`); it holds a list, sends every event to each view, and answers each view's
  calls as the port. What is not shared is what lives in the page's own memory: a variable, a
  canvas, an unsaved field. Each view runs its own copy of the page's script, so work the script
  does on its own (a timer that calls an AI model, a poll) runs twice while the port is on two
  displays, and costs twice. A port that keeps its state in port storage looks the same on both.
- **Terminal:** Port42 starts the shell inside the Ghostty surface today (exec mode). The GhosttyKit
  build Port42 ships (the cmux fork) also has a manual mode: the app owns the shell's pseudo-terminal,
  feeds its output to a surface (`ghostty_surface_process_output`) and receives its keystrokes
  (`io_write_cb`). In that mode one shell can feed two surfaces, and typing in either reaches it. A
  shell has one size, so it takes the size of the display last typed in, and the other surface shows
  it at that size. Not measured: the switch from exec to manual mode for companion terminals, and how
  two surfaces of different sizes read. A spike measures both before phase 1 builds it.
- **Browser port:** a second WKWebView on the same page, in the same website data store, so it is
  signed in wherever the first is. Navigation is kept in step: the URL observer the browser port
  already has (`PortBrowserURLObserver`) sends a navigation in either view to the other. Scroll
  position, a half-filled form and where a video is up to are each view's own. Sound comes only from
  the display last used, so a playing video is not heard twice.

## Built so far (phase 1a)

- `ShellState.spaceId`: each window shows its own space. The window in use (`appState.shell`, the key
  shell) shows `currentSpace`; the others hold theirs (`heldSpaceId`). A space is on one window at a
  time: switching the window in use to a space another window shows swaps the two.
- `DisplaySpaces` (Services/DisplaySpaces.swift): the display map (display UUID to space, kept in
  UserDefaults with the other window preferences rather than the database), a borderless window per
  mapped display showing its own `ShellView`, restored at launch and when a display is plugged back
  in; an unplugged display's window closes and its space keeps running.
- Arranging: the space card (hold a space in the galaxy) lists the other connected displays, "Show on
  <display>" and "Stop showing on <display>". Settings → Displays is still phase 2.
- Keys, menu commands and pinch act in the window they happen in; hold-to-talk stays with the main
  window's shell, which owns the one voice session.
- A port shown by two windows at once is live in the window in use; the other window says "live on
  the other display" and a click brings it over. The second live view per display (GM's decision 1)
  is phase 1b, after the terminal spike.

## Phases

1. **Display map and windows:** the map (display UUID to space, kept in the database), one takeover
   window per mapped display, `ShellState.spaceId`, the galaxy as arranger per display, `currentSpace`
   from the key display, overlays on the key display, peeks per display, web and browser ports live
   on two displays. The terminal spike runs first; terminals on two displays follow its result.
2. **Arranging and hot-plug:** Settings → Displays, unplug and replug, restore at launch, the
   "separate Spaces" measurement.
3. **API:** `display.list` (displays, names, their spaces) and `space.switchTo` with an optional
   `display`, with the scope and docs that come with any new method.

## Tests (headless)

- The map: putting space A on display 1 and then on display 2 moves it (a swap if display 2 had one);
  a space is never on two displays.
- Hot-plug as pure state: removing a display keeps its entry and closes nothing in the space; adding
  it back restores it, or leaves it empty when its space is now elsewhere.
- `ShellState` per display: two states on two spaces keep separate zoom, peeks and space chat state.
- `currentSpace` follows the key display: the default space for `port.create` and `chat.post` with no
  `space_id` is the key display's.
- Peeks: activity in space B raises a peek on the display showing A, and none on the one showing B.
- One port on two displays: an event reaches both views; a call from either view is the same port
  (same principal, same storage); closing one display's view leaves the other live.
- ImagineTeamScenarioTests unchanged.

Manual checks (displays are hardware): two displays, a different space on each, swap them from the
galaxy, unplug one and plug it back, quit and relaunch. Dev instances cannot share a display with the
daily driver's takeover, so this is checked with the takeover off or on a machine of its own.

## Decided (GM, 2026-09-29)

1. A port in two spaces that are both on screen is live on every display that shows it, whatever its
   kind. The cost is above: a web port's own script runs once per display.
2. An agent that names no space works in the space on the display the person is using, as it works in
   the space the person is in today.
