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

**Any port can carry a chat.** You talk at the scope you mean: the desktop, a space, or one port.
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

**The blocker.** `/call` reaches the app only through the messaging hub: gateway, WebSocket, the app
as host peer, `SyncService.handleCall`. `SyncService` has one function a scenario needs
(`onCallReceived`) and sixteen none does. Cut the hub first and scenarios 2 and 4 stop.

Decouple it. The gateway keeps one app-side connection, forwards `/call` to it, carries
`port.subscribe` stream frames back over `/ws`, and does nothing else: no channels, no host election,
no store-and-forward. The door also stamps the credential given at `identify` on each forwarded
WebSocket call; today a WS caller must repeat it per envelope, and the guest page's subscribe is
refused because it does not (audit F2).

**Also here, from the summer todo:**
- **Spawning an agent is ungated.** `port.create` has no permission, so any enrolled client can open a
  terminal port running any command in the user's space. Unnamed callers are refused since slice-02,
  so this is now attributable, but it is not consented. Gate a terminal port that runs a command.
- **An unknown argument is accepted in silence** (`terminal.exec` ignores an `id`). Still true on the
  current build: `port.position` with an extra `bogus` argument answers normally. The required-args
  work already on `main` did not cover it. Refuse an argument the method does not declare.

*Verify:* the CLI works with a token and is refused without; a subscribe over `/ws` delivers `state`
with the credential given once; the guest page renders and drives a port; existing `/call` tests pass.

### Phase 1 · Remove what no scenario needs, and build the chat port (1)

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
- **More agents as equal first-run paths**, such as Gemini and Antigravity.
- **The program as the credential.** Authenticate a caller by its code signature, not a token.
- **One guided permission flow** in place of a series of dialogs.
- **The membrane interprets.** Port42 understands what crosses it rather than only carrying it.
