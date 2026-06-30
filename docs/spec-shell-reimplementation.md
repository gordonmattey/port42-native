# Spec — re-implementing the shell prototype against `Port42Lib`

**Status:** spec, ready to build against. Derived by reading `prototypes/p42shell` (**rev8**) in full and
mapping it onto the real types in `Sources/Port42Lib`. This is the **prototype → production**
translation layer. It sits between the two existing docs and does not replace either:

- `plan-port42-shell.md` — the *product/architecture* plan (layer model, reuse map, Chrome §7a,
  phases S1–S5, kiosk/boot tiers). **WHAT** the shell is.
- `plan-uniform-port-create.md` Step 8 — the *re-parent mechanic* (one registry webview, moved
  between hosts with no reload). The load-bearing primitive the shell stands on. **HOW** ports move.
- **this doc** — the *engineering spec* for rebuilding the prototype's view/interaction layer on the
  real services: type mappings, the substance corrections, subsystem-by-subsystem. **HOW** to port it.

The prototype is a **spec you re-implement**, not code you import. Its structure is clean; its
*substance* is throwaway (singletons, demo HTML, fake models, in-memory state, app-global input).
Rough split: ~40% reusable design (the view + interaction layer), ~60% scaffolding the real app
already supplies better.

### What the prototype proves (rev3 → rev8 evolution — the design is settled)

The exploration converged on a concrete, opinionated design. Build to THIS, not the rev2 sketch:

- **A space IS a room — people + companions in a conversation.** Chat is the heart; the desktop of
  ports is what the collaboration produces. (rev3, rev5)
- **Chat is just a port** — a native conversation surface seeded per space, with a **member header**
  (you + the space's companions) and live companion status. (rev3, rev5)
- **Companions are a primitive of the space**, not global chrome — shown in the chat's member row and
  on each space's galaxy world; one companion can belong to **several spaces**. (rev4, rev5, rev6)
- **The loop:** a chat message → a companion *thinks* → *ports* → tiles appear and it replies, then the
  desktop auto-arranges. The conversation drives the desktop. (rev3)
- **ONE flat level — spaces. No modes.** A "mode" was a meta-space; the second hierarchy cost more than
  it gave. Each space carries its own accent + dock + companions + chat. (rev6 — resolves the old §6.1)
- **Zoom ladder: galaxy (all spaces) → space desktop → focus (one port).** ⌘↑/↓, **pinch** (one rung
  per gesture), and in galaxy **hover a world + zoom-in dives into it**. (rev6, rev7)
- **Two docks, distinct jobs:** bottom launcher = **create** new ports; right-edge rail = **park /
  minimize** existing ones. (rev8)
- **Parking** is a third presentation (`.parked`) — drag a tile into the right ~5% strip to minimize it
  to a chip; click to restore. Registry keeps the webview alive (no reload), same re-parent as pop-out.
  (rev8)

---

## 1. Keep / Drop ledger

Read against `prototypes/p42shell/Sources/p42shell/main.swift` (rev8).

| Prototype symbol | Verdict | Why |
|---|---|---|
| `Registry` (singleton, one WKWebView per UUID) | **DROP** → `PortWindowManager.webViews[id]` | the real registry already owns webviews, with bridge/console/nav/height wiring |
| `AdoptingHost` (NSViewRepresentable, no-op `dismantleNSView`) | **DROP** → `PortWebViewHost` | identical adopt-don't-recreate host, proven in Step 8 |
| `Port` model | **DROP** → `PortPanel` | real model has id/presentation/spaceId/position/size/bridge/persistence |
| `Presentation { tiled, floating, parked }` | **MERGE** → `PortPanel.presentation` | Step 8 has `inline`/`floating`; shell adds `tiled` (desktop canvas) + `parked` (right dock) — a 4-way |
| `Shell` (singleton state) | **DROP** → `AppState` + a new `ShellState` | spaces/ports/persistence/companions are AppState's; only shell-only UI state is new |
| `SpaceDef` (name/accent/dock/seed) | **DROP** → `Space` (DB) + per-space accent/dock config | flat spaces are real; accent/dock/seed become per-space config (new small fields or a side table) |
| `Companion` (name/color/glyph/`spaces: Set`/status) | **DROP** → `AgentConfig` + space membership (`agentSpaces`) | companions + space membership already exist; `status` (idle/thinking/porting) maps to the real typing/tooling indicators |
| `ChatMsg` + `ChatTile` | **DROP** → `Message` + `ChatView` / `isChatPort` panel | chat is already a per-space surface; the member header is the new bit |
| `Apps.all` + 6 HTML ports (`clock`/`pulse`/`sys`/`term`/`matrix`/`synth`) | **DROP** | demo content; real tiles come from `port.create` / saved ports / companions |
| `term` (fake contenteditable shell) | **DROP** → real Ghostty terminal port (`port.create({type:"terminal"})`) | |
| `PopoutPanel` | **DROP** → `PortNSPanel` + `popOut`/`promoteInlineToFloating` | real panel has hover/close/persist already |
| Global `NSEvent` monitors (mouse incl. `.magnify` + key) | **KEEP + 2 guards** (see §3.1) | app-global is fine in a TRUE kiosk; just yield keys to the focused field + ignore events not in the shell window |
| `NSScreen.main!` force-unwraps | **REWORK** → guarded | crashes a real app when `main` is nil; never the kiosk |
| `Dreamscape` (Canvas starfield/synthwave) | **DROP** → `DreamscapeVideoLayer` / `TransitionRoot` (Layer 0, done) | the real ambient surface exists; the Canvas was a stand-in |
| Zoom ladder (`galaxy`/`expose`/`focusId`/`selectedId`/`galaxyHover` + `unwind`/`pinch`) | **KEEP (reimplement)** | net-new shell UX, no real equivalent — faithful re-implementation on `ShellState` |
| Parking (`.parked` + `park`/`unpark` + `draggingOverPark` + `ParkRail`) | **KEEP (reimplement)** | net-new; a 4th presentation + a right-edge minimize dock |
| `Chrome`, `Dock`, `DockIcon`, `Palette`, `GalaxyView`, `SpaceWorld`, `FocusOverlay`, `Tile`, `ChatTile`, `MeChip`/`CompanionChip`/`CompanionStatusRow`, `ParkRail`, `Mark`, `Boot`, `FlowLayout` | **KEEP (reimplement)** | the view layer is the value; rebind to real state, wire actions to `port.create`/`switchToSpace`/companions |
| `arrange()` / `exposeRect()` / `tileRect()` / dock magnification / pinch accumulator | **KEEP (reimplement)** | pure layout/interaction math, portable as-is |
| ~~`SpaceRail`~~, ~~`SpacesOverview`~~, ~~`SpaceCard`~~, ~~`ModeDef`~~, ~~`ModeWorld`~~ | **GONE in rev8** | flatten removed modes + the spaces-in-mode middle layer + the left sidebar; galaxy + ⌘1…N replace them |

---

## 2. Type mapping (prototype → `Port42Lib`)

```
Registry.shared.web(id, html)        →  appState.portWindows.webViews[id]            (via registerInlinePort / popOut / a tiled-create)
AdoptingHost(id:html:)               →  PortWebViewHost(webView: webViews[id], bridge: panel.bridge)
Port(app, pos, z, space)             →  PortPanel { id, html, bridge, spaceId, position, size, presentation, z? }
port.presentation .tiled/.floating/.parked → panel.presentation "tiled"/"floating"/"parked"  (+ "inline" in chat context)
port.kind == .chat                   →  panel.isChatPort (ChatView host)
Shell.spaces[i] (SpaceDef)           →  appState.spaces[i] (Space) + per-space accent/dock config
Shell.crewIn(s)                      →  agents assigned to that space (agentSpaces / getAgentsForSpace)
Companion.status (.thinking/.porting) → the real typing / "is porting" (tooling) indicators
Shell.chat[key] (ChatMsg[])          →  db.getMessages(spaceId:) (Message[]) rendered by ChatView
Shell.send(text) → respond → spawn   →  send a Message → companion (AgentConfig) replies → companion calls port.create (the REAL loop)
Shell.switchSpace(s)                  →  appState.selectSpace(...) + portWindows.switchToSpace(spaceId, name)
Shell.spawn(app)                      →  appState.createPort(type:…, presentation:"tiled", position:…)  (see §3.3) + auto-arrange
Shell.park(p)/unpark(p)              →  set panel.presentation "parked"/"tiled" + re-parent webview + arrange
Shell.close(p)                        →  portWindows.close(panel.id)
Shell.focus(p) / z bump               →  portWindows.bringToFront(id) (+ a desktop z-order field — see §4)
popOut() / dockBack()                 →  promoteInlineToFloating(id:) / a new dockToTile(id:)  (Step 8 re-parent, both ways)
Dreamscape()                          →  DreamscapeVideoLayer (Layer 0)
Boot()                                →  AquariumBreakoutView / TransitionPhase (Layer 1)
Chrome status cluster                 →  the real bindings in ContentView.swift (gateway/tunnel/key/pause/usage/settings), re-parented (§7a)
```

---

## 3. The substance corrections

The prototype's *shape* is right; these are where production diverges. They are the real work.

### 3.1 Input — app-global monitors, in a TRUE kiosk vs the transitional cut

**The target is a pure kiosk:** the `ShellWindow` IS the app — one borderless fullscreen window, no
`NavigationSplitView`, sheets/QuickSwitcher reimplemented as shell overlays or gone. The prototype is
already this shape: **single-window**, compositing all tiles inside one content view; the only real
second window it makes is `popOut()`'s floating `NSPanel`.

So in a pure kiosk the prototype's app-global `NSEvent` monitors (mouse incl. `.magnify`, + key) are
**largely fine — nothing else in the app to fight.** The "hijacks the multi-window app" problem is the
**transitional** state (`plan-port42-shell.md` S1: shell toggled on while the old UI is still alive).

**What survives into the pure kiosk — two small guards (NOT a rewrite):**

1. **Yield keys to the focused field.** The prototype swallows **Tab unconditionally** and ⌘K/Esc/⌘J/⌘L
   globally; it survives because its only text inputs are the palette + chat field + HTML
   `contenteditable` (it passes other keys with `return e`). With real fields/forms: before swallowing,
   check `window.firstResponder` — if an `NSTextView`/`WKWebView` is editing, `return e`.
2. **Make the mouse monitor window-aware.** It computes `pt` against the shell window's `contentView`
   always. When the pop-out panel / a sheet is key, ignore events whose `e.window` isn't the shell
   window before running `hoverFocus`/`mouseDown`/drag/pinch.

**Pinch (rev7):** the mouse monitor also matches `.magnify` and drives the zoom ladder — accumulate
`e.magnification`, fire **one rung per gesture** (a `pinchFired` latch reset on `.began`), consume the
event (`return nil`) and set `webView.allowsMagnification = false` so webviews don't also zoom. Port
this as-is; it's kiosk-safe.

**Optional cleaner design (not required by the kiosk):** move tile mouse interaction into a dedicated
`ShellCanvasInteractionView: NSView` (own bounds/coords, `NSTrackingArea`, threshold-armed drag,
click-through, terminal/chat body-vs-edge exception) and window-scope shortcuts via
`performKeyEquivalent`/`.keyboardShortcut`. Textbook shape, but an upgrade — ship the two-guard kiosk first.

### 3.2 State — singletons → DI

`Registry.shared` / `Shell.shared` → injected `@EnvironmentObject AppState` (the app's single
`@MainActor ObservableObject` — spaces, ports, persistence, companions, gateway/tunnel/key status all
live there). Add ONE `@MainActor ObservableObject ShellState` for **shell-only UI state**: zoom level
(`galaxy`/`expose`/`focusId`/`selectedId`/`galaxyHover`), `idle`, `mouse` (parallax), `toast`, boot
phase, `draggingOverPark`, `pinchAccum`/`pinchFired`. `ShellState` reads `AppState`; it does not
duplicate ports/spaces/companions. Created when shell mode activates, owned by `ShellView`.

### 3.3 Content — demo HTML → real ports + the real companion loop

`Apps.all` and the six HTML strings are throwaway. Real tiles are **registered ports**:
- Dock buttons / ⌘K palette call `appState.createPort(type:…, html:…/command:…, spaceId:…,
  presentation:"tiled", position:…)` — every tile gets a real `PortBridge`, id, and is addressable by
  `port.push`/`ports.list`. The prototype's webviews have **no bridge**; production ones must.
- `createPort` needs a **`tiled` presentation** (generalize Step 8's `inline` routing flag into a
  presentation choice: `inline | floating | tiled`, + `position`).
- The fake `term` → a real Ghostty terminal tile (`port.create({type:"terminal"})`).
- **The companion loop is real, not scripted.** The prototype fakes `respond()` with keyword matching.
  In the app: a `Message` is sent → the space's companion(s) (`AgentConfig`/LLMEngine) reply → a
  companion calls `port.create` to put tiles on the desktop → auto-arrange. The prototype's
  think→port→reply→arrange choreography is the UX target; the real engine drives it.
- The dock's app list is data: saved/favorite ports or templates, not a static array.

### 3.4 Robustness — force-unwraps → guarded

`NSScreen.main!` / `.frame` → `guard let screen = NSScreen.main else { … }` with a fallback. `main` is
nil with no active display / some locked states — a long-running app hits these; the kiosk never does.

---

## 4. Subsystem specs

Each: *prototype behavior → real implementation → gotcha.*

**Webview ownership & the FOUR presentations.** Prototype: `Registry` + `AdoptingHost`. Real:
`PortWindowManager.webViews[id]` + `PortWebViewHost`; presentation is 4-way — `inline` (chat row,
Step 8), `floating` (NSPanel, Step 8), **`tiled`** (desktop canvas), **`parked`** (right dock). All
re-parent the *same* webview (move = `removeFromSuperview`/`addSubview`; host must not recreate —
`dismantleNSView` no-op, stable `.id`). *Gotcha:* a port is in exactly one host at a time; switching
presentation is a re-parent, never a second webview. Add a desktop **z-order** field (`port.z`) to
`PortPanel`/`ShellState` for the tiled ZStack.

**Companions & chat (the heart — rev3/4/5).** Prototype: `Companion` (name/color/glyph/`spaces:
Set<String>`/`status`), `ChatTile` with a wrapping member header (`MeChip` + `CompanionChip`), live
`CompanionStatusRow`, the `send`→`respond`→`spawn`+`arrange` loop. Real:
- Chat = the `isChatPort` panel hosting `ChatView`; seed one per space (`ensureChatPort` already does).
  The **member header** is the new piece: render `you` + `getAgentsForSpace(spaceId)` as chips with
  live status from the real typing/tooling indicators.
- Companions = `AgentConfig`; **space membership** = `agentSpaces` (a companion in several spaces is
  already supported). `Companion.status` (.idle/.thinking/.porting) → the real
  typing/"is porting" (tooling) state — the same object/state shared across the spaces it's in.
- The loop is the real send→reply→`port.create`→arrange (§3.3). *Gotcha:* a shared companion has ONE
  status across all its spaces — correct (one agent, one state); the prototype already models this.
- *Layout gotcha (rev6 fix):* the member row must **wrap** (`FlowLayout` / the `Layout` protocol),
  never a horizontal scroll — it breaks past a few companions.

**Spaces (flat — rev6, modes resolved).** Prototype: a flat `spaces: [SpaceDef]`, each with
name/accent/dock/seed; companions are members by space name; ports filtered by `space`. Real:
`appState.spaces` (DB) + per-space accent/dock config (new fields or a side table);
`switchToSpace(spaceId, name)` already swaps per-space ports; desktop = `panels.filter { spaceId ==
current && presentation == "tiled" }`. **No modes** — the old meta-space layer is gone. *Gotcha:* the
chat is a per-space `isChatPort` panel — it's one (prominent, larger) tile in the space, seeded first.

**Zoom ladder (galaxy → space → focus — rev6/7).** Prototype: `zoomUp`/`zoomDown`/`unwind` +
`pinch` + `galaxyHover`; overlays `GalaxyView` (all spaces as worlds, responsive grid, max 3 across) +
`FocusOverlay`. Rungs: **galaxy (all spaces) ↔ space desktop ↔ focus (one port)**; exposé (Tab) is an
orthogonal side-view of the current space's tiles. In galaxy, **hover a world** (`galaxyHover`) then
zoom-in (⌘↓ / pinch-in) **dives into that space**; click also enters; `selectedPort` (hover/click)
is what focus zooms into on the desktop. Keep verbatim as design on `ShellState`; bind worlds to real
spaces (name/accent/port-count/companion-members). *Gotcha:* `FocusOverlay` and the tile both want to
host one webview — moving to focus re-parents it out of the tile and back on exit (no reload).

**Parking dock (right edge — rev8).** Prototype: `presentation == .parked`, `park`/`unpark`,
`draggingOverPark`, `ParkRail` (right ~5% strip; `parkWidth = max(64, screenW*0.05)`). Drag a tiled
port into the right strip → `mouseUp` parks it (chip in the rail) + auto-arrange; click a chip →
`unpark` (back to tiled) + auto-arrange. Rail is faint idle, **highlights on hover** and stronger on
drag-over; **inset below the Chrome** so it never covers the header. Real: `.parked` is the 4th
presentation; the parked webview stays in the registry (no reload on restore — same re-parent as
pop-out); the rail renders parked panels for the current space. *Gotcha:* exclude `.parked` from the
desktop `ForEach` AND from `arrange()`/`exposeRect` (use a `desktopTiles` = non-parked computed). Park
detection is full-height right strip in window coords; the visual rail is inset below the chrome.
*Deferred:* drag-*out* from the rail (crosses AppKit-drag ↔ SwiftUI-button boundary) — click-restore
ships first.

**Two docks (rev8).** Bottom launcher = **create** (gaussian-magnified `Dock`/`DockIcon` → `createPort`,
entries are saved ports/templates). Right rail = **park** (minimize existing). Keep them visually and
functionally distinct. *Auto-arrange:* every user-initiated open (dock / palette / chat) tidies the
desktop into the grid (`spawn` calls `arrange(quiet:true)`); seeding on space-entry stays quiet.

**Chrome (§7a).** Prototype: PORT42 mark top-left; a single **✨ + active-space-name** unit that toggles
the galaxy (the only way up); arrange + exposé buttons beside it (with real 26×26 hit targets — bare
glyphs were finicky); status cluster on the right. Real: re-parent the live status/action cluster from
`ContentView.swift` (gateway/tunnel/key/pause/usage/settings + New Space/Companion), bound to
`appState`. Mark goes in the freed traffic-light gap (borderless window has none).

**Tile interaction (drag/resize/hover/focus).** Prototype: `portHit`, `mouseDown/Dragged/Up`,
threshold-arm, `tileRect`, edge cursors, `hoverFocus`, focus-follows-mouse; terminal/chat bodies are
interactive (move via titlebar only — `interactiveBody`). Real: same logic (app-global monitor + the
two §3.1 guards, or the optional `ShellCanvasInteractionView`), operating on `panels` +
`position`/`size`; persist on drag-end. *Gotcha:* tiled + parked ports persist (real desktop layout) —
the Step 8 "never persist inline" skip stays `inline`-only.

**Ambient surface & idle.** Prototype: Canvas `Dreamscape` + 9s idle timer + boot lines. Real: Layer 0
`DreamscapeVideoLayer`/`TransitionRoot` (done), Layer 1 `AquariumBreakoutView` for wake; idle timer
dismisses Layer 2 → Layer 0 via the existing lock path. *Gotcha:* idle resets on ShellWindow input only.

---

## 5. Persistence

Tiled + parked ports persist (real desktop/dock layout) — reuse `persistPanel`/`restoreFromDB` with
`presentation` + `position`. The Step 8 "never persist inline" guard stays `inline`-scoped. On restart,
tiled ports restore into the canvas and parked ports into the rail, per space (analogous to
`showRestoredFloatingPanels`, composited into `ShellView`). Per-space accent/dock config + space-companion
membership are already (or nearly) persisted; chat is the per-space `isChatPort` panel.

---

## 6. Decisions — resolved + remaining

1. **Modes** — **RESOLVED (rev6): flat spaces, no modes.** A mode was a meta-space; the second
   hierarchy cost more than it gave. Reintroduce grouping later as pinned/favorite spaces or tags if
   scale demands.
2. **⌘K ownership** in shell mode — shell palette vs QuickSwitcher. *Recommend: palette = ⌘K* (in a
   pure kiosk QuickSwitcher is gone, so no conflict).
3. **`createPort` presentation** — generalize Step 8's `inline` routing flag into `inline | floating |
   tiled` (+ `position`), and add `parked` as a settable presentation. The cleanest single change.
4. **Per-space accent + dock + seed** — new `Space` fields, a side table, or `ShellState` config? Each
   space needs an accent, a dock preset, and a default layout.
5. **Multi-display** — one desktop on main + secondaries blank, or a tile desktop per `NSScreen`?
   (Prototype + spikes were single-display.)
6. **Shell window vs. take the main window fullscreen** — start with S1's "take today's window
   fullscreen" (fastest proof), graduate to a dedicated borderless `ShellWindow` (prototype's `KioskWindow`).

---

## 7. Phasing

Aligns with `plan-port42-shell.md` S1–S5; adds the prototype-derived detail. Each ships runnable behind
`PORT42_SHELL=1` (default off, reversible).

- **S1 — Takeover behind a flag.** Real app window → fullscreen, hide Dock/menu bar, escape hatches
  (Esc/⌘Q/exit, restore on terminate). *Add:* guarded `NSScreen.main`. Real chat/ports, no new UI.
- **S2 — Desktop over Layer 0 + Chrome + flat spaces.** `ShellView` = `DreamscapeVideoLayer` + Chrome
  (§7a) + a canvas rendering current-space tiled `PortPanel`s via `PortWebViewHost`. Dock/⌘K spawn real
  registered tiled ports (`createPort`) + auto-arrange. Reuse `switchToSpace`; ⌘1…N + galaxy switch
  spaces. *Lands §3.2 (ShellState DI) + §3.3 (real content).*
- **S3 — Companions + chat (the heart).** Seed the per-space `isChatPort` tile; build the member header
  (you + `getAgentsForSpace`) with live status; wire the real send→companion→`port.create`→arrange loop.
  Member row must wrap.
- **S4 — Movable tiles + park + tile↔floating, no reload.** Tile drag/resize/hover/focus; the parking
  dock (drag-to-park + click-restore, `.parked`); "pop out" = `promoteInlineToFloating` (tile↔floating).
  *Ship the spike:* a counter/terminal tile keeps state across tile↔float↔park.
- **S5 — Galaxy + zoom + boot + idle-out.** Zoom ladder (galaxy=all spaces, pinch one-rung, hover-dive,
  focus), galaxy world grid (max 3, responsive), idle timer (ShellWindow-scoped) dismisses Layer 2 →
  Layer 0, wake via breakout, boot surface.

---

## 8. Out of scope (this spec)

- The kiosk boot tiers (LaunchAgent / MDM ASAM / lockdown) — `plan-port42-shell.md` §6/§8 owns those.
- Cross-restart *live-webview* persistence — same scope cut as Step 8; tiled/parked ports restore from
  the panel record, re-rendering, not a serialized live view.
- Drag-*out* from the parking rail (click-restore ships first).
- Foreign-window management (dragging Finder/Chrome in) — a separate axis: macOS has no cross-process
  window reparenting, so embed-a-foreign-app is impossible; managing foreign windows' frames via the
  Accessibility API is a future capability, NOT part of this shell. Browser/files are better as native
  ports (web port / `fs.*` files port).
- Multi-display tiling, pending §6.5.

---

## Appendix — why the prototype is structurally sound but substantively throwaway

Clean: tight MARK sectioning; the core abstractions (`Registry`/`AdoptingHost`/presentation re-parent)
map 1:1 onto `PortWindowManager`/`PortWebViewHost`/Step-8 presentation; the interaction model
(threshold-armed drag, edge-resize, hover-focus, pinch, drag-to-park) and the zoom ladder are
well-built and portable as design. Throwaway: `static let shared` singletons (→ DI), hardcoded demo
HTML + `Port`/`Registry`/`Companion`/`ChatMsg` mini-models (→ `port.create`/`PortPanel`/`AgentConfig`/
`Message`), in-memory-only state (→ DB), bridge-less webviews (→ `PortBridge`), scripted companion
`respond()` (→ the real LLM/companion loop), and app-global `NSEvent` monitors (→ scoped window input).
Treat it as a working reference for *interaction design and structure*; re-implement the plumbing on
the real services, which are better.
