# Shell — build spec (against `Port42Lib`)

A forward spec for the Port42 GUI shell. The design is demonstrated end-to-end in the throwaway kiosk
`prototypes/p42shell`; this is how to build it for real on `Port42Lib`. Companion to:

- `plan-port42-shell.md` — the product/architecture plan (ambient-surface layer model, Chrome §7a,
  kiosk/boot tiers). **What** the shell is.
- `plan-uniform-port-create.md` Step 8 — the no-reload re-parent primitive (one registry webview moved
  between hosts). **The mechanic** the shell relies on.

The prototype is a working reference for *interaction design and structure*. Build the plumbing on the
real services (`AppState`, `PortWindowManager`, `port.create`, companions, `ChatView`), which are
richer than the prototype's stand-ins.

---

## 1. The design

**A space is a room — people + companions, and the desktop of ports their conversation produces.**

- **Spaces are the only level.** A flat list of spaces; no modes/groups. Each space has its own accent,
  dock preset, companions, and chat.
- **Chat is a port.** Each space has a native chat surface (the `isChatPort` panel) with a **member
  header** — *you* + the space's companions — showing live companion status (idle / thinking / porting).
- **Companions are a primitive of the space.** They appear in the chat member row and on each space's
  galaxy world — not as global chrome. One companion may belong to several spaces (sharing one status).
- **The loop:** a chat message → a companion thinks → it opens ports → tiles appear on the desktop and
  it replies → the desktop auto-arranges. The conversation drives the desktop.
- **Ports are registry-owned webviews with four presentations**, re-parented between hosts with no
  reload (DOM/JS state preserved):
  - `inline` — hosted in a chat row (Step 8).
  - `floating` — its own `NSPanel` window (pop-out).
  - `tiled` — a tile on the space's desktop canvas.
  - `parked` — minimized to a chip in the right-edge dock.
- **Zoom ladder: galaxy → space → focus.** Galaxy shows all spaces as worlds (responsive grid, max 3
  across); a space shows its desktop of tiles; focus is one port immersive. Drive it with `⌘↑/↓` or a
  trackpad pinch (one rung per gesture). In galaxy, hovering a world and zooming in dives into it.
  Exposé (`Tab`) is an orthogonal grid view of the current space's tiles.
- **Two docks, distinct jobs.** The bottom launcher **creates** ports; the right-edge rail **parks**
  (minimizes) them — drag a tile into the right strip to park, click a chip to restore. Opening a port
  (dock / palette / chat) auto-arranges the desktop.
- **One ambient surface.** The dreamscape is the screensaver, lock screen, and desktop background; idle
  dissolves the chrome + ports back into it, any input wakes them.
- **Chrome (top bar).** PORT42 mark top-left (in the borderless window's freed traffic-light gap); a
  single ✨ + active-space-name unit toggles the galaxy; arrange + exposé controls beside it; the global
  status/action cluster (gateway / tunnel / key / pause / usage / settings) on the right.

---

## 2. Mapping to `Port42Lib`

| Design element | In the prototype | Build with |
|---|---|---|
| One webview per port, re-parented | `Registry` + `AdoptingHost` | `PortWindowManager.webViews[id]` + `PortWebViewHost` |
| A port | `Port` | `PortPanel { id, html, bridge, spaceId, position, size, presentation }` |
| Presentation (inline/floating/tiled/parked) | `Presentation` enum | `PortPanel.presentation` (extend Step 8's `inline`/`floating` with `tiled` + `parked`) |
| Chat surface | `ChatTile` / `ChatMsg` | the `isChatPort` panel hosting `ChatView`; messages are `Message` |
| Companion | `Companion` (name/color/glyph/status) | `AgentConfig`; status from the real typing/tooling indicators |
| Space membership (multi-space) | `Companion.spaces: Set<String>` | `agentSpaces` / `getAgentsForSpace(spaceId)` |
| A space | `SpaceDef` (name/accent/dock/seed) | `Space` (DB) + per-space accent/dock/seed config (§6) |
| Open a port | `Shell.spawn` | `appState.createPort(type:…, presentation:"tiled", position:…)` + auto-arrange |
| The companion loop | scripted `respond()` | send a `Message` → companion (`AgentConfig`/`LLMEngine`) replies → it calls `port.create` |
| Switch space | `Shell.switchSpace` | `appState.selectSpace(...)` + `portWindows.switchToSpace(spaceId, name)` |
| Pop out / dock back | `popOut` / `dockBack` | `promoteInlineToFloating(id:)` / a `dockToTile(id:)` (Step 8 re-parent, both ways) |
| Park / restore | `park` / `unpark` | set `panel.presentation` `"parked"`/`"tiled"` + re-parent webview + arrange |
| Shell-only UI state | `Shell` singleton fields | a `ShellState` `ObservableObject` (§3.2) |
| Ambient background | `Dreamscape` (Canvas) | `DreamscapeVideoLayer` / `TransitionRoot` (Layer 0) |
| Wake / boot | `Boot` | `AquariumBreakoutView` / `TransitionPhase` (Layer 1) |
| Chrome status cluster | hardcoded icons | the live bindings in `ContentView.swift`, re-parented (§7a) |

---

## 3. Engineering

### 3.1 Input (kiosk)

The shell is a **pure kiosk**: one borderless fullscreen `ShellWindow` is the app — no
`NavigationSplitView`; sheets/QuickSwitcher are shell overlays or absent. Input is handled by two
app-global `NSEvent` monitors (mouse incl. `.magnify`, + key), which is correct for a single-window
kiosk. Two guards make it robust against the few real auxiliary surfaces (pop-out `NSPanel`, settings
sheet, text fields, webview `contenteditable`):

1. **Yield keys to the focused field.** Before swallowing a shortcut key, check `window.firstResponder`;
   if an `NSTextView`/`WKWebView` is editing, pass the key through.
2. **Window-scope the mouse monitor.** Ignore events whose `e.window` isn't the shell window before
   running hover/drag/pinch (the monitor computes coords against the shell window's `contentView`).

**Pinch** drives the zoom ladder: accumulate `e.magnification`, fire **one rung per gesture** (a latch
reset on `.began`), consume the event, and set `webView.allowsMagnification = false` so webviews don't
also zoom.

**⌘K** belongs to the shell palette (QuickSwitcher is absent in the kiosk). Idle resets on shell-window
input; the dreamscape parallax reads mouse position read-only.

*Optional upgrade (not required):* move tile mouse interaction into a dedicated
`ShellCanvasInteractionView: NSView` (own bounds/coords, `NSTrackingArea`, threshold-armed drag,
click-through, terminal/chat body-vs-edge exception) and window-scope shortcuts via
`performKeyEquivalent`/`.keyboardShortcut`. Worth it only if the shell ever coexists with other real
windows.

### 3.2 State

`AppState` (the single `@MainActor ObservableObject`) owns spaces, ports, persistence, companions, and
gateway/tunnel/key status. Add one `ShellState` `ObservableObject` for shell-only UI state: zoom level
(`galaxy`/`expose`/`focusId`/`selectedId`/`galaxyHover`), `idle`, mouse parallax, toast, boot phase,
`draggingOverPark`, and the pinch accumulator/latch. `ShellState` reads `AppState`; it never duplicates
ports/spaces/companions. It is created when shell mode activates and owned by `ShellView`.

### 3.3 Content + the companion loop

Every tile is a **registered port**: dock / palette / companions call `appState.createPort(...)` so the
port has a real `PortBridge` (the `port42.*` API), an id, and is addressable by `port.push`/`ports.list`.
`createPort` needs a **`tiled` presentation + `position`** (generalize Step 8's `inline` routing flag
into `inline | floating | tiled`). Terminal tiles are real Ghostty ports
(`port.create({type:"terminal"})`). Dock entries are data (saved/favorite ports or templates).

The companion loop is **real, not scripted**: a `Message` is sent → the space's companion(s)
(`AgentConfig` / `LLMEngine`) reply → a companion calls `port.create` to place tiles → auto-arrange. The
prototype's think → port → reply → arrange choreography is the UX target; the real engine drives it.

### 3.4 Robustness

Guard display access: `guard let screen = NSScreen.main else { … }` with a fallback frame (`main` is nil
with no active display or in some locked states).

---

## 4. Subsystems

*How to build each, plus the gotcha.*

**Ports & the four presentations.** `PortWindowManager.webViews[id]` + `PortWebViewHost`; presentation
is `inline | floating | tiled | parked`. All re-parent the same webview (`removeFromSuperview` /
`addSubview`; the host must not recreate it — `dismantleNSView` no-op, stable `.id`). A port is in
exactly one host at a time. Tiled ports carry a desktop z-order (in `PortPanel`/`ShellState`) for the
canvas ZStack.

**Companions & chat (the heart).** The chat surface is the per-space `isChatPort` panel hosting
`ChatView`. The **member header** renders *you* + `getAgentsForSpace(spaceId)` as chips with live status.
A companion shared across spaces has one status (one agent, one state). The member row **wraps** to as
many lines as needed (a `Layout` flow), never a horizontal scroll. The send → reply → `port.create` →
arrange loop is §3.3.

**Spaces.** `appState.spaces` (DB) + per-space accent/dock/seed config; `switchToSpace(spaceId, name)`
swaps per-space ports; the desktop is `panels.filter { spaceId == current && presentation == "tiled" }`.
The chat is the per-space `isChatPort` panel — a prominent, larger tile, seeded first.

**Zoom ladder.** Rungs galaxy ↔ space ↔ focus, on `ShellState`. Galaxy renders all spaces as worlds
(name, accent, port count, companion members) in a responsive grid (max 3 across); hovering a world
arms it so zoom-in dives into that space; clicking enters; `selectedPort` (hover/click) is what focus
zooms into. Focus and a tile both want one webview — moving to focus re-parents it out of the tile and
back on exit (no reload).

**Parking dock.** A right-edge rail (`parkWidth = max(64, screenW*0.05)`) holds parked ports as chips.
Dragging a tiled port into the right strip parks it on mouse-up + auto-arranges; clicking a chip restores
it to tiled + auto-arranges; the parked webview stays in the registry (no reload on restore). The rail is
faint when idle, highlights on hover, strongest on drag-over, and is inset below the chrome so it never
covers the header. **Exclude `.parked` ports from the desktop render AND from `arrange`/`exposé`** (a
`desktopTiles` = non-parked computed). Park detection is the full-height right strip in window coords.

**Two docks.** Bottom launcher = create (gaussian-magnified, → `createPort`); right rail = park. Every
user-initiated open auto-arranges the desktop into a grid; seeding on space-entry does not.

**Chrome (§7a).** Re-parent the live status/action cluster from `ContentView.swift`
(gateway/tunnel/key/pause/usage/settings + New Space/Companion), bound to `appState`. PORT42 mark in the
freed traffic-light gap. The ✨ + space-name unit toggles the galaxy; arrange/exposé sit beside it with
adequate hit targets.

**Tile interaction.** Hit-testing, threshold-armed drag, edge-resize cursors, hover-focus
(focus-follows-mouse); terminal/chat bodies are interactive (move via titlebar only). Operate on
`panels` + `position`/`size`; persist on drag-end.

**Ambient surface & idle.** Layer 0 `DreamscapeVideoLayer`/`TransitionRoot`; Layer 1
`AquariumBreakoutView` for wake. An idle timer dismisses Layer 2 → Layer 0 via the existing lock path;
it resets on shell-window input only.

---

## 5. Persistence

Tiled and parked ports persist (the desktop/dock layout): `persistPanel`/`restoreFromDB` with
`presentation` + `position`. Inline ports are not persisted (Step 8). On restart, tiled ports restore
into the canvas and parked ports into the rail, per space, composited into `ShellView`. Per-space
accent/dock config and space-companion membership are persisted; chat is the per-space `isChatPort` panel.

---

## 6. Open decisions

1. **Per-space accent + dock + seed** — new `Space` fields, a side table, or `ShellState` config? Each
   space needs an accent, a dock preset, and a default layout.
2. **`createPort` presentation** — generalize the `inline` routing flag into `inline | floating | tiled`
   (+ `position`), and make `parked` a settable presentation. One clean change.
3. **Multi-display** — one desktop on the main display with secondaries blank, or a tile desktop per
   `NSScreen`? (`presentationOptions` hides the Dock globally.)
4. **Window strategy** — start by taking the existing app window fullscreen (fastest proof), then
   graduate to a dedicated borderless `ShellWindow`.

---

## 7. Phasing

Each ships runnable behind `PORT42_SHELL=1` (default off, reversible). **The spine comes first** — the
ambient surface (Layer 0) and the zoom ladder are foundational (they frame every other surface and the
"zoom out to swim in open water" first-run rides on them), so they're built before the desktop fills
with tiles. (Mirrors `plan-port42-shell.md` §8 S1–S5.)

- **S1 — Takeover + ambient surface.** App window → fullscreen, hide Dock/menu bar, escape hatches
  (Esc / ⌘Q / exit, restore on terminate), guarded `NSScreen.main`. `ShellView` root =
  `DreamscapeVideoLayer` (Layer 0) as the living desktop background. Real chat/ports, no new UI yet.
- **S2 — Spatial shell: spine + port desktop + Chrome.** Build the **spine first**: the zoom ladder on
  `ShellState` (galaxy ↔ space ↔ focus; ⌘↑/↓ + pinch one-rung + hover-dive), reusing the dive
  transition (`TransitionRoot`/`diveProgress`) as the zoom animation; galaxy renders `appState.spaces`
  as worlds; `switchToSpace` + ⌘1…N. (Demoable immediately on the existing per-space chat port.) Then
  fill the space rung: render tiled `PortPanel`s via `PortWebViewHost`; build the Chrome (§7a); dock/⌘K
  spawn real tiled ports + auto-arrange. Lands `ShellState` DI (§3.2) + real content (§3.3).
- **S3 — Movable tiles + park + tile↔floating.** Drag/resize/hover/focus; the parking dock; pop-out =
  `promoteInlineToFloating` (tile↔floating). A counter/terminal tile keeps state across tile↔float↔park.
- **S4 — Companions + chat.** The per-space `isChatPort` tile + member header (you + `getAgentsForSpace`)
  with live status; the real send → companion → `port.create` → arrange loop. Members wrap.
- **S5 — Idle-out + boot fusion.** Idle timer dismiss → Layer 0, wake via breakout; fuse the onboarding
  BIOS boot with the shell boot.

---

## 8. Out of scope

- Kiosk boot tiers (LaunchAgent / MDM ASAM / lockdown) — `plan-port42-shell.md` §6/§8.
- Cross-restart *live-webview* persistence — tiled/parked ports restore from the panel record by
  re-rendering, not a serialized live view (same scope cut as Step 8).
- Drag-*out* from the parking rail (click-restore is the first cut).
- Foreign-window management (dragging Finder/Chrome in). macOS has no cross-process window reparenting,
  so embedding a foreign app is impossible; arranging foreign windows via the Accessibility API is a
  separate future capability. Browser and files are better as native ports (a web port; an `fs.*` files
  port).
- Multi-display tiling (§6.3).
