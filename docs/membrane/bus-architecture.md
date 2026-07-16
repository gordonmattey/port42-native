# The Bus — Ports as Actors (the *actual* architecture)

*2026-07-15 — the **actual** architecture under the **conceptual** one. Where
[`membrane-architecture.md`](membrane-architecture.md) describes the experience by **role** (the Face,
the Crew, the Substrate), this describes the **mechanism** every role stands on: a single message bus
where every surface is an **addressable actor**. The Face's **Synchronizer** is not one faculty among
many — it is this bus, and the rest of the Crew are policies over it.*

*The wire protocol for the bus is already specified: **UERP** (`port42-rfc.txt`, `port42://` addressing +
Query/Response/Update/Subscribe/Notify). This doc is the layer between the roles and that wire.*

---

## The one idea

**A port is not pixels — it is an actor.** You send it **queries** and it emits a **stream**. That is
the entire contract, and it is the same whether the port is a terminal, a chat, a web surface, or an
agent; whether it runs local, on another instance, or on a server; whether the caller is a human's UI, an
agent's tool-use, or a peer instance.

```
   query  ──▶  ┌───────────┐  ──▶  stream
              │   PORT     │
              │  (actor)   │       state · addressable · right-of-way
   query  ──▶  └───────────┘  ──▶  stream
```

Pixel/video streaming is the **fallback for opaque surfaces you don't own** — it throws away the query
interface and ships dead pixels. For a port you *do* own, it never appears.

---

## Three layers, one spine

```
                               T H E   P E R S O N
              ▲ surfaced: screen · voice · ambient      │ intention: type · speak · point
              │                                          ▼
  ┌───────────────────────────────────────────────────────────────────────────────┐
  │  CONCEPTUAL — THE FACE  (membrane-architecture.md)                              │
  │                                                                                 │
  │     Sensor  ───────────▶   Synchronizer   ───────────▶   Presenter              │
  │     intention IN           the co-held surface          render OUT              │
  │     (a query source)       ( = THE BUS )                (a subscriber)          │
  └───────────────────────────────────────────────────────────────────────────────┘
                                     │  the Synchronizer IS the bus; the rest of the
                                     ▼  Crew are policies over it (see foot of page)
  ┌───────────────────────────────────────────────────────────────────────────────┐
  │  ACTUAL — THE BUS  (this doc)                                                    │
  │                                                                                 │
  │   ports are ACTORS — addressable · query-in / stream-out · right-of-way          │
  │                                                                                 │
  │     ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐                    │
  │     │ terminal │   │   chat   │   │   web    │   │  agent   │   … each an entity  │
  │     └────┬─────┘   └────┬─────┘   └────┬─────┘   └────┬─────┘                    │
  │        ▲ │ ▼          ▲ │ ▼          ▲ │ ▼          ▲ │ ▼    query in / stream out │
  │   ─────┴─┴─┴──────────┴─┴─┴──────────┴─┴─┴──────────┴─┴─┴───────  THE BUS ───────  │
  │        │                                                                          │
  │   SUBSCRIBERS (a stream has many):  render ·  agent-observe ·  peer-instance ·    │
  │                                     persist/record                                │
  └───────────────────────────────────────────────────────────────────────────────┘
                                     │  speaks
                                     ▼
  ┌───────────────────────────────────────────────────────────────────────────────┐
  │  WIRE — UERP  (port42-rfc.txt)                                                   │
  │                                                                                 │
  │   ADDRESS   port42://[type]/[identifier]/[optional-path]                          │
  │             types: context · agent · space · content · user · temporal · relation│
  │                                                                                 │
  │   MESSAGES  Query · Response · Update · Subscribe · Notify                        │
  │                                                                                 │
  │   REACH     local  │  another instance  │  a server      (location-transparent)   │
  └───────────────────────────────────────────────────────────────────────────────┘
```

The Face **rides on** the bus; the bus **speaks** UERP. Same spine at three heights: *experience → mechanism
→ wire.*

---

## The contract (six facets)

| Facet | What it is | UERP | In the code today |
|---|---|---|---|
| **Address** | a stable name that reaches a port anywhere | `port42://[type]/[id]/[path]` | id / title (local only) — **cross-instance address is the open work** |
| **Query in** | imperative messages TO the actor | `Update` (+ `Query` for reads) | `push` `exec` `patch` `update` `getHtml` `manage` `restore` `move` `rename` — shipped (P-400, Mar 2026) |
| **Stream out** | events FROM the actor | `Subscribe` → `Notify` | `portCreated`, `port42:data`, PTY bytes, `turnComplete`, height/console — shipped |
| **Right-of-way** | who may write to a port right now | (flags on Update) | focus / keyboard-follows-focus locally — **per-element right-of-way is open** |
| **Subscription** | render / agent / peer / persist are all subscribers to one stream | `Subscribe`/`Notify` | conceptually present; **not yet a unified multi-subscriber path** |
| **Temporal** | "the port as of T" is a first-class address | `temporal` type · as-of Query | `history` / `restore` / `getHtml(version)` — shipped |

**Read the two columns together:** four of six facets already exist in the running bridge. The three gaps —
**cross-instance Address**, **per-element right-of-way**, **unified subscription** — are *exactly*
multiplayer. One contract explains what shipped and what's next.

## The verb map (bridge ⇄ UERP)

```
   getHtml ............ Query  (read state; + as-of ⇒ temporal Query)
   push / exec ........ Update (deliver input / run)
   patch .............. Update (targeted delta — the surgical write)
   update ............. Update (full-set write)
   history / restore .. temporal address (Query as-of / Update to a prior state)
   (event stream) ..... Subscribe → Notify  (render · agent · peer · persist subscribe)
```

`patch` is the **delta verb** — introduced Mar 2026 in the P-400 bridge-symmetry pass, *before* the
port-units refactor, as the *preferred* mutation (only the matched string changes; errors if the search
isn't found). It was placed deliberately as the surgical member of the write family, which is why the
bridge already reads as a replication protocol: snapshot (`getHtml`) + delta (`patch`) + full-set
(`update`) + versions (`history`/`restore`).

---

## Why the Synchronizer is the bus (the placement fix)

`membrane-architecture.md` files the co-held surface as **one faculty in the Face**, a peer of Presenter.
Seen from the mechanism, that under-places it. If a port is an actor (addressable, query-in, stream-out,
right-of-way), then the rest of the Crew are **subscribers and policies over the same bus**:

- **Watcher** — subscribes to every port's stream (the calm, legible view *is* a Notify aggregator).
- **Controller** — gates the **Query/Update** edge (delegation & limits = who may send which query).
- **Guard** — audits the Update log; **temporal** addressing *is* reversibility.
- **Presenter** — one **subscriber** that renders a stream to screen / voice / ambient.
- **Librarian** — persists & re-lends entities (persist is another subscriber; reuse is re-addressing).

So the bus is not *in* the Crew — it is the **substrate the Crew stands on.** The Synchronizer names the
bus from the experience side; this doc names it from the mechanism side.

---

## Prior art & validation (2026-07-15)

- **UERP already specifies the wire** — `port42-rfc.txt` (a mock IETF standards-track memo): `port42://`
  addressing, the entity types, Query/Response/Update/Subscribe/Notify, temporal & relational resolution,
  a DHT discovery layer. The addressing keystone is **written, not open** — it needs wiring to the live
  bridge, not inventing.
- **Bash (`bash.tv`, Dom Hofmann, launched 2026-07-14)** ships the same product shape — human+AI rooms,
  apps-as-messages (their word for a port is **"patch"**), apps-with-embedded-chat, human+AI both drive
  the surface, layout-follows-activity. **Validation, not threat:** it proves the shape is real and the
  timing is live, and it sharpens the pitch — *Bash is the product; the bus is the layer under it.* Their
  "patch" is a surface; our `port42://` is a **protocol**.
- **Transport for the bus** is a solved-elsewhere problem (see the WebRTC / native-ports north stars in
  `../summer2026-todo.md`): most port-sharing is a **data-channel** problem (state replication over the
  Notify stream), and evaluate **go-libp2p** (native to the Go gateway; Circuit-Relay + DCUtR = the
  supernode + hole-punch) before writing any traversal code. Video is the opaque-surface fallback only.

---

## Open (the keystone work, in order)

1. **Address across instances.** Extend `port42://space/<id>/<portId>` to carry the instance, so a query
   reaches a port on another peer the same way it reaches a local one. This is the single foundational
   decision — get it right and subscription + location-transparency follow; get it wrong and multiplayer
   is bolted on.
2. **Per-element right-of-way.** Generalize local focus into "who holds this element/port now," so two
   drivers (human + agent, or two humans) never overwrite each other — the Synchronizer's core guarantee.
3. **Unified subscription.** Make render / agent-observe / peer / persist one `Subscribe` path over the
   Notify stream, instead of four bespoke code paths.

*Build order is a separate plan — deliberately not encoded here (matching `membrane-architecture.md`).*
