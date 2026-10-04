# Plan: bringing Port42 up in order (#223)

Gordon, 2026-10-04: the current space first plus a cap, five terminals starting at a time. Research and
measurements: `docs/research/boot-order.md` (spike/boot-order). Today every terminal in every space starts its
CLI at launch, together; on a loaded Mac the current space's sessions took 139 s once and did not finish in
200 s twice.

## The change

A terminal port is restored at launch as **waiting**: it exists (listed, in the rail, resolvable, its chat
works) with no surface and no process. One queue in the app starts waiting terminals:

- **Order.** The current space's terminals first (with those pinned everywhere or shown in it), then the other
  spaces, most recently visited first. Switching to a space moves its waiting terminals to the front.
- **Cap.** At most 5 starting at once. A start ends when its CLI reports its session, or after 20 seconds;
  then the next begins.
- **Need starts it now**, ahead of the queue and the cap: a mention or any message to its companion (which
  covers a turn a restart cut off and a watch's wake, both of which deliver that way), a push or other call
  that needs its terminal, a click on its tile. A message is held until the session is ready, as it already
  is for a companion that is starting.

## Phases

1. **The queue.** `TerminalStarts`: waiting, starting, the cap, the order, start-now. The launch restore
   enqueues terminals instead of starting them; `ensureTerminalLive` starts a waiting one now; a space switch
   prefers its terminals. Tests: the cap holds, the order holds, start-now jumps the queue and the cap, a
   settled start lets the next begin, a space switch reorders.
2. **The waiting tile.** A waiting terminal's tile says it is waiting and starts on a click, instead of a black
   rectangle.
3. **Calls that need a live terminal** (`port.push`, `terminal.*` and the rest that read `terminalControllers`):
   on a waiting port they start it and wait for its surface, instead of failing with "no live surface".

Not in this: web views still start at launch (`docs/plan-webview-eviction.md`). Companions in other spaces
sleeping until needed (the spike's option C) is a follow-on.
