# Port42 Architecture

Port42 is a native macOS app (macOS 14 or later, Apple silicon) in which people and AI agents work
in the same place. What they make is a **port**, a live surface on a desktop. Agents are CLI agents
(Claude Code, Codex) running in terminal ports. Every port, and every space, has a chat. One API, the
**bridge**, is how ports, agents and outside tools act on the app, and a port can be shared with
another Port42 or with a browser through a relay.

This document describes the code as it stands. The API itself is documented by `llms.txt` (generated
from the registry) and, against a running app, by `port42 help api` and `port42 help ports`.

## Components

```
+----------------------------------- Port42.app -----------------------------------+
|                                                                                  |
|  Shell (SwiftUI + AppKit)                 Bridge                                 |
|    ShellView, ShellDesktop, ShellState      BridgeRegistry (one declaration      |
|    ports as tiles                           per method)                          |
|      web      (WKWebView) -- port JS -->    AppState.runBridgeMethod             |
|      terminal (Ghostty)                       args, remote gate, permission,     |
|      browser  (WKWebView)                     token, run                         |
|    a chat on every port and space                  ^            ^                |
|    permission overlay <-- PermissionCoordinator    |            |                |
|                                                    |            |                |
|  AppState (@MainActor) <-- DatabaseService (GRDB, SQLite)       |                |
|                                                                 |                |
|  GatewayDoor (WebSocket, as host) ------------------------------+                |
|  TerminalHooksService (Unix socket) <-- port42-claude-shim (Claude, Codex hooks) |
|                                                                                  |
|  Contents/MacOS/port42-gateway   127.0.0.1:<port>  /ws  /call  /health           |
|  Contents/MacOS/port42-cli       linked onto PATH as `port42`                    |
|  Contents/MacOS/port42-claude-shim                                               |
+----------------------------------------------------------------------------------+
              |
              |  WebSocket (wss) to a relay, Noise IK end to end
              v
      port42-relay  (relay1.port42.ai by default, or self-hosted)
          |                                  |
   another Port42 instance            browser guest (guest/), its page
                                      served by port42-tele at tele.port42.ai
```

### Binaries

| Binary | Source | Role |
|---|---|---|
| `Port42` | `Sources/Port42` (entry point), `Sources/Port42Lib` | The app |
| `port42-gateway` | `gateway/` (Go) | The local call door and the relay client. Spawned by the app |
| `port42-cli` | `cli/` (Go) | The `port42` command. Linked into `~/.local/bin` by `CLIInstallService` |
| `port42-claude-shim` | `shim/` (Go) | Stands in for `claude` in Port42 terminals to register hooks, and reports Claude and Codex hook events to the app |
| `port42-relay` | `gateway/cmd/port42-relay` | The relay. Not bundled; runs on a server |
| `port42-tele` | `gateway/cmd/port42-tele` | Serves the browser guest's page. Not bundled |
| `p42peer` | `gateway/cmd/p42peer` | A test peer for relay work. Not a product |

The app bundle also carries `Sparkle.framework` for updates. Dependencies are declared in
`Package.swift` (GRDB, PostHog, Sparkle, FluidAudio, and the `GhosttyKit` binary target).

## State

State flows one way, from `DatabaseService` (GRDB, SQLite) to `AppState` (the single `@MainActor`
`ObservableObject`) to the views. Views render and call methods on `AppState` to mutate. GRDB
`ValueObservation` keeps spaces and space membership in `AppState` in step with the database.

The database is `~/Library/Application Support/Port42/port42.sqlite`, in WAL mode. A dev build uses
its own directory (`PORT42_DATA_DIR`, set by the launcher `build.sh` writes). Migrations are
append-only. An existing `registerMigration` is never edited; a schema change is a new one.

| Table | Holds |
|---|---|
| `users` | The local person |
| `spaces`, `agentSpaces` | Spaces, and which companions are in each |
| `agents` | Companion configurations (`AgentConfig`) |
| `port_panels` | Ports: type, HTML or terminal config, placement, pin, and `closedAt` (closing a port archives it) |
| `port_versions` | Each distinct version of a port's HTML |
| `port_storage` | `storage.*` values, and chat transcripts in a scope no `storage.*` caller can name |
| `grants` | Permissions, keyed by grantee, object and zone |
| `clients` | Enrolled callers (see [Identity and permissions](#identity-and-permissions)) |
| `companion_watches` | Companions watching ports |
| `imagine_teams` | The team an `/imagine` started, and its version budget |
| `invites` | Invites to ports on this instance (nonce and code stored only as hashes) |
| `remote_ports` | Ports on other instances this one was invited to |

The Keychain, not the database, holds the named secrets for `rest.call` (`Port42AuthStore`), the
root secret client tokens are derived from (`ClientRegistry`), and the instance key seed
(`InstanceKey`).

## The shell

The shell is the only UI.

- **`ShellView`** is the root: the ambient background, the galaxy, and the overlays (the permission
  ask, the ⌘K switcher, the ⌘I imagine box, share and accept boxes, session import).
- **`ShellState`** holds UI-only state over `AppState`, chiefly the zoom spine: galaxy (all spaces),
  space (one desktop), focus (one port).
- **`ShellDesktop`** draws the chrome, the tiled ports, the dock and the park rail. Each port is one
  persistent unit; tile, peek and focus are geometry states of the same mounted view, so a port is
  never reloaded by moving between them.
- **`PortWindowManager`** owns `PortPanel`, the port model, and builds port webviews. A web port's
  HTML is wrapped in the Port42 theme and runs as ES modules under a CSP with no network access.

Port types (`PortCreateKind`) are `web`, `terminal` and `browser`, all made by `port.create`.
Terminal ports use GhosttyKit: one `GhosttyApp` per process, one surface per terminal, driven by
`GhosttyTerminalController` and `GhosttyTerminalView`. A browser port is a WKWebView with an address
bar. `RemoteTile` is a tile that mirrors a port on another instance.

**Addressing.** Port 0 is the desktop, and a space is a port. A `port` argument takes `0`, a space
id, or a port's id, udid or title.

## Chat

Every port has a chat (`PortChat.swift`). The transcript is stored in `port_storage`, one row per
entry, and written only through `chat.post`, which speaks as the calling principal. Each post is
published on the port's topic (`NotifyBus`) as a `chat` event, so panels, companion routing and
remote guests all learn of it the same way.

`ChatRouting` (in `PortChat.swift`) holds the routing decisions: @mention parsing for the chat field,
the line typed into a companion's terminal (`[@sender in source]: text`), and the label that tells a
companion which chat a message came from. `PortChatPanel` puts the chat in a port's title bar;
`ChatTranscript` lays it out in an AppKit text view. `ChatPresence` shows a companion taking a
message (received, working, waiting on the person), fed by terminal hook events rather than a timer.

## Bridge API

The bridge is registry-first. Each method is declared once, and every calling surface dispatches
through `AppState.runBridgeMethod` (`BridgeDispatcher.swift`).

**Declaration.** `BridgeMethod` (`BridgeRegistry.swift`) carries the permission, the positional
parameter names, a description, a JSON input schema and the body. A write also declares
`writesTarget` (which argument names the port it writes), `replacesState`, and `needsLiveSurface`.
Methods are registered in `buildBridgeRegistry` (`BridgeMethods.swift`) through per-family register
functions, some of which live beside their feature (`PortChat.swift`, `Invites.swift`,
`CompanionWatch.swift`, `Imagine.swift`, `SessionImportFlow.swift`, `BridgeServiceStorage.swift`).
Streaming methods (`port.subscribe`) are `BridgeStreamMethod`s in `buildBridgeStreamRegistry`.

**Dispatch.** `runBridgeMethod` resolves an alias, refuses undeclared arguments, forwards the call if
the target port is on another instance, applies the remote-caller gate, asks for the permission if
one is needed, applies the imagine version budget, checks the write token and the target's liveness,
runs the body, turns an error-shaped result into a coded error, announces a state change to
subscribers, and returns the value with the port's new token.

**Surfaces.**

| Surface | Path |
|---|---|
| A port's JS | `PortBridge`. `window.port42` is a generic JS Proxy over the registry; positional calls map to named arguments through `paramNames` |
| The `port42` CLI, companions, any local tool | HTTP `/call` or `/ws` on the gateway, then `GatewayDoor`, `resolveGatewayCaller` (verifies the credential), `RemoteToolExecutor` |
| Tool use | `ToolExecutor` renders results as tool-use content blocks. Tool schemas are generated from the registry (`generatedToolDefinitions`); `ToolNaming` maps snake-case tool names to canonical names, and the gateway accepts either spelling |
| In-app actions | Imagine, the share and accept boxes, and chat call `runBridgeMethod` directly |

Every surface returns the same `BridgeValue` JSON.

**Write tokens.** Every write verb takes the port's `token`. A write without one is refused with
`token_required`, and one composed against stale state with `stale_write`; both carry `current`.
`ports.list`, `port.create` and every write return a token.

**Errors.** Codes are a closed set (`BridgeErrorCode`). The gateway's own codes
(`gateway/errorcodes.go`) must each exist there; a Swift test scans the Go file.

**Generated artifacts.** These are committed and checked by tests, so they cannot drift from the
registry:

| Artifact | Test | Regenerate with |
|---|---|---|
| `llms.txt` | `BridgeDocsExportTests` | `PORT42_REGEN_DOCS=1` |
| `Sources/Port42Lib/Skills/port42-skills/skills/*/reference.md` | `SkillCatalogTests` | `PORT42_REGEN_SKILLS=1` |
| `Tests/Fixtures/tool-definitions-golden.json` | `BridgeSchemaParityTests` | `PORT42_REGEN_GOLDEN=1` |
| `guest/src/methods.json`, `guest/src/port-page.json` | `GuestMethodsTests` | `PORT42_REGEN_GUEST=1` |

`Resources/llms-preamble.txt` and `Resources/ports-context.txt` are the hand-written parts of the
API reference and the port manual. `PublishedDocs` renders the code-derived blocks (error codes,
event kinds, the event envelope) into them.

## Identity and permissions

**Principals.** Every call is made by a `Principal`: `port` (a port's JS), `companion` (tool use),
`peer` (a gateway caller on this Mac), `remote` (a caller on another machine) or `human` (the local
person). The initializer is private; every identity comes from a named factory in `Principal.swift`.
Grants key on the principal's `id`, never its display name.

**Clients.** `ClientRegistry` is the only place a token is minted, named or revoked. Client kinds:

| Kind | Who | How enrolled |
|---|---|---|
| `child` | A terminal or command agent Port42 spawned | At spawn. Its token path is `$PORT42_TOKEN_FILE`, its name `$PORT42_CLIENT_ID` |
| `installed` | The `port42` CLI | At install |
| `manual` | The person's own scripts | Added in Settings, Access |
| `peer` | Another instance or a browser guest | Redeeming an invite. Recognized by its peer key; holds no token |

The gateway carries credentials opaquely and never parses them; the app verifies them. A gateway call
with no credential is refused with `auth_required`.

**Permissions.** `PermissionCoordinator` is the one queue for every permission ask. Asks from the
same principal for the same permission coalesce into one card, and `ShellPermissionOverlay` renders
the queue once, at the shell root. A grant persists in `grants`, keyed by grantee, object and zone;
machine capabilities are grants on port 0 (`PortObject`). The person can see and revoke grants in
Settings, Access. A remote caller never raises a card.

## Companions

Port42 runs no model of its own. Every companion is a command companion (`AgentMode.command`), in
one of two forms:

- **A CLI agent in a terminal port** (Claude Code or Codex). It can run hidden, reached only through
  its chat (`runsHidden`).
- **A headless command** that reads and writes NDJSON on stdin and stdout (`CommandAgent.swift`).

**Hooks.** `TerminalHooksService` listens on a Unix domain socket for Port42's normalized events
(`turnComplete`, `needsAttention`, `toolStarting`, `toolFinished`, and others). `CLIHookProducer`
prepares each session for its CLI. Claude Code is intercepted by a per-session `claude` link to
`port42-claude-shim`, first on `PATH`, which adds `--settings` registering hooks that call the shim
back in notify mode. Codex needs no interception. `CODEX_HOME` points at a directory Port42
prepares, whose `config.toml` points its hooks at the same shim.

**Routing.** A chat post that mentions a companion, or reaches one as a member, is typed into its
terminal as one line (`ChatRouting.terminalLine`). The companion's `turnComplete` posts its reply to
the chat that asked. `MentionParser`, `CompanionName` and `AgentRouter` (`AgentRouting.swift`) keep
names and mentions consistent.

**Watches.** `CompanionWatch` lets a companion watch a port for named event kinds. Events during a
turn are held and delivered together, and an hourly ceiling pauses a runaway watch.

**Imagine.** `/imagine <line>` in a chat, or ⌘I, creates a space, a placeholder port and three
companions (a lead and two engineers) on the CLI the person chose, with a version budget (default
10, at most 20). From then on they are ordinary companions (`Imagine.swift`).

**Bringing sessions in.** Session import (`SessionImport.swift`, first run and ⌘K) finds running
Claude Code and Codex sessions and brings them into spaces. `port42 teleport` does the same for one
Claude Code session from its own terminal.

**What agents are told.** `InstructionService` writes a short pointer block into `~/.claude/CLAUDE.md`,
`~/.gemini/GEMINI.md` and `~/.codex/AGENTS.md`. The skills plugin
(`Sources/Port42Lib/Skills/port42-skills`: `port42`, `port42-ports`, `port42-compose`, `port42-team`,
`port42-devices`) loads in Port42 terminals; `port42 skills install` installs it for other sessions.

## Gateway

`GatewayProcess` spawns `port42-gateway` bound to `127.0.0.1:<port>` (4242 for the installed app;
each dev instance has its own, set by `build.sh`) with `-watch-parent`. The app writes three lines to
its stdin (the host credential, the instance key seed and the attestation key), so none of them
appears in the environment or the arguments. The host credential and the attestation key are fresh
on every spawn. When the app exits by any means, stdin reaches EOF and the gateway exits. A gateway that dies unasked is respawned, at most five times
a minute.

| Route | Purpose |
|---|---|
| `/ws` | WebSocket. The app connects as host; callers may connect here too |
| `/call` | HTTP request and response. Streaming methods are refused here |
| `/health` | Liveness |
| `/` | A landing page |

Envelope types are `identify`, `welcome`, `call`, `response`, `stream`, `remote_call` and `error`.
The host claim is accepted only with the host credential. Non-host peers are limited to 30 frames a
second, and a message to 2 MB. The gateway routes calls and nothing else; it holds no channels,
messages or presence.

## Sharing

**Identity.** Each instance has one Ed25519 key (`InstanceKey`, seed in the Keychain). Its public key
is the instance's peer id. Two Macs are two peers, and so are two instances on one Mac.

**Relays.** The gateway registers as a host on each configured relay, proving its key by signing a
challenge. The default is `wss://relay1.port42.ai/v1`; the person can change the list in Settings,
Relays. The relay (`gateway/relay/server.go`) pairs a guest with a host by key and forwards frames.
Everything after pairing is `Noise_IK_25519_ChaChaPoly_SHA256` (`gateway/relay/noise.go`), so the
relay forwards ciphertext it cannot read or alter undetected, and it stores nothing.
`gateway/transport` is the seam the door sees; the relay is one implementation.
`docs/run-a-relay.md` covers running your own.

**Inbound calls.** The remote door (`gateway/remote.go`) stamps the transport-authenticated peer id
on each call with an HMAC under the attestation key, and the app builds a `remote` principal only
from an attested call. `RemoteAccess.table` classifies every registry method as reachable on a named
port with a given right, as a listing filtered to granted ports, or never; `RemoteAccessTests` fails
until a new method is classified. Rights are `see`, `use`, `edit`, `wake_agents`, `fork` and `move`.

**Invites.** `invite.create` makes a link, `https://tele.port42.ai/#<coupon>`. The coupon names the
host's peer id, its relays, one port, the rights, a one-time nonce and an expiry, and can require a
six-digit code sent separately. The fragment never reaches a server. Redeeming enrolls the redeemer
as a `peer` client with those rights on that port. The app also accepts `port42://invite#<coupon>`.

**Outbound calls.** Accepting an invite (`AcceptBox`, `invite.accept`) records the port in
`remote_ports` and opens a `RemoteTile`. Calls to that port leave through the host connection as
`remote_call`, and `gateway/outbound.go` dials the other instance through its relays with this
instance's key.

**Browser guest.** `guest/` is a guest-only Port42 in the browser. It holds the relay client, Noise
IK, the guest's identity (kept in the browser's storage), and the shared port's page, which runs in a
sandboxed iframe whose `window.port42` shim posts each call to the parent page. `npm run build` bundles `src/` into
`dist/port42-guest.js` and writes its SHA-384 into `invite.html`. `port42-tele` serves `invite.html`,
`frame.html` and the bundle with strict CSPs; `tele.Dockerfile` builds its image.

## Voice input

Hold space to talk. `VoiceTrigger` tells a hold from a typed space by duration, `VoiceCapture`
records 16 kHz mono, and `VoiceTranscriber` runs NVIDIA's Parakeet TDT v3 on device through
FluidAudio. The model is not in the app bundle; it is downloaded on first use into FluidAudio's cache,
shared by every instance on the Mac (`BUNDLE_MODEL=1 ./build.sh` bundles it instead).
`VoiceInserter` puts the text into the chat field, a web port or a terminal through
`NSTextInputClient`. With Accessibility granted, `VoiceGlobalTrigger` and `VoiceTyper` dictate into
other apps, and `VoiceHUD` shows the live microphone.

## Other services

- **Devices.** Audio, camera, screen and screen recording, clipboard, files, notifications,
  AppleScript and JXA automation, and headless browser sessions (`*Bridge.swift`,
  `ScreenRecorder.swift`), all reached through the registry. `rest.call` injects Keychain secrets as
  headers.
- **Updates.** Sparkle. The release build generates `dist/appcast.xml`.
- **Analytics.** PostHog (`Analytics.swift`), sent only after the person opts in.

## Repository layout

| Path | Contents |
|---|---|
| `Sources/Port42/Port42App.swift` | `@main`, the app delegate (`port42://` links, Sparkle) |
| `Sources/Port42Lib/Models` | `AppUser`, `AgentConfig`, `Space` |
| `Sources/Port42Lib/Services` | `AppState`, `DatabaseService`, the bridge, gateway door, identity, permissions, companions, sharing, devices, voice |
| `Sources/Port42Lib/Views` | The shell and its surfaces |
| `Sources/Port42Lib/Theme` | `Port42Theme` (colors, fonts) |
| `Sources/Port42Lib/Resources` | The API preamble, the port manual, media |
| `Sources/Port42Lib/Skills/port42-skills` | The skills plugin |
| `Sources/Port42Lib/DebugHarnesses` | `#if DEBUG` in-app probes |
| `Tests/Port42Tests`, `Tests/Fixtures` | Swift Testing suites and their fixtures |
| `gateway/` | Gateway, relay, tele, transport, and their Go tests |
| `cli/`, `shim/` | The `port42` command and the Claude hook shim |
| `guest/` | The browser guest, its page and its tests |
| `build.sh` | Build, test gate, packaging, signing, release |
| `docs/` | Plans, designs and guides |
