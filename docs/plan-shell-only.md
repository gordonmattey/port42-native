# Shell only: graft exactly what we need and no more

**Opened 2026-09-24.** GM: "imagine if Port42 was dramatically simplified in that it is only a shell."
Then: "the p2p is cool though, piping across the internet into a surface that can be shared."
Then: "I would graft exactly what we need and no more."

This plan is subtractive. Each phase deletes something, ships, and is verified live. The order is
forced by one coupling, measured below, not by preference.

## The target, in one line

A shell where every program has a face, and the namespace does not stop at your machine.

Unix composed text streams with pipes. This composes live surfaces with events. A port on another
machine is an address in the same namespace, not a message in a channel.

## What is measured, and what it forces

**1. The call door rides the messaging hub. This is the blocker.**

An external call arrives as HTTP `/call`, the gateway routes it over WebSocket to whichever peer is
host, and `SyncService.handleCall` hands it to `onCallReceived`. The app has no listener of its own.
So the shell's only door into the app is a feature of the hub that exists to route chat. Cutting the
hub with nothing in its place cuts the CLI, every companion tool call from outside, and the guest
page. This is phase 0 and it is not optional.

**2. `SyncService` has one function the shell needs and sixteen it does not.**

Measured by call site: `sendTyping` (8), `sendMessage` (8), `configure`, `gatewayURL`, `connect`,
`requestToken`, `isConnected`, `sendReadReceipt`, `remoteTypingNames`, `onPresenceChanged`,
`onMessageReceived`, `onlineUsers`, `knownNames`, `joinSpace`, `actAsHost`, and `onCallReceived` (1).
Only the last is shell. The rest is messaging.

**3. Companion routing has zero dependency on sync.**

`AgentRouting.swift` contains no `sync.` call. A mention goes message → `routeMentionsToTerminals` /
`AgentRouter.findTargetAgents` → companion, in process. Companions survive the cut untouched.

**4. The transcript is local first, sync second.**

Every send does `db.saveMessage(msg)` and then `sync.sendMessage(msg)`. Remove the second line and
the prompt still has its history. The messages table stays as the prompt's transcript; what goes is
the machinery that made it a channel.

**Sizing.** 48,668 lines in `Sources` plus `gateway`. The messaging surface is roughly 2,800 lines
directly (`SyncService` 886, `gateway.go` 1,106, `TunnelService` 363, `store.go`, `apple_auth.go`,
`AgentInvite`) plus tendrils through `AppState`, `DatabaseService` and five views. Of 137 test suites,
9 name a messaging concept, and three of those (`PortPresence`, `MessageBus`, `Agent Message
Routing`) are shell-side and stay. Roughly six suites go. The test investment was never in messaging.

## What stays, untouched

Ports and their types. `BridgeRegistry` and the one dispatch path. Port 0 and the grant object.
Address, actor, token. `ClientRegistry`, grants, the Access manager. Terminals. The prompt and its
transcript. Companions as enrolled processes. `ShellView`, `ShellDesktop`, the window manager.
`NotifyBus`, `PortActivity`, the input seam. Every gate and calibration built in the protocol thread.

Everything built in July and August survives. The deletion falls almost entirely on code that
predates it.

## Phases

Each phase is shippable on its own and is done when it is live-verified in Dev3, not when it is
committed.

### Phase 0 · The door

Decouple `/call` from the hub. The gateway keeps exactly one app-side connection, forwards `/call`
to it, carries `port.subscribe` stream frames back over `/ws`, and does nothing else. No peers, no
channels, no host election, no store-and-forward.

`is_host` stops existing: the app is the host by being the only thing on the app side of the door.
The per-spawn host credential simplifies to authenticating that one connection.

**Verify:** the CLI calls succeed with its token and are refused without one; `port.subscribe` over
`/ws` delivers `state` events; the guest page renders and drives a port. Every existing `/call` test
passes unchanged.

**Why first:** it is the only phase that builds rather than deletes, and every later deletion
depends on it.

### Phase 1 · Cut message sync

Delete the sixteen messaging functions of `SyncService`, `ChannelCrypto`, `store.go`,
`apple_auth.go`, and `AgentInvite` (already retired by `invite-taxonomy.md`). New migration dropping
`encryptionKey` and `syncEnabled` from `spaces` and `syncStatus` from `messages`. Never edit an
existing migration.

**Verify:** typing in the prompt still creates a message, a companion still answers a mention, the
transcript survives a restart. Nothing is sent anywhere.

### Phase 2 · Cut the social layer

Friends, presence of humans, member lists, typing indicators, read receipts, channel join tokens,
and invite-as-membership. `Space` keeps `name`, `accent`, `restedAt`, `workingDirectory`,
`sortIndex`: it is a zone. **Check before cutting:** `OpenClawSheet` and `PythonAgentSheet` touch
sync; determine whether they are messaging-shaped or a companion kind before deciding.

**Verify:** spaces still group ports, ⌘K still switches, arrange still works.

### Phase 3 · Cut the ceremony

Lock screen, dreamscape loop, boot cinematic, dolphin protocol. First launch names you and lands in
the shell.

**Verify:** a fresh data directory boots to the shell with no video and no blank frame.

### Phase 4 · The shell's plumbing

The three gaps from the OPEN SYNTH field report, now the core product work rather than feedback:

1. a port can emit on its own topic (`window.port42` gains a way to publish)
2. the two stores named `port:{id}` become one, so a subscriber hears what a publisher writes
3. a sleeping subscriber can be woken by a topic, not only by a message addressed to it

**Verify:** three ports composed with no glue code. One produces, one transforms, one renders. This
is the `ls | grep | wc` demonstration and it is the product's proof.

### Phase 5 · Remote pipes

`port42://<peerID>/space/<id>/<portId>` resolves through the phase 0 door. The guest page is the
browser lane. Access links burn on use. This is slice-02's wire half, landing on a base with no hub
under it. ngrok stays as the reachability mechanism for now; libp2p replaces it behind the door
later and is roadmap.

**Verify:** the acceptance table in `membrane/slice-02-cross-instance.md`, minus the rows that were
about the messaging transport.

## Risks stated plainly

**The messaging cut is irreversible in practice.** Multiplayer chat, if wanted again, is a rebuild.
Do this on a branch. Keep `slice-02-wire` and `main` as they are until phase 3 is verified.

**Milestone M3 (Sync) in `CLAUDE.md` is abandoned by this plan.** That is a product decision and it
should be made explicitly, not by omission.

**Nothing is pushed.** `main` is 93 commits ahead of origin, `slice-02-wire` 110. Two months of
work exists only on this machine. Independent of this plan, that is the largest single risk in the
repository.

## Not in this plan

libp2p. Code-signature caller identity. Per-element right-of-way. Everything in `summer2026-todo.md`
that is not a phase above. The point of the plan is what it does not contain.
