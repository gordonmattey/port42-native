# Nautilus: a shell, and exactly what we need

Branch `nautilus`, opened 2026-09-24. Evidence for every claim here is in `audit-nautilus.md`.

## Target

A shell where every program has a face, and the namespace does not stop at your machine.

Unix composed text streams with pipes. Port42 composes live surfaces with events. A port on another
machine is an address in the same namespace, not a message in a channel.

## The five scenarios

The spec. Code that serves none of them does not ship. The product is done when all five pass live.

| # | Scenario | Test |
|---|----------|------|
| 1 | **Make a thing.** I type what I want and a live surface appears. | Type "a chart of my CPU" into a chat at desktop, space and port scope. A port appears each time. Nothing else opens. |
| 2 | **Drive a thing.** An agent in a terminal drives a port I can see, as itself. | Claude Code in a terminal port creates a web port and updates it three times. The tile changes live, the driver chip names the agent, Settings → Access lists it and can revoke it. |
| 3 | **Compose things.** One port feeds another with no glue. | Three ports: produce, transform, render. A change in the first reaches the third in one round trip. No code outside the three ports. |
| 4 | **Share a thing.** Someone on another machine sees and drives my port. | A browser elsewhere renders the port with no install. A click there appears here. The stale write of two is refused with `current`, one retry lands, both driver chips agree. |
| 5 | **Arrange things.** The shell holds my surfaces where I put them. | Six ports across two spaces, two parked, one added afterwards, restart. Nothing moved. |

The prompt, the agent, the pipe, the remote pipe, the window manager. That is the whole product.

## Baseline (Dev3, 2026-09-24)

| # | Result | Evidence |
|---|--------|----------|
| 1 | PASS | A mention to a command companion produced the port in under a minute. No in-app model involved. |
| 2 | PASS | A named CLI client threaded the token through three updates. Stale and tokenless writes refused with `current`. |
| 3 | PASS | Produce, transform, render as three web ports. Out-of-process subscribe over `/ws` also delivered. |
| 4 | PASS, local half | A guest over `/ws` subscribed, was refused a stale write, landed a retry. Another machine and a second identity untested. |
| 5 | PASS with `shell-layout-place-not-arrange` merged | On `slice-02-wire` alone a changed space re-gridded on restart. With the layout branch, the added port took a free spot and a restart moved nothing. Suite 1424 green. |

So the kernel already does all five on one machine. The product work is the remote half of 4 and
the chat port. Every phase re-runs all five.

## Method

Work in the existing tree, which is tested and green; rewriting it would rediscover fixed bugs. The
criterion is not "can this go?", which defaults to keep, but **"which scenario needs this?"**, which
defaults to leave out. Every line justified, every step shippable.

## The model: everything is a port, and chat is scoped to one

**Every scope is a port.** The desktop is port 0, which the grant model already names. A space is a
port that holds other ports. A web or terminal port is a port.

**Every port has a chat**, opened from an icon in its chrome beside its other actions (GM, 2026-09-25).
You talk at the scope you mean: the desktop, a space, or one port. There is no separate chat port.
The transcript is that port's state, a file kept through storage. A companion attached to a scope is
a subscriber of that port, which replaces space membership. A mention is an event on the port.

**So there is no messaging system.** Two people looking at one chat port are two subscribers of one
port, as they would be for a chart. Presence is whoever moved the token last. Typing is a `state`
event. Collaboration is scenario 4 applied to a port whose content is a conversation, and a port with
subscribers is the sync system.

**A terminal port's chat** is the command companion's session, rescoped. A message in it is written
to the terminal as input; the shim's end-of-turn hook posts the agent's reply back as a chat event.
Both land in the terminal port's own chat, and a wider scope hears them only by subscribing. The chat
is the structured, persisted, shareable record that terminal scrollback is not, so a remote guest can
follow an agent without the terminal.

**What this unifies.** Grants already key on a port object, so a grant on a space needs no new case.
Addresses already name ports. Subscription already fans out, so membership stops being a system.

A space renders as what it is, a desktop full of ports, and its chat is a tile on that desktop.

## No LLM in the kernel

A unix shell does not contain grep, and Port42 does not contain Claude. Claude is a process in a
terminal port, enrolled as a client, calling the same registry as everything else. Command companions
are the only kind. Tool use means a named process calling `/call` with its token.

The in-app engine served LLM-mode companions, retired 2026-07-31 as "fragile, brittle and not that
powerful." It goes whole in Phase 1:

- `companions.invoke` runs only LLM-mode companions. A port that wants a command companion writes to
  its terminal chat and subscribes for the reply, so no replacement method is needed.
- `AgentRouterLLM` picks responders for a message with no mention. Under the port model a subscribed
  companion decides for itself.
- `ai.complete` and `AppState+PortAI` let a port's own JS ask a model at runtime. They go too (D7).
  The ports that call it break, and older ports are not preserved. If a need returns, a thin
  `ai.complete` capability is the way back.

The registry stays; it is the API.

This also takes Port42 out of the path between a person and their model provider (D9). The app never
uses a subscription credential outside the provider's own client, so its standing does not depend on
a provider tolerating that use at scale.

## What stays

- **Kernel:** ports and their types, the registry and its one dispatch path, port 0 and grants,
  address, actor and token, `ClientRegistry` and Access, `NotifyBus`, `PortActivity`, the input seam.
- **Companions:** command companions, terminals, the shim and the Claude and Codex hook producers.
- **Shell:** `ShellView`, `ShellDesktop`, the window manager, peeks (including the needs-attention
  peek a terminal agent raises in another space), the storage service.
- **Ceremony:** lock screen, dreamscape, boot cinematic, dolphin protocol. No scenario needs them and
  that is not their test: the sequence is a deliberate reorientation into a new experience (GM). They
  lose their invite routes and nothing else.

## Decisions (GM, 2026-09-24)

| | Decision |
|---|----------|
| D1 | A chat transcript is a file the chat port owns, one per scope, append-only. |
| D2 | The native chat tile goes with the `messages` table. No bridge period. |
| D3 | Storage stays. It is unused because authors cannot tell it survives remount, eviction and restart where browser storage does not. |
| D4 | The ceremony stays. Heartbeats are separate and return only if a command companion can take a timed mention. |
| D5 | Remote callers arrive over libp2p. ngrok goes. The local door stays on loopback. |
| D6 | The transport is a pluggable seam, so Iroh can replace libp2p. |
| D7 | `ai.complete` goes with the engine. No backward compatibility for ports that call it; a thin capability returns only if needed. |
| D8 | Milestone M3 (Sync) in `CLAUDE.md` is superseded. What it reached for arrives as scenario 4. |
| D9 | Port42 never calls a model provider. It reads no provider credential and holds no API key. A CLI agent talks to its own provider through its own client, under its own sign-in. |
| D10 | An invite is per port and grants that port only. The same invite opens in Port42 or in a browser. Sharing a whole space is deferred. |
| D11 | Port fences go. An agent makes a port with `port.create`; the manual and the skill teach only that. |

## Phases

Each ships alone and is done when all five scenarios pass live on Dev3.

### Phase 0 · The door (2, 4)

**Progress** (detail in `plan-nautilus-phase0.md`): step 1 harness ✓ · 1b manuals teach `port.create`
✓ · 2 door on its own connection, gateway respawn ✓ · 3 gateway drops the hub ✓ · 4 one connection one
caller ✓ · 5 already true · 6 undeclared arguments refused ✓. **Phase 0 complete 2026-09-25**; all five
scenarios pass.

**The blocker.** `/call` reaches the app only through the messaging hub: gateway, WebSocket, the app
as host peer, `SyncService.handleCall`. `SyncService` has one function a scenario needs
(`onCallReceived`) and sixteen none does. Cut the hub first and scenarios 2 and 4 stop.

Decouple it. The gateway keeps one app-side connection, forwards `/call` to it, carries
`port.subscribe` stream frames back over `/ws`, and does nothing else: no channels, no host election,
no store-and-forward. The door also stamps the credential given at `identify` on each forwarded
WebSocket call; today a WS caller must repeat it per envelope, and the guest page's subscribe is
refused because it does not (audit F2).

**Also here, from the summer todo:**
- **An unknown argument is accepted in silence** (`terminal.exec` ignores an `id`). Still true on the
  current build: `port.position` with an extra `bogus` argument answers normally. The required-args
  work already on `main` did not cover it. Refuse an argument the method does not declare.

*Verify:* the CLI works with a token and is refused without; a subscribe over `/ws` delivers `state`
with the credential given once; the guest page renders and drives a port; existing `/call` tests pass.

### Phase 1 · Remove what no scenario needs, and build the chat port (1)

**Detailed plan:** `plan-nautilus-phase1.md`. **Phase 1 is complete (2026-09-25).** 1.2
bring-your-own-agent removed ✓ · 1.6 shim resume and creator names ✓ · 1.4 ngrok, invite payloads,
sync client, friends, remote presence and Apple sign-in removed, schema v47 ✓ · housekeeping ✓ ·
1.3 engine, Keeper and first run on a CLI ✓ · 1.5 every port has a chat, the old chat and inline
ports gone ✓ (the desktop's chat deferred). The harness passes all five scenarios, scenario 1
through the space's chat.

**Messaging:** the rest of `SyncService`, `TunnelService`, `SpaceCrypto`, `AppleAuthService`,
`AgentInvite`, friends, member lists, typing, read receipts, join tokens, and the gateway's hub
(`store.go`, `apple_auth.go`, the channel cases). The space-invite and agent-invite payloads go.
**The invite flow stays for Phase 4:** the link grammar, the deep-link accept path, the clipboard and
the landing page. The bring-your-own-agent sheets
and `OpenClawService` ride space invites, so they go, with the `port42-openclaw` and `port42-python`
repos.

**In-app engine:** `LLMEngine`, `GeminiEngine`, `LLMBackend`, `LLMStreamCollector`, `BridgeServiceAI`,
`AgentRouterLLM`, `AppState+PortAI`, `AgentAuth`, `ModelPicker`, `UsageView`, the `ai.*` methods,
`companions.invoke`, `token_usage`, and the `.llm` companion mode with its columns.

**Also:** Keeper and its four empty tables, `swimMessages`, retired spikes (the four tier-B
instruments stay).

**Schema:** a new migration drops `encryptionKey`, `syncEnabled` and the heartbeat columns from
`spaces`, the signing keys and Apple id from `users`. `messages` goes once the chat port holds the
transcript.

**The chat port replaces the native chat tile** at desktop, space and port scope, per the model
above. Companion membership becomes subscription; the mention router and the teleport hooks move off
the `messages` table onto port events. Scenario 1 is off between the cut and the chat port landing.

**The first run is rebuilt, because both things it stands on go.** Today setup ends in a direct
space ("genesis") with Echo, an in-app LLM companion, and prefills "hey, i'm <name>. what is this
place?" Echo answers, builds a port and nudges toward the terminal. Direct spaces and LLM companions
are both cut. The goal stays: the first thing a person learns is that asking makes a port. That is
scenario 1, so it is the product's UX, not a detour from it.

The new shape: Echo becomes a command companion, a CLI agent session in a terminal port with
Port42's welcome as its appended system prompt (the shim already passes one to Claude Code). The 1-1
is that terminal port's own chat, which is what a DM becomes under the model. Setup ends focused on
it with the same prefilled line. The reply builds a port, and zooming out to the desktop shows the
port, the agent that made it, and its terminal: scenarios 1 and 2 in the first minute.

**Claude Code and Codex are equal first-run paths** (GM, 2026-09-24). The target users already run one.
Setup detects both on the PATH and Echo runs on whichever is there; with both, the person picks.
With neither, setup offers to install one: the existing Claude Code installer stays, and a Codex
installer is added beside it. Sign-in is the CLI's own, in its terminal. Codex gets its own welcome
prompt, delivered through `AGENTS.md`, which `InstructionService` already writes.

**The Keychain token step goes** (D9). It read Claude Code's OAuth credential out of the Keychain so
the app could call Anthropic directly. With no engine in the app, nothing needs it.

**Port fences go** (D11). A fenced port renders inline in a chat message and pops out on a click, and
both the inline render and the chat tile it lives in go in this phase. Agents make ports with
`port.create`, and the port manual and the skill teach only that (audit F12).

**Found by the audit, fixed here:** reap `port_versions` rows already written as layout noise (F6);
show a companion's codename as `createdBy` instead of its raw client id (F7); reap the panel whose
space no longer exists (F8).

**Companion defects to settle here, since the routing moves anyway:**
- **The shim's session pin collides with a user's own `--resume`.** The shim prepends `--resume <id>`
  for Port42's session, and a user's `claude --resume X` in that terminal then fails. Still open.
- **A teleported session does not join as a companion.** Under subscription it joins by subscribing to
  the terminal port's chat, so the fix is the new model rather than a patch.
- **A message to a command companion animates its terminal but never arrives** (reported 2026-07-21).
  Not reproduced in the baseline; re-check once mentions are port events.
- **Storage keys on the caller's principal**, so a port and its creating companion see different
  buckets. The transcript is read by the chat port only, so D1 does not need this fixed, but the keying
  rule is decided here.

*Verify:* a fresh data directory runs the ceremony, names you, detects the installed CLI, and lands
focused on Echo's terminal chat; pressing Enter produces a port. Once with Claude Code, once with
Codex. Scenario 1 passes at all three scopes. A mention reaches a companion subscribed at that
scope. The transcript survives restart. Nothing is sent anywhere.

### Phase 2 · Arranging (5)

**Detailed plan:** `plan-nautilus-phase2.md`. **Built 2026-09-25:** ⌘L gone ✓ · close is archive, reopen from ⌘K ✓ · exact parking ✓ · background pauses unseen ✓. Harness five of five; GM's manual pass pending.

Built on `shell-layout-place-not-arrange` (2d42eb1, design in `design-shell-layout.md`). A new port
takes a free spot and moves nothing; only ⌘L re-grids, by creation order. Positions are per space
(v46), off-screen tiles clamp on resize and restore, every port type gets one default size, and
identical HTML no longer writes a version. It merges cleanly with `slice-02-wire`.

Remaining:
- Land the branch, and a `userPlaced` flag so ⌘L leaves a hand-placed tile alone.
- **Closing never destroys** (GM: "we should never close them"). Close becomes archive, and a closed
  port reopens with the same id, so its subscribers and references survive. The record already
  persists; only the reopen is missing.
- **Parking places exactly.** Drop a parked port at a chosen spot in the rail and reorder there;
  today it appends.
- **The background's idle cost.** It burned about 30% of a core per instance while idle. A frame cap
  has landed; pausing it while covered is unverified. The ceremony stays, so this has to be right.

*Verify:* scenario 5 as written. Passed on the merged tree 2026-09-24.

### Phase 3 · The pipe (3)

**Detailed plan:** `plan-nautilus-phase3.md`. **Built 2026-09-26** (hidden ports, companions watch ports, the `port42` command, the new-companion card; five of five on Dev4). Antigravity moved to the roadmap.

From the OPEN SYNTH field report, three gaps. Two already pass live: a port publishes on its own
topic, and publish and subscribe resolve the same `port:{id}` key. The third remains: a rested
subscriber is woken by an event on a topic it watches. The same mechanism wakes a rested companion
when a chat it subscribes to mentions it.

This is the todo's `busWatch` trigger, generalized: a companion wakes on any event on a port it
subscribes to, chat or not, and runs a full turn with tools. It also answers the todo's "synchronous
invoke of a command companion from a port": push to its chat, subscribe for the reply.

**Invisible ports.** A port that runs with no tile: a producer, a transformer, a watcher, a desktop
organizer. The pipe's middle stages are usually logic, not surfaces. The same headless terminal port
then carries `terminal.exec`: a command runs in a port with an identity and a grant instead of as a
raw child of the app with none, so every shell action has a port, as the model says.

*Verify:* scenario 3 with a rested subscriber woken by an event, a rested companion woken by a
mention, and the middle stage running as an invisible port. The `ls | grep | wc` demonstration, and the product's proof.

### Phase 4 · The remote pipe (4)

`port42://<peerID>/space/<id>/<portId>` resolves over libp2p to the Phase 0 door. The Noise handshake
authenticates the remote peer id, so grants key on the peer and no token crosses the internet.
Reachability is mDNS on a LAN, then Circuit Relay v2 with DCUtR hole punching, as designed in
`membrane/slice-02-cross-instance.md` milestones B and C. Spike F measured go-libp2p in the signed
bundle: +22 MB, 4 ms start, sub-millisecond stream round trip. The browser guest dials in over
WebRTC-direct or WebTransport. Access links burn on use. A shared chat port needs nothing extra.

**Invites: one per port** (GM, 2026-09-24, superseding the peer invite of 2026-07-31). An invite
names a port and grants access to that port. Port 0 is never invitable. Sharing a whole space is
deferred (future roadmap); this phase shares single ports.

The same invite serves both lanes. Opened in Port42, accepting it enrols the other instance as a named
client (the connection is a side effect, not the thing granted) and records the grant on that one
port. Opened in a browser with no Port42, it is the guest link: a one-time credential in place of
today's query-string token, burned on use. Sharing a second port is a second invite. Revoking one
removes that grant and leaves the others.

**The transport is a seam.** The door sees an authenticated byte stream from a named peer: listen,
dial, peer id, stream. The address carries the peer id, never a transport. Iroh is Rust and the
gateway is Go, so an Iroh implementation runs as a sidecar speaking the same seam over a local socket.

**Open, settled before this phase starts:** the address grammar. The built form is
`port42://space/<spaceId>/<portId>`; the remote form needs the peer id; and with every scope a port,
the space segment may reduce to a port id.

**Open (GM, 2026-09-25): the Signal Protocol for what is stored and forwarded.** Signal's protocol
gives per-message forward secrecy and works when the other side is offline; Signal's network is not
peer-to-peer (every message goes through its servers). The transport here, libp2p or Iroh, already
encrypts end to end between two live peers (Noise, or QUIC with TLS), so live port traffic does not
need it. Where it could fit is a chat message or invite held for an offline peer by a relay that
cannot read it. To evaluate with this phase's relay design; not a replacement for the transport.

**Open:** libp2p's reported hole-punch rate is about 70% against Iroh's 90%, and "p2p is viable" needs
about 80% direct; milestone C measures it on real networks. Where the guest page is served from once
the gateway is not publicly reachable.

**Reads must be scoped before anything is remote.** Today any caller can list every port across
every space; during the July security fix a page on example.com did exactly that. Locally that is a
known gap. Remotely it would hand a guest the user's whole desktop. A remote caller sees only the
ports it was granted.

**The output seam.** Ten publish sites, two taking a caller-supplied kind, give an event one
definition locally. It is the payload gossipsub carries, so it lands before the remote pipe.

**Already covered by this phase:** "a port has a URL" is the guest page; "port teleport between
instances" failed only on instance-local addresses, which the peer-id address fixes.

*Verify:* scenario 4 from a second machine with its own client, on a chart and on a chat port. A
guest asking for anything beyond its grant is refused.

### Phase 5 · Skills, not a megaprompt (2)

**Detailed plan:** `plan-nautilus-phase5.md`. **Built 2026-09-26**: five skills load per session in every Port42 terminal (typed and teleported included), the brief is six rules (1,298 characters from 4,230), `port42 skills install` for sessions outside Port42; five of five on Dev4.

The generated reference owns which methods exist. A skill packages the concepts: a man page plus a
small program, composed by an agent the way a shell user composes commands. Port42 ships knowledge,
not an LLM.

`port42-connect`, `port42-port`, `port42-drive`, `port42-compose`, `port42-permissions`,
`port42-errors`, installed to `~/.claude/skills/port42-*` by the boot refresh that already rewrites
instruction files. Everything API-shaped is generated from the registry. `port42-port` leads with
storage (D3). The instruction block shrinks to a pointer. Nothing is installed today;
`plan-port42-ports-skill.md` is the one prior design.

*Verify:* a fresh Claude Code session with no Port42 block loads the skills, enrols, and passes
scenario 2. Then the same with Codex.

## Tests per phase

**Every phase ends the same way:** the Swift suite and the Go suites (`gateway`, `cli`, `shim`) are
green, and the five scenarios pass live on Dev3. The scenarios run from a committed harness, built in
Phase 0 from the scripts that produced the baseline, under a client enrolled for it rather than the
CLI's token. Each new gate is calibrated by breaking the code it guards and watching it fail.

| Phase | New gates | Removed with their code |
|---|---|---|
| 0 · Door | Go: a `/call` and a `/ws` subscribe reach the app with no channel state; a WS call carries the identify credential with none on the envelope; `join`, `message`, `typing` are refused as unknown. Swift: a terminal port that runs a command needs a grant; an unknown argument is refused. | Go: `store_test.go`, `apple_auth_test.go`, the hub cases in `gateway_test.go`. Swift: `SyncAuth` reworked to the single app connection. |
| 1 · Remove, chat port | A chat at port 0, space and port scope keeps its transcript in storage across restart. A mention on a chat port reaches a subscribed companion and not an unsubscribed one. Migrating `agentSpaces` to subscriptions loses no companion. First-run detection: Claude only, Codex only, both, neither. Shim: a user's own `--resume` survives the session pin. The drop migration leaves kept columns intact. Version reap, codename as `createdBy`, orphan reap. | About two dozen suites, listed in `audit-nautilus.md` §8: crypto, sync, swim, the engine, Gemini, Keeper, messaging segments. |
| 2 · Arranging | On the branch: `PlaceTests`, `SpawnMovesNothingTests`, `PerDesktopPositionTests`, `ArrangeAttributionTests`, `PortVersionNoiseTests`. New: ⌘L skips a hand-placed tile; close then reopen keeps the id and a subscriber still receives; a parked port lands at its drop index; the background pauses while covered. | `ShellLayout` cases that asserted a re-grid on spawn. |
| 3 · Pipe | A rested subscriber is woken by an event on its topic. A rested companion is woken by a mention. An invisible port runs, uses the bridge, subscribes, and draws no tile. `terminal.exec` runs inside a port with a client id and is attributed to it. | None. |
| 4 · Remote pipe | Go: the door works over a fake in-memory transport, which is what proves the seam pluggable. Two in-process libp2p hosts round-trip a stream and the door sees the authenticated peer id. Swift: a remote caller lists and reads only granted ports; a grant keys on a peer id. | `TunnelService` tests, if any remain. |
| 5 · Skills | Skills are generated from the registry: a method that exists is documented and one that does not is not, the `PublishedDocs` rule applied to skills. Boot installs them for Claude Code and Codex and a re-run is idempotent. | The instruction-block content tests shrink to the pointer. |

Measured, not gated: the background's idle CPU before and after Phase 2, and the hole-punch rate in
Phase 4 on the networks milestone C names. Both are recorded in the audit.

## Release: Port42 v1 (GM, 2026-09-26)

Nautilus completes as Port42 v1. What must be done, verified or decided before the release build.

| Item | Status |
|---|---|
| Phases 0, 1, 2, 3, 5 | Done; five scenarios pass on Dev3/Dev4 |
| Phase 4 (sharing, invites) | In progress on `nautilus-phase4` (0716d25, 1336 tests green, 2026-09-26): 4.6b tile, per-port share asks, 4.6c done; remaining 4.6b screens (GM choosing the chrome design), 4.7 browser lane, 4.8 harness scenario 4. Stable at a checkpoint, so it can merge back before the screens (GM's call). Its migrations run to v61; nautilus's next is v62 |
| `/imagine` (`plan-imagine.md`) | Done: a bootstrap (space, port, three companions, brief), budget of 10 versions; verified live on Dev4 |
| Merge `fixes-gemini-ngrok-floor` | Done (`5020941`): `3c9bec5` dead ngrok references (the four `ngrok-skip-browser-warning` headers in `gateway/main.go` stay, they emit a real header), `83c500d` macOS floor 14.0 everywhere, `be9251b` the managed instruction block outranks pre-marker Port42 instructions (the `auth_required` in `~/.gemini/GEMINI.md`) |
| macOS 14 floor on Sonoma hardware | Not verified; GM has decided 14 ships |
| Update feed | Never hand-edit `dist/appcast.xml`; `generate_appcast` regenerates it from the built bundle |
| The call stall after a NaN (`2afbe1c`) and the lock screen video freeze (`bfb1053`) | Fixed, with tests |
| Open defects (`defects-triage.md`) | Settled: terminal matched by name fixed (by id), companion per named terminal is by design (GM), blank page after a WebContent crash cleared (never observed), tool-result size fixed for `port.console` (levels). None left open for v1 |
| Seen in the imagine runs | Settled: the startup-stuck check removed; messages typed as a turn ended were lost (#6), fixed and verified live |
| Test gate | `swift test` green before the release build (1296 tests at `3752063`, 2026-09-27) |
| Voice input (GM, 2026-09-27: on the v1 list) | Feature-complete on `voice-input` (the "handoff: arrange" session, 2026-09-27): all five phases, confirmed by hand on Dev7, suite green (1351) merged against nautilus `e497a17`. Hold space past 0.2 s and speak; words stream into whatever has the keyboard (chat field, web port, terminal) and commit on release; other apps behind a setting and Accessibility. Parakeet TDT v3 on the Neural Engine via FluidAudio (new package, Apache 2.0). No migration, nothing in the bridge registry (a test pins that no port reaches the microphone or the typer). The 461 MB model is fetched on first use, not shipped; its CC BY 4.0 attribution goes in `THIRD-PARTY-LICENSES.txt` before release. Adds a Voice tab to Settings (`SignOutSheet`, which Phase 4 also changes). Voice starts from the app at launch, not `AppState.init`: starting it there doubled the suite and made a watch test flake |
| Pairing and scoped tokens (GM, 2026-09-27) | v1, built after the Phase 4 merge. Design in `plan-pairing-scopes.md`; all four decisions made (GM) |
| Daily-driver install | After the release scope is done (GM) |
| The app's videos are not in git (found 2026-09-27) | `*.mp4` is gitignored, so `DolphinProtocolLoading`, `dream-architect`, `dreamscape` and `TheAquariumsDoorIsOpen` exist only on this Mac; a fresh clone builds without them. `.gitattributes` already sends `*.mp4` to Git LFS, so un-ignoring them is the fix. GM to decide |
| Clean up after the release (GM, 2026-09-27) | The merged local branches and the 16 `worktree-agent-*` worktrees and branches, each worktree checked for uncommitted work first; GitHub untouched. The 390 leftover test keychain items were deleted 2026-09-27 (GM) |
| Final hit list | Below; every item done before the release build |
| Relay you can run yourself (GM, 2026-09-27) | Built on branch `relay-dist` (from `nautilus-phase4`, new files only, to merge into Phase 4): release binaries for Linux, macOS and Windows (x86 and ARM each; macOS Developer ID signed, Windows unsigned), a workflow that on a `relay-v*` tag publishes the image to ghcr.io and the binaries to the release, `gateway/railway.json` for the Railway deploy, and `docs/run-a-relay.md`. Checked locally: binaries, signature, image and `/health`. Publishing waits for the Phase 4 merge (GM, 2026-09-27): the repo is public and the relay's source is only on the unpushed Phase 4 branch. After the release reaches `main`: push `relay-v1.0.0` (the workflow publishes the image and binaries; GM grants `write:packages` once), make the image public, switch relay1 on Railway to `ghcr.io/gordonmattey/port42-relay:latest` (after Phase 4's sharing tests, which run through relay1), make the Railway template, and the port42.ai page (growth) |

### Integration into nautilus (coordinated by the nautilus session, GM 2026-09-27)

Four lines of work end in `nautilus`: `nautilus` itself, `nautilus-phase4` (sharing, relay, invites),
`relay-dist` (relay packaging, cut from Phase 4) and `voice-input`. Order, each step only when the
last is green:

1. **`relay-dist` into `nautilus-phase4`.** New files only; Phase 4 merges it.
2. **`nautilus-phase4` into `nautilus`,** when Phase 4 is done or at a checkpoint GM picks. Phase 4
   merges the latest `nautilus` first and resolves its side; then nautilus merges it.
3. **`voice-input` into `nautilus`,** after Phase 4 is in, so voice resolves once against the whole
   tree. It merges `nautilus` first. It adds a package (FluidAudio), so the first build fetches it.
4. **Pairing and scoped tokens** built on the integrated tree (migration v63), then the "…" menu
   reorder.
5. **Release build.**

At every merge: the branch has merged `nautilus` in and resolved its own conflicts; `swift test` is
green on the result; the generated files are regenerated, not hand-merged (the tool schema golden,
`llms.txt`, skill references); migrations keep distinct numbers (Phase 4 v57 to v61, nautilus v62,
pairing v63); the five scenarios pass on a dev instance; and a companion posts to its space with
the call its own instructions give, the post appears in that space's chat, and an @mention in it
wakes the companion it names (the voice session's check, 2026-09-27: prod's stored instructions
named `messages.send`, which no longer exists, so such posts vanished; nautilus now bakes a
companion's instructions at every launch). Overlapping files to watch: `AppState`,
`ShellState`, `ShellDesktop`, `ShellView`, `PortWindowManager`, `BridgeMethods`.

### Final hit list (GM, 2026-09-26)

Must-fix before launch, found testing first run and daily use on the dev instances. Added as GM finds
them; an item leaves only when it is done and verified.

| # | Item | Status |
|---|---|---|
| 1 | Boot cinematic: pressing a key right after the first scene appears skips to the BIOS | Done: the first scene's video took keyboard focus, so later keys never reached the cinematic and its scenes ran on by their timers (replayed on Dev5). Keys now come from a window monitor while it is up; a held key's repeats do nothing. Replayed live: ten spaces, one scene each, the tenth ends it; GM confirmed on a fresh Dev5 |
| 2 | Resizable chats: drag a port's chat panel to any width, all the way across the port; drag the space chat to set its size | Done, confirmed by GM (2026-09-27): invisible zones like a port's own edges; a port's chat drags by its bottom edge down to covering the port, the space chat by its bottom-right corner. Something behind the open space chat made windows under it hard to click once (GM); not reproduced, reopen if seen |
| 3 | "help improve Port42?" comes after echo's CLI is picked, not before: picking echo is the high point of sign-up | Done: it is the last question and its answer finishes setup |
| 4 | Presence in chat: the chat that asked shows who has its message, working, or waiting | Done (`ee2661a`) |
| 5 | Echo's welcome names the spaces setup made for imported sessions and who waits in each | Done (`2b34046`) |
| 6 | The first-run tagline "Every program has a face." (`SetupView` boot lines) is to go (GM: "terrible") | Done: "What will you imagine?" (GM, 2026-09-27; was "say it, see it") |
| 7 | An agent asked for a website built a server and a browser port instead of a web port, leaving a server to manage | Done: the port42-ports skill says a website is a web port; no server and localhost browser port for it; a server only when the project needs one, in the agent's own terminal; a browser port only for a real URL the person asks for. Guidance, so the proof is the next such request |
| 8 | The chat input wraps onto more lines as a message grows | Done (`6ad9ce9`), confirmed by GM |
| 9 | Chat layout: the person's messages on the right, others on the left under their name, and the time of where you are while scrolling | Done (`053f38b`), confirmed by GM: no bubbles; one AppKit text, so a drag copies across messages, with each message's time and sender; runs from one sender grouped; hover for a message's time; the time of the top message shown while scrolling |
| 10 | Opening a port's chat crashed the app (Dev5, 2026-09-27) | Done (`53515ac`), confirmed by GM: TextKit 1, and the scroll moves the clip view; a test reproduces the crash on the old code |
| 11 | A companion's own chat posts and its replies read as two senders (they did not group) | Done (`6caf2b7`): a post through a companion's terminal credential is recorded as the companion. Messages stored before keep the old sender |
| 12 | Checking a port put up to ~400 KB of log into an agent's context (`port.console` returned the last 100 lines of up to 4,000 characters) | Done: `level=count` gives only the error and warning counts; the default (`problems`) the errors and warnings themselves (last 20, each cut to 1,000 characters); `level=all` the whole log, for debugging. A terminal defaults to its last 50 lines. The ports skill and the /imagine roles check the count first and read errors only if there are any |
| 13 | Opening port chats lagged and slowed the machine (prod, #port42-app: the biggest chat 257 messages, ~280 KB) | Done on nautilus, not yet on prod: the old transcript was one SwiftUI Text of the whole chat, laid out again on every change. The AppKit transcript (item 9) opens 300 messages of ~1,000 characters in about 0.1 to 0.25 s, and a new message is appended in place (0.5 ms in a full 200-message chat) instead of a rebuild; both timed in tests. Reaches prod with the daily-driver install |
| 14 | The first-run breakout is back (GM, 2026-09-27): the aquarium video on the first zoom-out of echo's terminal grows from the port to full screen, plays and fades into the space; any zoom while it plays skips it | Done: restored on a bare player layer (the old AVPlayerView deadlocked the main thread). Its video had been deleted from the working tree with no trace, since every `.mp4` is gitignored; restored from the installed app, and a test fails when the source file is missing. It grows with the zoom-out under it, same spring, at once (GM: quicker). Confirmed by GM on Dev5. Open: none of the app's videos are in git (see below) |
| 15 | `port42://imagine?line=…&from=…` (growth, for port42.ai's "Imagine this" and its getting-started page, 2026-09-27) | Done (`360a7a8` and after): opens the imagine box filled in and never starts a team (any web page can fire it); the idea is cut to 300 characters and cleaned. Arriving before or during a first run, it is held on disk through quits and opens after the person lands on their desktop, and echo's welcome leads with it instead of the shader. Open for GM: an analytics event for an imagine started from a site line; the Elements generator in the app (growth's two routes); "What will you imagine?" in the ⌘I box |

## Future roadmap

Things that would be cool once the five scenarios hold.

- **The chrome is ports too.** The background, app bar, dock and rail become ports you author. Once
  every scope is a port, the shell's own parts are next.
- **Share a whole space** with one invite.
- **Publish a port as a website.**
- **Share a port's code** so someone installs it in their own space.
- **MCP as a port capability**, running with the viewer's own credentials.
- **A live media plane.** WebRTC across instances, with ports and agents as tracks, and native video
  ports.
- **Computer use.** An agent that sees the screen and acts on it in one loop.
- **Multi-display.** Spaces placed across monitors.
- **Support all the CLIs** (GM, 2026-09-27; was "more agents as equal first-run paths"). Every coding
  agent CLI as a first-class companion, not only Claude Code and Codex: Gemini CLI, Antigravity,
  Cursor's agent, OpenCode, Aider, Goose, Amp, Copilot CLI and whatever comes next. "Supported" means
  what Claude and Codex have today: a briefing it reads, the reply read at the end of a turn, a submit
  confirmation, a needs-you and a turn-failed signal (presence), its sessions found and forked for
  import, the port42 skills where it loads skills, and a place in first run. Per CLI, the hook system
  decides how much of that is possible; a CLI with no hooks gets a thinner tier (reply from its
  output, no presence), said plainly. One adapter per CLI behind the existing hook vocabulary.
- **The program as the credential.** Authenticate a caller by its code signature, not a token.
- **One guided permission flow** in place of a series of dialogs. GM, 2026-09-27: macOS prompts
  (files, photos, camera and the like) arrive at random, whenever a companion first touches something,
  and most come from agents running in Port42's terminals, which macOS attributes to Port42. Idea: a
  first-run step for the ones nearly everyone hits (the Desktop, Documents and Downloads folders, or
  Full Disk Access through System Settings, which macOS allows only by the person's own toggle), with
  camera, microphone and screen left to first use. Product idea; not designed.
- **Mac apps in spaces** (GM, 2026-09-27). Bring other macOS apps into Port42 and organize them in
  spaces. macOS gives no way to put another app's window inside ours. Two routes: manage the real
  windows through the Accessibility API (each space remembers its apps' windows and shows, places and
  hides them as you move between spaces; fully usable, but they sit over Port42 rather than in a
  tile), or a live mirror of a window as a tile through ScreenCaptureKit with input forwarded
  (in the tile, but input and fidelity are approximations). Research; demand unvalidated.
- **The membrane interprets.** Port42 understands what crosses it rather than only carrying it.
- **Antigravity as a companion** (GM deferred, 2026-09-26). `agy` has hooks (PreToolUse, PostToolUse,
  Pre/PostInvocation, Stop) from a workspace `.agents/hooks.json` or a plugin; open questions are an
  undocumented SessionStart, reading the reply from its own transcript, hooks that must print JSON, and
  where the hooks live without writing into the user's project or global config. Findings in
  `plan-nautilus-phase3.md` (3.7).
- **Pairing and scoped tokens: in v1, built after the Phase 4 merge (GM, 2026-09-27).** Design in
  `docs/plan-pairing-scopes.md`.
- **Pairing** (GM, 2026-09-27). `port42 pair` from any terminal or app: it asks Port42 for access,
  the app shows who is asking, the person accepts, and that process gets its own credential (the
  registry already has a `paired` kind; the verb was dropped earlier). Pairing agents across spaces
  is sharing (Phase 4). Decision pending: v1 or after.
- **Scoped tokens** (GM, 2026-09-27). A credential today can do anything its permissions allow,
  anywhere. Scope it to the galaxy (everything), one space, or one port; pairing and sharing grant a
  scope. Decision pending: v1 or after.
- **Hosted (SaaS) agents as companions** (GM, 2026-09-26; again 2026-09-27: GM had them working on
  Railway before). Agents that run as a service rather than
  a CLI on this machine, as companions beside Claude Code and Codex. Removed with the in-app model;
  GM wants them back. Product idea; demand unvalidated.
- **`companions.remove`** (GM, 2026-09-26). Take a companion out of a space by id or name, keeping
  every port it made (the card's "Remove from this space", as an API). Today the only removal is by
  hand, one card at a time, and "Delete companion" also closes the ports it created. Found cleaning
  up ten stale companions in prod's port42-app space.
- **Presence in chat** (GM, 2026-09-26). When a message in a port's or the space's chat wakes an
  agent, the chat shows it: received, working, done (and waiting on the person, when its CLI says so).
  The signals exist (the terminal's "typing" state from a typed message to its turn's end, Claude's
  submit confirmation, the needs-attention hook). **Done (2026-09-26):** `ChatPresenceStore`, shown
  under the transcript of the chat that asked ("@alpha is working (42s)"), fed by the terminal's
  events, no timeout. Codex reports no submit, so it shows "has your message" until its turn ends; a
  Claude that was waiting on a permission shows waiting until the turn ends (no hook reports the
  approval).
- **Presence shows why an agent cannot reply** (GM, 2026-09-27). When a CLI's turn fails (an API
  error, a dropped connection), the chat that asked shows only what the CLI's hooks report: on
  intermittent wifi, Claude's notice surfaced as "@name is waiting for your input", not the error
  itself. Surface the error in the presence line (and the chat) when the CLI reports one. Claude
  first; Codex to check. **Done for Claude (2026-09-27):** Port42 registers Claude's `StopFailure`
  hook; a failed turn clears the agent from the chat's presence and Port42 posts in the chat that
  asked why, in words ("echo could not reply: the API is overloaded. Wait a moment and send it
  again."), without @mentioning it, so it wakes no one. Codex has no failure hook; not covered.
- **Pinning ports** (GM, 2026-09-27). Pin a port in its space (it keeps its place and stays up), and
  pin a port across spaces (it shows in every space). **Built (2026-09-27):** "Pin in this space"
  keeps the tile above every unpinned tile there (the `isAlwaysOnTop` column, unused since the old
  windows went); "Pin in every space" shows it on every desktop, above the others, at one position
  (migration `v62-port-pinned-everywhere`). Paint order is a rank, so a tile never climbs over the
  shell's own layers. A pin mark shows in the title bar; `port.manage` takes pin, pinEverywhere,
  unpin. Today "Pin" is one row whose choices open under it (in this space, in every space, unpin), at the end of the "…" menu; it moves into the placement group
  with the menu review below, after the release (Phase 4 is changing the same menu).
- **Review the port's "…" menu: agreed order (GM, 2026-09-27), held until after the release.**
  Move to… (another space, background, hidden, parked) · Pin (in this space, in every space) ·
  Share… · Fork, then Refresh · History… for web ports. No "Copy port id" (GM: no need found).
- **A port shares its state, for the shapes where it is not drawn** (GM, 2026-09-27). Below a size a
  port should show what it is doing, not a shrunken window; a peek the same; hidden is size zero. Two
  layers. Where the port is drawn, it decides by drawing itself differently: a web port already gets its
  size from the `presentation` event and can switch to a compact view like a responsive site (skill
  guidance; Port42 draws the compact view for terminals). Where it is not drawn (a peek, the rail,
  hidden, the galaxy, ⌘K), it declares: a new call, `port42.state.set([{label, value}, …])` from a page
  or `port42 port.state` from an agent, an ordered list of anything ("doing: building the join card",
  "progress: 3 of 5", "fps: 60"). Port42 adds what it already knows, marked as its own: error and
  warning counts, unread chat, presence (working, waiting), a terminal's git branch. Who decides: the
  port (or its agent) what its state is and its order; Port42 where it shows and how much fits; the
  person the size. Hidden ports need it most, since they are never seen (a pipeline stage, a poller, a
  headless agent): the "N hidden" list and ⌘K show each one's line ("fetching every 5 min · last run
  2m ago · 0 errors"), so a person knows it is alive without bringing it back (GM). Other agents can
  read it (a lead sees its engineers without asking) and ⌘K can search it. Status is declared or known, never scraped from the page (`docs/research/port-shape.md`
  on `research`). **Straight after v1 (GM, 2026-09-27): the first thing built once v1 ships.**
- **Token usage charts, back** (GM, 2026-09-27). Settings had a Usage view with token charts; it went
  with the in-app model (`0369388`). The CLIs record what they spend, so it can return for the agents
  as they are now: every Claude Code transcript entry carries its `usage` (input, cache written, cache
  read, output), and Codex's session log has `token_count` events (totals and its rate limits). Per
  companion, per space, per imagine team, over time.
- **Verify the Elements recipes** (growth's plan, `port42-growth/nautilus-recipe-verification-plan.md`;
  GM, 2026-09-27: later). An imagine run per recipe on a dev instance, passing on a real web port, a
  zero error count, a non-empty page and DONE within budget, with evidence the site shows as
  "verified". Each recipe is a full three-agent run, so a sample first (about ten across the five
  groups) to measure what a run costs before the 129.
- **Structured chat** (GM, 2026-09-26). A chat message carries structured data as well as text:
  what it is about, and payloads attached with what they are (a port, a file, a result), so agents and
  people exchange data, not only prose.
- **Resizable chats** (GM, 2026-09-26). Moved to the release's final hit list (item 2).
- **A benchmark suite** (GM, 2026-09-26). Two layers: a free one that measures the size (bytes and
  estimated tokens) of every read method on real ports, with a size budget pinned per default; and the
  golden eval set (`eval-golden.md`) for tokens per task, run rarely since it spends the subscription.
  Prompted by `port.console` returning up to ~400 KB into an agent's context per check.
- **Zoom into a chat** (GM, 2026-09-26). A chat as a level of the zoom spine, entered like a port's
  focus, rather than a panel over the desktop. The space chat's expand button is the stopgap.
- **`/imagine`** (GM, 2026-09-25; moved into the release's scope 2026-09-26, plan in `plan-imagine.md`). Type one line ("a shader that reacts to music") and Port42 writes
  the brief, opens a new space with a lead and two engineers, and briefs the lead; the team builds and
  improves the port in its chat by rounds and reports DONE. The pieces exist and ran live
  (`scripts/scenarios/team.py`); what is new is turning the line into the brief. Product idea;
  whether people want it is unvalidated.
- **Windows and Linux** (GM wants Windows, 2026-09-25; demand unvalidated). A research branch
  (`research-windows-port`, `docs/recommend-kernel-boundary.md`) proposes moving the kernel to Go so
  other shells become clients of the door. Against this plan:
  - **The terminal comes first.** libghostty does not run on Windows (the branch's own spike), and
    every companion lives in a terminal port. A Windows shell needs another terminal, and a
    kernel-owned pty would replace Ghostty's on macOS too, or leave two terminal paths.
  - **A Go kernel reverses the door-only gateway.** The registry, grants, principals, tokens, the
    event bus, storage and the chat move to Go, and every method body that drives a native surface
    (terminal, browser, screen, camera) needs a call back into the shell, not yet designed.
  - **What stays compatible:** the pluggable transport (D6), no model in the kernel (D9) and the
    per-port invite (D10) do not depend on the platform.
  - **Cheap now, whatever is decided:** keep kernel code free of AppKit and view types (the port
    panel model out of a view file, shell geometry out of kernel code, the gateway process behind a
    protocol), and a CI build of the kernel files on Linux to hold that line.
  - Its figures predate the engine removal and the chat work and need re-measuring on nautilus.
