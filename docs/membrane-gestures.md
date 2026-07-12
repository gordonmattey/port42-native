# The Membrane — Affordances & Gestures

*2026-07-12 — the actual point of this whole thread: the interaction vocabulary for watching and
steering agent loops. Concrete and physical, not research. Companion to [`the-membrane.md`](the-membrane.md).*

## The objects (what gestures act on — there are only a few)

- **the field** — the ambient layer over your apps: edge presence by default, full galaxy on summon
- **agent token** — one per agent, persistent position (→ spatial memory), state in how it looks/moves
- **trail** — each agent's recent actions, scrubbable
- **leash** — each agent's autonomy level, made physical
- **the knock** — an agent pressing into your periphery, pressure building

## Design principles (thread through everything)

1. Every gesture acts on a **persistent agent token** — you always know what you're touching.
2. **Watch and steer through the same object** (H5) — no separate monitor and controller.
3. **Every steering gesture is cheaper than restarting** — or people just restart and the membrane fails.
4. **Calm by default** — 19 of 20 agents are visually silent; only what needs you moves.

---

## Watching  (agent loops → you)

| Gesture | Affordance | What happens |
|---|---|---|
| **Glance** | calm tokens breathe quietly; the one needing you is the only thing that moves/warms | passive read — you do nothing; the field is designed so your eye lands on what matters |
| **Peek** | bring attention to a token; it swells | reveals aim + last action + how long it's looped (semantic LOD); reversible |
| **Dive** | pinch/click into a token | opens into the agent's full work instrument (shell zoom) |
| **Scrub the trail** | a timeline on the agent | drag to replay what it did *(recast: version-scrub → action-scrub)* |

## Steering  (you → agent loops)

| Gesture | Affordance | What happens | Recast from |
|---|---|---|---|
| **Redirect** | touch a running agent, say the new aim | it re-plans toward the new aim, keeps context — *the flagship* | point-and-say |
| **Hold** | press-and-hold a token | freezes/dims; release to resume | keep/melt → pause |
| **Leash** | a tether showing how far it goes alone | pull in (ask me more) / let out (run free) — the trust dial, physical | new |
| **Rewind** | drag the trail backward | agent undoes last actions and retries | version-scrub → rewind |
| **Nudge** | quick chips on the agent ("slower", "check your work") | biases next iterations without changing the aim; *anneals* (a repeated nudge becomes automatic) | new |
| **Fence** | draw a boundary it can't cross | agent visibly respects the constraint ("not prod") | new |
| **Take the wheel** | grab an agent mid-step | you do that step yourself, hand back | take-the-wheel |
| **Fork** | pull an agent apart | two variants with different aims; keep the better | fork-apart |

## The knock  (the acute channel)

An agent presses into your periphery; **pressure builds** via lean / warmth / size / proximity.
Three responses to any knock:

- **Turn toward** — attend now; it expands into whatever it needs (instrument / call / approval)
- **Push back** — "later"; it recedes but keeps building pressure
- **Wave off** — dismiss — *and it learns*: this class of knock fades for this agent (anneal → earned trust)

Special knock forms:
- **Accept the call** — a call-request *rings*; accept drops you into a focused real-time session (the
  agent's loop pauses); decline → back to async. *(the genuinely-new interaction)*
- **Approve / reject** — a review-knock brings the thing to approve into the periphery, verdict in place

## Ambient presence

- **Summon / banish** — pull the whole field center for review, or push it to the edge for focus. The
  membrane lives at the margins; you call it center on demand. *(the shell zoom ladder is this)*
- **The edge** — persistent screen-edge presence over your other apps; **the knock happens here**, over
  whatever you're working in (pervasion, not a destination — see `the-membrane.md`).

---

## The evidence in the recast column

Half of the steering gestures are the surface gestures we already built, re-aimed from *editing a
surface* to *steering an agent loop*: point-and-say → redirect, scrub → rewind, fork-apart → fork,
keep/melt → pause. The gestures were right; they were pointed at the wrong noun (surfaces instead of
agent loops). This is the strongest signal that the membrane is the frame these gestures were always for.

## What to prototype first

The **glance + the knock** together — the calm field where one agent presses into your periphery and
you turn-toward / push-back / wave-off. It is the smallest thing that exercises the core: watching at
scale (glance), the acute channel (knock), and the gradient (pressure). Every other gesture needs a
visible agent to act on first, and this is the one that structurally isn't Lovable.
