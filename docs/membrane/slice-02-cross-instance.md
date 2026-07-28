# Slice 02 · Cross-Instance — Detailed Design

> **RE-HEADED 2026-07-28. The concurrency mechanism in this document is OBSOLETE, and the rest still
> stands.** This was written on 2026-07-15 against a per-port **lease**: one holder, a write requires
> it, no lease means the write is rejected. **That mechanism was built locally, then deleted.** The
> local protocol thread (`plan-port42-protocol-local-bus.md`) replaced it with three nouns —
> ADDRESS · ACTOR · TOKEN — and the replacement is not a refinement of the lease, it is a different
> answer to the same question:
>
> | this doc says | what actually exists |
> |---|---|
> | a lease grants the right to write | **a TOKEN says what you composed against**; a write carrying a stale one is refused with `stale_write` + `current`, and an untokened write with `token_required` (R5) |
> | one holder per port, others rejected | **nobody is ever blocked.** Refusing a caller who declined to declare state is not the same as refusing a caller who did not win a race |
> | the holder is broadcast so both UIs show the pen | **presence is DERIVED** from whoever moved the token last (step 3). It shows; it refuses nothing |
> | request → grant/deny → handoff | **no verbs.** `release` and `handoff` were deleted as lease-era code with no callers |
>
> **Why the lease died, and why it matters MORE across the wire than it did locally.** A lease is a
> lock with a TTL, and a TTL has no principled value; worse, it depends on clocks agreeing between
> peers, which they do not. A vanished holder leaves a port stuck. R1 removed it locally for those
> reasons, and every one of them is sharper at a distance. **The token is correct whether the writer
> thought for 3ms or 3 hours, and identical locally and remotely** — which is exactly why it was built
> peer-qualified from day one (`ActorRef` is `<peerID>/<principal>`, with local as the degenerate
> form) and epoch-qualified (`<epoch>:<seq>`).
>
> **What this means for the slice.** The Address, Query-in and Stream-out sections below are unchanged
> and still correct. Wherever this document says *lease*, *holder*, *grant/deny* or *take the pen*,
> read: **the write carries a token; if the port moved, it is refused and told the current one; and
> presence names whoever wrote last.** The acceptance row for right-of-way is rewritten in place. The
> open questions O-1 and O-4 are answered rather than open — see the bottom of this note.
>
> **O-1 (lease authority) is void.** There is no grant, so there is no authority to locate and no
> owner-versus-requester disagreement to resolve.
>
> **O-4 (causality under lease churn) survives in a better form.** The concern was a late delta from a
> prior holder being misapplied. Under CAS that delta carries a token the port has already moved past,
> so it is refused BY CONSTRUCTION rather than by ordering rules. What remains open is Notify ordering
> for DISPLAY, not for correctness.
>
> **Read `plan-port42-protocol-local-bus.md` §A before building from this file.**


*2026-07-15 — the second **vertical slice**: prove the **bus crosses instances**. Where
[`slice-01-trust-core.md`](slice-01-trust-core.md) validated the trust core (Controller/Guard/Runner) on
one machine, this validates the **Synchronizer** ([`bus-architecture.md`](bus-architecture.md)) across
two — a port on instance A, addressable and driveable from instance B, deltas streaming back, right-of-way
holding across the wire. It builds only the thin sliver of the bus the slice needs; it does not build
multiplayer in full.*

**Transport — decided.** **go-libp2p** (native to the Go gateway). This slice does **not** re-open the
transport question; it stands on libp2p's primitives and tests the *app contract* over them:

| Bus facet | libp2p primitive (given, not built) |
|---|---|
| instance address | **PeerID** (+ multiaddr) |
| reach across NAT | **Circuit-Relay v2** + **DCUtR** hole-punch, **AutoNAT** for reachability |
| discovery | **mDNS** (same-LAN, milestone A) → **Kademlia DHT / rendezvous** (milestone B) |
| query in | a **libp2p stream** on a `/port42/uerp/1.0.0` protocol id |
| stream out | **gossipsub** topic per port (the Notify fan-out) |

---

## The slice in one line

> A port lives on **instance A**. From **instance B** you address it, send it a query, and see its
> stream — as if it were local. When B takes the pen, A sees B holding it, and neither overwrites the
> other. Location is transparent; the wire is libp2p.

## Why this slice (what it validates)

1. **It proves keystone #1 — address across instances.** The single foundational decision in
   [`bus-architecture.md`](bus-architecture.md): extend `port42://space/<id>/<portId>` to carry the
   instance, so a query reaches a remote port the same way it reaches a local one.
2. **It proves a coarse keystone #2 — right-of-way across the wire.** Per-*port* ownership (not yet
   per-element): two drivers on two instances never double-write.
3. **It cashes out the hardest sentence.** My own earlier critique flagged the Synchronizer's real-time
   surface as the deepest unsolved piece stated as one bullet. This is where it meets code.
4. **It measures the honest falsifier.** Hole-punch success rate under real networks — the number that
   decides whether "p2p = sovereignty" is viable or whether relay dominates in practice.

## Scope — jobs this slice touches

| Job | What the slice exercises | Kept thin by… |
|---|---|---|
| **J8** working on the same thing together | co-hold one port across two instances | one port, per-port right-of-way (not per-element) |
| **J16** working with other people | A's surface driveable by B (another person) | two peers, no teams / no fan-out to N |
| **J13** wherever & whenever I am | the same port reachable from another instance/device | no mobile; two desktop gateways |

## Scope — roles this slice cuts

*Build **only** the one thing named.*

| Role (ID) | Build only this | Skip |
|---|---|---|
| **Synchronizer** (F2) | remote address + query-in/stream-out + per-port right-of-way over libp2p | per-element right-of-way; unified 4-way subscription; CRDT/OT merge |
| **Controller** (S3) | who-may-write across the wire — CAS on the port's token (was: the ownership lease) | full delegation matrix, cross-instance identity/auth beyond peer keys |
| **Coordinator** (R1) | two peers discover + connect | N-peer swarm, conflict detection among agents |

**Not in this slice:** Keeper, Sensor, Gatekeeper, Guard, Librarian, Presenter-beyond-terminal, agents
writing to the remote port. Human-driven both ends first.

---

## The reference implementation — extend the local bridge over the wire

The bus already exists **locally**: the port bridge ships `getHtml` (snapshot), `patch` (delta), `push`,
`update`, `history`/`restore`, and a local event stream (P-400, Mar 2026). The slice is **not** a new
system — it is: *make those same verbs cross a libp2p stream to a port on another instance, and add a
token so a write composed against stale state is refused rather than applied.* (Same move as Slice 01 naming git as the Guard's substrate:
here the substrate is the existing bridge + libp2p.)

### The shape

```
   INSTANCE A (owns port P)                         INSTANCE B (remote driver)
   ┌───────────────────────┐                        ┌───────────────────────┐
   │  port P (actor)        │                        │  proxy handle → P      │
   │   state · stream       │                        │   renders P's stream   │
   └─────────┬─────────────┘                        └──────────┬────────────┘
             │ gossipsub topic: port42/<space>/<P>  (Notify deltas)          │
             │◀───────────────────────────────────────────────────────────▶ │
             │ libp2p stream /port42/uerp/1.0.0     (Query / Update in)      │
             │◀───────────────────────────────────────────────────────────▶ │
        Circuit-Relay v2 ─── DCUtR hole-punch ──▶ direct conn (or stay relayed)

   ADDRESS   port42://<peerID>/space/<space>/<portId>     ← instance = PeerID
   WRITE     B reads P's token → B patches, carrying it → A applies, or refuses `stale_write`
             with `current` → B retries once → Notify to both (see the re-head note: no lease)
```

### The contract, made concrete

- **Address (F2).** `port42://<peerID>/space/<id>/<portId>`. Resolve `<peerID>` → live multiaddr via
  mDNS (milestone A) or DHT/rendezvous (milestone B). A local port keeps its short address; the instance
  segment is what's new.
- **Query in (F2).** B opens a `/port42/uerp/1.0.0` stream to A and sends a UERP-framed `Update`
  (`patch`/`push`) or `Query` (`getHtml`, incl. as-of). A executes it **through its existing local
  bridge** — the remote caller is just another origin.
- **Stream out (F2).** A publishes every port delta to gossipsub topic `port42/<space>/<portId>`;
  B (and any subscriber) receives `Notify`. One publish, many subscribers — the unified-subscription
  shape, minimally.
- **Right-of-way (S3) — the TOKEN, not a lease.** *(Rewritten 2026-07-28; the original paragraph
  specified a lease and is quoted in the re-head note.)* Every write carries the token it was composed
  against. A writes it through its own local bridge, which either applies it or refuses `stale_write`
  carrying `current`, so B self-corrects in one retry with no extra round trip. An untokened write is
  refused with `token_required`, also carrying `current`. **Nobody is blocked and nothing is granted.**
  Presence is derived from whoever moved the token last and is broadcast on the Notify topic as
  `kind: "driver"`, so both UIs show who is driving — a display fact that refuses nothing.
  *(The deliberate concurrency choice: optimistic CAS on a per-port monotonic counter, not pessimistic
  ownership and not CRDT/OT. A lock cannot cross the wire, because clocks do not agree between peers.)*

### Milestones (isolate app-contract from traversal)

- **A · same-LAN (mDNS).** Prove the *contract* — address, query, stream, token — with traversal taken
  out of the equation. If this doesn't feel instant on a LAN, nothing else matters.
- **B · cross-NAT (relay + DCUtR).** Prove *traversal* — two instances on different networks. Instrument
  the hole-punch: record direct-vs-relayed, and the success rate.

---

## Acceptance — pass/fail per seam

| Seam | PASS | FAIL |
|---|---|---|
| **Address** | `port42://<peerID>/…` reaches the remote port; the same verb path works local and remote | remote needs a different API than local |
| **Query in** | B's `patch`/`getHtml` executes on A's port via A's existing bridge | remote writes bypass A's local bridge/authority |
| **Stream out** | a delta on A appears on B within one round-trip; multiple subscribers get it from one publish | B must poll; or fan-out needs bespoke per-subscriber code |
| **Right-of-way** | a write composed against stale state is REFUSED with `current`, and one retry lands; presence names whoever wrote last, on both ends; no double-apply under contention | a stale write is applied and A's state diverges from B's view; or a caller is blocked outright, which is the lease failure again |
| **Traversal (B)** | direct connection via DCUtR where NAT allows, clean relay fallback otherwise; success rate recorded | connection only works same-LAN; or fails silently behind NAT |

**Slice-level acceptance:** on two instances across two networks — B addresses A's port, reads its
state and token, patches it carrying that token, both UIs converge on the new state and show B as the
driver; A then writes with a token it read BEFORE B's patch and is refused `stale_write` with
`current`; A retries once and lands. Location-transparent; the same verbs, and the same refusal, as
local.

**The measured number (the falsifier):** hole-punch **direct-connection success rate** across ≥4 real
network settings (home, café, corporate, tethered mobile). ≥~80% direct + clean relay fallback →
p2p-as-sovereignty is viable. Mostly-relayed → the moat thins; know it now, not later.

## What a green slice means — and doesn't

- **Means:** the bus is real across instances on libp2p; `port42://` is a working protocol, not a paper
  one; the sovereignty thesis (direct peer connections, no central node holding state) has a walking
  skeleton.
- **Does *not* mean:** per-element co-editing works (that's the next slice), agents drive remote ports,
  N-peer rooms scale, or the traversal rate holds at population scale.

## Explicitly out of scope

Per-element right-of-way (CRDT/OT vs. finer locks); agents as remote drivers; N>2 swarms; mobile;
persistence when the owning instance goes offline (room outlives host); auth beyond libp2p peer keys;
the Keeper/epistemic layer entirely (a Keeper, if present, is *a gossipsub subscriber* like persist —
not part of this contract).

## Open questions (marked — not asserted)

- **O-1 · ~~Lease authority~~ · VOID (2026-07-28).** There is no grant, so there is no authority to
  locate. Kept for the record: the question was — the owning instance grants the lease, so what happens
  when the *owner* is the one who should yield, or when owner and requester disagree? A single-owner lease is the thin start; a
  neutral arbiter is deferred.
- **O-2 · Availability when the host leaves.** If A goes offline, P is gone. Multiplayer usually wants
  the room to persist. Pure p2p vs. a designated always-on node is unresolved — and bears on the
  sovereignty story.
- **O-3 · Discovery trust.** DHT/rendezvous tells B where A is; what stops a hostile peer from answering
  for A's address? Out of scope here, real later.
- **O-4 · ~~Causality under lease churn~~ · ANSWERED for correctness (2026-07-28).** A late delta from
  a prior writer carries a token the port has already moved past, so CAS refuses it BY CONSTRUCTION.
  What remains is Notify ordering for DISPLAY, which is a rendering question, not a correctness one.
  The original: rapid lease handoffs + in-flight deltas need ordering
  (sequence/causal tag on Notify) so a late delta from the prior holder isn't misapplied.
- **O-5 · Per-element, later.** Per-port locking is coarse; real co-holding wants per-element. Whether
  that stays locking or moves to CRDT/OT is the next slice's central decision, explicitly deferred.

## Risk — what this slice retires vs. leaves

- **Retires:** cross-instance addressing correctness (keystone #1); that the local verb set replicates
  over the wire unchanged; that libp2p traversal is viable *for this workload* (the measured rate).
- **Early signal on:** the p2p-as-sovereignty bet — the direct-connection rate is the first real evidence
  it holds under real networks.
- **Leaves untouched (by design):** per-element concurrency (CRDT/OT vs. locks), host-offline
  persistence, N-peer scale, agent-driven remote writes, and the entire epistemic/Keeper layer.
