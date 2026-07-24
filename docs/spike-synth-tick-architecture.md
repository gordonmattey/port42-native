# Spike: Synth Jam — the Tick Architecture (2026-07-23)

Clean design after too much bolting-on. GM's model, captured so we stop going in circles.

## The model — no conductor, one tick everyone reacts to

A shared **tick** (the beat) drives everything. Each participant is a subscriber that, on the tick,
reads the synth, thinks, and pushes its own update back. Nobody conducts.

- **Synth = the port + the clock.** Holds the state (grid, all knobs, levels, notes) and the transport
  that produces the tick. It emits the tick on the bus, publishes its full state, and takes pushes back
  and lays them into lanes. The instrument is the heartbeat. Nothing else lives in it.
- **Member = a voice.** Turn it on → it subscribes to the synth (the whole state: knobs, levels, notes).
  On each tick it reads that, runs its LLM, and pushes its own lane update back. That is the entire
  member. The tick is the cue; no conductor invokes it. Off → silent.
- **Vibe AI = a peer member.** From its own port it subscribes to the synth, interprets the whole thing
  (all settings + notes) via LLM into a vibe, and pushes its vibe **into the tick**, so when the members
  read the tick the vibe is already there feeding their LLMs. A member that emits a reading, not notes.

Fully decentralized: one heartbeat, N subscribers, each read → think → push.

## Invariants

- The instrument stays pure. No orchestration/conductor/roster code in the synth. It only holds state,
  ticks, publishes, accepts pushes, persists lanes, and honors hand-placed human notes.
- Everyone talks over the bus (publish / subscribe / push). Same contract for a member, the vibe AI, and
  the human.
- A member owns exactly one lane and never writes another lane's cells.

## The crux to validate

What is a "member" *mechanically*, so it reacts to the tick on its own — no performer port, no conductor
invoking it? A member must hear the tick, run an LLM, and push back, repeatedly.

Known so far:
- `companions.invoke` returns the companion's TEXT only — no tool execution (verified: onthekeys replied
  with a phrase but never called `port_push`).
- `bus.publish` "does not trigger companion chat routing" — a bus signal may not wake a dormant companion.
- A companion triggered via chat (message/mention) is believed to have real tool access (that is how the
  original lanes — ghost/onthekeys/bass/arp — got driven). **To verify.**

Candidate member substrates:
1. Companion triggered per tick via a message/mention (has tools, but chat-routed and noisy).
2. Companion + a bus trigger, if a trigger can fire on a bus tick and execute tools (cleanest if it exists).
3. A member unit that runs the LLM itself (a port). Rejected by GM — no performer ports.

## Spike tests + findings (2026-07-23)

1. **The tick pattern already exists on the bus.** `bus.read('bus')` returns `{"beat":N}` — a beat
   signal published on topic `bus`. So the heartbeat channel is real (partly built before).
2. **`companions.invoke` returns text only** — no tool execution (onthekeys replied with a phrase but
   never called `port_push`).
3. **A chat mention did not make a companion push either** — `messages.send` with "@onthekeys ... call
   port_push ..." produced no lane after 30s.
4. **The decisive one: companions have no bus-triggered wake.** `AgentTrigger` (AgentConfig.swift) has
   exactly two cases — `mentionOnly` and `allMessages`. All six companions are `mentionOnly`. There is
   no "watch the bus / fire on a beat" trigger. "Companions subscribe via bus: watching signals" means
   an *already-active* companion can read the bus during its turn, not that a bus signal can *start* a
   turn.

## Conclusion — the model is right, the platform is one primitive short

The tick model needs a member to wake on the beat, run its LLM, and push — repeatedly, on its own.
Nothing on the platform does that today:
- Companions only wake on chat (mention / allMessages), never on a bus signal.
- `companions.invoke` wakes them but gives no tools (text only).
- Self-looping with tools only exists inside a port (a webview with setInterval + ai.complete + push).

So there are three ways forward:

- **A — add a bus-beat trigger (the real fix).** A new `AgentTrigger` (e.g. `busBeat`, or a topic-watch
  trigger) so a companion wakes when a beat lands on the bus, reads state + vibe, and pushes — with
  tools. This makes companions true tick-members and realizes GM's model exactly. Cost: app-level Swift
  (new trigger + routing that starts a companion turn from a bus signal) + rebuild.
- **B — tick as a chat message.** Set members to `allMessages` and have the synth emit a beat as a chat
  message each tick; members wake and push. Works today, no code, but it is chat-based and noisy, and
  every message wakes every allMessages companion.
- **C — member substrate = one port.** A single "band" port self-loops on the beat and runs the voices
  (companions not involved, or invoked text-only and the port pushes on their behalf). Works today; not
  "real companions playing."

**Recommendation:** the model is correct; if the goal is real companions as bus-tick members, **A** is
the honest build — it adds the missing primitive rather than working around it, and it generalizes
(any companion can watch any bus topic, not just the synth beat).
