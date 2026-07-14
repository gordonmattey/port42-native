# Plan: Retire classic mode — the shell is the only UI

Status: **BUILT + Tier-B-PASSED (2026-07-14).** All four port-unit harnesses re-ran PASS on the
retired codebase (cycle, peek repro, kinds, busy-desktop — `/tmp/portunit.log`). Tier C pending
(fresh boot → shell with no flag; ⌘K switcher; gateway dock/restore visibly hides/returns a tile).
Decision record: `plan-port-units-render-refactor.md` (2026-07-12) — no structure for unused
features in port management; breaking changes OK.

## What was deleted

- **`PORT42_SHELL` flag** (env + Settings toggle + `ShellMode.isEnabled`, 15 call sites):
  `TransitionRoot` always mounts `ShellView`. `PORT42_SHELL_TAKEOVER` (fullscreen vs windowed)
  survives as the only choice.
- **Classic views:** `ContentView`, `SidebarView`, `NewCompanionSheet`, `EditCompanionSheet`,
  `EditSpaceSheet`. Shared helpers they carried (`CompanionTypePreset`, the borderless-window
  `appKitTooltip`) re-homed into `ShellShared.swift`.
- **Invite links MIGRATED, not dropped (GM call):** `AgentConnectSheet`, `PythonAgentSheet`,
  `OpenClawSheet` (the BYOA / LangChain-wedge flow) are hosted as shell overlays via
  `shellSheetOverlay` in `ShellView`, presented off the existing AppState flags — the deep-link
  chain (encrypted `port42://space` → connect card → Python/OpenClaw snippet card) works in the
  shell. `port42://agent` deep links still add a companion headlessly (TransitionRoot). The
  **QuickSwitcher additionally accepts pasted `port42://agent` links** ("press enter to add
  companion <name>") — adds the companion AND lands it in the current space's crew; pasted space
  invites (port42:// + https invite pages) survived with the switcher.
- **The NSPanel layer** (~700 lines of `PortWindowManager`): `windows` dict, `createWindow` +
  `createWindowForExistingPanel` + `updateWindowContent` + `panelWindowClosed`, `PortNSPanel`,
  `PortPanelContentView`, `PortPanelTitleBar`, `PortVersionDropdown`, `PortDragArea`,
  `hoveredPanels`, `panelsVisible`, `hideFloatingPanels`, `showRestoredFloatingPanels`,
  `isTerminating`. Lock/unlock no longer touches ports (tiles stay mounted under the lock screen).
- **`--peer` / `Port42B`** (second-instance testing): the isolated Port42Dev.app instance is the
  dev/second instance now.

## What was re-mapped (API signatures kept; shell semantics)

- `undockInline` — always lands a **tile** (param `shellMode` gone).
- `popOut(html:…)` — creates/updates a **tiled** panel, announces via `portCreated` (peeks in).
- `minimize`/`restore` — pure `isBackground` flag flips; surfaces stay alive in the registry
  (the old path closed the window and tore down terminal controllers — restore now keeps state).
  `desktopTilePanels` excludes backgrounded panels (pre-existing gap: they used to still render).
- `bringToFront` — a z-raise (`setZ(max+1)`); `portFrame`/`movePort` read/write panel geometry.
- `switchToSpace` — record-keeping only (`activeSpaceId` + `ensureChatPort`); no window choreography.
- `closeWithConfirmation` — plain close (the shell's ✕/drag affordances are the confirmation).
- Permission prompts: every bridge routes to the ChatView dialog (`activePermissionBridge`).

## Data model

- Presentations: **`tiled` | `parked` | `inline`** (inline session-only). `PortPanel` default is
  `tiled`. **Migration `v39-retire-floating`** rewrites legacy `floating` rows to `tiled`.
- `ports.list` status vocabulary: `'tiled' | 'parked' | 'docked' | 'inline'` — updated in
  `ToolDefinitions`, `ToolExecutor`, `PortBridge` (JS), `ports-context.txt`, `llms.txt`
  (repo sources; the installer propagates to user CLAUDE.md).

## QuickSwitcher migration (kept, not deleted — GM call)

⌘K opens it as a shell overlay (`ShellState.showQuickSwitcher`, scrim + zIndex 215). Selecting a
space lands at the desktop rung (scoped to switcher-closes so galaxy management never yanks the
ladder); selecting a companion opens its DM tile on the current desktop via
`shell.activateCompanion` (classic `startSwim` space-switch retired).

## Epistemic-memory inspector re-homed (GM ask, 2026-07-14)

`CreaseInspectorSheet` (fold / position / creases / engravings) survived the retirement but its
only trigger — the eye icon in the floating swim window's titlebar (`PortPanelTitleBar`, deleted)
— did not, and it had never had a shell surface. Re-homed: **hover a companion's row in any chat
tile's member strip → the eye** opens the inspector for that companion IN THAT CHAT'S SPACE
(`ShellState.InspectTarget`, presented as a real `.sheet` so its own dismiss works). Broader than
the classic placement: works from group chats and DM tiles alike, per companion.

## Gates

- **Tier A ✅** — 73 green across port/shell suites; `ShellModeTests` + `PortWindowLifecycleTests`
  rewritten to the new contract; full run fails only the known pre-existing set.
- **Tier B ✅ PASS** (2026-07-14) — all four harnesses re-ran clean on the retired code:
  `PASS`, `PASS`, `KINDS PASS [web · terminal · browser]`, `DESKTOP PASS` (zero remakes, zero
  windowless; the once-bugged `888AE5D5` port healthy through the sweep).
- **Grep gate ✅** — `NSPanel`/`createWindow` only in DEBUG spikes + comments; `"floating"` only
  in migration/comments; `ContentView`/`Port42B` only in historical comments.
- **Tier C ⏳** — fresh boot lands in the shell with no flag; ⌘K switcher works (space + companion
  selects); gateway `port_manage dock` / `restore` visibly hides/returns a tile; an old-DB launch
  (floating rows) comes up fully tiled.
