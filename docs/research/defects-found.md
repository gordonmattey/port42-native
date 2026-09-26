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
