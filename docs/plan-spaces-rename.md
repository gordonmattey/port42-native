# Plan: "Channel" → "Space" UI/UX Rename

Rename all user-visible (and LLM-visible) strings from "channel/Channel" to "space/Space".
Internal wire protocol (`"channel_id"` JSON keys, gateway Go code) stays unchanged.

---

## Tier 1 — Visible UI strings

Low risk. All mechanical text swaps, no logic changes.

| File | Line | Current | New |
|------|------|---------|-----|
| `Sources/Port42/Port42App.swift` | 189 | `"New Channel"` | `"New Space"` |
| `Sources/Port42B/Port42B.swift` | ~30 | `"New Channel"` | `"New Space"` |
| `Sources/Port42Lib/Views/NewSpaceSheet.swift` | 17 | `"New Channel"` | `"New Space"` |
| `Sources/Port42Lib/Views/EditSpaceSheet.swift` | 26 | `"Edit Channel"` | `"Edit Space"` |
| `Sources/Port42Lib/Views/SidebarView.swift` | 74 | `Label("New Channel", ...)` | `"New Space"` |
| `Sources/Port42Lib/Views/SidebarView.swift` | 280 | `Button("Edit Channel")` | `"Edit Space"` |
| `Sources/Port42Lib/Views/SidebarView.swift` | 284 | `Button("Copy Channel ID")` | `"Copy Space ID"` |
| `Sources/Port42Lib/Views/SidebarView.swift` | 287 | `toastMessage = "Channel ID copied"` | `"Space ID copied"` |
| `Sources/Port42Lib/Views/SidebarView.swift` | 290 | `Button("Delete Channel", ...)` | `"Delete Space"` |
| `Sources/Port42Lib/Views/SidebarView.swift` | 165 | `"Delete \(name ?? "channel")?"` | `"...\"space\"?"` |
| `Sources/Port42Lib/Views/SidebarView.swift` | 175 | `"...delete the channel and all its messages."` | `"...delete the space..."` |
| `Sources/Port42Lib/Views/SidebarView.swift` | 328 | `Menu("Remove from Channel")` | `"Remove from Space"` |
| `Sources/Port42Lib/Views/ContentView.swift` | ~400 | `("Cmd+N", "new channel")` | `"new space"` |
| `Sources/Port42Lib/Views/ContentView.swift` | ~415 | `"right-click channel"` | `"right-click space"` |
| `Sources/Port42Lib/Views/SignOutSheet.swift` | 91 | `statRow(label: "channels", ...)` | `"spaces"` |
| `Sources/Port42Lib/Views/SignOutSheet.swift` | 298 | `"...to your channels, add a free ngrok token"` | `"...to your spaces..."` |
| `Sources/Port42Lib/Views/NgrokSetupSheet.swift` | 31 | `"...to your channels, Port42 uses ngrok..."` | `"...to your spaces..."` |
| `Sources/Port42Lib/Views/AgentConnectSheet.swift` | 68 | `Text("channel")` (scope label) | `Text("space")` |
| `Sources/Port42Lib/Views/OpenClawSheet.swift` | 73 | `Text("channel")` (scope label) | `Text("space")` |
| `Sources/Port42Lib/Views/OpenClawSheet.swift` | 289 | `"...appear in the channel shortly"` | `"...appear in the space shortly"` |
| `Sources/Port42Lib/Views/PythonAgentSheet.swift` | 94 | `Text("channel")` (scope label) | `Text("space")` |

---

## Tier 2 — LLM/companion-facing strings

These reach the model — accuracy matters for companion behavior.

| File | What | Current → New |
|------|------|---------------|
| `Sources/Port42Lib/Services/AppState.swift` | Companion system prompt template header | `"# Port42 Channel Companion"` → `"# Port42 Space Companion"` |
| `Sources/Port42Lib/Services/AppState.swift` | Prompt preamble | `"Channel messages arrive prefixed..."` → `"Space messages arrive prefixed..."` |
| `Sources/Port42Lib/Services/AppState.swift` | Template key | `CHANNEL_NAME` → `SPACE_NAME` |
| `Sources/Port42Lib/Services/AppState.swift` | System join/leave messages | `"joined the channel"` / `"left the channel"` → `"...the space"` |
| `Sources/Port42Lib/Services/DatabaseService.swift` | LLM context string (~125) | `"in channels and direct conversations"` → `"in spaces and direct conversations"` |
| `Sources/Port42Lib/Services/DatabaseService.swift` | LLM context string (~172) | `"Humans and AI companions coexist in channels"` → `"...in spaces"` |
| `Sources/Port42Lib/Services/PortBridge.swift` | Context injected per turn | `"You are in the #\(name) channel."` → `"...space."` |
| `Sources/Port42Lib/Views/NewCompanionSheet.swift` | ~973 | `"bridged to this channel"` → `"...space"` |
| `Sources/Port42Lib/Views/NewCompanionSheet.swift` | ~1095 | `"before channel messages arrive"` → `"...space messages..."` |
| `Sources/Port42Lib/Services/ToolDefinitions.swift` | Tool descriptions (not names) | Any `"channel"` in description text → `"space"` |

---

## Tier 3 — Tool API names

LLM-internal tool names. No wire compat concern — change definition and executor case strings atomically.

| Current name | New name | Files |
|--------------|----------|-------|
| `channel_current` | `space_current` | `ToolDefinitions.swift`, `ToolExecutor.swift` |
| `channel_list` | `space_list` | `ToolDefinitions.swift`, `ToolExecutor.swift` |

Also update `PortBridge.swift` bridge API method names if they're exposed as strings:
- `channel.current` → `space.current`
- `channel.list` → `space.list`
- `channel.switchTo` → `space.switchTo`

---

## Tier 4 — URL scheme (invite links)

`port42://channel/...` → `port42://space/...`

Low backward-compat risk: invite links are ephemeral (not stored, generated fresh). Parser should briefly accept both `"channel"` and `"space"` host values during the transition.

| File | Line | What |
|------|------|------|
| `Sources/Port42Lib/Services/SpaceInvite.swift` | 36 | `components.host = "channel"` → `"space"` |
| `Sources/Port42Lib/Services/SpaceInvite.swift` | 60 | `components.host == "channel"` → accept `"space"` (and `"channel"` for compat) |
| `Sources/Port42Lib/Views/QuickSwitcher.swift` | 243 | `"port42://channel"` prefix check → `"port42://space"` |
| `Sources/Port42Lib/Views/TransitionRoot.swift` | 309 | `case "channel":` deep link handler → `case "space":` (keep `"channel"` as fallback) |
| `Sources/Port42Lib/Views/PythonAgentSheet.swift` | 315–317 | Invite URL display string |

---

## Tier 5 — Internal (low priority / skip for now)

No user visibility. Rename later or never.

| Item | Location | Notes |
|------|----------|-------|
| `channel_created`, `channel_switched` analytics events | `Analytics.swift` | Analytics pipeline may expect these — leave for now |
| `"lastSelectedChannelId"` UserDefaults key | `AppState.swift` | Renaming loses saved selection on first launch after upgrade (benign, one-time) |
| `newChannelRequested` notification name | `Notifications.swift` | Internal only |
| Log/print strings | Various | Not user-facing |

---

## Implementation Order

1. Tier 1 — all views (no build risk, straightforward)
2. Tier 2 — LLM-facing strings in AppState, DatabaseService, PortBridge
3. Tier 3 — tool names (ToolDefinitions + ToolExecutor atomically)
4. Tier 4 — URL scheme (SpaceInvite + QuickSwitcher + TransitionRoot)
5. Build verify: `./build.sh`
6. Tier 5 — analytics/UserDefaults if desired

---

## Gate

- [ ] `./build.sh` compiles clean
- [ ] Sidebar: "New Space", "Edit Space", "Copy Space ID", "Delete Space", "Remove from Space"
- [ ] Delete confirmation says "space"
- [ ] Companion scope sheets show "space"
- [ ] Companion system prompt says "# Port42 Space Companion"
- [ ] `space_current` / `space_list` tools callable from chat
- [ ] `port42://space/...` invite links parse and open correctly
