# Pluggable primitives architecture

The reframe that the Hermes investigation converged on. Companion to
[hermes-integration-map.md](./hermes-integration-map.md) and
[shell-with-intelligence-thesis.md](./shell-with-intelligence-thesis.md).

## The reframe

It is **not** "integrate Hermes." It is a **pluggable engine-primitive interface**:
Port42 is the **composition layer** that owns the user-facing surface and the slot
contracts; engine-facing capabilities are **slots**, each with a Port42-native provider
*and* the ability to accept a foreign one. Hermes is the **reference plugin** — the
thing that proves the slots are real. Its properties (skills, execution, autonomy,
memory, model routing) are *representative members of an open set*, not a fixed list
and not the whole set.

Goal stated plainly: **plug in whatever primitive the user chooses.** By renting the
engine-facing slots, the team concentrates its effort on the **user-facing primitives**
— the only place Port42 is differentiated.

## Two layers

**User-facing primitives (Port42 owns — priority focus).** The differentiation.
- `port` — a disposable, need-shaped surface
- `space` — a place: membership, encryption, presence
- `permission` — the gate
- the **shell grammar** — zoom / peek / adopt / dismiss

**Engine-facing primitives (pluggable slots).** Rented, swappable, never user-visible
except *through* the layer above.

## The slot registry

Each slot defines a **contract** (what a provider must supply), ships a **native
provider**, and can accept an **external** one. Hermes is the reference external.

| Slot | Contract (what a provider must supply) | Native provider | Reference external (Hermes) |
|---|---|---|---|
| **Reasoning / model** | turn intent + context → actions/tokens | `LLMEngine` (Claude) / `compatibleEndpoint` | its model router (local vLLM / OpenRouter) |
| **Autonomy / loop** | run work over time, not just on a message | **`tick`** (loop engine) | the Hermes daemon + self-improvement loop |
| **Execution** | run code somewhere with an isolation level | **`tick` execution backends** + terminal ports | Docker sandbox / SSH / Modal |
| **Skills / procedural memory** | persist a reusable recipe; improve with use | *gap today* (candidate for `tick` to grow) | `SKILL.md` (agentskills.io) — **the slot Hermes most uniquely fills** |
| **Memory / state** | durable files, kv, relationship state | **`fs` + `storage` (kv) + creases/fold** via the bridge | `~/.hermes` |
| **Tools / capability** | the hands on the machine | **the bridge, exposed via `port42-mcp`** — *special: Port42 owns it and lends it downward* | (consumes the bridge; brings web-search etc.) |

Note the two special rows: **Autonomy** and **Execution** already have a real native
provider in `tick`, so the architecture is not hollow. **Tools/capability** is the one
slot Port42 owns and lends *down* to every engine — it is the trust boundary.

## The one invariant (two-directional — both surfaces Port42-owned)

> **Up:** an engine primitive reaches the user *only* through a user-facing primitive.
> **Down:** an engine primitive touches the machine *only* through the bridge
> (permission-gated).

This is what makes "plug in anything" and "I trust my machine" simultaneously true. An
engine may keep its own sandbox for *ephemeral* compute (its business), but the moment
it touches *your* host, it is your gate. The invariant is **testable**: any leak — an
engine's own chat UI surfacing *up*, or raw host access *down* — means the boundary is
broken.

## Open design questions

- **skill ↔ port relationship — unresolved, but there's something here.** A skill is
  engine-facing (a persistent *procedure*); a port is user-facing (a disposable
  *surface*). They are not the same axis: a skill may produce zero, one, or many ports,
  and a port need not come from a skill. So "skill = disposable render" is too tidy.
  The real question the *up*-invariant forces: **how does a persistent engine-side
  skill surface in the user-facing layer?** As an invokable command? a dock item? a
  space object? a port it can spin up? This is design work, not a settled mapping.
- **Autonomy vs. the reactive UX.** `tick` / a Hermes daemon act *over time*; proactive
  work must surface as a **peek** (ties directly into the notification-as-port work)
  and stay revocable. Autonomy without a leash breaks trust.
- **Memory ownership line.** Native `fs`/`kv`/relationship vs. an engine's own store —
  draw the line so the user's identity/state doesn't fork across two systems.
- **Contract design against ≥2 providers (the anti-"Hermes-in-a-trenchcoat" guard).**
  A pluggable interface designed around its first plugin is just coupling with extra
  ceremony. **Every slot contract must be validated against `tick` *and* Hermes at the
  same time.** If a slot only makes sense with Hermes plugged in, the abstraction is
  fake. The slot contracts *are* the product-defining work now — that is where the
  design effort goes, not the Hermes adapter.

## Strategic consequence

- **The OS answer.** Owning the user-facing grammar + the slot contracts + the bridge
  makes Port42 the platform, with engines as interchangeable providers. Moat = grammar
  + contracts + bridge — none of which any engine vendor is building.
- **A resource thesis.** Rent the engine slots; concentrate fire on the user-facing
  primitives. That is the whole point of the exercise.

## Phased plan (leads with contracts, not wiring)

- **P0 — Write the slot contracts (paper).** Define each slot's interface, validated
  against `tick` *and* Hermes simultaneously. The abstraction is proven on paper before
  any adapter is built.
- **P1 — Prove the *down*-invariant (Tools slot).** Point Hermes at `port42-mcp` as its
  only host-touching toolset; from Hermes, "create a port showing X" renders a real
  port through the gated bridge. Existing MCP server → near-zero Swift. Frames the
  trust boundary as "an external engine touches the machine only through the bridge."
- **P2 — The Autonomy slot behind one contract.** `tick` (native) vs. the Hermes daemon
  (external) satisfying the same interface; proactive output surfaces as peeks.
- **P3 — The Skills slot + the *up*-question.** Hermes `SKILL.md` as reference; design
  how a persisted skill surfaces in the user-facing layer (the open question above).
- **P4 — Memory ownership line + local-model default.** Draw the state line; make a
  local model the recommended zero-cloud engine — the thesis's local-first payoff.

## Grounding (seams already in-tree)

- `Sources/Port42Lib/Resources/port42-mcp.js` — bridge as an MCP tool (the Tools slot,
  lent downward).
- `tick` — native Autonomy + Execution provider.
- `AgentMode.remote` + `SyncService` peer protocol — an external engine as a companion.
- `OpenClawService.swift` — the proven playbook for onboarding an external agent CLI.
- `fs` / `storage` / creases / fold — the native Memory slot.
