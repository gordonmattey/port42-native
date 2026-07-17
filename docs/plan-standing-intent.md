# Standing Intent — say "go do X" once; the desktop answers

*2026-07-16, riffed with GM late in the permission-surface session. Status: **CONCEPT** — no code,
no commitments. Written down because it reframes three items already on the release path: they are
not papercuts blocking the interesting work, they **are** the interesting work, and this is what
they're for.*

---

## The one idea

You say **"go do X"** once. It does not become a message. It becomes an **object in the space with a
heartbeat** — it runs, it keeps running, and it never comes back to ask what's next.

Its output is not text in a chat log. Its output is **the desktop rearranging itself**. A port
appears because right now that is the best way to say something. It updates while you watch. It
leaves when it has finished saying it.

```
   "go do X"  ──▶  ┌──────────────────┐  ──▶  a port appears
                   │  STANDING INTENT │  ──▶  a port updates
                   │   (has a pulse)  │  ──▶  a port leaves
                   └──────────────────┘
                          ▲   │
                          └───┘  it decides when, and what shape
```

## The inversion (this is the load-bearing part)

**A port stops being a thing you keep and becomes a sentence the companion says.**

Today a port is an artifact: created deliberately, kept forever, never evicted, every version
retained (184 orphaned histories in the prod DB). That's correct for a port a human authored. It is
exactly wrong for a port a running intent emits as *expression*.

Flip it, and most ports are **transient**. The companion's judgment — what to show, at what size,
for how long, and when to let it go — **is** the interface. Text becomes the artifact; ports become
the speech.

This is the same object either way (`membrane/bus-architecture.md`: a port is an addressable actor,
query-in / stream-out). What changes is **lifetime**, and lifetime is the one dimension the port
model has never had.

## What already exists (most of it)

The mechanism doesn't need inventing — it needs composing:

- **`tick`** — the loop. A unit of work pulled and run on a cadence, cold, without a human turn.
  The Autonomy slot's native provider (`pluggable-primitives-architecture.md`).
- **Peeks** — *already* the "shows up as it needs to" grammar. A port that surfaces itself, ages,
  and dissolves without being asked. The standing intent's output channel is built.
- **`port.create` / `port.patch` / `port.push`** — a running intent can build and mutate its own
  surfaces. `patch` is already the surgical delta verb.
- **`port42.storage`** — memory across surfaces, proven non-destructive across a full HTML replace.
- **`companions.invoke`** — a port can reach an intelligence directly; no human in the loop needed
  for a surface to become intelligent.

## What's missing — and it's the release path in a different hat

**1. Permissions become a standing grant, not a modal.**
A standing intent *cannot answer a dialog*. Nobody is looking. That doesn't weaken the permission
work — it specifies it. The prompt is the wrong primitive for unattended work; the right one is a
**scope + a budget + a kill switch**, granted once, visible always, revocable instantly.

This is a better design than the per-call modal we have, and it's the same code. The permission
shell surface (Track A #1) is not a chore blocking this; **this is why it must be a shell surface
with an explicit scope.** See the scope question already open in `summer2026-todo.md`
(per-port vs per-(companion, space)) — a standing intent answers it: **the intent is the scope.**

**2. Teardown must be exhaustive before anything runs unattended.**
The mic leak (`summer2026-todo.md`, 2026-07-16) is survivable today only because a human is driving.
An intent that acquires the microphone at 3am, leaks it forever, and leaves no port behind to show
for it is the same bug with nobody awake. **Rule: nothing may run unattended until every `start` a
port can reach has a `stop` the app can reach.**

**3. The missing verb: a port that closes itself.**
A TTL, or the intent's own judgment. Today the system remembers every version forever and exposes no
way to let one go — the same theme as no-reopen, seen from the other end. Ephemeral ports need:
- a **TTL / self-close** (`port.expire(id, after:)` or an intent-owned close), and
- **provenance** — a port emitted by an intent is *its* utterance and dies with it, distinct from a
  port a human authored and keeps.

**4. Accumulation, not concurrency, is the cost.**
*(Corrected on the spot by GM, and worth recording: five live surfaces does not stress the machine.
What cooked it was 88 live webviews × unconditional 60fps `requestAnimationFrame` loops — the
registry's never-evict bill plus ports that can't idle, not the count of what's on screen.)*
A standing intent emits ports **continuously**, so its real cost is **unbounded growth over time**.
That makes two existing items prerequisites, for a sharper reason than perf hygiene:
- **eviction** (`the webview registry never evicts`) — an intent running for a week must not leave a
  week of live webviews behind it.
- **presentation state** (`ports must know their presentation state`) — an emitted port should idle
  when unwatched, which it cannot do while the shell knows its state and never tells it.

Both are cheap next to the thing they unlock.

## Open questions (unresolved — do not pretend otherwise)

- **Where does the intent live?** A first-class row (its own object, its own state), or a companion
  in a mode? It has a pulse, memory, a budget, and a kill switch — that's an entity, not a message.
- **How do you steer it without stopping it?** "Go do X" then "less of that" — an amendment to a
  running intent, not a new turn. Probably the interesting UX question in the whole idea.
- **How does it know when to speak?** The judgment about *whether a port is warranted right now* is
  the entire product. A companion that emits a port per thought is noise; the peek's ageing grammar
  is the closest existing answer.
- **When is it done?** X may have no terminal state. Does an intent end, rest (`restedAt` is already
  the vocabulary), or run until revoked?
- **Skill ↔ port, again.** The unresolved *up*-invariant question from
  `pluggable-primitives-architecture.md` — how a persistent engine-side procedure surfaces in the
  user layer — is exactly this question. A standing intent may be the answer to it, or a second
  instance of it.

## Gates (what would prove it, not demo it)

- An intent runs **unattended overnight** and, in the morning: nothing is leaked (no live mic /
  camera / screen capture, no orphaned webviews), and the ports it emitted have aged out on their
  own.
- It reached for a permission it didn't hold and **did the right thing without a human** — deferred,
  logged, and surfaced the ask, rather than hanging on a modal nobody saw.
- The desktop in the morning is **legible** — you can tell what it did and why each surface is
  there, without reading a log.
- You steered it once and it **kept going**, changed.

## Sequencing (why the boring items come first)

```
   permission shell surface  ──┐
   exhaustive teardown       ──┤──▶  safe to run unattended  ──▶  STANDING INTENT
   evict + idle              ──┤
   port TTL / self-close     ──┘
```

Nothing here argues for building the intent first. It argues that the four items above have a
destination, and that the destination changes their design — most sharply the permission scope
(the intent is the scope) and port lifetime (a port may be speech, not an artifact).

## Related

- `membrane/bus-architecture.md` — a port is an addressable actor; an intent is a caller that never
  stops calling.
- `summer2026-todo.md` — the mic leak, the never-evicting registry, presentation state, no-reopen,
  and the permission-UX item. All four are prerequisites; the todo's recurring theme (*the system
  knows; nothing exposes the knowing*) is what an intent would have to stand on.
- `pluggable-primitives-architecture.md` — `tick` is the Autonomy slot's native provider; the
  *up*-invariant says an autonomous tick reaches the human only through a user-facing primitive.
  Here that primitive is a port.
</content>
</invoke>
