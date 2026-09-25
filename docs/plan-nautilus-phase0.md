# Nautilus Phase 0: the door

Detailed plan for Phase 0 of `plan-shell-only.md`. Scenarios served: 2 and 4. Written 2026-09-25
against `nautilus` at `e40ab8f`.

## Goal

`/call` and `/ws` reach the app without the messaging hub. After this phase the gateway does three
things: it accepts the app's one host connection, it forwards calls to it, and it carries responses
and stream frames back. Nothing in it knows what a channel is.

## What is measured

- **The app side.** The door is one callback, `SyncService.onCallReceived`, set in
  `AppState.swift:1553`, fed by `SyncService.handleCall`. Everything else `SyncService` does is
  messaging. Outside `SyncService`, the app uses `sync.` for messaging in AppState, ChatView,
  BridgeMethods and three sheets, and for one status light (`sync.isConnected`, three sites in
  `ShellDesktop`).
- **The gateway side.** The door is `HandleHTTPCall`, `routeCall`, `routeStream`, `routeResponse`,
  the `call`, `response` and `stream` cases, the peer table and the host credential. `routeCall` has
  a second branch that routes by channel host (`g.hosts`); it goes.
- **The silent-argument defect is live.** `ports.list` has no `all_spaces` argument; every audit
  call passed one and it was ignored (audit F13).
- **Nothing else uses the hub.** The CLI and the shim send no `join` or `message` envelopes. The
  CLI calls over HTTP.

## Steps

Each step is its own commit, with the Swift suite and the Go suites green at each.

### 0.1 The scenario harness

`scripts/scenarios/`: the scripts that produced the baseline, cleaned up. One entry point runs all
five and prints a pass or fail row per scenario with its evidence.

- **It runs under its own client.** It reads its token from a path given in an environment variable
  and refuses to start without one. No borrowed token.
- **Scenarios 2, 3, 4 (local half) and 5 are automatic.** Scenario 5 restarts the instance it is
  pointed at.
- **Scenario 1 is automatic through today's mention path** and moves to the chat port in Phase 1.
- **It never points at production.** It refuses port 4242.

Blocked on one thing: a client enrolled for the harness in Settings → Access.

### 0.1b The manuals teach `port.create`, never the fence (done)

Scenario 1 failed because the agent followed its manual: the port manual's first line, the reference
preamble and `llms.txt` all taught the ```` ```port ```` fence first. They now teach only `port_create`
and warn off the fence (D11), with a gate that fails if any of them teaches the fence again. Echo's
first-run prompt still asks for a fence; Echo is rebuilt in Phase 1.

A resumed companion still answered with a fence, from its old transcript, without reading the
manual. So scenario 1 asks a fresh session: the harness opens a terminal running the CLI, waits for
it to register as a companion, and mentions it. With that, scenario 1 passes in 12 seconds.

### 0.2 The app's door gets its own connection

New `Services/GatewayDoor.swift`. It connects to `/ws`, identifies as host with the per-spawn host
credential, answers `call` envelopes through the existing handler, sends `response` and `stream`
frames, and reconnects. `handleCall` and `jsonContent` move out of `SyncService` unchanged.

- **`AppState` wires `door.onCallReceived`** to the existing closure body, unchanged. The caller
  resolution, the unnamed-caller refusal and `RemoteToolExecutor` stay exactly as they are.
- **`SyncService` stops being started.** It no longer connects or identifies, so it is no longer the
  host. Its code stays until Phase 1 deletes it. Remote space sync stops working here, which the plan
  has already accepted.
- **The status light reads the door.** `ShellDesktop`'s three `sync.isConnected` sites read
  `door.isConnected`.

**Done 2026-09-25.** `GatewayDoor` owns the host connection; `SyncService` lost its call path and is
never started, so a launch shows `[door] open as host` and no sync connection at all. `JSONValue`
moved to the door, so Phase 1 can delete `SyncService.swift` whole. Nine gates in
`GatewayDoorTests`, calibrated by breaking stream handling, a wire key and the respawn limit.

**Added to this step, found while verifying it:** nothing restarted a gateway that died, so one crash
locked every caller out until the app was relaunched (audit F17). `GatewayProcess` now respawns a
gateway that exits unasked, with a fresh host credential, at most five times a minute. Live: the
gateway was killed and calls were answered again 4 seconds later. Harness after the step: 1, 2, 3 and
5 pass; 4 waits on step 4.

### 0.3 The gateway drops the hub

- **Envelope switch:** keep `call`, `response` and `stream`. Every other type gets the existing
  `unknown_method` error.
- **Delete:** `joinChannel`, `handleCreateToken`, `flushStoredForChannel`, `leaveChannel`,
  `broadcastPresence`, `broadcastTyping`, `routeMessage`, `routeReceipt`, `storeForPeer`,
  `flushStored`, the nonce challenge, `store.go`, `apple_auth.go`, the channel branch of `routeCall`,
  and the channel bookkeeping in `removePeer`, `Peer` and `Gateway`.
- **Keep:** `/health`, `/call`, `/ws`, `/port` (the guest page), `/invite` (the flow Phase 4
  reuses), the rate limit and the host credential.
- **`main.go`** loses the flags that only configured the store and Apple auth.

**Done 2026-09-25.** `gateway.go` went from 1,106 lines to 516 and says what it is in its header.
`store.go`, `apple_auth.go` and their tests are deleted, and `go.mod` lost SQLite and the JWT library.
The WebSocket handshake is `no_auth` then identify, with no challenge. Frames are logged by type
only, because a call frame can carry a caller's credential and its body used to be logged. New Go
gates: a hub envelope of every type is refused `unknown_method` (checked by re-adding `join`), an
HTTP call and a WS call need no channel state, and a call with no host is refused `no_host`. Live:
`join` on Dev3 answers `unknown_method`, and the harness gives 1, 2, 3 and 5 passing, with 4 waiting
on step 4.

**Why the gateway had been crashing is not recoverable.** The gateway truncated its own log on every
start, and macOS kept no crash report, so each restart erased the evidence. Now the gateway keeps the
previous run's log as `.1`, and the app logs how the gateway ended: exit or signal, the status, and
whether it was asked to stop. The next crash will say why.

### 0.4 A connection is one caller

The gateway stores the credential given at `identify` on the peer, and `routeCall` stamps it on
every call that peer forwards, replacing whatever the envelope carries. One connection, one
identity, set once. This fixes the guest page's live half (audit F2) without touching the page.

### 0.5 Opening a terminal is consented: already true

Verified 2026-09-25: a client without the grant that opens a terminal running `claude` raises a
permission card, and approving it records `terminal` on port 0 for that client. The summer todo item
predates slice-02's consent work. Nothing to build.

### 0.6 An argument the method does not declare is refused

`BridgeDispatcher` compares the caller's argument names with the method's declared parameters, plus
the reserved write fields (`token`), and refuses the rest with `bad_arg`. The error names the
argument it did not know and lists the ones the method takes. Ports that pass extra arguments today
break, and that is accepted (no backward compatibility, D7).

## Tests

Every new gate is calibrated by breaking the code it guards and watching it fail.

| Step | Gate |
|---|---|
| 0.2 | A call reaches the handler through `GatewayDoor` and its response returns; a streaming method's frames arrive in order on the same call id; the door reconnects after the gateway restarts; `SyncService` is not connected after launch. |
| 0.3 | Go: an HTTP call and a WS subscribe work with no channel state; `join`, `message`, `typing`, `read` and `create_token` each get `unknown_method`. `store_test.go`, `apple_auth_test.go` and the hub cases in `gateway_test.go` are deleted with their code. |
| 0.4 | Go: a WS call with no credential on its envelope arrives carrying the identify credential; an envelope credential different from the identify one is replaced, not honored. |
| 0.6 | An undeclared argument is refused and named; a declared one passes; `token` passes on a write. `BridgeSchemaParity` still holds. |

`SyncAuth` is reworked to cover the door's host identify, or deleted if `GatewayDoor`'s tests cover
it fully.

## Verify, live on Dev3

- The harness passes all five scenarios.
- The CLI works with its token and is refused without one.
- The guest page opens a port, receives its live events, and drives it, with the credential given
  once at identify.
- An unknown argument from the CLI is refused with the list of accepted ones.

## Not in this phase

Deleting `SyncService`, the messaging views and the `messages` table (Phase 1). Any change to what a
caller is allowed to read (Phase 4). The invite payloads (Phase 4).
