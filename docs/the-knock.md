# The Knock

*2026-07-11 — the acute primitive of the membrane's watching side. Companion to
[`the-membrane.md`](the-membrane.md). This is a design seed, not a spec — we build fresh.*

## The claim

**The knock is the notification, redesigned for a world where the number of things that can want your
attention is unbounded.**

Notifications are the incumbent answer to "something needs you." They were never allowed into the
core loop of any application — they are a bolted-on side channel, and people mute them. That is not
an accident of implementation; it is structural. Notifications fail because they are:

- **undifferentiated** — a critical one looks like a trivial one
- **push-by-sender** — they interrupt on the sender's schedule, not the receiver's
- **binary** — fired or not; no gradient of *how much* this needs you
- **stateless** — isolated events; no memory, relationship, or learning
- **non-composing** — 50 notifications are 50 interruptions, never one synthesized picture
- **triage-dumping** — you must read each to discover whether it mattered

This is *tolerable* when a handful of apps ping you. It **fails catastrophically** when every agent
loop can raise "I need you" — the agentic world. It becomes all noise. And current agent products are
still bolting notification-style "agent finished ✅" toasts on top, which will drown people. Nobody is
rethinking the primitive itself.

## The redesign

The knock re-solves "something needs you," point-for-point against those failures:

| Notification failure | The knock |
|---|---|
| pushed by the sender | **triaged by the membrane** — the agent raises a *need*; the membrane decides if it earns your calm. The membrane is your attention's bouncer (an OS notification can't be — the OS has no model of your attention). |
| binary fired/not | **gradient** — the agent leans, glows, edges toward you, gets "louder" the longer it waits or the more it needs you. Pressure builds in the periphery; you attend when your loop allows. |
| a line of text pointing elsewhere | **the knock is the instrument** — you act *through* it in place: get on a call, approve a surface, make the decision. Not a pointer to go find something. |
| stateless, isolated | **stateful, in-relationship** — a moment in an ongoing loop you have context on. And it **learns**: waved-off knocks teach the agent to stop knocking (creases → anneal → the knock-rate *falls* as trust builds). |
| non-composing | **composed** — N needs become a legible few. "Three agents blocked on the same decision" = one knock. "Everything calm except forge" = forge is simply the only thing not quiet. |

## Kinds of knock

The knock is not one thing — the need determines its form and urgency:

- **Blocked** — the agent cannot proceed without you. Highest pressure; it *should* eventually break
  focus if unanswered, because work is stalled.
- **Decision** — the agent hit a fork only you can call. Pressure grows with how long the loop idles.
- **Review / approve** — the agent finished something and wants a look before it counts. Low pressure;
  waits for your review phase. Prime candidate for annealing away (if you always approve, stop asking).
- **Call** — the agent wants to *talk it through*, not exchange messages — a real-time channel for
  something too tangled for async. A genuinely new interaction: an agent requesting synchronous time.
- **Surfacing** — not a need at all; the agent found something worth your eyes. Lowest pressure;
  belongs in the review digest, not the acute channel.

Each is a different urgency and a different physical form. The membrane's job is to render the right
form at the right pressure — and to *compose across* them so the human sees a shaped few, not a pile.

## The mechanism half-exists

The **peek** in Shell mode is already the physical form of the knock — today a window peeking in from
another space (`ShellPeekTile` / the notification rail). The design work is not building the organ;
it is generalizing **what can peek, and why**: an agent peeking to request a call, a surface peeking
for approval, a decision peeking for a verdict. The peek is the body; the knock is what flows through
it — triaged, graded, composed, learning.

This is not "reuse what we built" in the gi-engine sense. It is that the Shell grew the right organ
before we knew what it was for. We build the knock fresh; the peek is where it lands.

## Why this is the wedge

The glance (the calm field of N agents) is the membrane's steady state. The knock is its *acute*
edge — the moment the calm breaks. The knock may be the better first build than the glance, because:

- it is a **crisp, legible pitch**: "we rethought the notification for the agent world" — a problem
  everyone feels and no one has solved
- the **mechanism already exists** (the peek) — less to invent, more to design
- it is the **most-felt failure** of today's agent products (notification noise), so it lands
  immediately with anyone using them
- it forces the core questions anyway: triage (whose need earns attention), gradient (how pressure is
  shown), composition (many needs → few knocks), learning (knocks that fade) — the whole watching
  side in miniature

## Open threads (to reason through before building)

1. **The triage function** — on what basis does the membrane decide a need earns your calm? (stakes,
   blocking-ness, your current phase, this agent's trust level, how long it has waited?)
2. **Rendering the gradient** — what does "getting louder" look and feel like in the periphery without
   becoming the noise we are escaping? (motion, warmth, size, proximity, sound?)
3. **Composition rules** — when do multiple needs merge into one knock vs stay distinct?
4. **The call** — an agent requesting *synchronous* time with a human is genuinely new. What is that
   interaction? (voice? a shared surface? a focused session that pauses the agent's loop?)
5. **The fade** — how does a knock learn to stop? What signal (waved off N times unchanged) retires a
   knock class for an agent, and how does the human see/undo that?
