# Where the Product Lives or Dies — Anxiety Analysis

*2026-07-12 — the analysis that replaces the guess. Every anxiety across all jobs in
[`membrane-requirements.md`](membrane-requirements.md), ranked by **adoption-impact**, mapped to the
role (from [`membrane-architecture.md`](membrane-architecture.md)) that addresses it, then aggregated.
Conclusion is derived, per-row contestable — not asserted.*

## Method

Each anxiety is classified by what happens if it's left unaddressed:

- **Dealbreaker (D)** — would stop adoption or cause abandonment. Trust-destroying, irreversible, or
  control-losing. *Test: would one occurrence make them stop relying on it?*
- **Barrier (B)** — significantly caps how much they'll delegate or rely; keeps the product from
  reaching its value, but tolerable and recoverable. *Test: would it limit adoption without ending it?*
- **Friction (F)** — annoyance; degrades the experience but not adoption. *Test: would they keep using and grumble?*

**On privacy.** How private an instance is, is an **operator setting** (just-me / local → shared team →
org policy), *not* a make-or-break property. So the "my context leaked" fears aren't a privacy-pillar
dealbreaker — they're "the system broke the boundary I set," which is a **control** failure and lands on
the **Controller**. This is a correction to an earlier draft that listed privacy of the person-model as
a third pillar.

**Caveat.** The anxieties are candidate hypotheses (not yet interview-validated), so this ranks
*what's on paper* — a first draft. The tier is a judgment — but a disciplined, per-row, contestable one.

## The anxieties, ranked

| Job | Anxiety (abbrev.) | Tier | Addressed by |
|---|---|---|---|
| J1 [P] | hands off vague → runs confidently wrong | B | Runner (agent asks) + Watcher/steer |
| J1 [A] | ask too much/little | F | Gatekeeper |
| J2 [P] | locks in interpretation before I decided | B | Synchronizer + steer |
| J2 [A] | mistakes exploration for instruction | F | Synchronizer |
| J3 [P] | overview hides the thing that mattered / shows everything | B | Watcher |
| J3 [A] | "stuck" looks like "working" | B | Watcher / Runner |
| **J4 [P]** | **triage suppresses the one thing I needed** (spam-folder, H8) | **D** | **Gatekeeper** |
| J4 [P] | mute everything → lose track | B | Gatekeeper / Watcher |
| J4 [A] | reach too eager/timid | F | Gatekeeper |
| J5 [P] | auto-approval rubber-stamps something bad | B | Controller |
| J5 [A] | ask at wrong grain | F | Gatekeeper / Controller |
| J6 [P] | redirect leaves a broken in-between | B | Synchronizer (coherence) |
| J6 [A] | redirect conflicts, breaks silently | B | Synchronizer |
| J7 [P] | parallel runs wasteful / apples-to-oranges | F | Runner |
| J8 [P] | reacts to my half-finished work | B | Synchronizer |
| **J8 [P]** | **overwrites the very thing I'm holding** | **D** *(co-hold)* | **Synchronizer (right-of-way)** |
| J8 [A] | touches what they're holding, becomes a hindrance | B | Synchronizer |
| J9 [P] | drown in "look at this" → mute it all | B | Gatekeeper |
| J9 [A] | present wrong = noise | F | Gatekeeper |
| **J10 [P]** | **the one time I stop watching, it does the thing I'd have caught** | **D** | **Controller + Guard** |
| **J10 [P]** | **grant freedom → can't see what it did or pull it back** | **D** | **Controller + Watcher + Guard** |
| J10 [A] | misjudge latitude | F | Controller |
| **J11 [P]** | **agents silently conflict / undo each other** | **D** | **Coordinator + Guard** |
| J11 [P] | not routing → lose the thread of how it connects | B | Watcher + Coordinator |
| J11 [A] | silent conflict undoes work | B | Coordinator |
| J12 [P] | context leaked *beyond the boundary I set* | B | **Controller** (honor the setting) |
| J12 [P] | wrong model of me, can't see or fix it | B | Keeper (inspect & correct — *designed into the contract*) |
| J12 [A] | acts on stale/wrong belief | B | Keeper |
| **J13 [P]** | **to act on my real world, must trust real access** | **D** | **Sensor + Controller + Guard** |
| J13 [P] | always-present → constant low-grade intrusion | B | Gatekeeper + Sensor |
| **J13 [A]** | **acts on real things wrongly — damage isn't sandboxed** | **D** | **Guard + Controller** |
| J14 [P] | unattended → far wrong before I catch it | B (strong) | Runner + Watcher + Guard |
| J14 [P] | long run = a heap I must reconstruct | B | Watcher + Guard |
| J14 [A] | run too long wrong / pause too often | F | Runner |
| **J15 [P]** | **destructive action faster than I can react** | **D** | **Guard + Controller** |
| J15 [P] | can't tell what broke or how to fix | B (strong) | Guard (audit) |
| **J15 [A]** | **irreversible mistake / hidden failure destroys trust** | **D** | **Guard** |
| J16 [P] | sharing crosses my context *past the boundary I set* | B | Controller + Coordinator |
| J16 [P] | handoff drops the thread | B | Coordinator |
| J16 [A] | carry one person's context into another's view | B | Controller + Coordinator (isolation) |
| J17 [P] | teaching > just doing it myself | F | Librarian |
| J18 [P] | mode-switch loses the thread | F | Presenter |
| J19 [P] | background agent burns resources on wrong thing | B | Guard + Runner |
| J19 [A] | silent overrun betrays budget | B | Guard |
| J20 [P] | saving/organizing becomes its own pile | F | Librarian |
| J21 [P] | invisible exposure → I wall agents off from anything sensitive | B | Guard (audit of what's sent) + Controller (bound) |
| J21 [A] | send more than the person expected | F | Guard + Controller |

## Aggregation — dealbreakers by role

| Role | Group | Dealbreakers it addresses |
|---|---|---|
| **Guard** (R2) | Crew | J10, J11, J13[A], J13[P], J15[P], J15[A] (shared) — **~6** |
| **Controller** (S3) | Crew | J10 ×2, J13[P], J13[A], J15[P] — **~5** |
| **Coordinator** (R1) | Crew | J11 (shared) — **~1** |
| **Sensor** (F4) | Face | J13[P] (shared) — **~1** |
| **Gatekeeper** (S1) | Crew | J4[P] — **1** |
| **Synchronizer** (F2) | Face | J8 overwrite (faculty-scoped) — **1** |
| **Keeper** (F3) | Substrate | **0** — privacy fears moved to Controller; correctability designed into the contract |

## Conclusion (derived)

**The product lives or dies on trust-with-real-stakes — recovery (Guard) and control (Controller).**
Every dealbreaker is a version of the *same* fear: **letting an agent near my real world.** Irreversible
harm (Guard), loss of control (Controller), unsafe real-world access (Sensor/Controller/Guard). The
dealbreakers concentrate hard on **Guard + Controller**, adjacent to **Coordinator + Sensor**.

**Privacy is not a pillar — it's a setting.** How private an instance is, is the operator's choice; the
system's job is to *honor the boundary set*, which is a **control** guarantee (Controller). So the leak
fears (J12, J16) fold into control, not a separate privacy dealbreaker — matching the master goal's own
phrase, *"without losing control."*

**The Keeper (person-model) is not where adoption is decided.** Its scary anxiety — "wrong about me and
I can't fix it" — is **designed out by its own contract**, which requires you can see and correct what
it believes. The Keeper is still built early, but because it is **foundational** (the Gatekeeper's
personalization can't work without it), not because it is make-or-break.

**The Gatekeeper (attention)** carries **exactly one dealbreaker** (the spam-folder fear) plus barriers.
Real and the most *novel* part, but adoption is **not** decided there.

**Build implication.** The make-or-break roles are **Guard (recovery & safety) and Controller
(authority)** — get these right or the product is dead on arrival. Guard is not a scale-up nicety;
recoverability and the guardrail-before-irreversible are load-bearing from day one. The Keeper and the
Sensor are built early for a *different* reason — the Gatekeeper depends on them — not because they're
make-or-break.

**Caveats.** (1) This ranks candidate forces, not validated ones — the "instrument a week" experiment
would correct the inputs. (2) Some dealbreakers are faculty-scoped (J8's overwrite kills co-holding's
adoption, not the whole product) and are marked so. (3) The tiers are contestable per row — that's the
point; argue any row and the conclusion updates, unlike an assertion.
