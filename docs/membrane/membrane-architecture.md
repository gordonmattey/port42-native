# The Membrane — How It's Built (Architecture)

*2026-07-12 — **the how.** The roles that realize the faculties in
[`membrane-spec.md`](membrane-spec.md), which serve the jobs in
[`membrane-requirements.md`](membrane-requirements.md). Traceability continues: role → job. This is the
architecture shape, not the code; each role earns a deeper spec of its own when we build it. **Build
order is a separate plan — deliberately not encoded here.***

## The membrane is an experience layer over a pluggable substrate

**The membrane does not reimplement the substrate.** It defines the **interfaces** it needs from
whatever runs agents and whatever knows the person — so *different systems can serve them* (an existing
agent framework as the Runner; a memory backend as the Keeper). The membrane's own value is the
**experience layer**: watching, attention, trust, co-holding.

Every part is specified the same way — as an **invariant interface/contract** — whether it's something
the membrane **consumes** (a provider we plug in) or something it **owns** (a faculty we build). That
consume-vs-own line is about *implementation*; the **primary organization is by role** — the Face, the
Crew, the Substrate (below).

**Two kinds of invariant, one fluid layer** (the dependency running downward):
1. **Jobs + constraints** (`membrane-requirements.md`) — invariant **requirements**. The fixed point
   for the *user*. Change only if the requirement itself was wrong.
2. **Interfaces** — invariant **contracts**, per version. The fixed point for *implementations*. Also
   invariant — *versioned*, so the contract evolves by minting a new version (v0.2), never by silently
   mutating the old one. Versioning preserves invariance; it doesn't undermine it.
3. **Implementations** — the only **fluid** layer. Swapped freely behind an interface (ours or a
   provider's); they don't have to be stable.

Both (1) and (2) are invariants — the difference is what each is invariant *for*: (1) is the contract
with the user, (2) the contract with implementations. And (1) governs (2): if an interface serves the
jobs badly, you version to a new contract, because the jobs are the ground truth.

## Shape — three groups, by role

The membrane organizes by the **role each part plays** — *not* by build order (that's a separate plan):

- **The Face — how it meets you.** The membrane's two-way interface with the person: it **senses** you
  (Sensor), lets you and an agent **hold the same live work** (Synchronizer), and **renders** everything
  back to you in the medium that fits (Presenter). This is the UX — the membrane's skin, not a place you
  go to.
- **The Crew — the faculties that do the work.** Six peers, no order among them: **Watcher** (see every
  agent), **Gatekeeper** (decide what reaches you), **Controller** (grant & limit what agents may do),
  **Coordinator** (agents hand off without colliding), **Guard** (undo, guardrails, keep work safe),
  **Librarian** (keep & lend reusable work).
- **The Substrate — what it plugs into.** The external systems the membrane consumes: **Runner** (runs
  the agent loops) and **Keeper** (holds what's known about you). Swappable behind their contracts.

Each role keeps a stable **ID** (F1–F4, S1–S3, R1–R3) as its traceability anchor, so renaming a role
never breaks the chain.

### How it fits together

*The outer view first — what's **core** and what **plugs in**. Port42 is the **canvas** (the one
invariant layer); the two swappable ends sandwich it — **packs** (a domain, as configuration) above,
**plugs** (agents, memory, knowledge) below. This is the boundary from
[`plays-with-others.md`](plays-with-others.md).*

```
                              P E R S O N
                    sees · drives · is reached
                                 │

   ┌───────────────────────────────────────────────────────────────┐
   │ PACKS — the domain, as configuration            (swappable)   │
   │ tool · skill · command · port packs:  dev · research · ops    │
   │ policy & logic, tuned per domain — never in the core          │
   └───────────────────────────────────────────────────────────────┘
                                 │  run on the canvas's hooks
   ┌───────────────────────────────────────────────────────────────┐
   │ PORT42 — THE CANVAS   (the UX layer = the bus)   ★ THE CORE   │
   │ surface · addressing (port42://) · presence · co-hold &       │
   │ right-of-way · render/modality · persistence · the hooks      │
   │ domain-agnostic · local-first · the one invariant layer       │
   └───────────────────────────────────────────────────────────────┘
                                 │  consumes
   ┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐
   │ AGENTS  (seats)   │ │ MEMORY  (store)   │ │ KNOWLEDGE (store) │
   │ Claude · Codex    │ │ AtomicMemory /    │ │ vaults · docs     │
   │ GLM · Pi · any    │ │ port42-companion  │ │ · RAG             │
   └───────────────────┘ └───────────────────┘ └───────────────────┘
                    plugs — not Port42's job    (swappable)
                                 │
  ═══════════════════════════ WIRE ══════════════════════════════
        UERP (port42://)   ·   libp2p (cross-instance)
```

**Zooming into the canvas layer** — the roles *inside* Port42 (the Face + Crew) and the Substrate they
plug into. Arrows are the load-bearing relationships, not every call:

```
                              P E R S O N
        ▲ surfaced: screen · voice · ambient       │ intention: type · speak · point
        │                                           ▼
  ══════════════════════ THE CANVAS (Port42) — roles inside ═══════════════════════

   THE FACE — how it meets you (two-way)
   ┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐
   │ Sensor             │  │ Synchronizer       │  │ Presenter          │
   │ senses you (in)    │  │ same live work     │  │ renders out        │
   └────────────────────┘  └────────────────────┘  └────────────────────┘

   THE CREW — the faculties that do the work
   ┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐
   │ Watcher            │  │ Gatekeeper         │  │ Controller         │
   │ watch every agent  │  │ what reaches you   │  │ grants & limits    │
   └────────────────────┘  └────────────────────┘  └────────────────────┘
   ┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐
   │ Coordinator        │  │ Guard              │  │ Librarian          │
   │ hand off, no clash │  │ undo & guardrails  │  │ keep & reuse work  │
   └────────────────────┘  └────────────────────┘  └────────────────────┘

   THE SUBSTRATE — external systems it plugs into
   ┌────────────────────┐  ┌────────────────────┐
   │ Runner             │  │ Keeper             │
   │ runs the agents    │  │ knows you          │
   └────────────────────┘  └────────────────────┘
  ═══════════════════════════════════════════════════════════════════════════════
            │ Runner runs & exposes the agent loops ▼
       AGENT LOOPS ×N  —  observable · steerable · bounded
```

**The load-bearing relationships:**
- **The Gatekeeper needs the Keeper & the Sensor** — it scores each interruption against *who you are*
  (Keeper) and *your moment* (Sensor); without them it can only decide generically. The single most
  consequential dependency in the picture.
- **The Watcher needs the Runner** — its calm view renders the live agent state the Runner exposes.
- **The Controller governs the Synchronizer** — every write on the shared surface, and every steer,
  passes through the Controller's delegation and limits.
- **The Presenter is the medium, not a step** — it renders anything (the Watcher's view, a Gatekeeper
  knock, the Synchronizer's surface) to screen / voice / ambient, chosen by the Sensor's read of you.
- **The Face is two-way** — Sensor takes intention *in*, Presenter renders *out*, Synchronizer is the
  shared surface between.

---

## The Face — how it meets you

*The membrane's two-way interface with the person. Sensor is *in*, Presenter is *out*, Synchronizer is
the shared surface between. A place-noun would be wrong for a role, but the Face itself is the UX — the
membrane's skin.*

**Sensor (F4)** — what the membrane needs *from* environment/OS/device providers: signals of your
**attention and availability** (focused app, at-desk, meeting, away, asleep) and **scoped access to your
real environment** (files, screen, accounts, devices). Providers supply the signals and access; the
membrane consumes them.
→ the *in* side of the Face; feeds the Gatekeeper's triage and the Presenter's medium choice.

**Synchronizer (F2)** — the **co-held surface** (its own protocol, host/driver conformance): shared
state, addressable elements, **per-element right-of-way**, a live event stream carrying in-progress
action. You and an agent both drive it, each seeing the other, without overwriting what the other holds.
→ realizes co-holding; the surface Steering acts through.

**Presenter (Modality)** — renders any output (the Watcher's view, a Gatekeeper knock, the
Synchronizer's surface) to **screen, voice, or ambient**, chosen by the Sensor's read of your moment.
One logical thing, many media.
→ the *out* side of the Face · upholds C5/C6.

## The Crew — the faculties that do the work

*Six peers, no order among them. Owned and built by the membrane.*

**Watcher (S2)** — the **calm, legible view** of all agents: quiet when fine, the one that needs
attention standing out; drill-in for one agent's detail; a returning digest. Also where new surfaces are
**introduced and placed** (interrupt / ambient / parked / nested).
→ realizes the Watcher faculty (spec §1) · upholds C2.

**Gatekeeper (S1)** — takes every need an agent raises, **scores it against the Keeper (who you are) and
the Sensor (your moment)**, decides **suppress / defer / reach**; sets the **pressure** (quiet lean →
urgent break-in); **composes** many needs into a legible few; **learns** from what's waved off. The
**intended mechanism** for "nothing becomes noise" (C2) — whether it can be trusted not to suppress what
matters is **unproven** (the J4 spam-folder anxiety; hypotheses H8/H9).
→ realizes the Gatekeeper faculty (spec §2) · targets C2.

**Controller (S3)** — **delegation by area and stakes**, autonomy that rises as earned and drops on
error, **hard limits it's designed never to cross**, **meta-authority you cannot be deprived of**, and
**honoring the privacy boundary the operator set** (how private this instance is). Governs every write on
the Synchronizer and every intervention.
→ realizes Delegation (spec §5) · upholds C1 · honors the privacy setting behind J12, J16.

**Coordinator (R1)** — lets agents **communicate, hand off, and detect conflict** among themselves
without routing through you, and lets work and supervision **span multiple people** with authority and
boundaries preserved.
→ realizes Coordination (spec §8).

**Guard (R2)** — **background and long-running** execution, **history** and **reversibility**, a
**guardrail-and-confirm** gate before the irreversible, an **audit record** of what was **done** — and,
per J21, of what was **sent** to a model — and **cost** tracking with bounds.
→ realizes Endurance & Safety (spec §9) · upholds C1, C6.

**Librarian (R3)** — makes agent abilities **discoverable**, supports **teaching** new skills and
**turning one-offs into reusable** workflows, and keeps finished work **keepable and revisitable**.
→ realizes Capability & Reuse (spec §10) · upholds C3.

## The Substrate — what it plugs into

*The external systems the membrane consumes, each behind an invariant contract. Implementation may be an
existing system wired in or one we provide, per role.*

**Runner (F1)** — what the membrane needs *from* whatever runs agents: each agent loop must be
**observable** (exposes aim/progress/state), **steerable** (accepts intervention mid-run), and
**bounded** (executes within granted authority). Any runtime meeting this contract is valid — existing
framework or one we build.
→ the basis of Steering, the Guard's long-running execution, the Watcher's view of live state, and the
needs the Gatekeeper routes.

**Keeper (F3)** — what the membrane needs *from* a memory/knowledge provider: a **unified, cross-project,
correctable** store of who you are (preferences, context, project connections, what you'd want
interrupted for), **honoring the operator's privacy setting**. One model of you across all your work, not
per-agent or per-project silos.
→ realizes the person-model; is the Gatekeeper's knowledge. Full contract: *parked — to be re-specced*
(not needed for Slice 01).

---

## Role → job (traceability)

| Role (ID) | Group | Serves |
|---|---|---|
| Sensor (F4) | Face | J13 (+ powers J4) |
| Synchronizer (F2) | Face | J1, J2, J8 |
| Presenter (Modality) | Face | J18 |
| Watcher (S2) | Crew | J3 |
| Gatekeeper (S1) | Crew | J4, J9 |
| Controller (S3) | Crew | J5, J10 (+ honors the privacy setting: J12, J16) |
| Coordinator (R1) | Crew | J11, J16 |
| Guard (R2) | Crew | J14, J15, J19, J21 |
| Librarian (R3) | Crew | J17, J20 |
| Runner (F1) | Substrate | J5–J7, J14 |
| Keeper (F3) | Substrate | J12 (+ powers J4, J9) |

## The dependency that shapes the build

**Personalized triage depends on the Keeper and the Sensor.** Crude, rule-based triage is possible
without them — but the *personalization* (what reaches you, based on who you are and what you're doing
now) is what's meant to make attention management not-noise, and that needs the Keeper (knows you) and
the Sensor (knows your moment). So the Gatekeeper's real value depends on them being in place. *(A
quality dependency, not a hard logical one — and separate from where adoption is make-or-break.)*

## What's actually make-or-break (analyzed)

Where adoption lives or dies has been analyzed — every anxiety ranked by adoption-impact in
[`make-or-break.md`](make-or-break.md). The derived answer:

**The product lives or dies on trust-with-real-stakes — recovery (Guard) and control (Controller).**
Every dealbreaker is a version of "letting an agent near my real world": irreversible harm (Guard), loss
of control (Controller).

**Privacy is not a third pillar — it's an operator setting.** How private an instance is (just-me /
local → shared team → org policy) is a choice the operator makes; the system's job is to **honor
whatever boundary was set**, which is itself a **control** guarantee. So the "my context leaked" fears
(J12, J16) fold into the **Controller**, not a separate privacy faculty.

**The Keeper is not where adoption is decided.** Its one remaining scary anxiety — "wrong about me and I
can't fix it" — is **designed out by its own contract**, which requires you can see and correct what it
believes. The Keeper is still built early, but because it's **foundational** (the Gatekeeper's
personalization can't work without it), not because it's make-or-break.

**Guard (recovery & safety) is core, not a scale-up nicety** — reversibility and the
guardrail-before-irreversible are load-bearing for adoption from day one.
