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

## Stack rank (2026-09-26)

Ranked by what a person running v1 would hit, weighted by how often. Engineering assessment; none of
this is measured beyond the observations cited.

| # | Defect | Impact | Fix | v1 |
|---|---|---|---|---|
| 1 | A companion's terminal is found by display name | Reproduced: after a rename, a mention opened a second terminal | Terminals match by `companionId`; a rename reaches the live terminal (current name from the id, tile title and client name updated); a rename onto an existing name is refused | Done |
| 2 | Every terminal name mints a companion; nothing reaps them | Roster clutter, every stray name addressable, the same inflation on the grantee side. GM hit it | Decision first: a companion made by a deliberate act and removed with its last port. Minimum: reap an auto-registered companion when its terminal closes | By design (GM, 2026-09-26): a named terminal is a companion. Not a defect |
| 3 | No recovery after a WebContent process crash | A port goes blank for good, silently; more likely with dozens of live webviews | Handle `webViewWebContentProcessDidTerminate` by reloading the port's HTML | Cleared (GM): never observed on nautilus; a resilience item, not a root cause |
| 4 | The startup-prompt test is flaky | Test hygiene, not a product defect | Gone with the detector it tested | Done |
| 5 | A Claude slower than 30s to start is called stuck | A false notice in the space, every run | The detector is removed (GM, 2026-09-26) | Done |
| 6 | Messages typed into a starting Claude not submitted | The brief can sit unsent and the agent idles. Seen in /imagine run 2, not in run 3; run 2 also queued three Port42 notices, now gone | Re-observe in the I.5 runs before changing code | Watch |
| 7 | No cap on tool results on the live path | Token cost per call (`port.console` can return ~400,000 characters). The 2 MB frame refusal (`too_large`) now bounds the worst case | Per-method limits on the verbose reads | Optional |
| 8 | A name with a space cannot be mentioned | Reproduced: `app dev` was stored as typed, its terminal named `app-dev`, and neither mention reached it | Names are kept as typed (no hyphen folding, GM); a mention escapes what it cannot carry, as a URL does (`@app%20dev`); autocomplete and whoami give the escaped form | Done |
| 9 | Settings opens on a tab named "AI" | It shows an accurate one-line note that agents are CLIs; the name is a leftover | Rename or fold into another tab | Polish |
| 10 | `aiPaused` / `isSuspended` dead, with a false comment | None at runtime | Delete | Cleanup |

Not ranked: the child environment carrying provider keys is a decision about D9, not a defect; the
guest page's full re-render and the `ngrok-skip-browser-warning` headers belong to Phase 4.

## Seen in the /imagine runs, not yet ranked

- **A Codex companion speaks first, unprompted**, when its terminal starts (runs 4, 5, 6): it posts
  "ready" before anyone asks it anything. Harmless in a team; noise in a space.
- **A hung CLI turn goes unnoticed.** A Claude engineer sat on one command for 28 minutes (run 3)
  with nothing in the space to say so. Port42 could post a notice when a turn shows no transcript
  activity for a few minutes. Idea; not built.

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
