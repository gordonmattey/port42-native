# Shell layout subsystem: design pass

**Date:** 2026-08-03. **Why:** GM asked whether the current design had been analysed in detail before
committing to the placement work in `summer2026-todo.md` ("the desktop rearranges itself", Phase 1).
It had not. This is that pass: every piece of layout state, every reader and writer, how it persists,
what happens across desktops, and what happens when the window changes size.

Everything below is either read from the code at the cited line or measured on Dev2. Claims that are
read-but-not-measured say so.

---

## 1. The state model

One tile's geometry lives on `PortPanel` (`Views/PortWindowManager.swift:14-56`):

| field | meaning | persisted |
|---|---|---|
| `position: CGPoint?` | top-left in DESKTOP coordinates. `nil` means "never placed" | `posX`, `posY` |
| `size: CGSize` | the tile's own size, never equalised by the grid | `width`, `height` |
| `z: Int` | stacking, monotonic, higher is frontmost | `z` |
| `presentation: String` | `tiled` / `parked` / `inline` | `presentation` |
| `isBackground: Bool` | full-bleed as the desktop background | `isBackground` |
| `adoptedSpaceIds: [String]` | spaces that kept this port as a peek | `adoptedSpaceIds` |

Desktop coordinates are NOT window coordinates. `ShellView` is `VStack { ShellChrome; ShellDesktopView }`,
so the desktop's `GeometryReader` already starts below the Chrome bar. `y = 0` is the first pixel under
the Chrome. Measured: window 1728x1080 gives a desktop area of 1728x1035.

Sizes at birth, all hard-coded, none derived from the desktop:

| path | size |
|---|---|
| `registerTiledPort` (`:435`) | 360 x 260 |
| `addTiledTerminalPanel` (`:457`) | 520 x 380 |
| `addTiledBrowserPanel` (`:478`) | 900 x 640 |
| `popOut` (`:353`) | 40% x 40% of the SCREEN's visible frame, not the desktop |
| `registerInlinePort` (`:407`) | 100 x 100, resized on undock |

`minTileSize` is 220 x 160 (`ShellState.swift:955`).

## 2. Who writes a position

| writer | trigger | persists |
|---|---|---|
| `updateTileFrame` (`:617`) | drag end, resize end, and every tile `applyArrange` touches | yes |
| `movePort` (`:934`) | the `port.move` bridge method | yes |
| `position = nil` | five birth paths: `popOut:370`, `addTiledTerminalPanel:460`, `addTiledBrowserPanel:481`, `undockInline:514`, `ensureChatPort:1179` | yes (as NULL) |

Position is EXPOSED, three ways: `ports.list` returns `x`/`y` (`:916`), `port.position` returns the
full frame (`BridgeMethods.swift:1747`), `port.move` writes it (`:1633`). What is missing is not the
API. It is that **no layout code ever reads a position as an input.** `ShellState.arrange` takes
`(id, size, z)` and computes every origin from scratch, so where a tile currently sits is discarded.

## 3. Who decides where a tile is DRAWN

`ShellPlacement.placement` (`Services/PortPlacement.swift:70`), pure and headless. Precedence:
focused, then peeking, then tiled.

- focused: `focusRect` = 0.78 x 0.8 of the area, centered.
- peeking: `railSlot(i)` = a left-edge column at x=12, y=60+i*152. **Peeks are placed on top of tiles,
  never around them.**
- tiled: `resolvedTileFrame(position:size:fallbackIndex:)` (`:58`), which returns the committed
  position, or, when `position == nil`, a **cascade seed** at `x = 330 + (i%4)*90, y = 200 + (i%3)*80`.

That cascade is worth naming: a placement fallback already exists, it is just blind (it ignores every
other tile) and temporary (the next arrange overwrites it). It is the natural home for a real `place`.

**Nothing clamps at render time.** `resolvedTileFrame` returns the stored origin unmodified. The only
clamp in the system, `ShellTile.clampedOrigin` (`ShellDesktop.swift:799`), runs during a drag.

## 4. The re-grid path

Three call sites, all in `ShellDesktopView`, plus the probe. Full Phase 0 measurement is in
`summer2026-todo.md`; the short form:

- `onChange(tiledPanels.count)`: spawn, close, park, unpark, adopt, unadopt, DM surface/close.
- `onChange(arrangeBump)`: eleven callers, of which two are the user asking.
- `seedIfNeeded` from `onAppear`: window mount only, if any tile is unpositioned, then it re-grids ALL.

`ShellState.arrange` (`:1115`) sorts by `z`, computes `cols = ceil(√n)`, divides the work area into
equal cells, and centers tile *i* in cell *i*. Consequences: cell assignment follows recent attention,
cell geometry is a function of `n` so one birth moves every tile's target, and occupancy is never
consulted (cells are deliberately smaller than tiles when crowded, so overlap is by design).

Work-area insets today: top 70, sides 40, bottom 100, right also `parkWidth = max(64, 5% of width)`.
The top 70 is dead space, since the desktop already starts below the Chrome, and the same file's drag
clamp allows `y >= 0`. Only the bottom inset is earned: the dock is a real overlay (its pill plus 24pt
of bottom padding, about 88pt) and a tile behind it cannot be clicked.

## 5. Persistence, and a defect found in this pass

`persistPanel` (`:289`) does two things: `savePortPanel` (upsert the row) and **`savePortVersion`,
which INSERTs a new row into `port_versions` carrying the port's full HTML** (`DatabaseService.swift:1860`).
There is no dedupe: the version number is `MAX(version) + 1`, unconditionally.

`persistPanel` is called by `updateTileFrame` (every drag end and every tile an arrange moves) and by
`setZ` (`:625`), which runs on **every click, hover-to-front and focus**.

Measured on Dev2, a dev instance with 6 panels:

```
1108 version rows, 1718 KB of html
one port: 102 rows, 1 distinct html
top 8 ports: every one has exactly 1 distinct html
```

So the entire version history is layout noise. Two costs: the "version" feature is unusable (a user
opening it sees 102 identical entries rather than their edits), and the database grows by a full copy
of a port's HTML every time a tile is clicked. This is not caused by the arrange bug, but arrange
multiplies it by the tile count on every spawn.

**Fix direction:** geometry-only persistence must not snapshot a version. Either `persistPanel` gains a
`snapshotVersion: Bool = false` and only the HTML-changing paths pass `true`, or `savePortVersion`
no-ops when the HTML is byte-identical to the latest row. The second is one line and fixes every
caller at once, including any future one. Not part of the arrange work, and it should not be smuggled
into it, but it should be its own item.

## 6. One position, several desktops

`desktopTilePanels` (`ShellState.swift:545`) renders a port on its home space AND on every space in
`adoptedSpaceIds`, plus surfaced DM/foreign chats via `openDMSpaceIds`. `position` is a single field.

Therefore a port that lives on two desktops has ONE position shared between them, and an arrange run
on one desktop writes a position that also moves it on the other. Read from the structure, not
measured: there are no adopted ports on Dev2 right now, and reproducing one needs a cross-space peek.

This constrains the placement work directly. `place()` computes a spot in the context of one desktop,
so writing the result is a cross-desktop side effect. Three options, GM to choose:

1. Accept it. A port kept on two desktops sits at the same coordinates on both.
2. Make position per-desktop: `positions: [spaceId: CGPoint]`, migrating the current single value to
   the home space. Correct, and it touches persistence, restore, `port.move`, `port.position`.
3. Place only on the desktop where the tile was born, and let an adopted copy fall back to the render
   cascade until the user drags it. Cheap, but the adopted copy is then unplaced on that desktop.

## 7. Window resize

`onChange(geo.size)` updates `shell.lastDesktopArea` and nothing else. No position is re-clamped, and
the render path does not clamp either (section 3). So shrinking the window leaves tiles at absolute
coordinates that may be entirely outside the visible desktop, with no drag able to reach them. They
are recoverable only by ⌘L, which re-grids into the new area, or by exposé, which is transient.

Read, not measured: the resize case is the one Phase 0 reproduction still outstanding, because
resizing a window needs assistive access the agent shell does not have.

After Phase 1 this gets slightly worse before it gets better: if ⌘L is the only thing that re-grids,
and a tile has been stranded by a resize, ⌘L becomes the only rescue. That argues for one rule Phase 1
should carry: **on resize, clamp any tile that would be off-screen back into the work area, and move
nothing else.** It is not a re-grid, it is the same clamp the drag path already applies, and it is the
one case where "arrange nothing" is the wrong answer.

## 8. What survives a restart

`restoreFromDB` (`:192`) rebuilds every panel with its stored position, size, z, presentation and
adoption. It does not clamp against the current window size, so a layout saved on a large display
restores off-screen on a small one. Same failure as section 7, same fix.

## 9. Consequences for Phase 1

1. `place()` belongs in `PortPlacement.swift` beside `resolvedTileFrame`, not in `ShellState`. That
   file is already the pure geometry layer, and the blind cascade it holds is what `place` replaces.
2. The work area must be defined ONCE and shared by `place`, `arrange` and the drag clamp. Today
   arrange has one definition and the clamp has another, and they disagree by 70pt.
3. A 900x640 browser tile does not fit twice across a 1728pt desktop with margins. The cascade
   fallback will therefore be common, not exceptional, so it has to look deliberate.
4. Peeks are drawn over tiles at a fixed left-edge column. Placement should treat the peek column as
   occupied, or a newborn will land under it.
5. Cross-desktop position sharing (section 6) needs a decision before `place` writes anything.
6. Resize clamping (section 7) should ride with Phase 1, because Phase 1 removes the accidental
   re-grids that currently rescue stranded tiles.

## 10. Decisions (GM, 2026-08-03)

- **Section 6, shared position across desktops: "we shouldn't have this."** Position becomes
  PER-DESKTOP. `position: CGPoint?` becomes a map keyed by space id, the current single value migrating
  to the port's home space. Touches the panel model, the `port_panels` schema (a new migration, never
  an edit to an existing one), `restoreFromDB`, `port.move`, `port.position` and `ports.list`. A port
  kept on two desktops is then placed independently on each, which is what adoption implied all along.
- **Section 7, clamp on resize: yes.** Clamp only what would be off-screen, move nothing else. Same
  clamp the drag path already applies. Also applies on restore (section 8).
- **Section 1, tile sizes: ONE default for every port type.** Browser, web, chat and terminal all get
  the same birth size; the four hard-coded values (360x260, 520x380, 900x640, 40%-of-screen) collapse
  to one. Existing panels keep whatever size they were given. This also removes the reason the cascade
  fallback would have been the common case (a 900x640 browser could not fit twice across the desktop).
- **Section 9.3, when a newborn does not fit:** cascade on top, unchanged. Shrinking a tile changes a
  size the user did not ask to change.

- **Section 5, version-snapshot-on-every-click: fixed** (GM: "yeah we should fix that defect").
  `savePortVersion` no-ops when the html is byte-identical to the latest row, so the guard covers every
  caller including future ones rather than the two that happen to exist. `PortVersionNoiseTests`.

## 11. What shipped, 2026-08-04

All of section 10 is implemented and green (1406 tests). Against this document:

- §1 sizes: one `ShellPlacement.defaultTileSize` (620x440) for every port type. Pop-out no longer sizes
  itself from the SCREEN.
- §2/§3: `place` lives in `PortPlacement.swift` and replaced the blind cascade in `resolvedTileFrame`
  as the answer to "where does a new tile go".
- §4: the three re-grid sites became one re-grid site (⌘L) plus placement. `arrangedForSpace` was
  deleted rather than fixed, since placement cannot re-grid, which also retired candidate 3.
- §4 work area: ONE definition, `ShellPlacement.workArea`. Top inset 70 → 8; the desktop already
  starts below the Chrome.
- §5: fixed, above.
- §6: `positions` keyed by space id, migration v46, `port.move`/`port.position` take an optional
  `space_id`. Backfill verified on Dev2's real data: keyed per home space, `posX`/`posY` preserved,
  nothing moved.
- §7/§8: `clampTilesIntoView` on resize and on first appearance, moving only what is off-screen.

One thing changed by measurement rather than by decision: a placed tile anchors at its gap's top-left
rather than centering in it. Centering a 620x440 tile splits a 1626x931 work area into four strips,
none wide enough for the next tile, so every later birth would have cascaded on top of something. The
test "two births in a row do not land on each other" caught it before it shipped.
