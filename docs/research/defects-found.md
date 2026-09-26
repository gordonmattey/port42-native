# Defects found while scoping

Found during the September 2026 research, none of them the thing being researched. Security items are
not here; they are in `security-bridge-authorization.md`. Measured against `nautilus` at `0369388`
unless stated.

## Live, in shipped code

**The background port is told it is not visible while it is the only thing on screen.**
`setBackgroundPort` writes `presentation = "background"` (`ShellState.swift:88`), `desktopTilePanels`
filters on `== "tiled"` (`:544`), so the port never reaches `contextItems`, so `presentationSnapshot`
passes `item: nil` (`:607`) and the pure mapping answers `.tiled, visible: false`
(`PortPresentation.swift:97`). That bool is what a port gates its `requestAnimationFrame` on
(`PortPresentation.swift:13`), and it also drives the AI-suspend gate and the heartbeat skip
(`ShellState.swift:614-619`). Fix: a case in the pure mapping, plus a test beside the five that
already cover the other states (`PortPresentationTests.swift:29-95`).

**Generated agent instructions hardcode one gateway port.** `~/.codex/AGENTS.md` contains
`127.0.0.1:4245` in five places, so every Codex session on the machine is told to call Dev3 whatever
instance started it. A session spawned by production authenticates with a production token against
Dev3 and fails as `auth_required`, which names the wrong problem. Observed live. The project's own
`CLAUDE.md` block already does this correctly with `${PORT42_GATEWAY_PORT:-4242}`.

**The macOS floor disagrees with itself.** `Info.plist` says `LSMinimumSystemVersion` 15.0;
`Package.swift`, `README.md:7`, `README.md:581` and `CLAUDE.md:160` all say 14. Both numbers trace to
the initial commit `12454da` and neither was ever edited. The shipped bundle refuses to launch on
Sonoma, and `build.sh:454` runs `generate_appcast`, which copies the value into the Sparkle feed, so
Sonoma users are refused updates too. The only macOS 15 API actually used is ScreenCaptureKit
microphone capture.

**Ten `ngrok` references outlived the tunnel.** `TunnelService.swift` was deleted in Phase 1;
references remain in `AppState.swift`, `GatewayProcess.swift` and `gateway/main.go`.

**Nothing handles `ContentProcessDidTerminate`.** `grep -rn "ContentProcessDidTerminate" Sources`
returns nothing, so a dead WebContent process leaves a port blank permanently, recoverable only out
of band through `port.history` and `port.restore`.

## Structural, worth knowing before building on them

**A port has no storage to ship.** `port_storage` keys resolve from the caller, not the port
(`BridgeServiceStorage.swift:58-70`), so two ports made by the same companion in one space share a
namespace, and no query enumerates one port's keys. "Ship the port's data" is currently
inexpressible.

**A port has no transcript to carry.** There are no `chat.*` methods; chat is still
`messages.recent` and `messages.send` over the `messages` table. D1's transcript-as-a-file is
unbuilt.

**`port_versions` cannot identify a port across machines.** Seven columns, no title, type,
capabilities, signature, content hash or origin (`DatabaseService.swift:303-311`). `version` is a
local `MAX+1` counter, so it is not comparable between instances. A `web` port can be rebuilt
elsewhere from `getHtml` plus `history`; a `terminal` port cannot, because its `html` column holds a
JSON config carrying the author's command, cwd and env (`PortWindowManager.swift:79-84`).

**`.ai` gates nothing.** Its engine went in Phase 1 and the only streaming method left,
`port.subscribe`, is ungated. Two tests keep the case alive
(`PortPermissionTests.swift:136`, `:152`), and three more assert nil for methods that no longer
exist (`:40-53`) and pass vacuously.

**The pause-while-covered never landed.** `grep -rn "occlusionState\|paused:" Sources` returns
nothing. The frame cap shipped; the pause did not, which matches `plan-shell-only.md:241`.

**Nothing evicts webviews.** `grep -rn "evict" Sources` returns nothing, against a prior measurement
of 88 WebContent processes at 101 ports (`plan-webview-eviction.md:1-7`).

## Test debt

Three permission tests assert `nil` for methods that do not exist and therefore pass vacuously
(`PortPermissionTests.swift:40-53`).

## Found 2026-09-26, after the first pass

**The shipped `port42` CLI is not Developer ID signed.** `build.sh:383` signs `$MACOS/port42`, but
`build.sh:326` bundles the file as `port42-cli`. The rename documented at `build.sh:309-313` never
reached the signing line, so the CLI keeps the Go linker's ad-hoc signature (`a.out`, adhoc) inside a
notarized bundle whose gateway and shim are both properly signed. Verified against `dist/Port42.app`.

**`LOCAL_PEERCRED` on a TCP socket fails open and reports uid 0.** Recorded because
`plan-caller-identity-fixes.md:79-80` already names kernel peer credentials as a deferred fix, so this
is the first thing whoever picks it up will write. `SOL_LOCAL` is `0`, which on `AF_INET` means
`IPPROTO_IP`, and `LOCAL_PEERCRED` through `LOCAL_PEERTOKEN` collide exactly with `IP_OPTIONS`
through `IP_RECVRETOPTS`. Measured: five of six options return success with garbage on TCP, and a
zero-filled `xucred` has `cr_version = 0`, which equals `XUCRED_VERSION`, so the two sanity checks a
careful implementer writes both pass and the answer is **uid 0**. Only asserting the returned length
and the socket family defends.

**The guest page destroys the guest's state on every host write.** `gateway/guestpage.go:147` reloads
the entire `srcdoc` on each `state` event, so scroll, focus and runtime state are lost every time the
host writes to the port. Cheap to fix independently of anything else.

**`port42-mcp.js` advertises four deleted methods.** `Resources/port42-mcp.js:82` tells MCP clients
that `ai.complete`, `messages.send`, `messages.recent` and `companions.invoke` are available. All
four were deleted in Phase 1. Agent-facing and wrong.

**Settings still has a tab named "AI"** (`SignOutSheet.swift:17`), after the engine it configured was
removed. User-facing; needs a look at a running instance to see what it renders.

**`ai.cancel` and `suspendAI()` are misnamed, not dead.** They are the live cancel path for
`port.subscribe` (`PortBridge.swift:704`, and `suspendAI()` is called on park and background at
`PortWindowManager.swift:540`, `:737`). The genuinely dead pair is `aiPaused` / `isSuspended`
(`PortBridge.swift:261`, `:267-278`), read only by tests, and the comment at `:281` claiming they
gate new stream calls is false.

**A child process inherits the parent's environment, including provider credentials.**
`AgentProcess.swift:54-60` and `CommandAgent.swift:117-123` pass
`ProcessInfo.processInfo.environment`, and the terminal path runs `/bin/zsh -lc`
(`CommandAgent.swift:100-108`), which sources the user's profile. Measured: `claude` authenticates
from an inherited `ANTHROPIC_API_KEY`. So D9's "the CLI authenticates under its own sign-in" holds
only for the environment Port42 hands the child, which Port42 chooses.

**A companion can be given a name it can never be mentioned by.** `MentionParser`'s pattern is
`@([a-zA-Z][a-zA-Z0-9-]*…)` (`AgentRouting.swift:121`), and the file's own comment at `:10` states it
"stops at the first space". Hyphens are in the character class; spaces are not. So a companion named
`app dev` cannot be reached: `@app dev` parses as a mention of `app`, which does not exist, and `dev`
becomes ordinary text.

The failure mode is the bad one. Nothing rejects the name at creation, nothing warns, and the message
looks addressed while reaching nobody. Observed 2026-09-26 in `#port42-app`, where an `@app dev`
mention in a `chat.post` silently reached no one.

Two ways to close it: reject or slugify a name containing a space at creation time, which matches the
pattern the autocomplete already feeds (`PortChatPanel.swift:142`); or teach the parser a quoted form
such as `@"app dev"`. The first is smaller.

**Every terminal port with a new name mints a companion, and nothing reaps them.** GM, 2026-09-26:
"a new name spawns a new companion... it keeps happening."

`autoRegisterTerminalCompanion` (`AppState.swift:1540`) writes a new `AgentConfig` row for any
terminal port whose `companionName` is not already a companion, keyed on the panel id
(`:1543`, `:1551`). The guard is per panel and per name, so it prevents a duplicate for one port; it
does nothing about volume. Spawn ten terminals with ten titles and the space has ten companions.
There is no reaper: closing the port does not remove the companion, and nothing reconciles the roster
against live ports.

Observed tonight: creating one terminal port titled "growth: editor+critic" produced a companion
named `growth-editor-critic` that outlives it.

This is the roster half of the identity inflation the permission work already measured on the grantee
half: `ClientRegistry.swift:240` keys a spawned terminal's client id on the port's session id, and
Dev3 minted 25 grantees in 12 hours, six sharing one name (`security-bridge-authorization.md`). Two
registries, the same cause, so a fix for one should be designed with the other in view.

Worth deciding rather than patching: a companion is currently created as a side effect of naming a
window. If a companion is meant to be a durable identity, it should be created by a deliberate act
and removed when its last port goes.

**Mentioning a companion spawns a second terminal instead of messaging the one it has.** GM,
2026-09-26: "if I @ one it should message, right?" It does not; it opens a new one, repeatedly.

The cause is that a companion's terminal is found by NAME, and the name is rewritten behind its back.

`ensureTerminalLive` (`AppState.swift:1018`) locates a companion's terminal with

```swift
panel.terminalConfig?.companionName.lowercased() == companion.displayName.lowercased()
```

and, finding none, concludes "fully closed" and calls `spawnTerminalAgentPort` (`:1038`).

`reconcileCompanionHandles` (`:1696`, called at boot from `:789`) folds an unaddressable companion
name into a mentionable handle: it sets `renamed.displayName = handle` and saves the **agent row**.
It updates `companions` and calls `refreshSpaceCompanions()`. It never touches the ports. So a
terminal port created before the fold still carries `companionName = "growth: editor+critic"` while
its companion row now reads `growth-editor-critic`. The two no longer match, the lookup fails, and
every mention spawns another terminal.

`spawnNativeTerminalPort` (`:1730`) normalizes the name once at spawn, so terminals created after the
normalization landed are self-consistent. The orphans are the ports that existed before it.

The same function has a second orphaning path: when a handle is already taken, the unaddressable row
is **deleted** (`:1707`), so a companion can be removed while its terminal keeps running.

**Root cause, and the fix worth making instead of a patch: a companion is identified by its display
name.** `AgentConfig` has an id and `spawnNativeTerminalPort` already accepts `companionId`
(`:1733`). Matching a terminal to its companion on id would survive any rename, fold or reap.
Matching on a mutable human-facing string cannot.
