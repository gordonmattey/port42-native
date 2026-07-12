# After the App — Primitives of Agent-Provided Software

*2026-07-12 — the concrete grounding of the membrane. If applications no longer need to exist because
agents provide functionality on demand, what does that agent-provided software need to *exist* on a
desktop and be *co-operated* by human and agent? Companion to [`the-membrane.md`](the-membrane.md).*

## The unit shift: application → surface

| | Application | Agent-provided surface |
|---|---|---|
| origin | pre-built, installed | **materialized on demand** from intent |
| drivers | **single** — only you operate it | **dual** — you *and* the agent operate it |
| lifespan | permanent until uninstalled | ephemeral or persistent, as needed |
| location | its own window; you go to it | over/around your other apps; it comes to you |
| model | a container you enter | a thing an agent hands you |

The app was the unit of software. The **surface** replaces it — but because it is generated on demand
and co-operated with an agent, it needs a richer primitive set than an app ever did.

## The primitives

1. **Materialize** — an agent conjures the surface from intent. No install, no build. Functionality
   appears when needed, not before.
2. **Render** — a live interactive canvas. Not a terminal, not a file, not a puppeted human app.
3. **Dual-drive** ⭐ — the human operates via input events; the agent operates via a *native
   programmatic channel* (read the surface, update it, act through it). Same surface, same state,
   both hands on it. **This is the core primitive and the one apps never had.**
4. **State** — the surface remembers (its data persists across time and re-open).
5. **Capability** — scoped permissions: what this surface/agent may touch — files, screen, network,
   devices, other surfaces. Granted by you or by the agent's trust level.
6. **Connect** — data in and out; wire to real data, to other surfaces, to the world.
7. **Persist & address** — a lifecycle (live → parked → evaporate) and an address so it can be found
   again or handed off.
8. **Locate** — where it sits relative to your other apps: over/around them (pervasion), not a
   separate destination (see `the-membrane.md`).

## The core: dual-drive (and why it isn't computer-use)

Apps are **single-driver** — only the human touches them; the software just responds. The defining
primitive of agent-provided software is the **dual-driver surface**: the human *and* the agent both
operate the same surface, over the same state.

The critical distinction from **computer-use**: a computer-use agent *puppets your existing apps* —
moves your cursor, clicks your buttons, impersonates a human operating human software. That is the
wrong primitive. An agent should not pretend to be you. It should have a **native channel** to a
surface built to be co-operated: the agent fills a form by *setting the field's value*, not by aiming
a cursor at it. Human drives by events; agent drives by API; one surface, one state.

## The modes of a shared surface

How control splits between human and agent on the same surface:

- **agent shows** — it renders, you watch
- **agent asks** — it renders a request, you fill it in
- **you direct, agent builds** — you say, it updates the surface
- **both manipulate** — collaborative, both editing the same thing
- **agent acts through it** — the surface is a control panel the agent operates to do work; you watch
  and approve

## The unification with the membrane

The agent-provided surface **is** the membrane's instrument. You *watch and steer through it*; the
agent *works through it*. Dual-drive is literally how watching and steering physically happen — the
human's gestures (redirect, hold, fence — see `membrane-gestures.md`) are one side of the dual-drive;
the agent's programmatic channel is the other. "The primitives of agent-provided GUI" and "the
membrane" are the same thing from two directions. **The surface is where the human loop and the agent
loop meet in the flesh.**

## Port42's head start

The **port + bridge** is already most of this:
- **port** = a materialized, rendered, addressable surface with a lifecycle (Materialize, Render, Persist)
- **port bridge** (`port.push` / `exec` / `getHtml` / `update`) = the agent's native drive channel (Dual-drive, agent side)
- **storage** = State
- **permission model** = Capability
- **push / bus / rest.call / device APIs** = Connect

Underbuilt for this frame: **truly simultaneous dual-drive** (human and agent on one surface at once,
not turn-taking), and **Locate/pervasion** (the surface living over your other apps rather than inside
Port42). The `gi-engine` prototype was groping at Materialize + Render + State — the surface primitives
— without the framing that they are the membrane's instrument.

## What this reframes to build

Not "a better generator." The buildable core is the **dual-drive surface**: one interactive surface
that a human operates by hand and an agent operates by API, over shared state, living over your other
apps. Prove that a human and an agent can hold the same surface at once — that is the atom of the
whole membrane, and the thing no app-world primitive provides.
