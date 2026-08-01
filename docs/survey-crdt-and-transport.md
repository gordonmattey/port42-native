# What to build on: transports and merge libraries

**Surveyed 2026-07-31**, from GM's question about whether a shared chat generalizes to any content,
and whether open-source projects give us a leg up. Checked against current sources rather than
recalled; links at the bottom.

## The ladder, one level up

Three tiers, and they are not three mechanisms.

| tier | what it is | conflict | needs |
|---|---|---|---|
| **append** | chat, logs, terminal output, console | impossible by construction | what milestone B already builds |
| **CAS state** | one driver at a time, stale writes refused | prevented | the token, which exists |
| **merged state** | simultaneous editing, the Google Docs case | resolved | a CRDT |

**The insight that collapses tier 3 onto tier 1: a CRDT update stream IS an append.** Yjs and
Automerge both work by exchanging opaque update messages that are commutative and idempotent —
order-independent, duplicate-safe, union-merged. That is exactly the append tier. So co-editing does
not need new transport semantics, new ordering guarantees or a new delivery contract. **It rides the
append path we already have to build for chat.**

Which means the sequencing is: appends first, and merged state is then a library plus an authoring
contract, not a second distributed-systems project.

## Transport

**go-libp2p — validated, and already measured here.** Spike F built it into the real gateway:
+22.2 MB, 4 ms host start, 0.2% idle CPU, mDNS discovery in ~4 s, a `/port42/uerp/1.0.0` stream
round-tripping in 291–466 µs, gossipsub delivering both ways, all working from inside a Developer ID
signed hardened-runtime bundle. Native to the Go gateway, no new language.

**Iroh 1.0 shipped 2026-06-16, and its headline number is the one this slice bet on.** Reported
hole-punch success is **~90% for Iroh against ~70% for libp2p**, with QUIC and TLS 1.3 directly, and
stateless relays that forward encrypted packets without holding session state. Iroh's own framing is
that libp2p minimizes central points of failure at a cost in effectiveness, while Iroh maximizes
effectiveness at the cost of a little centralization.

**Why that matters more than a feature comparison.** The slice's stated falsifier is a
direct-connection rate across ≥4 real networks, with **≥~80% direct plus clean relay fallback** as
the threshold for "p2p-as-sovereignty is viable". If libp2p caps near 70% in practice, **the slice's
own measurement could fail on the transport rather than on the thesis**, and we would draw the wrong
conclusion about the bet.

**But it is a milestone C question, not a B one.** Milestone B is same-LAN mDNS, where hole punching
does not happen at all. So B proceeds on go-libp2p as planned, and C measures the rate for real. If C
lands near 70%, `libp2p-iroh` exists as a bridge (iroh QUIC as a libp2p transport, Rust) — which does
not help a Go gateway directly, and that cost belongs in the decision rather than being discovered
inside it.

## Merge libraries

**Yjs — the production default, and it already speaks our transport.** ~920k weekly downloads, the
largest ecosystem of bindings and providers. Decisive detail: **`y-libp2p` propagates updates via
GossipSub and includes a peer-sync mechanism to catch up on missed updates.** That is not an analogy
to our design, it is our design: a gossipsub topic per port plus a resync path, which is exactly what
milestone B step 5 specifies.

**Automerge — transport-agnostic by design.** Its sync protocol is explicitly not tied to a
transport and runs over TCP, WebSocket, WebRTC or anything else, with `automerge-repo` providing
pluggable network and storage adapters. No libp2p adapter surfaced in the search, so we would write
one, against a protocol built to have adapters written for it.

**Loro** appears in current comparisons as a third option and was not evaluated here.

**Where the CRDT would live, and it is convenient.** A port is JS in a webview, so a Yjs document
lives in the port itself. The Swift app and the Go gateway never need to merge anything — they carry
opaque update blobs on an append topic. That keeps the merge out of the app entirely.

## What this does to the authoring contract

The UX map found that shareability depends on how a port is written: both sides converge only on
state that flows through the bridge. The CRDT tier sharpens that into something specific and
teachable.

- state in ordinary JS variables and direct DOM mutation → **cannot** be shared meaningfully
- state flowing through `patch` / `push` → **one driver at a time**, CAS
- state in a Yjs document, updates published as appends → **simultaneously editable**

So a port opts into its own concurrency tier by how it holds state. That belongs in the
port-authoring manual, and it is the honest version of "Google Docs for a whole website": achievable,
but as an authoring contract rather than a transport feature.

## Recommendation

1. **Milestone B stays on go-libp2p.** Spike F validated it in our actual bundle, and LAN discovery
   does not exercise the thing Iroh is better at.
2. **Build the append tier properly**, because chat needs it, terminal output needs it, and a CRDT
   rides it unchanged.
3. **Treat milestone C's measurement as a transport verdict, not only a thesis verdict.** If the rate
   lands near 70%, that is a libp2p number rather than a p2p number, and Iroh is the retest.
4. **Evaluate Yjs first if we do tier 3**, on the strength of `y-libp2p` already using gossipsub plus
   peer-sync.

## Open

1. Does anything need to merge in **Swift**, or does the CRDT stay entirely in the port's webview?
   The latter is much cheaper and appears sufficient.
2. `libp2p-iroh` is Rust. If C pushes us toward Iroh, what does that mean for a Go gateway?
3. Loro unevaluated.

## Sources

- [Yjs](https://github.com/yjs/yjs) and [Yjs docs](https://docs.yjs.dev/)
- [Automerge Repo](https://automerge.org/automerge-repo/) and [Network Sync](https://automerge.org/docs/tutorial/network-sync/)
- [Iroh 1.0 ships](https://www.techtimes.com/articles/318490/20260616/peer-peer-library-iroh-10-ships-dial-devices-key-not-ip-address.htm)
- [Comparing Iroh and libp2p](https://www.iroh.computer/blog/comparing-iroh-and-libp2p)
- [libp2p-iroh](https://github.com/rustonbsd/libp2p-iroh)
- [Yjs vs Automerge vs Loro, 2026](https://www.pkgpulse.com/guides/yjs-vs-automerge-vs-loro-crdt-libraries-2026)
