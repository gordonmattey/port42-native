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
