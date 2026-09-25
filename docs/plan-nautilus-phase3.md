# Nautilus Phase 3: the pipe

Detailed plan for Phase 3 of `plan-shell-only.md`. Scenario served: 3. Draft for GM's review,
written 2026-09-25 against `nautilus` at `3735d59`, with Phases 1 and 2 built and the harness at five
of five. Nothing here is built.

## Goal

One port feeds another with no glue, including when the middle stage has no tile, when the receiver
is not on screen, and when the receiver is a companion rather than a port.

## Decisions for GM

1. **Which events wake a companion that watches a port.** Recommended: the events the port publishes
   itself (`port.publish`, kind `port.*`) and mentions in its chat. Not system traffic such as
   `terminal.output`, `state` or `console`, which would start a model turn per keystroke.
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

A companion can watch a port: `companions.watch(id, port)` and `companions.unwatch(id, port)`, stored
on the companion. An event of a waking kind (decision 1) on a watched port's topic starts a turn: a
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
