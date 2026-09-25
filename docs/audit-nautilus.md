# Nautilus audit: what exists, what each scenario needs, what the baseline shows

Date 2026-09-24. Branch `nautilus`. Measured against the Dev3 instance (port 4245) running the
`slice-02-wire` head plus the plan, database `~/Library/Application Support/Port42Dev3`. Every
number below was read from the tree or the live instance on this date; nothing is restated from
older documents. Companion to `plan-shell-only.md`, which this audit grounds.

Caller note: this session has no Port42 client of its own. Live calls were made with the installed
CLI's token, limited to ungated methods, and the one gated thing a scenario needed (a companion
answering a prompt) ran in the companion's own terminal under its own credential. Settings → Access
should get a client for this session before any further live work.

## 1. Baseline: the five scenarios on the tree as it stands

| # | Scenario | Result | Evidence |
|---|----------|--------|----------|
| 1 | Make a thing | PASS | `@swift-otter make me a web port with a chart of my CPU usage` sent 23:02:36; port `nautilus s1 cpu` listed in space-3 at 23:03:34, created by the companion's terminal client, 4 KB, canvas chart fed by `automation.runJXA`. No in-app model involved. |
| 2 | Drive a thing | PASS | As client `port42-cli`: `port.create` returned token `:0`; three `port.update` calls threaded `:0`→`:1`→`:2`→`:3`; a write with the `:0` token refused `stale_write` with `current: :3`; a write with no token refused `token_required`. The port lists `createdBy: port42 CLI`; the `driver` event names `port42 CLI`. Access lists the client with its one grant (`terminal`, last used today). |
| 3 | Compose things | PASS | Three web ports, no code outside them. A publishes `{n}` each second via `port.publish`; T subscribes to A, publishes `{tenfold: n*10}`; R subscribes to T and renders. R's log showed `1010, 1020, … 1070` within the first read. A separate two-port run reached 99 events in 99 seconds with no gap. Out-of-process subscribe over `/ws` delivered `driver` and `state` frames carrying the token. |
| 4 | Share a thing | PASS, local half only | Guest page served at `/port` (HTTP 200, 8 KB). A browser-less guest over `/ws`: subscribe stream live; stale write refused with `current`; retry with `current` landed (`:4`→`:5`); the in-app tile changed. Not tested: another machine, a second identity (so "both driver chips agree" is unmeasured). |
| 5 | Arrange things | FAIL on `slice-02-wire`, PASS with the layout branch merged | Moved one port to (222, 333); read back exactly. Restarted the instance. Spaces `general` and `space-2` held every position and the parked port stayed parked. Space-3, which had gained six ports since its last layout, was re-tiled onto a grid: the moved port landed at (55, 372), the companion terminal moved from x=1081 to x=756, the chat tile from x=560 to x=365. The inline `echo` port left the list (inline presentation is session-only by design, `PortWindowManager.swift:291`). |

What the baseline says: the kernel already does 1 through 4 on one machine. Scenario 4's remote half
and scenario 5 are the product work. Nothing in the messaging system was exercised by any pass except
as transport for the door (finding F1) and as the channel the prompt travelled on (finding F4).

**Harness baseline, 2026-09-25** (`scripts/scenarios/run.py`, client `nautilus-harness`, Dev3 on
`nautilus` at `e40ab8f`):

| # | Result | Evidence |
|---|--------|----------|
| 1 | FAIL | The mention reached the companion and it replied in 12 s, but with a port fence; the chat tile was parked, so no port appeared (F12). |
| 2 | PASS | Four tokens threaded; stale and tokenless writes refused; `createdBy` is the harness client. |
| 3 | PASS | Render received 12 transformed events in 6 s; produce to render median 2 ms, max 3 ms. |
| 4 | FAIL | A guest giving its credential once at identify is refused `auth_required` on subscribe and on write (F2). The gate for Phase 0 step 4. |
| 5 | PASS | Six ports across two spaces, two parked, one added: nothing moved; restart moved nothing. |

**Harness, after Phase 0 step 1b** (manuals teach `port.create`; scenario 1 asks a fresh session):

| # | Result | Evidence |
|---|--------|----------|
| 1 | PASS | A fresh `claude` session made the port with `port.create` in 12 s. |
| 2 | PASS | Unchanged. |
| 3 | PASS | 12 events in 6 s; median 3 ms, max 6 ms. |
| 4 | FAIL | Unchanged: identify-only credential refused (F2, step 4). |
| 5 | PASS | Unchanged, restart included. |

**Harness, after Phase 0 step 4** (2026-09-25): **all five pass.** Scenario 4's guest gives its
credential once at identify, receives live state events, is refused a stale write with `current`,
and lands its retry.

## 2. Findings that change the plan

**F1. The door rides the hub.** `/call` → gateway → WebSocket → the app identified as host peer →
`SyncService.handleCall` (`SyncService.swift:736`) → `AppState.onCallReceived` (`AppState.swift:1553`).
The app has no listener of its own. `SyncService` has exactly one user (`AppState`) and one shell
function (`onCallReceived`) beside sixteen messaging ones. Phase 0 stays as written.

**F2. The WebSocket door drops the identify credential.** `routeCall` (`gateway.go:999`) forwards the
call envelope as received; the credential given at `identify` is not stored on the peer and not
stamped on later calls. A WS caller must put `credential` on every call envelope. The guest page sends
its `port.subscribe` without one (`guestpage.go:131`), so on this build the guest's live half is
refused with `auth_required`; its writes go over HTTP with a bearer header and work. Fixed in
Phase 0 by stamping the peer's identify credential in `routeCall` (D5), which matches the design
comment at `gateway.go:67` ("carried opaquely, the app derives the principal").

**F3. Scenario 5 fails on re-tile, not on persistence.** Positions persist (the moved port read back
before restart and the two untouched spaces held). A space whose port set changed since its layout
is laid out again on load. Cause located on branch `shell-layout-place-not-arrange` (2d42eb1): spawn
and close re-gridded every tile, and arrange dealt cells by z. That branch replaces it with placement
into a free spot. Re-run on the merged tree 2026-09-24: six ports across two spaces, two parked, a
port added afterwards, restart. The newcomer took a free spot, and every position and status was
identical after the restart. Suite 1424 green.

**F4. Scenario 1 works with no in-app model.** The prompt reached a command companion through the
`@mention` router (`AgentRouting.swift`, zero `sync.` references) and the companion built the port
from its own terminal under its own credential. The in-app engine (`LLMEngine`, `GeminiEngine`,
`LLMBackend`, `LLMStreamCollector`, `BridgeServiceAI`, `AgentRouterLLM`, `AppState+PortAI`,
`AgentAuth`, `ModelPicker`, `UsageView`, `token_usage`) served `.llm` companions only. The plan's
LLM table stands: none in the kernel.

**F5. The prompt travelled on the messages table.** `messages.send` wrote a row, the router read it,
the companion's reply and the `[portref:…]` card are rows. Inline-presented ports anchor on a chat
message. "Chat is a port" therefore has a concrete meaning: the chat tile keeps a per-space
transcript, and the transcript is that port's state. Whether it stays in the `messages` table or
moves under the port is decision D1.

**F6. A port's version history is unbounded.** New noise is stopped on the layout branch (identical
HTML no longer writes a version); the rows already written still need a reap. `port_versions` holds 1,848 rows for 19 panels; one
port has 177. The only delete is the full reset. `port.history` and `port.restore` read it. A cap or
a reap belongs in Phase 1.

**F7. `createdBy` shows the raw client id for a companion's port.** The scenario 1 port lists
`terminal-ce51bc77-…-d450f484-…` where the companion's own terminal lists `swift-otter`. The name a
person sees should be the companion's codename. Small, Phase 1.

**F8. An orphan.** One `port_panels` row (`db comparator`) sits in a space id that no longer exists,
and `ports.list --all_spaces` returns it. Reap on load or refuse to list; Phase 1.

**F9. Skills are not installed.** `~/.claude/skills` has no `port42-*` entry and no scaffold exists
in a sibling repo. `InstructionService` writes only the slim pointer block. Phase 5 starts from zero,
with `plan-port42-ports-skill.md` as the one prior design.

**F11. Two instances can share one data directory.** `build.sh` stops a running instance by its own
bundle path, and a worktree build writes its bundle to `~/port42-build-<worktree>`. So a Dev3 built from
a worktree launched beside the Dev3 already running, and both processes opened the same SQLite file
until the old one was stopped by hand. The kill should key on bundle id or data directory. Found
while re-running scenario 5; not a nautilus phase, a build fix.

**F12. A port made by a code fence exists only if the chat renders it.** Asked to "make a web port",
a command companion may answer with a ```` ```port ```` fence in its reply instead of calling
`port.create`. The fence becomes a port only when the chat tile renders the message. On 2026-09-25 the
space's chat was parked, the companion replied in 12 seconds, and no port ever appeared. Phase 1
decides the fence's fate with the chat port: either a fence in a chat message creates a real port
whether or not anything renders it, or fences go and the skill (Phase 5) steers agents to
`port.create`.

**F13. `ports.list` has no `all_spaces` argument.** Every audit call passed one; it was ignored, and
the method returns every space by default. A live instance of the silent-argument defect Phase 0
step 6 fixes.

**F14. A resumed companion answers from its transcript, not the manual.** After the manuals were
rewritten, `swift-otter`, respawned onto its old session, answered "make a web port" with a fence in
five seconds without reading anything. A fresh session read the new manual and called `port.create`.
Consequence for Phase 5: a skill or manual change reaches only new sessions, so shipping one means
new sessions for long-lived companions.

**F15. The space member list lags and duplicates.** A companion that auto-registered did not appear
in `space.current` members within 90 seconds, while one closed earlier appeared twice. Mention
routing ignores the list and worked. Membership is replaced by subscription in Phase 1.

**F16. `messages.send` from a client speaks as the human.** The harness's message reached the
companion as `[@gordontest3]`, the person, not `nautilus-harness`. An API caller can put words in the
person's mouth. In Phase 1 a mention becomes a port event, and it must carry the caller who sent it.

**Corrected 2026-09-25: opening a terminal is consented.** Section 5's claim that `port.create`
spawns agents ungated came from a July todo item. A client without the grant raises a permission
card; approving records `terminal` on port 0.

**F17. A dead gateway stayed dead.** `GatewayProcess` noted the exit and did nothing, so a gateway
crash refused every caller until the app was relaunched. Fixed in Phase 0 step 2: respawn on an
unasked exit, at most five times a minute.

**F18. The app's main thread stalls for up to 70 seconds in SwiftUI layout during port churn.** Seen
three times on 2026-09-25 while the harness created and closed a dozen ports in a row. Calls queue
behind it, so a harness step times out and the scenario flakes. The sample shows `NSHostingView.layout`
and attributed-text rendering, with no Port42 frame beneath. The accumulated chat is a plausible
driver: space-3's chat holds 139 messages, 101 of them `[portref]` cards that every `port.create`
posts. Not root-caused. Phase 1 removes both the native chat and the cards, and the harness will show
whether the stall goes with them.

**F10. The port-positioning gap is closed.** `port.move` and `port.position` exist and worked live.
The memory note claiming the gap is retired with this audit.

## 3. Inventory

| Area | Files | Lines | Notes |
|------|-------|-------|-------|
| `Sources/Port42Lib` + `Sources/Port42` | 104 Swift | 48,668 | Services 60, Views 30, Models 6, Theme 2, App 1 (approx.) |
| `gateway/` | 7 Go | 2,076 | gateway.go 1,106 · main.go 374 · guestpage.go 182 · apple_auth.go 191 · store.go 132 · credentials.go 91 |
| `cli/` | 5 Go | 836 | Subcommands: `teleport`, `help`. Not a general caller. |
| `shim/` | 1 Go | 374 | Hooks notifier for Claude and Codex |
| `Tests/Port42Tests` | 138 suites | | 1,394 tests green at the last Dev3 build |
| `docs/` | 101 md | | largest: summer2026-todo 4,659 · slice-02-cross-instance 1,913 · protocol-local-bus 1,821 |
| Migrations | v1 … v45 | | Live tables: 18 |

Largest Swift files: AppState 4,015 · DatabaseService 2,086 · BridgeMethods 1,758 · PortWindowManager
1,698 · ConversationContent 1,654 · ShellView 1,541 · SignOutSheet 1,480 · ShellDesktop 1,450 ·
SetupView 1,151 · ShellState 1,122 · SyncService 886 · DolphinProtocolView 789 · PortBridge 770 ·
LLMEngine 755.

## 4. Dependency map

Reverse dependencies were computed by type-name reference across all Swift files with comments
stripped. The numbers below are "how many files name this type".

**The kernel spine** (everything routes through these): `AppState` 33 · `Port42Theme` 20 ·
`AgentConfig` 16 · `BridgeErrorCode` 16 · `Space` 15 · `BridgeValue` 14 · `PortPermission` 14 ·
`PortBridge` 12 · `Principal` 11 · `ShellState` 11.

**Messaging, and who reaches it.** `SyncService` ← AppState only (34 `sync.` sites in AppState).
`TunnelService` ← AppState, SpaceInvite. `SpaceInvite` ← NgrokSetupSheet, OpenClawSheet,
QuickSwitcher, TransitionRoot. `AgentInvite` ← QuickSwitcher, TransitionRoot. `SpaceCrypto` ←
AppState, Space, SyncService. `AppleAuthService` ← AppState, SetupView, SyncService. `Message` ←
AgentRouterLLM, AppState, BridgeMethods, CommandAgent, DatabaseService, SyncService. Persistence of
messages is called from AppState (22 sites), SyncService (5), BridgeMethods (2), ChatView (1),
CommandAgent (1).

**The in-app engine, and who reaches it.** `LLMEngine` ← AgentRouterLLM, AppState+PortAI,
BridgeServiceAI, LLMBackend, LLMStreamCollector, ShellDesktop (one line: `LLMEngine.paused`),
SignOutSheet (one line: `testConnection`). `AgentRouterLLM` ← AppState (three `route(` sites).
`companions.invoke` guards on `mode == .llm` (`BridgeMethods.swift:102`).

**Shell views, tendrils counted by line.** SetupView: Apple sign-in 15, Claude Code setup 18.
SignOutSheet: ngrok 22, engine/auth 13. QuickSwitcher: invite 11, friends 4. ChatView: sync 4,
typing 5. ConversationContent: typing 24. ShellDesktop: sync 3, tunnel 4. ShellView: BYO-agent sheets
13. TransitionRoot: invite 5.

**Gateway.** Door: `HandleHTTPCall` 124 lines, `routeCall` 54, `routeStream` 19, `routeResponse` 32,
`HandleWebSocket` 202 (identify plus the envelope switch), `Send` 61, host credential 20. Hub:
`joinChannel` 111, `routeMessage` 56, `leaveChannel` 40, `removePeer` 35 (partly), `handleCreateToken`
34, `flushStoredForChannel` 30, `broadcastPresence` 30, `flushStored` 24, `routeReceipt` 23,
`broadcastTyping` 20, `storeForPeer` 11, nonces 22, plus `store.go` and `apple_auth.go` whole. The
hub is roughly 580 of 1,106 lines in `gateway.go` plus 323 in the two files.

## 5. Scenario map: every source file, and which scenario needs it

Legend: K kernel (every scenario) · 1–5 scenario · M messaging (no scenario) · L in-app engine (no
scenario) · S spike or probe · D decision (section 10).

**Bridge and registry (K):** BridgeArgs, BridgeDispatcher, BridgeErrorCode, BridgeMethods (trim the
`messages.*`, `bus.*`, `companions.invoke` families), BridgeReference, BridgeRegistry, BridgeValue,
Principal, PortPermission, PermissionCoordinator, ToolNaming, PublishedDocs, ServiceManifest,
ToolExecutor (only as `RemoteToolExecutor`, the door's adapter), NotifyBus, PortEventKind,
PortActivity, PortPresence, PortInput, PortResolution, PortAddress, PortObject, PortOwnedResource,
PortCreate, PortConsole, PortExecJS, PortLibrary, PortPlacement, PortPresentation, ShellExec.

**Identity and callers (K, 2, 4):** ClientRegistry, CLIInstallService, InstructionService (Phase 5
installs skills through its boot refresh), GatewayProcess (shrinks to the door), Port42App.

**Companions (1, 2):** AgentRouting (MentionParser, AgentRouter, CompanionName), AgentProcess,
AgentProtocol, CommandAgent, CompanionCodename, ClaudeSessionId, CLIHookProducer, CLIHookProducerClaude,
CLIHookProducerCodex, CodexConfigMerge, TerminalHooksService, TerminalOutputProcessor,
GhosttyApp, GhosttyTerminalController, GhosttyTerminalView, ClaudeCodeSetup, ClaudeCodeSetupView.
Models: AgentConfig (drop the `.llm` mode and its provider, model, thinking, secret columns).

**Device bridges (1, and any port that asks):** AudioBridge, AutomationBridge, BrowserBridge,
CameraBridge, ClipboardBridge, FileBridge, FileDropUtil, NotificationBridge, ScreenBridge,
ScreenRecorder, RecordFraming. Scenario 1's port used `automation.runJXA`; the rest stay because a
grant system with nothing to grant is not a kernel.

**Shell (5, and the surface for all):** ShellMode, ShellState, ShellView, ShellDesktop,
ShellBackground, ShellPermissionOverlay, ShellShared, PortView, PortBridge, PortWindowManager,
QuickSwitcher (drop invite paste and friends), NewSpaceSheet, TransitionRoot (drop invite routes),
SetupView (shrinks to display name and CLI install), SignOutSheet (shrinks to Access and gateway),
Port42Theme.

**Chat (1, D1):** ChatView, ConversationContent, Message, the `messages` table, `input_history`.
The prompt surface and the transcript. Stays as a tile now; becomes a port under D1.

**Messaging (M, cut):** SyncService (after the door is lifted out), TunnelService, AgentInvite,
SpaceInvite, SpaceCrypto, AppleAuthService, Port42Members, NgrokSetupSheet, `friends` on AppState,
typing indicators, read receipts, `Space.encryptionKey`, `Space.syncEnabled`, `AppUser` signing keys,
`users.appleUserID`, `messages.syncStatus`, `swimMessages`.

**BYO agents over invites (M, cut):** OpenClawService, OpenClawSheet, PythonAgentSheet,
AgentConnectSheet. All four ride a space invite with an encryption key. The sibling repos
`port42-openclaw` and `port42-python` go with them.

**In-app engine (L, cut):** LLMEngine, GeminiEngine, LLMBackend, LLMStreamCollector, BridgeServiceAI,
AgentRouterLLM, AppState+PortAI, AgentAuth, ModelPicker, UsageView, the `ai.*` methods,
`token_usage`, the `LLMStreamDelegate` and "Space Agent Response Handler" regions of AppState
(lines 115–687).

**Keeper and memory (no scenario, cut):** BridgeServiceKeeper, CompanionRelationship,
CreaseInspectorSheet, the four `companion_*` tables (all empty on Dev3).

**Storage service (no scenario, D3):** BridgeServiceStorage, `port_storage` (empty on Dev3).

**Cinematics (no scenario, D4):** DolphinProtocolView, LockScreenView, DolphinCursor, the video
dreamscape in TransitionRoot. Heartbeats (`Space.heartbeatInterval`, `heartbeatPrompt`, the
Heartbeats region of AppState) belong here too: they prompt an `.llm` companion on a timer.

**Spikes and probes (S):** Retired spikes to delete: GhosttyProbe, GhosttyResizeSpike,
PortDesktopSpike, PortResizeSpike, ScreenRecordSpike, MainLoopProbe, GhosttyDebugHarness. Instruments
that still gate the shell, keep: PortRenderProbe, RestWakeProbe, ActorProbe, PortInputProbe.

**Analytics:** PostHog through `Analytics`. No scenario needs it. Product decision, default keep.

## 6. Gateway map

Keep: `main.go` routes `/ws`, `/call`, `/health`, `/port`; `HandleWebSocket` identify half and the
`call`, `response`, `stream` cases; `addPeer`, `removePeer` (minus channel bookkeeping); `rateOK`;
`Send`; host credential; `HandleHTTPCall`, `routeCall`, `routeStream`, `routeResponse`;
`errorcodes.go`; `credentials.go`; `guestpage.go` (spike today, the Phase 4 surface).

Cut: `join`, `leave`, `message`, `typing`, `create_token`, `read`, `ack` cases and their functions;
`storeForPeer`, `flushStored`, `flushStoredForChannel`; nonces; `store.go`; `apple_auth.go`; the
`/invite` route and its landing page.

Decided: F2 stamping lands in Phase 0; the remote transport is libp2p behind a pluggable seam and
ngrok goes (Phase 4, D5, D6).

## 7. Schema

| Table | Rows (Dev3) | Verdict |
|-------|-------------|---------|
| users | 1 | keep; drop publicKey, privateKey, appleUserID |
| spaces | 4 | keep; drop encryptionKey, syncEnabled, heartbeatInterval, heartbeatPrompt |
| agents | 7 | keep; drop mode, provider, model, thinking*, providerBaseURL, secretNames, systemPrompt |
| agentSpaces | 8 | keep |
| clients | 16 | keep |
| grants | 1 | keep |
| port_panels | 19 | keep; reap orphans (F8) |
| port_versions | 1,848 | keep; cap (F6) |
| input_history | 5 | keep |
| messages | 124 | D1; drop syncStatus, senderOwner either way |
| swimMessages | 0 | drop (swims retired) |
| port_storage | 0 | D3 |
| token_usage | 12 | drop |
| companion_positions, _creases, _folds, _engravings | 0 each | drop |

Migrations are append-only. A drop is v46 onward; the 45 existing entries stay as history.

## 8. Tests

138 suites. Cut with their subject (about 24): AppleAuth, ChannelCrypto, EncryptionIntegration,
SyncAuth, MessageBus, MessageSegment, Swim, SwimUnification, DirectSpaceLookup, SenderOwner,
AgentProvider, GeminiEngine, GeminiToolFormat, BridgeAIService, PortAIResolution,
StreamCollectorHardening, BridgeParityMemory, D4MemoryScope, CompanionRelationship, AgentAuth,
CompanionInitiative, CompanionPostGate, GatewayReclaimSafety (re-read: it may guard the door),
BridgeComms (re-read: it covers `messages.*`).

Keep everything else. The gates that matter most for this work: BridgePrincipal, ClientRegistry,
CLIIdentity, PortActivity, PortCAS, PortSubscribe, PortStateEvent, DriverAttribution, PortUnit,
ShellLayout, ShellState, RestWake, PublishedDocs, BridgeDocsExport, SessionEnvContract.

New tests the plan needs: the door without the hub (Phase 0), WS credential per call (F2), a
restart that must not re-tile (F3), a version cap (F6).

## 9. Docs

**Live, governs this work (26):** plan-shell-only, this audit, membrane/slice-02-cross-instance,
plan-web-port-sharing, browser-guest, ux-port-sharing, invite-taxonomy, design-append-writes,
slice02-risks-and-decisions, survey-crdt-and-transport, decision-identity-model,
architecture-invariants, plan-port42-protocol-local-bus, membrane/bus-architecture,
bridge-architecture-and-mcp, plan-api-unification, plan-caller-identity-fixes, plan-teleport,
plan-port42-ports-skill, plan-knowledge-distribution, plan-port42-shell, spec-shell-reimplementation,
shell-style-guide, plan-port-units-render-refactor, plan-working-set, plan-port-presentation-state,
plan-companion-cwd, summer2026-todo (as backlog).

**Contradicts the plan, mark superseded on the cut (24):** e2e-encryption-plan,
plan-f506-f509-remote-identity, plan-f511-relay-auth, plan-gateway-auth-tls (the TLS half may return
with Phase 4), openclaw-channel-adapter-spec, plan-http-agent-sdk, plan-swim-channel-unification,
plan-swim-is-space and its three phase docs, plan-spaces-rename, companion-architecture,
companion-scopes, companion-scopes-implementation, multi-provider-llm, plan-oauth-opus-access,
plan-anti-drowning, plan-standing-intent, plan-computer-use, hermes-engine-investigation,
hermes-integration-map, plan-chat-ui, membrane/membrane-spec, membrane/membrane-requirements,
membrane/membrane-architecture (the person-to-person assumptions; the grant model in
slice-01-trust-core stays live).

**Historical, done or overtaken (about 45):** the ports plans and spec, the terminal plans, the
unification plan, the retire-classic plan, the teardown and eviction plans, the handoffs, the RCAs,
the spikes, the gateway security audit, the early bug reports, boot-sequence-tweaks,
backlog-review-2026-07-20. Leave in place; none is load-bearing.

**Not this domain (untouched):** growth-strategy, gtm-engineering-teams, positioning-anti-drowning,
one-pager-2026-07, one-pager-working-notes, shell-with-intelligence-thesis, spec-mvp-extraction,
pluggable-primitives-architecture, membrane/make-or-break, membrane/plays-with-others.

**Summer todo items closed by the cut rather than done:** ngrok not staying off, the dev gateway
sharing prod's store-and-forward database, stale membership rows, swims, `companions.invoke` for
command companions, companion-global memory, the anti-drowning system. Bugs outside the plan stay in
`summer2026-todo.md`: terminal text input (`NSTextInputClient`), the `screen.stream` pointer glitch,
the lost permission prompt (unconfirmed).

## 10. Decisions this audit puts to GM

D1. Decided 2026-09-24: the transcript is a file the chat port owns, one per scope, append-only,
kept through the storage service (D3). Companions hear the chat by subscribing to the chat port, not
by reading the file. The mention router and the teleport hooks move off the `messages` table onto
that event stream in Phase 1, and the table goes after.

D2. Decided 2026-09-24: the native chat tile goes in Phase 1 with the `messages` table, and the chat
port replaces it. No bridge period. Chat is scoped to a port, and every scope is a port: desktop
(port 0), space, and individual port. Companion membership becomes subscription.

D3. Decided 2026-09-24: storage stays. Ports need it, and it is unused because an author cannot tell
it exists or why it beats browser storage (a port's webview is non-persistent, and storage survives
remount, eviction and restart). Fix is discoverability: the port manual and the `port42-port` skill
lead with it.

D4. Decided 2026-09-24: cinematics stay (lock screen, dolphin protocol, dreamscape). Heartbeats are
separate: they prompt a companion on a timer and today reach `.llm` companions only; they return if a
command companion can take a timed mention.

D5. Decided 2026-09-24: the remote lane is libp2p, and ngrok goes. The local door stays loopback-only
(HTTP and WebSocket for the CLI, companions and the in-app webviews), and gets the small fix of
stamping the identify credential on each forwarded WebSocket call. Remote callers arrive over a
libp2p stream, where the Noise handshake authenticates the peer id, so no bearer token crosses the
internet and a grant is keyed on the remote peer. The browser guest reaches the instance over
WebRTC-direct or WebTransport, both of which go-libp2p can listen on. Open inside Phase 4: where the
guest page is served from once the gateway is no longer publicly reachable.

D6. Decided 2026-09-24: the transport is a pluggable seam (listen, dial, peer id, byte stream), so Iroh
can replace libp2p without touching the door, grants or addresses. An Iroh implementation would run as
a Rust sidecar behind the same seam.

D7. Decided 2026-09-24: `ai.complete` and `AppState+PortAI` go with the engine. Ports that call it
(4 on production, 12 on Dev, 1 on Dev3) are not preserved. `companions.invoke` and `AgentRouterLLM`
go as well: the first runs only LLM-mode companions, and the second has no job once a subscribed
companion decides for itself whether to answer.

The one blocker for starting Phase 0 is none of these; it is F1, and F1 is already in the plan.
