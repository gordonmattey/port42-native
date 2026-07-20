# How Port42 Plays With Others — Boundaries & Composition

*2026-07-17 — the **outer boundary**. The membrane docs describe what the experience *is*
([`membrane-architecture.md`](membrane-architecture.md)) and the mechanism under it
([`bus-architecture.md`](bus-architecture.md)). This one draws the line around what is **Port42's job at
all** — because the scoping decision is the product decision.*

---

## The thesis

**Port42 is the UX layer — the shared canvas where humans and agents meet.** It is *not* the agents, *not*
their memory, *not* the knowledge store, and *not* the domain logic. Those **plug in.** Port42's job is
the surface everything meets on: presence, addressing, co-holding, and how it renders to you.

Everything a specific *domain* needs — dev supervision, research, ops, whatever — arrives as
**configuration: tool / skill / command / port packs tuned for that domain.** Never as a core feature.

## The boundary test (one question)

> **Is it about the shared surface where humans and agents meet** — seeing each other, addressing each
> other, co-holding work, how it renders to you? → **Port42.**
> **Is it about what an agent *is* (the runtime), what it *knows* (memory/knowledge), or what a *domain*
> needs done (workflow/policy)? → it plugs in.**

Three things are never Port42: **the agent, the knowledge, the domain.** One thing is: **the canvas.**

---

## What Port42 owns (the canvas + the bus)

The surface, and the mechanism that makes it shared. Roughly the membrane's **Face** + the **bus**:

- **The surface** — ports as addressable actors; terminal / chat / web / agent as one contract.
- **Addressing & transport** — `port42://` (UERP). A stable name reaches a port anywhere.
- **Presence** — humans and agents in the same space, seeing each other act.
- **Co-hold & right-of-way** — two drivers on one surface without overwriting (the *mechanism*; the
  *policy* of who-may is a plug — below).
- **Rendering / modality** — how anything surfaces to you (screen / voice / ambient).
- **Connect & trust** — invite, join, E2E, device-scoped identity. The *connective* trust — not
  authorization semantics for a domain.
- **Persistence & versioning** — the canvas's own history / restore / patch.
- **The hooks, not the policy** — Port42 exposes the *enforcement points and surfaces* (the write edge,
  an audit stream, an attention channel). What runs on them is a plug or a pack.

## What plugs in (never Port42's job)

| Plug | What it is | Interface | Today |
|---|---|---|---|
| **Agents** | the runtimes — Claude, Codex, GLM, Pi, any loop | connect as a **seat** (outbound, invite URL) | shipped (agents-as-peers) |
| **Memory** | cross-session/agent person-model & recall | a **store agents query + a subscriber to the stream** | plug (AtomicMemory the candidate; `port42-companion` the in-house test) |
| **Knowledge** | vaults, docs, RAG, project facts | a **store**, same shape as memory | plug |

The agent isn't Port42. The memory isn't Port42. Port42 is where they show up and are driven.

## What's a pack (a domain, via configuration)

A domain is **not** a feature — it's a bundle of **tool / skill / command / port packs** that tune the
canvas for that domain. The pack carries the *policy and logic*; Port42 carries the *surface and hooks*.

**Worked example — the dev-supervisor** (from Ethan's dev-harness analysis): worktrees, model/harness
routing, plan→implement→review state, autonomy gates. **None of that is Port42.** It's:
- **seats** — Claude + Codex agents plugged in;
- a **memory** — AtomicMemory plugged in;
- a **dev pack** — the workflow (plan→implement→review), the gate policy (autonomy profiles), the routing
  rules (GLM-cheap vs. Claude-review), worktree/sandbox handling, expressed as command/skill/tool packs.

Port42 **shows and drives** it — the seats, the attention items, the gates, the diffs render on the
canvas and are operated there — and **owns none of it.** Swap the dev pack for a research pack and the
same canvas is a research supervisor. That's the point of the boundary.

## The composition contract (four ways to plug)

1. **Seat** — an agent/runtime connects (outbound) and becomes an addressable actor. *(the Runner shape)*
2. **Store + subscriber** — a memory/knowledge system subscribes to the stream and answers queries.
   *(the Keeper shape — and per [`bus-architecture.md`](bus-architecture.md), a memory is "a subscriber
   like persist," never part of the interaction contract)*
3. **Pack** — tool/skill/command/port config that tunes the canvas for a domain's policy & logic.
4. **Adapter** — an external platform (Warp Oz, Omnigent, OpenRig, …) hosted as a seat or routed to.

---

## The membrane, re-cut by this boundary

The Crew wasn't wrong — but this line splits each faculty into *mechanism (Port42)*, *policy (pack)*, and
*knowledge (plug)*:

| Membrane element | Under this boundary |
|---|---|
| Face — Sensor / Synchronizer / Presenter | **Port42** (the canvas) |
| Bus — addressing · right-of-way write-edge · subscription · persistence | **Port42** (the mechanism) |
| Watcher (see agents) | **Port42** surfaces it; *what* an agent reports is the agent's |
| Gatekeeper (what reaches you) | **Port42** routes/surfaces; *personalized* triage needs the **memory** plug |
| Controller (gates/authority) | **Port42** exposes the write-edge; the leash/autonomy *policy* is a **pack** |
| Guard (reversible/audit) | **Port42** owns versioning + the audit stream; *what-counts-as-irreversible* is a **pack** |
| Coordinator (agent handoff) | **Port42** is the bus; the coordination *logic* is a **pack / the agents** |
| Librarian (keep/reuse) | **Port42** persists surfaces; capability/knowledge reuse is a **pack / knowledge** plug |
| Runner (agent runtime) | **plugs in** (agent seat) |
| Keeper (person-model) | **plugs in** (memory store) |

Read the middle column: Port42 keeps the *surface and the hooks*; everything policy-shaped becomes a
pack; everything knowledge-shaped becomes a plug.

## Why this boundary (the discipline)

- **It keeps Port42 domain-agnostic.** The dev-supervisor, research, ops are packs — the core never
  learns any one domain, so it never bloats into a vertical.
- **It makes Port42 the thing others compose on**, not compete with. Agents, memory backends, and
  platforms are *complements* that plug in — not features to out-build.
- **The moat is the canvas.** Central players own the room-on-our-server; memory players own the store;
  agent labs own the model. Port42 owns the **shared surface where a human and any agent meet, addressed,
  co-held, local-first** — the one layer none of them can cede without becoming a different product.

**The rule, restated:** if a request would teach the core a *domain*, an *agent*, or a *body of
knowledge* — stop. That's a pack or a plug. The core only ever learns new ways for humans and agents to
*share a surface*.
