# The Membrane

*2026-07-11 — the foundational reframe. Supersedes the "generative interface / loop stack"
framing as the thesis (see "What this changes" below). Ports are a component here, not the point.*

## Thesis

**Humans loop. Agents loop. They loop at different speeds, for different reasons. The UX is the
membrane between the two.**

The world is coming to run on agentic loops — many autonomous agents, each perceiving, acting,
observing, repeating, continuously. A person does not experience that as "faster answers." They
experience it as being surrounded by many fast autonomous processes they must live with, steer, and
trust — using one slow, singular, deliberate loop of attention.

Port42's job is to be that membrane. The most interesting, least-solved part of it is **watching and
steering**: how one human supervises and directs many agent loops that are already running.

This is structurally not a code generator (Lovable/v0/bolt). Those are a single request→response
with no ongoing agent loop to supervise — no swarm, so no membrane. The membrane only exists when
agents keep looping without you.

## The two loops

| | Agent loop | Human loop |
|---|---|---|
| shape | perceive → orient → act → observe → repeat | notice → understand → judge → decide → rest |
| speed | fast | slow |
| count | many, in parallel | one |
| autonomy | runs without you | must choose to engage |
| stamina | tireless | tires; needs rhythm |
| visibility | opaque unless surfaced | self-aware |

Everything hard about the membrane comes from four **mismatches** between these:

1. **Speed** — agents finish before you can watch. The membrane must checkpoint and summarize so you
   see meaning, not a firehose.
2. **Cardinality** — many agents, one you. The membrane must triage which agent gets your attention.
3. **Visibility** — agent work is invisible unless surfaced. The membrane must make looping legible.
4. **Autonomy** — agents act without asking. The membrane must let you trust without checking
   everything, and intervene without stopping everything.

**The membrane's job:** make many fast, invisible, autonomous loops legible and steerable by one
slow, singular, deliberate loop — without the human becoming the bottleneck or losing control.

---

## Watching  (agent loops → human)

The observe side of the membrane. How the human loop sees what the agent loops are doing.

- **Legibility** — the current state of all agent activity, glanceable. Not logs; a living picture
  that answers "is everything fine?" in one look and "what is this one doing?" on demand.
- **Attention routing** — with many agents and one you, the membrane decides what deserves your eyes
  *now* and surfaces it where you'll see it, at the right moment. (the *knock* — an agent requests
  attention; *speculation* — an agent shows what it's about to do before doing it.)
- **Level of detail** — zoom from "all green" to "show me exactly what this agent changed," and back.
  Unwatched loops compress to a glyph of their live state; the watched one expands. (semantic LOD)
- **Pacing** — agents outrun attention. The membrane buffers, batches, and checkpoints so watching
  is possible at human speed. You review meaning at your cadence, not the agents'.
- **Rhythm** — the human loop has a cadence (focus, review, rest). Agents sync to it: work while
  you're away, present when you return. (the *dreams rail*.)

## Steering  (human → agent loops)

The act side. How the human loop directs the agent loops without micromanaging each step.

- **Direction** — set and adjust what an agent is looping *toward* — the goal, not the steps. A good
  membrane lets you change an agent's aim in a sentence and let it re-plan.
- **Intervention** — reach into a *running* loop: pause it, redirect it, correct it mid-flight. Not
  "kill it and start a new prompt" — steer the one that's going.
- **Delegation & trust** — hand off more of a loop as trust builds; pull it back when needed.
  Progressive autonomy. (keep/melt is a primitive form: "I trust this, stop touching it.")
- **Constraint** — set the bounds an agent loops *within* ("never touch prod", "check before X"); the
  membrane enforces them so you can delegate without watching every step.
- **Learned steering (anneal)** — the membrane learns your repeated corrections and stops asking. A
  steering decision you make often becomes automatic, so the human loop spends less over time. (Named
  "anneal" after metalwork: repeated behavior cools into a fixed, low-cost shape.)

Watching and steering are one motion, not two screens: you watch *through* the same instrument you
steer *with*. Seeing what an agent did and redirecting it happen in the same place.

---

## The form: pervasion, not containment

The single architectural statement the membrane forces. Port42 today is built as **containers you
enter**; the membrane is a **layer that is always around you**. This bites in two places at once:

- **Surface** — an *app* is contained (one window you alt-tab to; a destination) and a *takeover
  shell* is totalizing (it owns the whole screen, which displaces your other apps rather than joining
  them). Neither can be *part of* your other apps. The membrane's resting state is "present while you
  use everything else" — so its true form is a **third thing: an ambient layer over all apps**, owning
  the *margins* of the whole screen, floating above whatever has focus (presence, like Raycast/
  notification-center — not a destination). "Own the periphery" ≠ *be* the whole screen; it means own
  the periphery *of* the whole screen, over everything. The takeover shell stays as an immersive/focus
  mode; the default is ambient-over-everything.
- **Data** — a *space* contains the person's relationship state the same way the app contains the
  presence. Space-scoping was right for "companions as chat threads" (each its own context) and wrong
  for "a personal AI that knows you across everything." The person is **one**, across all spaces;
  spaces should be *contexts within* a unified person-model, not silos of it. (This is the fix H3a's
  triage engine requires — see `membrane-hypotheses.md`.)

Buildable now, and the pieces exist: `PortWindowManager` already floats NSPanels; the peek rail is
the seed. The move is a **screen-edge presence that floats over your other apps** (always-on-top,
mostly click-through), reading the focused app/window as its presence signal — not a tile living
inside the shell. Pervasion in the surface; unification in the data.

## Port42 is already a membrane (recast)

The pivot is not starting from zero — it is recognizing what Port42's parts already are, and building
the watching/steering UX on them explicitly instead of building a generator on top.

- **Companions** = the agent loops. Heartbeats already make them loop autonomously.
- **Spaces** = the shared context where the human loop and agent loops meet.
- **Ports** = the membrane's instruments. A port is not a generated app you keep — it is a living
  window you *watch through* and *steer with*, made on demand for specific agent activity. Some watch
  (a picture of what agents are doing), some steer (controls that redirect them), most do both.
- **Relationship layer** (fold / position / creases / engravings) = the membrane learning the human —
  a steering primitive, not a memory feature.
- **Device / gateway APIs** = agents acting on the real world; the membrane is what makes that action
  visible and controllable rather than blind.

## What this changes

- **Supersedes as thesis:** the "generative interface / say-it-see-it" story and the nine-loop
  latency stack. Generation is a *capability of the membrane* (you spin up instruments to watch and
  steer), not the point. The latency loops (reflex/morph/patch/regenerate) are demoted to an
  engineering note about how fast the *agent-side* of one instrument responds — one loop's internals,
  not the product.
- **Survives, recast as membrane primitives:** the *knock* (attention routing), *speculation*
  (watching-ahead), *dreams* (rhythm), *semantic LOD* (watching at scale), *keep/melt* (trust),
  *anneal* (learned steering).
- **Becomes a component:** the `gi-engine` prototype (`port42-growth/gi-engine/`) is how you
  *generate* an instrument — one piece of the machine, not the thesis. It works; it was the wrong
  slice to lead with.

## What a real demo shows (watching + steering, not generating)

A single surface on a blank canvas will always look like Lovable, because it removes the swarm. The
membrane demo has agents *already looping*:

- several companions working autonomously (via heartbeats) on real tasks
- one glanceable surface showing what each is doing — attention routed to the one that needs it
- the human redirecting a running agent in a sentence and watching it re-aim
- an agent *knocking* when it hits a decision only the human can make
- the workspace having quietly reorganized overnight (dreams) — results waiting on return
- a correction the human keeps making becoming automatic (anneal) — visibly less steering over time

None of that is expressible as a code generator. All of it is native to what Port42 already is.

## Open questions (to answer before building)

> **Reasoned answers now in [`membrane-design-answers.md`](membrane-design-answers.md).** Summary:
> (1) the glance is a *calm spatial field*, not a dashboard — N stay quiet, only the one that needs
> you surfaces; (2) intervention = direct manipulation of a running loop (our surface gestures recast
> onto agents); (3) trust = a per-(agent×task×stakes) autonomy level that anneals up and drops fast;
> (4) goal = intent, task = steering, agent = trust, constraint = safety; (5) ambient-by-default,
> central-on-demand — which decisively favours the Shell. Meta-finding: nearly every existing Port42
> piece recasts as a membrane component. Build the *glance* first.

1. **The glance** — what is the single legible picture of N looping agents? (galaxy of orbs? a
   status membrane? per-agent peek tiles?) This is the core watching artifact and we don't have it.
2. **Intervention grammar** — what are the concrete gestures to pause/redirect/constrain a *running*
   loop, not spawn a new one?
3. **Trust ladder** — how does delegation visibly increase and decrease? What does "I trust this
   agent with more of its loop" look like as an action?
4. **The unit of steering** — do you steer an agent, a task, a goal, or a constraint? Probably all
   four at different altitudes; which is primary?
5. **Where the human's attention lives** — is the membrane a place you go, or an ambient layer over
   everything? (Shell suggests ambient.)

Prototype the *glance* first (question 1). It is the thing that isn't Lovable and that we have never
built.
