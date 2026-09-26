# Nautilus Phase 3: the pipe

Detailed plan for Phase 3 of `plan-shell-only.md`. Scenario served: 3. Draft for GM's review,
written 2026-09-25 against `nautilus` at `3735d59`, with Phases 1 and 2 built and the harness at five
of five. Nothing here is built.

## Goal

One port feeds another with no glue, including when the middle stage has no tile, when the receiver
is not on screen, and when the receiver is a companion rather than a port.

## Decisions for GM

1. **Which events wake a watching companion: the subscription says (decided, GM 2026-09-25).** A
   watch names the event kinds it wakes on; the default is the port's own `port.*` events plus
   mentions in its chat. `state` (a reviewer watching edits) and `console` (fix it when it throws) can
   be asked for; `terminal.output` is never a trigger, since it would wake on every keystroke.
2. **What a burst of events costs.** Every wake is a full model turn (the Open Synth report measured
   one inference per beat). Recommended: at most one turn in flight per companion; events that arrive
   during a turn are delivered together as the next turn.

## What is measured

- **The pipe works for live, visible ports.** Scenario 3 passes: produce, transform and render as
  three web ports, produce to render in single-digit milliseconds.
- **Durable versus live is no longer split.** The field report found `bus.publish` durable but never
  delivered to `port.subscribe`, and `port.push` live but leaving nothing. The bus methods went in
  Phase 1; a port's chat is durable AND published on the port's own topic as a `chat` event, so one
  name, one channel.
- **Web ports do not sleep.** Every web port's view is created at launch and stays live off screen,
  in a resting space or parked; only a closed port is gone. A "rested" subscriber that is a web port
  should therefore already hear its events. Not yet shown by the harness.
- **A companion wakes only on chat.** A mention wakes it (a closed terminal is respawned first). It
  cannot watch a port.
- **Errors reach port JS, and there is no token carve-out** (both field-report defects, verified
  2026-09-25). Since 2026-07-28 the bridge rejects with the whole envelope, so `e.code` and
  `e.current` are set in a port's catch. A port's own JS writing without a token is refused
  `token_required`, whether it writes to itself or to another port: one rule for every caller.
- **`terminal.exec` runs as a raw child of the app**, attributed to its caller only by the grant it
  needed. It has no port.
- **There is no tile-less port.** Every port is tiled, parked or the wallpaper.

## Before this phase: agents in a room (GM's multi-agent test, 2026-09-25)

Two Claude companions and a Codex companion tried to work on one port through its chat. Found and
fixed, each with tests calibrated by removing the fix:

- **Every reply is posted.** A turn typed into the terminal was never posted, so its @mention
  hand-off went nowhere. Replies go to the chat that asked, else the terminal's own chat, whose
  @mentions then route. Companions must @mention each other there, so two cannot loop.
- **Messages arrive whole.** A long or multi-line message goes in as one paste with an Enter that
  waits for it; typed as keys, one lost about 1,100 characters and its Enter. An unsent first-run
  prefill is cleared before the next message.
- **Codex can take part.** Its sandbox blocked the network, loopback included, so it concluded Port42
  was not running; this session's config now allows it. Its instructions keyed on an env var that did
  not reach its shell; they key on the token file now. A terminal that starts codex is registered as
  codex, not claude (the session-start hook names its CLI).
- **Agents know where they are.** A new `whoami` answers, from the caller's credential, its name,
  space, terminal port and chat, and who else is here. Claude's prompt and Codex's AGENTS.md teach the
  chats from one source (`CompanionProtocol.chats`): whoami first, a message names the chat it came
  from, a port's work belongs in that port's chat (`chat.read`, `chat.post`), @mention to reach
  someone. A port's chat is named with its id. Replies are "delivered back to the chat it came from".

Open from the same test: a person's plain post in a web port's chat reaches nobody (who counts as in
that chat is 3.3's watch), and the MIC ON button GM reported missing in the mic shader port.

## Steps

Each step is its own commit: suite green, harness five of five, plans updated.

### 3.1 Errors reach port JS: already true

Verified 2026-09-25, nothing to build (like Phase 0 step 0.5). The rejection carries `code` and every
detail (`PortBridge.handleMethod`), and a port's tokenless write to itself or another port is refused
`token_required`. One gate is added with 3.2: a refused write from a port principal carries `code`
and `current` in the envelope the page receives.

### 3.2 Invisible ports

`port.create({ ..., presentation: "hidden" })` makes a port with its full bridge, storage and
subscriptions and no tile: not on a desktop, not in the rail, listed by `ports.list` with status
`hidden`, closable and reopenable like any port. `port.manage(id, "show")` gives it a tile for
debugging and `"hide"` takes it away. Its presentation reports it not visible, so it pauses any
drawing loop while its logic keeps running.

*Gates:* a hidden port is in no desktop set and no rail; it receives a subscribed event and publishes
one; show and hide round-trip its presentation; it survives a restart hidden.

### 3.3 Companions watch ports

A companion can watch a port: `companions.watch(id, port, kinds?)` and `companions.unwatch(id,
port)`, stored on the companion. An event of a kind the watch names (decision 1) on the port's topic
starts a turn: a
terminal companion gets the event typed in with its source (`[port 'x' published beat]: {...}`); a
headless one is launched with it. The reply goes to that port's chat. One turn in flight at a time,
with events batched into the next (decision 2). This is the todo's `busWatch`, generalized.

*Gates:* a watched port's `port.*` event wakes its watcher once; `terminal.output` does not; a burst
of five during a turn arrives as one batched turn; unwatch stops it; a companion's own event does not
wake it.

### 3.4 `terminal.exec` runs in a port

Each caller that runs `terminal.exec` gets one hidden terminal port of its own (3.2), created on first
use and reused, named after the caller. The command runs there, its output is captured and returned
as today, and the port's chat and console keep the record. Every shell action then has a port with an
identity, as the model says; the grant stays on port 0 as today.

*Gates:* two callers' commands run in two different ports; a caller's second command reuses its port;
output, exit code and timeout behave as before; the port is listed hidden with its creator.

### 3.6 Port42 as native tools, not curl

Companions reach Port42 by curl, so Codex asks for approval on every call and each call is a shell
round trip. Port42 runs an MCP server generated from the registry (the tool list already is, as
`generatedToolDefinitions`) and registers it in each companion's session: Claude through its MCP
config, Codex through `[mcp_servers]` in its per-session config. `whoami`, `chat.post`,
`port.create` and the rest become tool calls, authenticated as the companion. The stale
`port42-mcp.js` (hardcoded port 4242, removed methods) is replaced.

*Gates:* the MCP tool list equals the registry's generated one; a call through it is attributed to
the companion's client; both CLIs' session configs name the server.

### 3.5 Scenario 3, extended

The harness's scenario 3 gains: the transform stage as a hidden port; the render port in a resting
space, still receiving; a companion watching the render port, woken by one published event and
replying in its chat.

## Verify, live on Dev3

The harness passes five of five. GM watches a companion react to a port's event, and shows then hides
a hidden port.

## Not in this phase

Remote subscribers (Phase 4). REST reaching the gateway from a port, the field report's containment
finding, which belongs with Phase 4's read scoping. Bridge proxies firing phantom calls when coerced
to a string (a small fix, taken whenever the bridge is next touched).
