# Slice-02: decisions, risks, and the design work each implies

**Opened 2026-07-31**, before step 2, so the reasoning is on paper rather than in code. Companion to
`membrane/slice-02-cross-instance.md`; this file holds what was decided and what is still uncertain,
not the build order.

---

## Decisions (GM, 2026-07-31)

### D-a · The transport is a seam, not a choice made now

Iroh 1.0 reports ~90% hole-punch success against libp2p's ~70%, and this slice's own falsifier is a
~80% threshold. So **milestone C's number could be a transport verdict masquerading as a verdict on
the thesis.**

Deciding now would mean choosing on someone else's number before measuring our own, and both options
carry real cost: Iroh is Rust against a Go gateway (FFI, sidecar or rewrite) and shipped 1.0 six
weeks ago; go-libp2p is validated inside our actual signed bundle by spike F, and the Yjs ecosystem
(`y-libp2p` over gossipsub) sits on that side.

**Decision: build B on go-libp2p, and keep the transport behind a narrow seam** so C's measurement
can force a swap rather than a rewrite. Both provide the same three things: dial a peer by key, open
a stream, publish and subscribe to a topic.

*Design work:* define that three-verb surface in one file. **No plugin architecture for two
implementations** — one narrow interface, no framework.

### D-b · Chat over gossipsub gets a spike

Approved. Chat working today is the baseline that makes it cheap: swapping a transport under
something that demonstrably works is a real test, where a thing that never worked proves little.

*Design work:* what "sync" means for chat when peers were offline. Appends make merging trivial;
delivery is the question, not conflict.

### D-c · The port-authoring contract goes in the manual, and it is a GENERATOR problem

Both sides of a shared port converge only on state that flows through the bridge. A port holding
state in JS variables and mutating its own DOM diverges silently, and it looks like a bug in sharing
rather than a bug in the port.

**GM: no backward compatibility needed, old ports do not matter.** Correct, and the sharper point is
that this was never really about old ports: **ports are written by companions on the fly, reading
`ports-context.txt`.** If the rule is not in the manual the generator reads, every newly generated
port is a coin flip on whether it can be shared.

*Design work:* the rule stated in the authoring manual, and probably a way for a port to declare
which of its writes are appends (see `design-append-writes.md`).

### D-d · A permission is a message that gets a reply

Today a gateway call blocks until a human clicks, measured at 12 seconds in §10a3. Over a wire, with
nobody at the far machine, that becomes a hang and then a timeout with no explanation.

**Decision: asynchronous.** The caller gets "pending" immediately and the outcome when the human
acts. The machinery already exists — step 5 built `stream` frames and endless subscriptions — so a
pending permission is an event on a stream a caller can already receive.

**It fixes the local case too**, not only the remote one. Nothing should block on human latency
anywhere.

*Design work:* the pending state has to be legible, which is the next section.

---

## Failure legibility: can the user tell it will not work, and what else can they do?

FR10 says every refusal states how to fix it. Async introduces a state that is **not** a refusal —
asked, waiting, may never resolve — and the guest must be able to tell these apart:

| state | what it means | the alternative offered |
|---|---|---|
| this port needs nothing from the host | self-contained; it just works | none needed, and the guest should never see a prompt |
| the host is offline | `host_offline` exists; the port cannot serve | show the port as dormant, not broken. Retry when they return |
| the host is present, has not looked | pending. **Not a failure** | tell them it is waiting on a person, and who |
| the host declined | a real refusal | say so plainly, and do not re-ask on every click |
| the guest is not enrolled | `auth_required`, already carries its fix | the enrolment route |

**The rule worth holding: a spinner is not an answer.** Three of those five states are indefinite,
and today they would all look identical to a guest.

---

## The case that may reframe the feature: your own instance, on another machine

**GM, 2026-07-31:** *"you could have your own instance on another machine also driving your machine as
if it was you. That is how the iOS app would work."*

This is probably the **primary** case rather than a variant of friend-sharing, and it changes two
things.

**A person and a device are different things, and the model must not conflate them.** Your identity
is the P-256 key. **Each install must derive its OWN PeerID**, or two Macs of yours produce the same
peer and addressing collapses — the requirement already flagged in the slice doc's step 2. So a
person has many devices, and `<devicePeerID>/<yourUserId>` says "me, on my iPhone". That shape is
already expressible: `ActorRef` is `<peerID>/<principal>` and the spike showed grants key on the pair
cleanly.

**The consent posture is different.** A friend's instance asking for filesystem access is a stranger
at the door. Your own phone asking is you, and being prompted repeatedly for your own devices would
be noise rather than safety. But standing access for "your devices" is exactly the shape of the
blanket pre-grant D12 deleted, so it cannot simply be waved through.

*Open:* does a device you enrolled get broader standing than a peer you invited, and if so, what
distinguishes them at the grant level? The honest answer is probably that a device is still a peer,
still asks, but asks **once per capability rather than once per session** — which is what grants
already do.

---

## Risk register, ranked by damage if wrong times how late it surfaces

| # | risk | kind of action | cost |
|---|---|---|---|
| 1 | **C's number is a libp2p verdict, not a p2p verdict.** Can invalidate the whole bet, and surfaces last | **spike**: run spike F's harness and an Iroh equivalent from a tethered phone and a café, before writing C | half a day |
| 2 | **The messaging migration**, if "no legacy gateway-to-gateway" is in this slice. Store-and-forward, offline delivery and per-space encryption all assume one central gateway. Unknown size, and it would dominate | **spike**: chat between two instances over gossipsub, against today's working baseline | D-b |
| 3 | ~~Existing ports are unshareable~~ | **closed** by D-c. Not legacy, a generator contract | manual edit |
| 4 | ~~Permission at a distance hangs~~ | **closed** by D-d, async | design below |
| 5 | **Routing `window.port42` from guest to host.** The mechanism does not exist; ports are in-process by construction (CR1). The principal shape is proven, so what remains is plumbing | **spike**: proxy one bridge call between two instances over the existing gateway. No libp2p needed | small |
| 6 | **The invite path may have rusted.** It leans on ngrok end to end and step 2 builds on it | **measurement**: send one and click it | minutes |
| 7 | **"One retry lands" at N writers.** Correctness holds at any number; only contention degrades | measure at step 6, free | none |
| 8 | **Peer id persistence** | mostly closed by spike F: the derivation is deterministic | none |

**The useful shape:** only 1, 2 and 5 are real spikes. 6 is a measurement, 3 and 4 are now decisions
with design work attached rather than unknowns.
