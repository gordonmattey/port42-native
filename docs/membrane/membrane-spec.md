# The Membrane — What It Does (Solution Spec)

*2026-07-12 — the membrane as the **solution** to the jobs in
[`membrane-requirements.md`](membrane-requirements.md). Where the requirements are architecture-free,
this is the membrane's answer: its **faculties** — what it does — each named for the **role** that
carries it (see [`membrane-architecture.md`](membrane-architecture.md)), and each traced to the jobs
(`J#`) it serves and the constraints (`C#`) it upholds. A coverage matrix at the end maps every job to a
role. This is capability-level, not implementation.*

**These two docs — [`membrane-requirements.md`](membrane-requirements.md) (the jobs) and this spec
(the faculties) — are the source of traceability. Every faculty cites the jobs it serves; every job is
served by a faculty.**

## The membrane in one line

The membrane is the interface between the **human loop** and the **agent loops** — it makes many
running agent loops **watchable, reachable, steerable, and trustable** by one person, lets human and
agent **hold the same work together**, and does all of it **around the person's real life**, not in a
place they must go to. Every faculty serves both loops (the person's side and the agent's side of each
job) — which is how it upholds **C5** (the agent is a participant, not a tool).

The roles group three ways: **the Face** (Sensor, Synchronizer, Presenter — how it meets you), **the
Crew** (Watcher, Gatekeeper, Controller, Coordinator, Guard, Librarian — the faculties that do the
work), and **the Substrate** (Runner, Keeper — what it plugs into).

---

## 1 · The Watcher — watching at rest
*What it does.* Maintains a calm, always-available picture of every agent and its state. Healthy,
working agents are **quiet**; it is designed so the one that needs attention is what **stands out**. A
glance answers "is everything fine?" without reading; looking closer reveals one agent's aim, progress,
and history; a returning digest gives what happened while away. The agent side: it makes an agent's
aim/progress/blocked-ness **legible without being asked**.

- **Serves** J3 · **Upholds** C2 (quiet by default — nothing surfaces unless it must).

## 2 · The Gatekeeper — managing attention
*What it does.* The **single channel** by which anything reaches the person — and the membrane, **not
the agent**, decides what earns their attention. It **triages** each need against what the person is
doing and who they are (via the Keeper, §6, and the Sensor, §7); presents it as **graded pressure** (a
quiet lean → an urgent break-in), not a binary ping; **composes** many needs into a legible few;
**learns** from what's waved off, *intended* to reduce the rate over time (whether the learning
converges is unproven — H10); and picks the **channel** by the person's context. Unrequested finds enter
here too, at an intensity matched to their worth, and either interrupt, wait ambiently, or park for
later. The agent side: it lets an agent **reach proportionately** when it truly needs the person, and
wait without losing its place when deferred.

- **Serves** J4, J9 · **Upholds** C2 (no capability may generate noise; every surfacing is earned).

## 3 · Co-holding — the shared surface (the Synchronizer)
*What it does.* Lets a person and an agent operate the **same live work at once** — the person on one
part, the agent on another — each **seeing the other act**, with the person keeping the say on what
they're actively holding (**right-of-way**, so it never overwrites what they hold). The person can
**point at a part and say what should change**; the agent **reacts to what the person is doing as they
do it**, not to a submitted turn. This is where a half-formed intent gets developed together, and where
handed-off work is co-operated.

- **Serves** J1, J2, J8 · **Upholds** C1 (the person keeps the say on what they hold).

## 4 · Steering — acting on running loops
*What it does.* Lets the person reach into a **running** agent and reshape it without starting over:
**redirect** its aim, **pause/resume**, **nudge** its manner, **constrain** it mid-task, **take over**
a single step and hand back, **undo** its recent actions. Lets the person **fork** to pursue two
approaches at once and compare. Lets the person **decide/approve** at the right grain. The agent side:
it can absorb a redirect and re-plan, yield cleanly when taken over, and flag a conflict rather than
silently breaking. *(No single role — realized by the Runner's steerability, governed by the Controller,
acting through the Synchronizer.)*

- **Serves** J5, J6, J7 · **Upholds** C1 (steering aims to be cheaper than, and available before, restarting).

## 5 · The Controller — trust & authority
*What it does.* Grants an agent **latitude by area and stakes** — it acts freely where trusted, asks
where not. Trust **rises as earned** (a thing always approved stops being asked) and **drops on error**.
**Hard limits it is designed never to cross.** The person holds **meta-authority they cannot be deprived
of** — able to change the rules and **reclaim** any zone. And it **honors the privacy boundary the
operator set** — how private this instance is, and who any context may cross to (both being design
guarantees, only as strong as their enforcement). The agent side: it knows its bounds and acts at the
latitude granted.

- **Serves** J5, J10 · **Honors the privacy setting behind** J12, J16 · **Upholds** C1 (control is inviolable).

## 6 · The Keeper — knowing you
*What it does.* Maintains a **unified, cross-project** model of the person — preferences, context, how
their projects connect, what they'd want interrupted for. This is what lets the Gatekeeper (§2) triage
against **this person**, not a generic rule; without it, triage can only be generic. It is
**inspectable, editable**, corrects when wrong, and is **shared across agents** so the person teaches
once. It spans the person's **whole life**, because the value is in the connections between projects. How
private it is kept is the **operator's setting**, which the Controller (§5) enforces — the Keeper's own
job is to be correct and correctable.

- **Serves** J12 · **Upholds** C3 (no repetition), C4 (whole-life scope) · **Powers** J4, J9 (it is the Gatekeeper's knowledge).

## 7 · The Sensor — presence
*What it does.* Lives **ambient around the person's work** — over their other apps, in the margins, not
a place they go to. **Senses their attention and availability** (which app has focus, at-desk, in a
meeting, away, asleep) and behaves accordingly. **Acts on their real environment** — files, screen,
accounts, devices — within granted permission. **Follows them across devices.** The agent side: it can
sense the person's context to reach them well, and act on real things rather than only advise.

- **Serves** J13 · **Powers** J4 (attention-aware triage), the Presenter (channel choice).

## 8 · The Coordinator — many agents & people
*What it does.* Lets agents **coordinate and hand off among themselves** without routing every step
through the person, while keeping how it all **connects** visible to them. **Surfaces conflicts**
between agents rather than letting them collide. Lets work and its supervision **span multiple people**,
with each person's authority and boundaries kept separate.

- **Serves** J11, J16 · **Upholds** C1 (the person still sees and can seize the whole).

## 9 · The Guard — across time, safely
*What it does.* Lets agents **run in the background and over long horizons** — overnight, for weeks —
using **idle time** productively and pausing for input when needed. Keeps actions **reversible**, with
a **guardrail-and-confirm before the irreversible**, and a **record** of what was done. Makes
**cost visible and boundable**, warning before overrun. And makes **exposure visible** — what data was
**sent** to which model, so the person can judge and bound their risk (J21). The agent side: it stays
reversible, stops before the irreversible, reports failure honestly, and tracks its own cost.

- **Serves** J14, J15, J19, J21 · **Upholds** C1 (recoverable, auditable), C6 (works under reduced conditions).

## 10 · The Librarian — grow and keep
*What it does.* Makes what agents can do **discoverable**, lets the person **find the right agent** and
**teach new skills or workflows**, and turns a useful **one-off into something repeatable** — so value
**compounds** rather than resetting. Keeps finished work **keepable, revisitable, inspectable**.

- **Serves** J17, J20 · **Upholds** C3 (teach once).

---

## Cross-cutting

- **The Presenter (modality)** — every faculty can express in **visual, voice, or ambient**, chosen by
  the person's context (via the Sensor, §7): a card when they're watching, a spoken word when their eyes
  are busy, ambient sound when away, a live call when text is failing. *Serves* J18.
- **Graceful degradation** — every faculty **works smaller** under reduced conditions (fewer agents,
  less trust, no network, another device). *Upholds* C6.
- **Dual-serving** — because each faculty serves both the person's and the agent's side of a shared
  job, the agent is a first-class participant throughout. *Upholds* C5.

---

## Coverage matrix (every job maps to a role)

| Job | Served by role |
|---|---|
| **J1** getting work started | Synchronizer (+ Watcher as the surface it lands on) |
| **J2** developing a half-formed intent | Synchronizer |
| **J3** knowing what's happening | Watcher |
| **J4** being reached, reaching | Gatekeeper (powered by Keeper, Sensor) |
| **J5** deciding & approving | Steering, Controller |
| **J6** steering work in flight | Steering |
| **J7** exploring alternatives | Steering (fork) |
| **J8** working on the same thing together | Synchronizer |
| **J9** being shown things I didn't ask for | Gatekeeper (placement) |
| **J10** building & adjusting trust | Controller |
| **J11** many agents at once | Coordinator |
| **J12** being known | Keeper (privacy setting enforced by Controller) |
| **J13** wherever & whenever I am | Sensor |
| **J14** work across time | Guard |
| **J15** recovering & staying safe | Guard |
| **J16** working with other people | Coordinator (privacy setting enforced by Controller) |
| **J17** finding & growing capability | Librarian |
| **J18** interacting naturally | Presenter (cross-cutting) |
| **J19** cost, limits & accountability | Guard |
| **J20** finishing, saving & reusing | Librarian |
| **J21** knowing & bounding my exposure | Guard (audit of what's sent) · Keeper (what's known) · Controller (bounds it) |

| Constraint | Upheld by |
|---|---|
| **C1** control inviolable | Synchronizer (the say), Steering (steer > restart), Controller (meta-authority), Guard (recoverable) |
| **C2** nothing becomes noise | Watcher (quiet), Gatekeeper (triaged) |
| **C3** no repetition | Keeper (knows you), Librarian (reuse) |
| **C4** whole-life scope | Keeper (cross-project) |
| **C5** agent is a participant | dual-serving (every faculty) |
| **C6** graceful degradation | cross-cutting |

Every job maps to a role; every role is justified by a job. The key dependency: **the Gatekeeper's
triage against *this person* (§2) depends on the Keeper (§6) and the Sensor (§7)** — generic triage is
possible without them, but the personalization that's meant to make attention management not-noise is
not. That dependency is the one that shapes the build.
