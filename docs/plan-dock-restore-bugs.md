# Plan — dock restore + launch: z-order and animation origin

Two related defects on the park-rail (dock) restore path and the new chat/terminal launch path
(logged at the top of `docs/summer2026-todo.md`). RCA complete; GM confirmed the Bug 2 approach
(morph from the chip, 2026-07-21).

## Bug 1 — restored / launched surface lands UNDER everything (z-order + focus)

### Root cause (one class, two triggers)

A surface becomes a current-space tile without ever being stamped frontmost.

- **Launch.** `registerTiledPort` / `addTiledTerminalPanel` / `addTiledBrowserPanel` /
  `createPortPanel` append a panel with the default `PortPanel.z == 0`. z=0 is the bottom of the
  paint order (`ShellTile` renders by `.zIndex(pl.z)`), so any existing tile ever focused
  (z >= 1) covers it.
- **Restore.** The rail chip button (`ShellDesktop.swift:811`) calls `unpark(id:)`, which flips
  `presentation` to `"tiled"` and persists but never re-stamps z or selects. The port keeps its
  stale pre-park z and lands under anything focused since. `revealChat` / `ensureChatTiled` share
  the gap.

### Fix — single z authority at the shell layer (`shell.bringToFront` = select + `nextZ()`)

1. **All births, one site.** `ShellState.handlePortCreated` (`ShellState.swift:221`), same-space
   branch. Replace the bare `return` with `bringToFront(id)` then return. `portCreated` is the
   choke point every creator fires (4 sites) and the sink is `.receive(on: RunLoop.main)`, so the
   panel already exists in `panels` when this runs. Covers dock Terminal/Browser, AI- and
   companion-created current-space ports alike. Other-space peeks unchanged.
2. **Restore from dock.** Chip button (`ShellDesktop.swift:811`): after `unpark`, call
   `shell.bringToFront(p.id)`.
3. **Reveal chat.** `openChat()` (`ShellDesktop.swift:1034`): after `revealChat`, resolve the
   space's chat panel and `shell.bringToFront(panel.id)`.

`unpark` / `revealChat` stay pure presentation flips in the manager (no z there) so there is one z
authority at the shell layer, matching hover/focus. Terminal-companion focus
(`AppState.focusTerminal` -> `portWindows.bringToFront`) is a separate working path, out of scope.

## Bug 2 — restore animates from the RIGHT screen edge, not the dock chip

### Root cause

No chip-anchored transition. Unpark flips `presentation`; the tile re-enters the ForEach as a
fresh `.opacity` insertion while `arrangeBump` fires `applyArrange`, which springs every tile to a
new grid origin. The tile pops in at its stale stored frame and the arrange-spring drags it across
— read as sliding in from the right. The park rail (`ShellParkRail`, zIndex 10000) shares no
geometry with the tiles subtree.

### Fix — matchedGeometryEffect morph from the chip (GM's call)

For any port, parked and tiled are mutually exclusive (parked XOR tiled), so chip and tile are
never simultaneously present for the same id — a clean matched-geometry hand-off.

- A `@Namespace` owned by `ShellDesktop` body, threaded to both `ShellParkRail` (chips) and the
  tiles ForEach (`ShellTile`).
- Chip: `.matchedGeometryEffect(id: "restore-\(p.id)", in: ns, isSource: true)`.
- Tile: `.matchedGeometryEffect(id: "restore-\(item.id)", in: ns, isSource: false)`. When the chip
  (source) is removed on restore, the tile animates its frame from the chip's last frame to its own
  resolved frame — the morph.
- Drop `arrangeBump += 1` on the chip-restore path so the morph is the only motion (the tile
  returns to its stored position; no re-grid needed).

### Implementation risk

`matchedGeometryEffect` injects frame+position; `ShellTile` already places via `.position(x:y:)`.
Modifier order / conflict needs live tuning in Dev. Timebox: if the morph fights the
absolute-positioning layout, fall back to the controlled-slide (anchor an asymmetric insertion
transition to the chip rect) and flag it — do not thrash.

## Tests

- Unit (Swift Testing, headless `ShellState` + in-memory manager): two current-space births -> the
  second is frontmost; a restored parked port -> frontmost over existing tiles.
- Animation: not unit-testable. Live Dev repro — park two tiles, restore one, confirm it is
  frontmost + focused and morphs out of its chip.

## Build / verify

Dev only (:4243). Quit the dev app, `./build.sh`, relaunch, zoom into a space, repro both bugs
before and after. Update `docs/summer2026-todo.md` (mark the item done) and the backlog banner
when complete.
