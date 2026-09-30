# API gap review (#132)

What a person can do in the app that the bridge API cannot, checked against `main` at `9e071ab`.
Every state-changing UI action (menus, buttons, settings, shortcuts, boxes) was traced to the
function it calls and matched against the registry (91 methods, including `state.set` and
`state.get` in `BridgeStateMethods.swift:82, :109`).

- **Validation:** read from the code only. Nothing was built or run. Line numbers are at `9e071ab`.
- **Scope:** gaps and partial coverage. View-only navigation (zoom rungs, galaxy, exposé) is listed
  only where an agent plausibly needs it.

## Summary

| Area | Missing from the API | Partial |
|---|---|---|
| Ports | move to another space, show in another space too (adopt) and detach, park and unpark, reorder the rail, resize, fork, reload, clear console | `port.manage close` (closes everywhere), `show`, `focus`, `unbackground`; `ports.list` omits pins and adopted spaces |
| Spaces | rename, accent color, rest, wake, reorder | `space.switchTo` does not wake a resting space; `space.list` omits resting and accent |
| Companions | delete, update (name, prompt, runs hidden, secrets), add to a space, remove from a space | open a companion (no "respawn its terminal") |
| Sharing | list who a port is shared with, set a person's rights, stop sharing, leave a remote port, toggle remote wake on a tile, fork someone's port | `invite.list` lists invites only |
| Settings | clients, grants, secrets, machine name, relays, voice, updates, sign out and reset | none |

Keep human-only (recommendation, not a gap to close): adding or revoking clients, answering or
revoking permissions, secrets, relays, sign out, power down, reset.

## Ports

| UI action | UI (file:line) | Calls | API today | What is missing |
|---|---|---|---|---|
| Move to another space | ShellDesktop.swift:780, SharePanel.swift:178-179 | PortWindowManager.move(toSpace) :494 | none | `port.move` only sets x/y on a desktop the port is already on (BridgeMethods.swift:1695-1719). Ticket #126 |
| Show in another space too, and detach | peek keep ShellDesktop.swift:860, :914; ✕ on an adopted tile :824 | PWM.adopt :505, unadopt :515 | none | No adopt or unadopt; `port.manage close` on an adopted tile archives it in its home space too. Ticket #128 |
| Park to the rail, restore | ShellDesktop.swift:923-926, :1071-1073 | PWM.park :532, unpark :541 | only `port.create presentation:"parked"` | park and unpark of an existing port |
| Reorder rail chips | ShellDesktop.swift:1088-1099 | PWM.moveInRail :550 | none | |
| Resize a tile | ShellDesktop.swift:940-955 | updateTileFrame :592 | none | `port.move` has no width or height; PWM.resize :690 has no bridge caller |
| Fork: a copy | ShellDesktop.swift:773-779 | RemoteTile.swift forkPort :224 | none | approximable with getHtml + create, but not for a remote port |
| Refresh | ShellDesktop.swift:766 | PWM.reloadPort :819 | none | approximable with `port.exec` |
| Show a hidden port | ShellDesktop.swift:1147-1148 | ShellState.showHidden :1170 | `port.manage show`, partial | API only restores; the UI also switches space, places and raises it |
| Set as background, reset | ShellDesktop.swift:786-792, :60 | setBackgroundPort :125, clearBackgroundToTile :181 | `port.manage background` / `unbackground`, undocumented | not in the schema or description; unbackground does not raise or recreate |
| Focus | ShellDesktop.swift:809-815 | `shell.zoom = .focus(id)` | `port.manage focus`, partial | raises only; no focus rung, no keyboard |
| Browser tile back, forward, reload, URL | ShellDesktop.swift:1227-1248 | WKWebView | none for the tile | `browser.*` drive headless sessions, not the tile |
| Clear a port's console | PortChatPanel.swift:240 | PortConsole.clear | none (minor) | |
| Pin | ShellDesktop.swift:782-785 | PWM.setPin :600 | `port.manage pin` etc. | `ports.list` does not report pin state |

## Spaces

| UI action | UI (file:line) | Calls | API today | What is missing |
|---|---|---|---|---|
| Rename | ShellView.swift:1265-1271 | AppState.updateSpace :1667 | none | |
| Accent color | ShellView.swift:1277 | updateSpace | none | |
| Rest | ShellView.swift:1320 | restSpace (ShellState :358, AppState :1722) | none | `space.list` does not report resting |
| Wake, wake and enter | ShellView.swift:1314, :925-926 | wakeSpace :1734, wakeAndEnterSpace :1742 | none | `space.switchTo` selects without waking |
| Reorder | ShellView.swift:1061-1074 | reorderSpaces :1656 | none | |

## Companions

| UI action | UI (file:line) | Calls | API today | What is missing |
|---|---|---|---|---|
| Delete | ShellView.swift:1221-1233 | AppState.deleteCompanion :2492 | none | existing ticket |
| Rename, edit prompt | ShellView.swift:1188-1204, :1372-1376 | updateCompanion :2467 | none | |
| Runs in a port or hidden | ShellView.swift:1198-1201 | updateCompanion, setCompanionHidden :244 | none | |
| Grant secrets | ShellView.swift:1211-1214 | updateCompanion (secretNames) | none | likely human-only |
| Add to this space | ShellView.swift:1557, :1683-1686 | addCompanionToSpace :2452 | none explicit | only as a side effect of an @mention in `chat.post` (PortChat.swift:190-196) |
| Remove from this space | ShellView.swift:1217 | removeCompanionFromSpace :2463 | none | Since closed: `companions.remove` (#131) |
| Open (respawn its terminal) | ShellDesktop.swift:1338 | activateCompanion :1128 | partial | `port.manage focus` on its terminal only |

The API does more than the UI in one place: `companions.unwatch` has no UI.

## Sharing, invites and remote

| UI action | UI (file:line) | Calls | API today | What is missing |
|---|---|---|---|---|
| Who a port is shared with | SharePanel.swift | sharedPorts | none | `invite.list` lists invites, not people |
| Toggle a person's rights | SharePanel.swift:77-80 | Invites.swift setRemoteRight :443 | none | |
| Stop sharing with a person | SharePanel.swift:83 | stopSharing :379 | none | `invite.revoke` covers unused invites only |
| Leave a remote port | SharePanel.swift:159 | RemoteTile.swift leaveRemotePort :253 | none | `port.manage close` closes the tile but keeps the remote row |
| Remote wake on a tile | SharePanel.swift:145-146 | setMirrorWakes :261 | only at accept (`remoteWake`) | |
| Move to another machine | SharePanel.swift:182 | `invite.create` with `move` | covered | the `move` right is missing from the description (named only in the error, Invites.swift:270) |

## Also found

- **Two dead menu items.** Port42App.swift:320-325 (New Space, ⌘N) posts `.newSpaceRequested` and
  :339-344 (Help, ⌘/) posts `.helpRequested`. Nothing in `Sources` observes either, so both menu
  items do nothing.
- **The user's name** is set only at setup (SetupView.swift); `user.get` is read-only and Settings
  has no way to change it.

## Proposed tickets, most useful first

1. **Move a port to another space** (#126): `port.move` gains `space_id`, backed by
   PortWindowManager.move(toSpace) :494, under the APP-11 write scope.
2. **Show a port in another space too** (#128): `port.manage showIn` / `hideFrom`, backed by
   adopt/unadopt; `ports.list` reports `pinned` and `alsoIn`; `port.manage close` on an adopted tile
   detaches it here instead of archiving it.
3. **Companion lifecycle:** `companions.update` (name, prompt, runs hidden), `companions.delete`,
   `space.addCompanion` / `space.removeCompanion` (removal shipped as `companions.remove`, #131). Secrets
   stay human-only.
4. **Space management:** `space.update` (name, accent), `space.rest`, `space.wake` (and
   `space.switchTo` wakes), `space.reorder`; `space.list` reports resting and accent.
5. **Port tiles:** `port.manage park` / `unpark`, `port.move` width and height, `port.manage reload`,
   `port.fork`.
6. **Sharing after the invite:** `invite.shared` (who, with which rights), `invite.setRights`,
   `invite.stop`, `remote.leave`, `remote.setWake`.
7. **Documentation only:** `port.manage background` / `unbackground` and the `move` right in their
   descriptions; the regenerated references pick them up.
8. **Dead menu items:** wire New Space and Help, or remove them.

Each new method needs its authorization decided with it (space scope from APP-10/11, code authority
from APP-07 where it changes what a port runs) and a scope in the client-scopes design
(`docs/design-client-scopes.md`).
