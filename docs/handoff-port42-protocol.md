# Handoff — Port42 protocol (local bus)

Next-session pickup for the "port as addressable actor" work. Detailed plan and rationale live in
`docs/plan-port42-protocol-local-bus.md`; this is the at-a-glance state.

## Status

- **L0 (address resolver)** — DONE. `PortAddress`, `PortResolution`, `AppState.resolvePortRef`; all
  by-id bridge methods route through it. `PortAddressTests` green.
- **L1 (Subscribe → Notify)** — DONE, live-verified. `NotifyBus` (1:N), `port.subscribe` stream
  method, four producer taps (`port.push`, terminal `onFlush`, web console, browser events),
  per-surface JS delivery `port42.port.subscribe(id, onEvent)`.
- **L2 (right-of-way lease)** — NOT STARTED. Next keystone.

## Last session (2026-07-23), on `main`

- `edb120b` — `port42.port.subscribe(id, onEvent)` JS delivery. Live: two web ports, three
  `port.push` → three parsed `{topic, kind, payload}` envelopes in order.
- `e65fd99` — corrected a wrong note: subscribe DOES work through `port.exec`. The earlier failures
  were malformed test JS (see footgun below), not a bridge limit.
- `46535b3` — bounded `port.exec` with a timeout so a returned long-lived promise can't hang/leak the
  task. `PortExecJSTests` 7/7 green (`swift test`).

## What to know before touching this

- **Do not `return` a subscribe stream from `port.exec`.** `callAsyncJavaScript` auto-awaits; the
  subscribe promise settles only on cancel. Correct: `var s = port42.port.subscribe(id, fn); return
  "ok";`. Now guarded by `PortExecJS.run`'s 30s timeout (`PortExecError.timedOut`).
- **`port.exec` body footgun.** A multi-statement one-liner with no `return`/newline (e.g. `foo();
  42`) wraps to `return (foo(); 42)` — a syntax error shown as "A JavaScript exception occurred". Use
  an explicit `return` or newlines. Pinned by `PortExecJSTests`.

## Verification gap

The `port.exec` timeout guard is compile- and unit-tested only. Its runtime path (an exec that
actually times out) was NOT live-tested — that needs `./build.sh` + a dev relaunch, deferred to avoid
disrupting the running instance. The subscribe feature itself was live-verified against the
already-running Dev build.

## Open threads

- Remove the `[portdrive]` NSLog in `port.push` (BridgeMethods) when RCA 2.3 closes.
- RCA 2.3 (app freeze) still formally OPEN; terminal ports untested as the hang suspect.
- Rigs: Port42Dev (:4243), Port42Dev2 (:4244) for isolated testing.

## Next

L2 — right-of-way lease (keystone #2). Prereq (stable port identity) already satisfied by L0's
`PortRef`/`resolvePortRef`.
