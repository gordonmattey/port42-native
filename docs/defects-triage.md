# Defects triage

The defects list from the research branch (`docs/research/defects-found.md`, measured at `0369388`),
checked one by one against `nautilus` on 2026-09-26 after /imagine I.4. Status is what the code says
today, not what the list said then. Nothing here is fixed by this document.

## Already fixed on nautilus

| Defect | Evidence now |
|---|---|
| Codex AGENTS.md hardcodes one gateway port | `~/.codex/AGENTS.md` has no `4245`; each Codex home owns its own AGENTS.md with `${PORT42_GATEWAY_PORT:-4242}` |
| macOS floor disagrees (15.0 against 14) | `Info.plist` `LSMinimumSystemVersion` is 14.0, matching `Package.swift` |
| Shipped `port42` CLI not Developer ID signed | `build.sh:387` signs `$MACOS/port42-cli`, the name it is bundled as |
| `port42-mcp.js` advertises deleted methods | the file is gone |
| `ports-core.txt` and `llms-cli.txt` have no consumer | both files are gone |
| Background port told it is not visible | `PortPresentation.swift:90-95` maps `background` explicitly (GM, 2026-09-25) |
| Three permission tests pass vacuously | `PortPermissionTests.swift:40-53` now asserts on live methods (`chat.post`, `space.current`, `storage.set`) |

## Still open

| Defect | Where now | Weight |
|---|---|---|
| A mention of a companion can spawn a second terminal: terminals are matched to companions by display name | `AppState.swift:1086`, `:1094` (`ensureTerminalLive`), also `:238`, `:1053`, `:1079` | High: user-visible, GM hit it; the fix is matching on `companionId` |
| Every terminal with a new name mints a companion, nothing reaps them | `autoRegisterTerminalCompanion`, `AppState.swift:1642` | High: GM hit it; wants a decision (companion made by a deliberate act, removed with its last port) |
| No cap on tool results on the live path (`port.console` can return ~400,000 characters) | `ToolExecutor.capForModel` guards only the old in-app path | Medium: token cost per agent turn |
| Nothing handles `webViewWebContentProcessDidTerminate`: a crashed page stays blank | no handler in `Sources` | Medium: recovery is a reload of the port's HTML |
| A companion name with a space cannot be mentioned | names are folded by `CompanionName.mentionable` at spawn and boot (`AppState.swift:1813`, `:1859`); creation paths not yet checked for all callers | Low, partly mitigated |
| Child processes inherit the app's environment, including provider keys | `AgentProcess.swift:55`, `CommandAgent.swift:118` | Decision, not a bug: D9 says the CLI signs in as itself |
| Settings still has a tab named "AI" | `SignOutSheet.swift:17` | Low: needs a look at what it renders |
| `aiPaused` / `isSuspended` are dead, and a comment says they gate streams | `PortBridge.swift:266-273` | Low: cleanup |
| Four `ngrok-skip-browser-warning` headers | `gateway/main.go:45`, `:55`, `:64`, `:180` | Low; leave to Phase 4, which owns sharing |
| The guest page re-renders the whole `srcdoc` on every `state` event | `gateway/guestpage.go:119`, `:147` | Phase 4 (sharing and the guest page are its scope) |

## Structural (from the list, unchanged)

A port has no storage of its own to ship, no transcript file (chat entries are rows in `port_storage`), and
`port_versions` cannot identify a port across machines. These belong to Phase 4's design, not to
defect fixes.

## Found while building /imagine

The app stopped answering every call after a NaN reached a JSON write on the main thread
(`JSONSerialization` raises, AppKit swallows it, the main queue never runs again); fixed in `2afbe1c`
with `SafeJSON`, along with the host rate limit, the door's frame limit and oversized results, all
found by running the real gateway and door in tests (`GatewayStallTests`). The lock screen's video
froze the app at the switch between clips (sampled on Dev4; fixed in
`bfb1053`). A flaky test, "stuck: the person is told..." (`StartupPromptTests`), failed once in
three full-suite runs and is not root-caused (`docs/plan-imagine.md`, I.3).
