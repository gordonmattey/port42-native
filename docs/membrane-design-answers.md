# The Membrane — Reasoned Answers to the Open Questions

*2026-07-11 — worked answers to the five open questions in [`the-membrane.md`](the-membrane.md).
Each reasons from first principles (the two-loop model, calm-technology, autonomy theory) rather
than asserting. The recurring finding: almost every piece Port42 already has recasts cleanly onto
the membrane — strong evidence the pieces were right and only the framing (generator) was wrong.*

---

## Q1 — The glance: the legible picture of N looping agents

**The reasoning.** "Legible at a glance" is a perceptual claim, so start with perception. Human
pre-attentive processing can track a few dozen items *only* when they differ on a single salient
channel — motion, colour, size, position. Reading does not scale; a dashboard of N rows is not a
glance, it is a chore. So the glance cannot be an information display. It must be a **field of
pre-attentive signals**.

Then apply the two-loop mismatch. There are many agents and one human; the human cannot watch all N.
So the glance's job is *not* "see all N clearly." Invert it: **N stay calm; only the one that needs
you surfaces.** This is calm technology (Weiser/Brown) — the periphery stays quiet, and the single
thing that needs attention is the only thing that moves to the centre. A healthy looping agent should
be *visually quiet* (a slow breathing motion = alive but fine); a stuck, blocked, or
decision-needing agent breaks the calm (motion toward you, warmth, growth — the *knock*).

But there are two human phases, so the glance needs two layers:
- **Ambient** (during focus): pre-attentive, alerts-only. Nothing demands you until something must.
- **On-demand detail** (during review): hover/zoom reveals each agent's *aim, last action, and how
  long it has been looping* — readable, deliberate. Semantic LOD ties the layers: zoomed out, one
  glyph of live state per agent; zoomed in, the full instrument.

**Spatial, not temporal.** Agent loops are ongoing processes, not events. A stream/feed forces
reading in time-order and has no persistent identity — bad for glancing. A spatial field gives each
agent a *fixed position* (so you build spatial memory: "forge lives top-left") and lets the eye scan
pre-attentively. The temporal view ("what happened while I was away") is a *different* artifact — the
review digest / dreams rail — not the glance.

**Answer.** The glance is a **calm spatial field**, not a dashboard. Persistent per-agent tokens
(position = identity → spatial memory); loop-state in pre-attentive channels; healthy agents visually
quiet (breathing); only the agent that needs the human breaks calm. Two layers — ambient (alerts
only) and on-demand detail (aim / last action / duration) — bridged by semantic LOD. Port42 already
has the raw material: the Shell **galaxy** (orbs = agents), the **peek rail** (live surfaces from
elsewhere), and the **knock**. Build the glance = a galaxy whose orbs are agents, breathing when
alive, where the knock is the *only* thing that breaks the calm.

---

## Q2 — Intervention grammar: acting on a running loop

**The reasoning.** The distinguishing act is reaching into a loop *that is already running* — not
"kill it and send a new prompt," which is all today's AI UX offers. Enumerate the primitive
supervisory acts (from control/supervision theory):

- **pause / resume** — freeze the loop where it is
- **redirect** — change its *aim* mid-run; it re-plans, keeping context
- **nudge** — bias the next iterations without changing the aim ("more conservative", "check your work")
- **constrain** — add a bound mid-flight ("don't touch that file")
- **rewind** — undo the agent's last N *actions* and let it retry (agents err; you roll back a loop, not a document)
- **take the wheel** — drop in and do one iteration yourself, then hand back
- **fork** — let it continue *and* spawn a variant with a different aim; compare

**The design constraint that governs all of them: intervention must be cheaper than restarting**, or
people will just restart and the membrane fails. So each must be gesture-cost, in-context, and
non-destructive (rewind always available).

**The striking finding:** almost every gesture we already built for *surfaces* is an intervention on
an *agent loop*, mis-aimed at the wrong object:
- point-and-say → **redirect** (say a new aim at a running agent)
- version scrub → **rewind** (scrub the agent's action history, not a surface's versions)
- fork-apart → **fork** (one keeps the aim, one gets a new one)
- keep / melt → **pause / resume**

That the gestures recast this cleanly is evidence they were right and pointed at the wrong noun.

**One necessary mechanism: checkpoints.** An agent mid-action can't always absorb a redirect
instantly. The loop must yield at safe points where intervention lands cleanly. So interventions come
in two speeds: **soft** (queued, applies at the next checkpoint, shown as "will apply in a moment")
and **hard** (pause now, even mid-action). The membrane must expose which is happening.

**Answer.** Intervention grammar = **direct manipulation of a running process**, primitives
pause/redirect/nudge/constrain/rewind/take-the-wheel/fork — most of them our existing surface
gestures recast onto agent loops. Governed by "cheaper than restarting": gesture-cost, in-context,
non-destructive. Requires loop **checkpoints**, with soft (queued) vs hard (immediate) interventions
made visible.

---

## Q3 — The trust ladder: how delegation moves, visibly

**The reasoning.** Trust is not a mood; it is an *autonomy level*, and autonomy levels are a solved
taxonomy (SAE driving levels, the automation-level literature). The rungs, applied to an agent loop:

- **L0 ask-everything** — agent advises; human executes each step
- **L1 approve-each** — agent acts but pauses for approval before each action
- **L2 approve-risky** — agent acts freely on safe things, asks only on consequential ones
- **L3 notify-after** — agent acts autonomously, reports, human can rewind
- **L4 autonomous** — agent runs its loop; only *knocks* on genuine decisions

So the trust ladder is a **visible, adjustable autonomy level per agent** — a rung the human can move.

**How it moves up — two ways:**
- *Explicit*: the human promotes ("you've got this, stop asking").
- *Earned*: the membrane observes and proposes. "I've approved forge's last 20 edits unchanged — let
  it run without asking?" **Repeated unchanged approval anneals into autonomy** — the anneal
  primitive applied to trust.

**How it moves down:** an error demotes, fast. Either the human pulls it back a rung, or the membrane
auto-demotes on a bad outcome (something it did got rewound → drop its autonomy there). Trust is
**asymmetric — earned slowly, lost fast** — which matches human trust and is the safe default.

**Crucial nuance: trust is not scalar per agent.** It is per **(agent × task-type × stakes)**. You
might trust forge to edit CSS autonomously but never to touch the database. So the autonomy level is
the *default*, and **constraints (Q2) carve the exceptions**: "forge is L4, except database = L1."

**The earned-trust loop is the killer mechanism**, and it is the relationship layer applied to
delegation: the membrane watches your approve/reject/rewind pattern and proposes autonomy changes.
**A crease — where your model of the agent broke — is exactly the trust-adjustment signal.**

**Answer.** Trust ladder = a **visible, adjustable autonomy level per (agent × task-type × stakes)**,
rungs ask-everything → approve-each → approve-risky → notify-after → autonomous. Up by explicit
promotion or *earned* (repeated unchanged approval anneals into autonomy; the membrane proposes it);
down fast on error (asymmetric, safe). The level is visible in the glance (the agent's "leash").
Constraints carve exceptions. Creases are the trust signal.

---

## Q4 — The unit of steering: agent, task, goal, or constraint

**The reasoning.** These are not four candidates for one slot — they are a *nested stack*, and the
error is asking which is "the" unit. Goals decompose into tasks; tasks are assigned to agents;
constraints bound the whole. They sit at different altitudes and serve different roles. The clean
move is to ask, for each, *the unit of what?*

- **Goal = the unit of intent.** The only thing the human intrinsically wants ("ship the release").
  Durable, high-leverage, rarely changed.
- **Task = the unit of steering.** The concrete piece of work where interventions actually land ("fix
  this bug"). This is the *primary* steering object because it is tractable — you can redirect a task;
  a goal is too abstract to nudge and an agent is too granular.
- **Agent = the unit of trust.** Autonomy (Q3) attaches here — you delegate *to an agent*, not to a task.
- **Constraint = the unit of safety.** The persistent bounds that apply across tasks and agents.

So steering *lands on tasks*, intent *lives as goals*, trust *attaches to agents*, safety *attaches
as constraints*. The membrane's whole structure falls out of this: goals → decompose → tasks →
assign → agents, all bounded by constraints.

**The trajectory.** The dream is to steer mostly at the *goal* level and let the membrane decompose
and assign — but that requires trusting the membrane to decompose well, which is itself the highest
rung of the trust ladder (Q3). So **the primacy of steering rises from task toward goal over time**,
as the membrane earns the trust to own decomposition. Near term: steer tasks. Long term: steer goals.

**Answer.** Not alternatives — each is the unit of a *different* thing: **Goal = intent, Task =
steering (primary — where interventions land), Agent = trust, Constraint = safety.** Goals decompose
to tasks, tasks assign to agents, constraints bound all. Steering's primacy rises from task toward
goal as the membrane earns trust to decompose goals itself.

---

## Q5 — Where the human's attention lives: a place, or ambient

**The reasoning.** The human loop has phases — focus, review, rest — and the membrane serves each
differently, so "place vs ambient" is a false binary; the answer is *both, gated by phase*:

- **Focus** (deep on one thing): the swarm must be **peripheral** — calm, non-demanding. Ambient.
  Only a knock breaks in. (calm technology again.)
- **Review** (deliberately checking the swarm): the glance comes **central**. A place you turn to.
- **Rest / away**: the swarm works; the membrane accumulates a digest for return (dreams).

So it is **ambient-by-default, central-on-demand**, and the membrane must make that transition fluid.

**This maps exactly onto the Shell's zoom ladder** — galaxy (all agents = the glance = review) ↔
focus (one instrument, deep work, swarm pushed to the peek rail). The zoom *is* the attention-phase
control. Which means Port42 already has the right spatial grammar for the membrane's attention model.

**And it resolves an earlier open question.** "Ambient over everything" means the swarm's periphery
must be available even while you do your own work — which a single window cannot provide, but a
full-screen shell can (persistent peek tiles in the periphery). **The membrane therefore argues
decisively for the Shell/takeover model over the classic window.** Ambient supervision of a swarm
*needs* an always-available periphery; only the Shell gives it. (This settles shell-vs-classic in the
membrane's favour — see `summer2026-todo.md` GUI-shell item.)

**Answer.** **Both, gated by the human's loop-phase:** ambient/peripheral during focus (only a knock
breaks through), central-on-demand during review (the glance comes forward), digesting during rest
(dreams). The Shell's **zoom ladder is the attention-phase control** (galaxy = review, focus = deep
work with the swarm in the peek rail). This is a decisive argument for the Shell over the classic
window.

---

## The meta-finding: everything recasts

Reasoning through the five questions, nearly every asset Port42 already has landed as a membrane
component — not by force, but naturally:

| Existing piece | Membrane role |
|---|---|
| Shell **galaxy** | the glance (Q1) |
| **peek rail** | ambient periphery / watching at scale (Q1, Q5) |
| the **knock** | attention routing — the one thing that breaks calm (Q1) |
| **point-and-say** | redirect a running agent (Q2) |
| **version scrub** | rewind an agent's loop (Q2) |
| **fork-apart** | fork an agent (Q2) |
| **keep / melt** | pause / resume a loop (Q2) |
| **anneal** | earned trust — approval annealing into autonomy (Q3) |
| **relationship layer** (fold/creases) | the membrane learning trust; creases = the trust signal (Q3) |
| **companions + heartbeats** | the agent loops themselves (whole thesis) |
| **Shell zoom ladder** | the attention-phase control (Q5) |
| **dreams / heartbeat idle work** | the rest-phase digest (Q5) |
| **gi-engine** | how you generate one instrument to watch/steer through |

The gestures were right. The primitives were right. Port42's parts were right. Only the *framing* was
wrong — we called it a generator when it was always a membrane. The build is not "start from scratch";
it is "re-aim the existing pieces from surfaces to agent loops, and build the one thing missing: the
glance."

## What to build first

The glance (Q1) — the calm spatial field of N looping agents — because it is (a) the core watching
artifact, (b) the thing that is structurally not Lovable, (c) the thing we have never built, and
(d) the surface every other primitive needs something to act *on*. Intervention, trust, and steering
all need a visible agent to touch first.
