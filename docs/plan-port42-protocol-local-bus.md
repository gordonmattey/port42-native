# Plan: the Port42 protocol, proven locally

***THE single plan for the protocol thread.** Rewritten at the head 2026-07-26 — everything below
§A is the detailed record (phases, spikes, findings), and §A is the plan those details serve. If the
two ever disagree, §A wins and the detail is stale.*

*Canonical register of primitives: `architecture-invariants.md` — a reference, not a plan. It says
what must have one definition and whether it does. This doc says what we build and in what order.*

---

## A. The whole thing in one frame

**A protocol write is three nouns: an ADDRESS, an ACTOR, and a TOKEN.**

> *port `X`* · *by `Y`* · *composed against state `Z`*

That is the entire contract, locally and over the wire — slice-02 changes the transport and nothing
else. **Each noun must have exactly one definition, or the protocol lies the moment there is a second
instance.** Everything in this plan is one of those three nouns being made single-definition and
honest. Nothing else belongs here.

| Noun | Means | State |
|---|---|---|
| **ADDRESS** | which port | ✅ **done 2026-07-26.** `PortRef.key` — one definition, was three. Inline ports were unaddressable and had no protection at all. |
| **TOKEN** | which version of it | ⚠️ **mechanism done, not yet honest.** R2/R3 ship the counter and CAS. But a token only tells the truth if EVERY mutation counts, and today terminals and browsers have ways in that do not. |
| **ACTOR** | who is writing | ✅ **done 2026-07-27 (I1.1–I1.5).** Measured first, which found two holes neither plan had named and killed the one both led with. One private constructor; a gateway-created port authorizes as itself, not as the shared `local-http`; no identity is a heap address. Remaining: I1.6, attribution follow-through. |

### Definition of done

**A write to any port, from any surface, carries all three nouns; each has one definition; and the
token is honest because every way in counts.** At that point the local protocol is complete and
slice-02 is a transport change rather than a redesign.

### Why the input seam is in this plan and not new scope

It looked like new scope, and it is not. **It is what makes the TOKEN honest.** The token is a claim
about "has this port changed since I looked" — and that claim is false for any mutation that does not
count. Measured this session: dictation, the emoji picker, right-click paste and a cross-app drag all
changed a port while the token stood still. Fixing the web listener closed those four; terminals and
browser navigation are still open. Until every way in counts, R5 ("terminals REQUIRE a token") would
be enforcing a guarantee we cannot make.

### The sequence

Flat. Each line ships on its own. Plans do not nest below this.

| | Step | Noun | Why here |
|---|---|---|---|
| ✅ | L2 R1 · demote the lease to presence | actor | a lock could never cross the wire; clocks do not agree between peers |
| ✅ | L2 R1b · rename + throttle fix | actor | the code called it a lease while doing presence |
| ✅ | L2 R2 · activity token | token | `<epoch>:<seq>`, peer-shaped from day one |
| ✅ | L2 R2b · one surface writer | token | every pty write counts, verified by grep |
| ✅ | L2 R3 · CAS + `port.getDom` | token | the first step that refuses anything |
| ✅ | `PortRef.key` | address | one definition, was three |
| ✅ | port sandbox (origin pin) | actor | a P0: a port could navigate away and take the bridge |
| ✅ | I1 · Identity | actor | §B. Measured first, which killed the defect both plans led with and found two nobody had named |
| ▶ | **I2 · the input seam** | **token** | §C. Every way in counts → makes R5 honest. C0 + C1 done; C2.0 next |
| | L2 R4 · pty choke point | token | @mention and `port.push` covered identically |
| | L2 R5 · terminals require a token | token | only sound after I2 |
| | L2 R6 · presence lifetime | actor | turn-scoped, no chip flicker |
| | L2 R7 · native claim | actor | move the human's claim off shadowable `isTrusted` |
| | **then: slice-02** | — | the same three nouns over libp2p |

**Not in this plan**, though real and registered: the output seam, the error taxonomy, trust beyond
R7. They are quality, not protocol completeness. See the register.

---

## B. I1 · Identity — the ACTOR noun · **IN PROGRESS**

**First because presence and CAS are both built on `principal.id`.** Anything identity gets wrong is
already inherited by both guarantees shipped this session. `decision-identity-model.md` settles
person/instance/actor in prose; nothing enforces it in code.

### I1.1 is DONE (2026-07-27), and it did not confirm this section. It replaced it.

`ActorProbe.swift` (DEBUG only) registers a fallback identity as SYNTHETIC at the site that mints it,
then records any dispatch whose principal id is one of those. Membership is the test rather than a
string match, so the instrument cannot drift when a fallback string is edited. Live tally at
`/tmp/port42-actor.log`, rewritten in place, so a per-keystroke path cannot bury the one call that
matters.

**What the previous draft of this section said was broken:**

```swift
Principal(id: createdBy ?? "anonymous-tool-caller", …)   // ToolExecutor:75, :92
```

**That fallback is UNREACHABLE, and I1.5 deleted it.** `ToolExecutor` has exactly one production construction site
(`AppState.swift:139`), which passes `createdBy: agent.id`, and `AgentConfig.id` is a non-optional
`String`. All eight test sites pass a real id too. The `= nil` default on the init parameter is the
only thing that keeps it looking live. Zero probe hits across a full session, agreeing with the source.

### The two holes that are real

**1. Every gateway-created port authorizes as `local-http`, and the bucket already holds a grant.
FIXED in I1.3 (2026-07-27).**

`port.create` sets `createdBy: p.id` (`BridgeMethods.swift:169`). From the gateway that id is the
deliberately-shared `local-http`, so the port's `PortBridge.createdBy` is `local-http` and
`portPrincipal` takes **rung 1, the rung that looks attributed** because a real non-nil string flows
through it. It pools anyway. Measured: two independently created ports both dispatched as
`id=local-http surface=port space=set`. Persisted in Dev3:

```
portPerms.local-http.4C7AE45B-501D-4E3E-B9AD-5563F9C354CF = automation
portPerms.local-http.global                               = ai
```

`automation` is `runAppleScript` and `runJXA`, so driving other applications. Any port created through
the gateway in that space inherits it silently and permanently. Gateway-created ports are how Claude
Code works against Port42, so this is the ordinary path.

**The P-260 rule is not wrong; its precondition is.** "A port acts as its creator, one bucket per
author per space" assumes the creator is an author. `local-http` is not an author, it is every local
process, and extending that sharing to ports was never a decision anyone made.

**2. Every space's chat port authorizes as a heap address. FIXED in I1.4 (2026-07-27).**

`PortWindowManager.swift:1020` (`ensureChatPort`) and `ShellView.swift:1512` (the ambient background
port) both construct with `messageId: nil, createdBy: nil`, so `portPrincipal` falls to rung 3,
`ObjectIdentifier(self).debugDescription`. That fails in a different direction from pooling: the id
changes every launch, so a grant against it can never restore, and an address is reused after dealloc,
so a later object can inherit a grant issued to a different one. **Reachability is proven from the two
construction sites; no dispatch was ever observed.** Fixed by giving all three sites an explicit
`stableIdentity`. The probe still reports `rung=objectIdentifier` if a fourth site appears.

### Revised steps

| # | Step | Gate |
|---|---|---|
| ✅ I1.1 | **Instrument and measure.** | DONE 2026-07-27. Produced a list of real callers that contradicts the list this section was written against. |
| ✅ I1.2 | **One constructor.** | DONE 2026-07-27. Memberwise init private; four surface factories, two policy factories. The gate is the COMPILER (`initializer is inaccessible`), calibrated by reintroducing a call; a package-wide scan is the backstop. |
| ✅ I1.3 | **A port created by a SHARED identity gets its own, it does not inherit.** | DONE 2026-07-27, **GM chose to un-pool everything.** Two gateway-created ports cannot see each other's grants. Calibrated: reverting it fails the gate with both ports reading `local-http`. |
| ✅ I1.4 | **Chat and ambient ports get a stable identity.** | DONE 2026-07-27. `PortBridge.stableIdentity`, passed by `ensureChatPort` (the panel id), the DB restore path (`row.id`) and the shell background (a fixed constant). Calibrated: reverting the fix fails the test with two different heap addresses for one port. |
| ✅ I1.5 | **Delete the dead fallback.** | DONE 2026-07-27. Removed as DEAD, not fixed. `ToolExecutor.createdBy` is now non-optional, so the hole cannot be reopened at a call site. |
| ✅ I1.6 | **Presence and token attribute correctly** under I1.3 and I1.4. | DONE 2026-07-27. Every surface's driver name pinned by `DriverAttributionTests`; live-confirmed in Dev3 for the gateway (`Local (gateway)`) and the human (their display name, taking over immediately, which is R1b's throttle fix working). |

**I1.6 found a live defect that was on no list.** The driver chip's tooltip read *"your writes are
refused until they finish"*. **R1 removed the refusal** three steps earlier: presence refuses nothing,
last driver wins, and what actually refuses is CAS against stale state. This is §D's untruth again, but
in-product rather than in marketing copy, so it is a defect and not a positioning call. Fixed, and
pinned by a scan over user-facing strings (comments excluded, so the record of the fix is not itself an
offence). Calibrated: the original tooltip trips it.

**I1 is COMPLETE.** Next is I2, the input seam (§C).

**Why I1.4 did not just pass `messageId`.** It looked like the one-line fix (`ensureChatPort` mints a
UUID one line above the bridge and drops it). But `messageId` drives panel dedupe, inline bridge lookup
and owner routing, which are ADDRESSING concerns, and this is an AUTHORIZATION concern. Overloading it
would have changed three behaviors to fix one. `stableIdentity` is separate and feeds only the
principal's last rung.

**I1.2 stops being hygiene and becomes the fix.** Both holes are shapes a memberwise init taking any
`String` cannot refuse: it cannot tell a heap address from an identity, and it cannot tell an inherited
shared id from an authored one. Fixing the two sites without the constructor only resets the clock.

### I1.3 as decided and built (GM, 2026-07-27: un-pool everything)

**The cost accepted: prompts.** Each gateway-created port is its own grant bucket, so a session
creating four ports that want permissions asks four times where it asked once. The alternative
granularity (share per Claude Code SESSION) is unavailable because **the gateway authenticates
nobody**, so there is no session to key on. That is `plan-gateway-auth-tls.md` P1, open. Revisit
sharing when P1 lands; `Principal.isSharedIdentity` is the one place that changes.

**How it was built.** `createdBy` is skipped as an authorization identity when it is shared, so the
port falls to rung 2 and authorizes as ITSELF. `createdBy` remains the PROVENANCE record: still
stored on the panel, still returned by `ports.list`, still resolving the port's AI model. **"Who made
this" and "what it may do" stopped being the same field**, which is what made this a one-line policy
change rather than a sweep.

The permission card names the PORT, not the gateway. Naming the creator would have asked the human to
grant to "Local (gateway)" while the grant landed on one port, which is the opposite of informed
consent.

**Migration debt, not fixed here:** existing installs keep orphaned `portPerms.local-http.<space>`
keys, which nothing reads any more (ports use their own id; gateway calls are space-less and read the
global bucket). Dev3 still holds an `automation` one. Harmless while unreachable, worth a cleanup
decision because it is a real grant sitting in storage.

### The method finding, which outlasts the specific bugs

The list this section was built from came from counting `Principal(` construction sites and fallback
strings. **It could not have found either real hole.** Hole 1 has no fallback at all, so a source scan
sees an attributed caller; hole 2 needed a caller list rather than a code read. The rung the scan
flagged loudest is dead.

That is the third instance of the same failure in this thread, after finding 7's three sweeps and
Spike C's guessed labels. **A property about who calls in is not decidable by reading the callee.**
The probe stays wired while I1.2 to I1.6 land, as the regression detector.

---

## C. I2 · The input seam — making the TOKEN honest

*Was `plan-input-seam.md`; folded in here 2026-07-26 so the protocol has one plan. Not called "the
membrane" — `docs/membrane/` uses that for the whole experience layer.*

The frame is already public: *"a human and an agent reach the same surface through **one bridge**, with
the same methods and the same permissions."* Five caller types are named there and **all are
programmatic**. A person typing, dictating, pasting or dropping touches no bridge at all. So this is
the missing half of a promise already made.

**Six seams today**, split by surface technology, which is why three separate sweeps each missed a
path. One door instead. **As built in C1** (2026-07-27):

```swift
struct PortInput {
    let port: String        // PortRef.key
    let kind: Kind          // .text(String) | .gesture | .navigation(URL) | .programmatic
    let actor: ActorRef?    // nil = nobody to attribute it to. See below.
    let actorName: String?  // display only; a label never becomes part of an identity
    let trust: Trust        // .native | .reportedByPage | .principal   ← R7 lives here
}
struct PortInputSeam {                       // owns the tables; pure, no bus/view/clock
    mutating func received(_: PortInput, now: Date) -> Outcome   // { token, driverChanged? }
    mutating func portClosed(_: String)
}
```

**`actor` is OPTIONAL, against this plan's original sketch, and the reason matters.** I1.1 measured
native input arriving with nobody to attribute it to (before setup completes, `humanPrincipal` is
nil), and the app writes to a pty at spawn time on behalf of no one. Forcing a value would mean
inventing an identity for those paths, which is exactly what I1.3 forbade after finding every
gateway-created port pooled into one shared id. **nil is a real answer: the port changed and we do not
know who.** The token still moves, because it must; presence records nothing, because naming a driver
would be a lie.

That is also what kept the design at four fields. Whether to record presence is **not** a flag, it
follows from whether an actor exists, and a flag would have been the fifth field the recorded risk
below warns about.

`received` returns what the caller must then do in the world rather than doing it, so the policy
reaches no bus, view or clock and tests without an app.

**The enforcement is privacy, not discipline.** `portActivity` and `portDrivers` become private to the
seam, so any path that wants to affect them must build a `PortInput`. A compile error, not a code
review — "remember to call the thing" has failed four times in this subsystem alone.

**Scope, corrected 2026-07-27: 6 mutation sites** (3 bump, 1 record, 2 forget) **plus 4 READ sites**
(`BridgeMethods` ×2, and the dispatcher's CAS check and throttle check). Reads travel with writes:
making the fields private breaks them too, so C4's scope is ten sites, not six. The seam already
exposes `token(for:)` and `driver(of:)`, so nothing is blocked.

**The translator count is unknown, and this plan should stop asserting one.** It said 8 (7 existing
plus browser navigation); C0 then collapsed the two terminal translators into one, so it was already
stale on the day it was written. Re-derive it when C2 runs, and do not trust the result. See the
reframe below.

| # | Phase | Gate |
|---|---|---|
| ✅ C0 | **Collapse the terminal duplication.** One factory taking `(panel, config)`. | DONE 2026-07-27. Found a THIRD site (`PortWindowManager.restart`) doing one of five steps, leaving a controller bound to no surface. `bothHostsWireIt` replaced by a tree-wide walk asserting exactly one builder. |
| ✅ C1 | The door: `PortInput` + the seam, fields still internal. | DONE 2026-07-27. Pure tests, nothing calls it. `actor` had to become optional (above). |
| ▶ C2.0 | **Ownership first.** `AppState` holds ONE seam; its three fields go; reads forward to it. | **This step is new and it is a correctness prerequisite, not tidiness.** See below. |
| C2.1..n | **Delete a passthrough; the compiler names its callers; convert those.** One commit each, each LIVE-verified. | Independently green, behaviour identical, path observed counting in Dev3, and the passthrough gone. |
| C6 | **Re-measure every surface, the way Spike C did.** | The class no compiler can find (below). Without this, R5 is unsound however clean C4 leaves the routing. |
| C3 | Browser navigation via KVO on `webView.url`. | A page-initiated navigation bumps the token (Spike B: `didCommit` misses SPA route changes). |
| C4 | **Flip the fields private.** | The compiler names every path missed. This is the phase that matters. |
| C5 | The streaming registry joins. | A streaming write verb cannot escape. |

### C2.0 exists because the tables would otherwise be split in two

`AppState` owns `portActivity`, `portDrivers` and `presenceThrottle`; the seam owns its own. **Move one
translator onto the seam and it bumps the seam's table while every reader still reads AppState's.** A
port's token would be split across two counters for the length of the migration, which is precisely
the lie the seam exists to prevent, introduced by the work meant to prevent it.

So ownership transfers atomically first, and only then is "one translator per commit" actually
independent.

### TWO failure classes, and only ONE of them is a compiler's job

This plan has been blurring them together, and R5 depends on the harder one.

**WRONG CALLER: a path mutates the tables directly instead of through the door.** The compiler finds
every one of these the moment the direct route is deleted. C2.0 proved it by accident: removing
`AppState.portActivity` surfaced an eleventh site that two careful hand-derivations had missed, because
it BINDS the value (`let activity = appState.portActivity`) rather than calling through it, and a grep
for `portActivity.` cannot see that shape. **C4 closes this class completely**, and C2.1..n now closes
it incrementally by deleting one passthrough at a time.

**MISSING CALLER: a path changes the port and touches the seam not at all.** Dictation, the emoji
picker, right-click paste, a cross-app drag, an SPA route change. **No compiler will ever find these**,
because there is nothing that fails to compile. Spike C found three only by measuring, and measured the
web listener at 8 of 11 real content changes.

**R5 ("terminals require a token") depends on the SECOND class.** So "C4 is the phase that matters" is
true for routing and false for honesty: finishing C4 proves nothing bypasses the door, never that
everything arrives at it. C6 exists because declaring the token honest on C4's evidence would be
exactly the "asserted rather than measured" error this thread has now made three times.

### C2 is preparation. C4 delivers ROUTING. C6 delivers HONESTY.

This plan had the weight the wrong way round, treating C2 as the bulk and C4 as a finishing move.
**Reverse it.** The reason is the finding this whole thread keeps re-proving: **enumeration
undercounts, every single time.** Five instances now (finding 7's three sweeps, Spike C's 8-of-11,
C0's third build site, I1's two unlisted holes, I1's dead headline defect).

C2 was an enumeration phase, and C2.0 showed how to stop it being one: **delete the direct route and
let the compiler produce the list.** Effort spent hand-deriving translators is wasted, and demonstrably
so, since two careful passes still missed a site the type system found in seconds.

**The transitional passthroughs are a liability while they exist**, because the seam then has two
doors. They should die fast, one per commit, rather than linger.

### Method, carried from I1 (all four earned the hard way)

- **A gate scoped to named files is not a gate.** `bothHostsWireIt` named two files and a third site
  walked past it; the old `Principal` scan was per-file and both live holes hid behind it. Tree-wide
  walks only.
- **Calibrate every gate by breaking it.** Two written this session were wrong on first draft and
  passed anyway (a scan that matched its own source; an attribute orphaned by an insertion). A gate
  that has never failed has not been shown to work.
- **Green tests cannot see a lost closure.** C0's suite passed before a real terminal was spawned and
  its token watched moving. Rewiring is the class of change where the types are satisfied and the
  behaviour is gone.
- **Done means live-verified, not committed.** P0 sat three days behind a doc that said `SHIPPED`.
- **A scan for "who touches X" must match BINDING, not just calling.** `a.b.method()` and
  `let x = a.b` are both uses; a pattern for `X.` sees only the first. That shape hid the eleventh
  site from two hand-derivations (C2.0).

Dictation and remote peers are then translators, not phases — which is the test of whether the seam is
shaped right, and weak evidence, because both cases were chosen by the person proposing it.

**Decisions (GM):** a gesture bumps the token (a canvas click can change everything with no
`beforeinput`); input only, not output; Port42 owns dictation as a translator; per-port, not the old
spec's per-element.

**Recorded risk, now PINNED by a test (C1):** `PortInput` has four fields because four things need it
today. If a fifth is added for a CONSUMER rather than a SOURCE, it has become a bag and the design
failed. `PortInputSeamTests` asserts the stored-property count, so adding one is a deliberate act with
a test to change rather than a drift. Calibrated: a fifth field fails it with this reasoning in the
message.

---

## D. A published promise R1 made untrue

The architecture page says right-of-way *"decides who acts"* and lets you *"take the pen from an agent
mid-task and hand it back."* R1 removed the deciding; the handoff verbs were deferred and never built.

**Call: change the copy, do not build the knock.** "Take the pen" is a lock's ergonomics, and under CAS
you do not need to take anything — your write cannot be clobbered. Suggested replacement, weaker-
sounding and actually stronger because it is a guarantee rather than an arbitration:

> When two callers reach the same port, you can see who is driving — and a write composed against stale
> state is refused, not applied.

---

*Everything below is the detailed record: the original phases, the L2 revision, Spikes A–C and
findings 1–7. Accurate as history; §A governs.*

---

## Original framing (2026-07-22)

*Status at the time: PLANNED, no code. Read-level architecture spike done (four traces, cited below).*

Related: `membrane/bus-architecture.md`, `port42-rfc.txt` (UERP, the address + verb north star),
`membrane/slice-02-cross-instance.md`, `plan-api-unification.md` + `plan-phase3-principal.md`.

---

## 1. The slice in one line

> A port is an **addressable actor**: you resolve it by `port42://` address, send it a query, and
> subscribe to its stream — uniformly across web, terminal, and browser ports, **all within one
> instance**. When this is green, cross-instance is a prefix on the address plus a transport swap; the
> contract does not change.

This proves bus-architecture keystones **#1 address** and **#3 unified subscription** locally, with the
**#2 right-of-way lease** as a fast-follow. Transport (libp2p vs the current WebSocket gateway) is out
of scope here by design: the whole point of proving it local-first is that the contract is
location-transparent, so transport slots under a proven contract instead of being co-designed with it.

## 2. Where the stack already is (the two shipped layers this rides on)

The protocol is a four-layer stack; the bottom two shipped, so the shape is right at the app-contract
level:

- **Message layer (SHIPPED, `plan-api-unification.md`).** One registry, one impl per method, one
  `BridgeValue` shape, reached identically by every caller through the single choke point
  `AppState.runBridgeMethod(name, principal, args, pregrant) -> BridgeValue` (`BridgeDispatcher.swift:25`).
  A streaming twin `runBridgeStream` (`:56`) already produces >1 output per call.
- **Identity layer (SHIPPED, `plan-phase3-principal.md`).** An authenticated principal carried end to
  end; grants key on `principal.id`. `Principal` already carries `portId` (the specific live port) and
  `spaceId` (`Principal.swift:15`), and its doc comment states `portId` exists "for owner resolution
  (event routing)". `portId` is deliberately excluded from `==` so it never splits a grant bucket.

**Four of six bus facets already run** (per `bus-architecture.md`): Query in (`push`/`exec`/`patch`/
`getHtml`), Stream out (per-type, see §4), Temporal (`history`/`restore`), local Address (bare id). The
three gaps are exactly this slice: a real cross-addressable **Address**, unified **Subscription**, and
**right-of-way**.

## 3. The architecture decision (settled by the spike)

**Shape (A): the bus is a thin layer around the existing registry, not a rewrite of it.** Rejected shape
(B) — reframing every registry method as a Query/Update actor mailbox — is unnecessary. Evidence:

- Dispatch keys on a **string name**, and the target port is passed as an ordinary `id` **argument**
  resolved inside the method body (`BridgeDispatcher.swift:25`, method bodies in `BridgeMethods.swift`).
  There is no addressing layer between caller and method today — that absence is the seam.
- So an **address resolver slots between the dispatcher and the method bodies** without touching the
  registry contract. It consolidates a real fragmentation the spike found (§3.1).
- The Notify path **reuses the `BridgeStreamMethod` dispatcher + adapter pattern** (`BridgeRegistry.swift:74`),
  generalized on two axes (§3.2).

### 3.1 The address resolver consolidates three scattered id→port tables

`id→port` resolution is fragmented today, which is also why a bare `id` is polymorphic (UDID **or**
terminal name **or** title):

| Resolver | Backing table | Match semantics | Callers |
|---|---|---|---|
| `webView(_ id:)` (`BridgeMethods.swift:110`) | `portWindows.webViews` / `findInlineBridge` | UDID exact | `port.exec`, web `port.push` |
| `resolveTerminalController(idOrName:)` (`AppState.swift:2760`) | `terminalControllers` | fuzzy id-or-companion-name | terminal `port.push` |
| `findPort(by idOrTitle:)` (`PortWindowManager.swift:765`) | `panels` | UDID exact, then title | `port.manage` |

Routing between them exists only in `PortPushRoute.classify` (`PortPushRoute.swift:13`), and only for
`push`. The resolver's real job: **one `resolve(address) -> PortRef` over all three tables**, with a
`PortRef` that names which surface it is (web / terminal / browser) so the Query and Notify paths branch
once, in one place, instead of per method.

### 3.2 The Notify fan-out reuses BridgeStreamMethod

`BridgeStreamMethod` already solves the hard parts of a Notify stream: unified auth/dispatch, per-surface
`yield` fan-out (port JS → `_tokenCallback`; gateway → chunked; tool-use → collect), cancellation via a
tracked `Task`, and terminal value/error semantics. Two generalizations turn it into a bus:

1. **Typed event, not a bare token.** `yield` carries `String` today; a Notify carries a typed envelope
   `{ topic, kind, payload }` so web dicts, terminal line-batches, and browser nav events all fit one
   shape.
2. **1:N, not 1:1.** Today one call → its own callback. A Notify needs a subscriber registry keyed by
   topic. The `bus.*` mechanism already uses a `port:{portId}` topic convention (`BridgeMethods.swift:1104`),
   so the topic key exists; what's missing is an **in-memory** fan-out (there is no general
   `PassthroughSubject`/observer registry in Services today beyond the single `portCreated` subject —
   `PortWindowManager.swift:110`).

## 4. Across ports: the three publish attach points (the "particularly terminal and browser" answer)

Each port type has a concrete, already-present seam to publish its native stream into the Notify bus.
None forces a pixel/video fallback.

- **Web** — `pushEvent → port42._emit` (`PortBridge.swift:389`). JS-side listener fan-out already exists
  (`_emit` walks `_listeners[event]`, `PortBridge.swift:486`). Native side has no fan-out; add a native
  publish alongside the JS inject. Inbound channels stay the three handlers (`port42`/`portHeight`/
  `portConsole`).
- **Terminal** — the preserved no-op `onFlush` at `GhosttyTerminalController.swift:129` (`{ _ in }`).
  `TerminalOutputProcessor.onFlush` emits **batched, ANSI-stripped, deduped clean lines** (a `String`),
  on a path **parallel to rendering** (the Ghostty PTY tee feeds both). Replace the no-op with a publish.
  **This also cashes out open item 3.4** (native terminal output-streaming bridge). Two caveats to carry
  into the design: it is batched/debounced (prompt-detect / 3s quiet / 8KB), not a live byte stream; and
  the only TUI guard today is a coarse claude/gemini name check (`CompanionPostGate.hooksCapable`) — there
  is **no alt-screen probe**, so streaming an ad-hoc `vim`/`htop` in a non-hooks terminal would emit
  redraw garbage. The bus must gate terminal Notify behind that guard and document the limit.
- **Browser** — already emits structured `browser.load/redirect/error` via `pushEvent` (`BrowserBridge.swift:334/373/391`).
  It is a **WKWebView we own** (`.nonPersistent()` data store), so richer streams (DOM, console, network)
  are reachable by adding `WKScriptMessageHandler`/observers later; nothing forces pixels. **The
  integration gap:** the headless `BrowserBridge` has the query + stream, but the **visible tiled browser
  port** (`portType == "browser"`, `ShellDesktop.swift:870`) is a *different* WKWebView with no
  `browser.*` interface wired to it. Making the on-screen browser an addressable actor = connecting the
  tile to the `BrowserBridge` query/stream plumbing. This is the one genuinely new sub-build in the browser
  path.

## 5. The RFC reconciled to the working contract

The RFC (`port42-rfc.txt`) is a mock-IETF memo from mid-2025. Keep the spine, drop the theater. This is
the durable-vs-evolve split so the address grammar we build to is decided:

**Durable (build to these):**
- Address grammar `port42://[type]/[id]/[path]`. For a running port, the local form is
  `port42://space/<spaceId>/<portId>` (the `<peerID>` instance segment is the cross-instance prefix,
  added later). Reuse the existing `URLComponents` host-switch parser convention (`SpaceInvite.parse`
  `SpaceInvite.swift:56`, `AgentInvite.parse` `AgentInvite.swift:55`); add a port-addressing host, which
  is net-new (today the host axis is only `{agent, space, openclaw}`).
- The five verbs Query / Response / Update / Subscribe / Notify — they already map onto the shipped bridge
  verbs (verb map in `bus-architecture.md`).
- Location transparency and temporal addressing (already live as `history`/`restore`).

**Evolve or drop:**
- The binary wire format (RFC Figure 2) — the live bus is JSON; keep it JSON.
- The proof-of-work DHT discovery — deferred; slice-02 already softens it to mDNS→Kademlia.
- The seven entity types — reconcile to what shipped (`context`≈`space`; `content`/`relation`/`temporal`
  partly = creases/fold/history), do not preserve verbatim.
- IANA "reassign port 42" — flavor, not a constraint.

Treat `bus-architecture.md`'s six-facet contract as the working spec; treat the RFC as the address+verb
north star.

## 6. The build, in phases (address + subscription first, lease fast-follow)

### Phase L0 — the address resolver (keystone #1) — CONSOLIDATE variant (GM, 2026-07-22)

**STATUS: SHIPPED (2026-07-23), verified live.** `PortAddress` + `PortResolution` + `PortAddressTests`
(13 green) landed; `AppState.resolvePortRef` gathers the live candidate lists and calls the one
resolution rule; all nine by-id methods (`push`/`exec`/`getHtml`/`history`/`manage`/`update`/`patch`/
`restore`/`move`) route through it. Live-verified in Port42Dev: web+terminal push, and `getHtml`/`update`
now resolve by **title/name**, not just UDID (parity preserved for UDIDs). All ten by-id methods
(the nine above + `rename`) route through the resolver; `PortPushRoute` is deleted (precedence lives in
`PortResolution`); `BridgeResolverGateTests` is the source-scan invariant that keeps it that way.
Commits `0a2fc9d`, `e40a0ae`, `7833704`, `682e21a`. **L0 DONE.** **Next keystone: L1 (unified
Subscribe→Notify).**

**Decision (GM 2026-07-22):** consolidate, not minimal. L0 makes the scattered id→port lookups callers
of one resolver, because the resolver must span all of them to resolve any address anyway, and the
fragmentation is the actual cause of the polymorphic-id ambiguity.

#### The fragmentation being removed (spike-confirmed)

A bare `id` today means any of: a panel UDID, a `webViews` panelId key, a terminal companion-name, a
port title (exact **or** fuzzy `contains`), or a `PortBridge.messageId` — across five lookup paths with
different match semantics:

| Path | Backing | Match | Callers |
|---|---|---|---|
| `webView(id)` (`BridgeMethods.swift:110`) | `portWindows.webViews` / `findInlineBridge` | exact id / messageId | `port.exec`, web `port.push` |
| `resolveTerminalController` (`AppState.swift:2760`, pure rule `resolveTerminalId` `:2747`) | `terminalControllers` | id-hit → exact name → `contains` | terminal `port.push` |
| `findPort(by:)` (`PortWindowManager.swift:765`) | `panels` | udid → title exact → title `contains` | `port.manage`, `port.move` |
| `updatePort(idOrTitle:)` (`PortWindowManager.swift`) | `panels` (same scan, inlined) | udid → title exact → `contains` | `port.update` |
| DB (`db.fetchPortHtml(udid:)` / `fetchPortVersions`) | `port_panels` / `port_versions` | udid exact | `port.getHtml`, `port.history`, `port.restore` |

#### The design (pure rule + thin wrapper, mirrors `resolveTerminalId`) — reviewed 2026-07-22

Two new pure, headless-testable files (no live objects), plus one thin `AppState` wrapper. **The
architecture review (2026-07-22) changed this design in four load-bearing ways; the code as landed
reflects the reviewed version:**

**(a) Identity is a triple, not a single id — the review's headline.** A port carries `id` (panel id,
the `webViews` key), `udid` (the stable/DB key), and, for a `port` fence, a `messageId`; `webViews` is
keyed by `panel.id` and `id != udid` for post-migration ports. A `PortRef` that returned one string
would break the accessor keyed on a different member (a real `port.exec`/`push` regression). So `PortRef`
carries all three; each method body uses the member its accessor needs.

**(b) The DB probe is lazy.** Passing an eager `dbUdids` set would force loading every udid from the DB
on every resolve. Instead `dbHas: (String) -> Bool` is called at most once, only after the live tables
miss — the common path (push/exec) never touches the DB.

**(c) The name-match rule is owned by the resolver.** `AppState.resolveTerminalId` now forwards to
`PortResolution.terminalMatch`, so the pure resolver no longer reaches up into `AppState` (dependency
direction fixed) and there is one terminal-matching rule.

**(d) DB-only kind is `.unknown`, not a guessed `.web`.** A DB-only ref's surface kind isn't verifiable;
`kind` says so rather than lying.

```swift
// PortAddress.swift — the address grammar (pure). `_` is the reserved nil-space placeholder, so
// canonical ∘ parse is identity for a bare-id alias too (round-trip fixed).
public struct PortAddress: Equatable {
    public let spaceId: String?    // nil = current/any space (a bare-id local alias); renders/parses as `_`
    public let portId: String
    public static func parse(_ s: String) -> PortAddress?   // port42://space/<spaceId>/<portId>
    public var canonical: String                            // port42://space/<spaceId or _>/<portId>
}

// PortResolution.swift — the resolution RULE (pure) + its result
public enum PortSurfaceKind: String, Equatable { case web, terminal, browser, unknown }
public struct PortCandidate: Equatable {   // a live panel's full identity, fed to the resolver
    public let id: String; public let udid: String; public let messageId: String?
    public let title: String; public let portType: String?
}
public struct PortRef: Equatable {
    public let kind: PortSurfaceKind
    public let spaceId: String?
    public let id: String?          // panel.id / webViews key / management key; terminal key for .terminal
    public let udid: String?        // DB / versions key
    public let messageId: String?   // inline web bridge key
}
public enum PortResolution {
    public static func terminalMatch(_ idOrName: String,
                                     candidates: [(id: String, name: String)]) -> String?
    // Precedence: terminal → panel(id|udid|messageId|title) → inline → DB-only. Pure; unit-tested.
    public static func resolve(_ idOrAddress: String,
                               terminals: [(id: String, name: String)],
                               panels: [PortCandidate],
                               inlineMessageIds: Set<String>,
                               dbHas: (String) -> Bool) -> PortRef?
}
```

`AppState.resolvePortRef(_ idOrAddress:) -> PortRef?` (the thin wrapper, to be added in the post-demo
pass) gathers the live candidate lists — `terminalControllers` → (id, companionName); `panels` →
`PortCandidate(id, udid, messageId, title, portType)`; inline `PortBridge.messageId`s not backed by a
panel; and a lazy `db.portExists(udid:)` closure — and calls `PortResolution.resolve`. A bare string
becomes `PortAddress(spaceId: nil, portId: s)`, so **UDID/name/title stay working as short local
aliases, no break**.

Browser kind: a `PortCandidate` with `portType == "browser"` resolves `.browser`; else `.web`. (The
headless `BrowserBridge` sessions are addressed by their own `sessionId`, a separate axis from port
units — out of L0 scope; noted in §4's browser gap.)

#### Rewiring the method bodies (the consolidation)

Each by-id method calls `resolvePortRef` and switches on `.kind`, fetching the concrete handle by the
identity member its accessor keys on (the triple from fix (a)):

- `port.push` → `resolvePortRef(id)`; `.terminal` → `controller.sendRaw` (via `ref.id`); `.web`/
  `.browser` → `dispatchEvent` on `webViews[ref.id] ?? findInlineBridge(by: ref.messageId)`; `.unknown`
  → `notFound`. **Deletes** the `resolveTerminalController` + `webView` + `PortPushRoute.classify` triad
  at the call site (precedence now lives in `PortResolution`).
- `port.exec` → require `.web`/`.browser` → webview via `ref.id`/`ref.messageId`.
- `port.manage`, `port.move` → operate on `ref.id` (the panel/management key) directly — no second
  `findPort` scan.
- `port.update` → route through the resolver (`ref.id`/`ref.udid`), drop the inline panel scan in
  `updatePort`.
- `port.getHtml`, `port.history`, `port.restore` → use `ref.udid` for the DB read.

`PortPushRoute` is subsumed (its precedence moves into `PortResolution`) — keep the file as a thin
re-export or delete it once nothing imports it; the existing `PortPushRouteTests` port to
`PortResolutionTests`.

#### Making the consolidation an invariant, not a convention (review fix)

The resolver being a shared helper means nothing *prevents* a sixth method from hitting a table
directly. Add a source-scan gate (the pattern `BridgeCloseOutTests` already uses): assert no
`BridgeMethods`/`ToolExecutor` body references `portWindows.webViews[`, `findPort(`, or
`resolveTerminalController(` outside `resolvePortRef`. That turns "one resolver" from a hope into a
checked invariant, matching the strength of the dispatch choke point this builds on.

#### Deeper follow-up (not L0): unify identity to one canonical id

L0 surfaces the full identity triple so the rewire is regression-free, but the underlying fragmentation
(a port has three coexisting ids; `webViews` keyed by `panel.id`; defensive `id||udid||messageId`
matching scattered across the codebase) remains. The real fix is one canonical identity with the others
derived, so `webViews`/panels/DB key on the same thing. That is a larger, separate change (call it
**L0.5**); L0 does not block on it, and carrying the triple is the correct interim.

#### Sequencing under the demo constraint (GM prepping a demo, 2026-07-22)

- **Now (safe, additive, zero build):** land `PortAddress.swift`, `PortResolution.swift`, and
  `PortAddressTests.swift` — new files, no live path touched, the running dev bundle is unaffected (file
  writes don't rebuild it). The pure rule is fully unit-testable.
- **After the demo (needs a build + GM's say-so):** add `AppState.resolvePortRef`, rewire the method
  bodies above, run `swift test` + the live cross-path check in Port42Dev. Held until GM clears the demo
  window, because it requires `./build.sh` (which kills the running dev instance) and a `swift test`
  compile.

**Test gate (Swift Testing, headless).** All landed, unrun (held for the post-demo build).
`PortAddressTests`: parse/round-trip of a real address; the **nil-space `_` round-trip** (canonical ∘
parse is identity); a bare id is not an address; rejects foreign scheme / space-invite form / wrong
segment count / wrong host. `PortResolutionTests`: terminal by id and fuzzy name (canonicalizes to id);
**terminal wins over web**; a panel resolves by **id, udid, messageId, and title while surfacing the full
identity triple** (the regression case — matching by udid still yields `panel.id`, the `webViews` key); a
`portType:"browser"` panel → `.browser`; an inline-only bridge → `.web` with only a `messageId`; a
DB-only udid → **`.unknown`, probed lazily** (and the live path does NOT touch the DB); unknown → nil; a
full address carries its space. Post-rewire, add the **source-scan invariant gate** above. Command:
`swift test --filter PortAddress` / `--filter PortResolution`.
**Done when:** one resolver backs all by-id methods; the five old lookups are callers of it, not parallel
paths; the precedence + identity-triple tests are green; the source-scan gate holds.

#### Sequencing note (review, 2026-07-22)

The prerequisite L1 (Notify) and L2 (lease) actually share is a **stable port identity**, which already
exists (`udid`), not the alias-consolidation. So L0-consolidate is worthwhile cleanup but not a hard
blocker for L1/L2: if a demo timeline is tight, L1 (the felt "a port streams, many watch") can be taken
on the existing `udid` with L0-consolidate running alongside. The plan's earlier "everything hangs off
L0" overstated it; identity is the real shared dependency. Relatedly, `Principal.portId` (the caller's
self-address) is a bare id while `PortRef` is the target address — L1/L2 will want one address notion, so
consider `Principal` vending its own `PortAddress` when L1 lands.

### Phase L1 — unified Subscribe → Notify (keystone #3) — detailed (2026-07-23)

**STATUS: SHIPPED (2026-07-23), verified live.** `NotifyBus` (in-memory 1:N, `NotifyBusTests` 4 green),
`port.subscribe` (a `BridgeStreamMethod`; end-to-end `PortSubscribeTests` green: subscribe → publish →
yield → cancel unsubscribes), and two producer taps: `port.push` ("push") and the terminal `onFlush`
("terminal.output", threaded through `GhosttyTerminalController` — **ships backlog 3.4**, non-hooks
tools only). **All four producer taps in:** `port.push` ("push"), terminal `onFlush`
("terminal.output"), web `portConsole` ("console" — also the console-as-Notify roadmap item), and
`PortBridge.pushEvent` (browser `load`/`redirect`/`error` + filedrop/presentation). So all three port
types stream. **Per-surface delivery shipped:** `port42.port.subscribe(id, onEvent)` in the port JS
bridge (`PortBridge.swift`) predicts the callId, registers a `_tokenCallback` that parses each
`{topic, kind, payload}` envelope, and delivers it to `onEvent`; the returned promise carries a
`.cancel()` that unsubscribes. Same token-callback machinery as `ai.complete`.

**Live-verified (2026-07-23):** two separate web ports in Port42Dev. Port A's own page script called
`port42.port.subscribe(B, e => …)`; three `port.push` calls to B were received by A in order with
correct parsed payloads (`{seq:1}`, `{seq:2}`, `{seq:3}`), topic `port:<B>`, kind `push`. Also
verified driving `subscribe` through `port.exec` (subscribe then `port.push`, envelope arrives) —
`exec` is a valid subscriber surface too. **L1 done.**

**One real constraint — do not `return` a subscribe stream from `port.exec`.** `callAsyncJavaScript`
auto-awaits the returned value; the subscribe promise resolves only on cancel, so `return
port42.port.subscribe(...)` would hang the exec task forever. **Enforced (2026-07-23):**
`PortExecJS.run` now bounds every exec body with a timeout (`PortExecJS.defaultTimeoutSeconds`, 30s)
and throws `PortExecError.timedOut` with guidance pointing at the long-lived-promise cause, so a bad
return fails fast and frees the task instead of leaking it. Correct usage: start the stream, keep the
handle in a variable, return a plain value — `var s = port42.port.subscribe(id, fn); return "ok";`.
The carveout JS comment states the rule at the call site.

**`port.exec` contract footgun (not a bus limitation):** `PortExecJS.wrapBody` treats a bare
expression as `return (<expr>)`. A multi-statement one-liner with no explicit `return` and no
newline — e.g. `foo(); 42` — becomes `return (foo(); 42)`, a **syntax error** reported as the opaque
"A JavaScript exception occurred". This has nothing to do with the bridge or promises (`1+1; 42`
fails identically). Any multi-statement `exec` body must use an explicit `return` or newlines.
`PortExecJSTests` pins this shape (and the timeout message). Candidate hardening: have `wrapBody`
split on `;`/newlines and only wrap the final segment, or detect multi-statement input and require the
caller's `return`.

A port is an actor that emits a stream; L1 makes that stream subscribable by many, over one path.

**NotifyBus (in-memory, 1:N).** On `AppState`: `notifySubscribers: [String: [Int: (String) -> Void]]`
(topic → subscriber id → deliver). Topic = `port:<portId>` (the existing `bus.*` convention).
- `publishNotify(topic:, kind:, payload:)` — encode `{topic, kind, payload}` as one JSON string and
  deliver to every subscriber of the topic. No subscribers → cheap no-op (the common case).
- `subscribeNotify(topic:, deliver:) -> Int` and `unsubscribeNotify(id:, topic:)`.

**The Notify envelope.** `{ "topic": <string>, "kind": <string>, "payload": <json> }` — one shape for
every port type. It rides the existing `String` `yield` of `BridgeStreamMethod` (yield the JSON string),
so the stream contract is unchanged; each adapter delivers an envelope to its surface (port JS → an
event callback, gateway → a chunk, tool-use → collect).

**`port.subscribe` (a `BridgeStreamMethod`).** Resolves the target via `resolvePortRef`, subscribes to
`port:<udid>` with `deliver = yield`, then awaits cancellation (mirrors `ai.complete`'s continuation +
`withTaskCancellationHandler`); on cancel/close it unsubscribes and returns. So render / an agent /
persist each open a `port.subscribe` and receive the SAME Notify stream — one publish, many subscribers.

**Three publish attach points.**
- **Terminal (first slice — also cashes out backlog 3.4):** `GhosttyTerminalController.swift:129` —
  replace the `onFlush { _ in }` no-op with `publishNotify(topic: "port:<id>", kind: "terminal.output",
  payload: <clean line batch>)`, behind the existing `hooksCapable` guard (no alt-screen probe; the
  documented limit for ad-hoc TUIs).
- **Web (follow-up):** tap the native receipt of the port's `pushEvent` / height / console and republish
  to `port:<id>`.
- **Browser (follow-up):** route `browser.load/redirect/error` to `port:<id>` (pairs with the
  console-as-Notify roadmap item).

**Sequencing.** (1) NotifyBus + `port.subscribe` + the terminal tap — proves the 1:N bus end to end and
ships terminal output streaming. (2) Web attach point. (3) Browser attach point + console-as-Notify.

**Test gate.** Unit: `publishNotify` → N subscribers each receive the envelope; unsubscribe stops
delivery; publish with zero subscribers is a no-op. Live in Port42Dev: `port.subscribe` a terminal, run
a command, receive `terminal.output` envelopes; two concurrent subscribers both receive.

### Phase L1 follow-on — `port42.publish`: a port emits its own state (consumer-symmetry fix)

**Why (proven live 2026-07-23).** Open Synth is a port built to be driven by peers: it accepts a defined
`port.push` input contract (cells, op, lane register) and anyone pushing plays the canvas. Its input
side was already a proper interface. Its output side was not. The only way to read the synth's current
state was `port.exec(id, 'return OPENSYNTH.getState()')` — an agent reaching into the port's JS to pull
state, a path no human render and no remote peer has. That is the one place an AI consumer does not use
a port the way every other consumer does (GM caught it).

**Live proof of the target model (Port42Dev, no rebuild).** A heartbeat emitter was injected into Open
Synth that publishes `getState()` on its own topic every 2.5s (bootstrap via `port.push(self, {kind:
'state', state})`, since the push tap already publishes on the port's topic). A separate SYNTH MONITOR
port then read the synth's full live state through `port42.port.subscribe` alone — the five existing
lanes, params, and live drives — with zero `exec` on the synth. Claude then joined as a peer: registered
a lane and drove cells entirely through `port.push`, and the monitor reflected the new `claude` lane off
the bus. State flowed synth → NotifyBus → subscribe → consumer; input flowed through the push contract.
The `exec(getState)` asymmetry was closed in the running instance.

**The primitive to ship.** `port42.publish(kind, payload)` — a port emits its OWN application state on
its own Notify topic, a first-class signal distinct from `port.push` (which is input INTO a port).
- **JS surface:** a carveout in the `port42` bridge (`PortBridge.swift`): `port42.publish(kind, payload)`.
- **Native:** publishes `{topic: "port:<self-messageId>", kind, payload}` on `NotifyBus`, the topic being
  the CALLING port's own id (the `PortBridge`'s `messageId`, the same source `pushEvent` already uses).
  No target argument — a port can only publish as itself.
- **Retires the workaround:** replaces the push-to-self heartbeat and, with it, the `exec(getState)`
  hydration path. A port publishes its state; consumers subscribe. Same contract for human render, agent,
  and remote peer.
- **Fifth producer tap** alongside push / terminal / console / browser, and the first one owned by the
  port's own application code rather than a native surface event.

**Sequencing.** An L1 follow-on; needs an app build (touches `PortBridge.swift`), so it lands in a build
cycle, before or alongside L2. Bake the emitter into Open Synth's source at the same time and retire the
injected bootstrap.

### Phase L2 REVISED — state tokens for correctness, the lease for presence (GM, 2026-07-26)

**The built L2 conflated two problems.** Stale writes are a CORRECTNESS problem; who is driving is a
COORDINATION problem. One time-based lock was doing both, badly — which is why the TTL had no
principled value, and why justifying it reached for LLM latency on a bus whose writers are scripts,
ports and peers as much as companions.

#### The rule

**Every port exposes a monotonic state token. A write carries the token it was composed against; if
the port has moved, the write is rejected and the error carries the current token.** No holder, no
timer. Correct whether the writer thought for 3ms or 3 hours, and identical locally and across
instances — which a lock can never be, because clocks do not agree between peers.

A rejected write is self-correcting: the conflict response carries `current`, so a naive caller does
push → conflict → push-with-token → success. One extra round trip, once.

#### The token is ONE activity sequence, not a per-type table

*(Corrected 2026-07-26 by checking the code. The per-type table below survived about ten minutes of
verification. What killed it is in §Verification finding 1.)*

**Every port carries a monotonic `seq`, bumped by anything that changes it**: a bridge write
(`push`/`exec`/`patch`/`update`/`restore`), a programmatic terminal write (`inject`/`sendRaw`/
prefill), trusted human input into the surface, and an external change we observe (a browser
navigation). A write carries the `seq` it was composed against; a mismatch is a conflict.

One counter, one rule, every type. The per-type differences that remain are only **where the bumps
come from**, not what the token means:

| Type | Bumped by |
|---|---|
| **web** | bridge writes + trusted human keydown/pointerdown in the surface |
| **terminal** | `inject` / `sendRaw` / prefill + trusted human keystrokes (`onHumanInput`) |
| **browser** | the above + a committed navigation (the page changed under us) |
| **chat** | n/a — not addressable by port verbs at all (`PortSurfaceKind` is web/terminal/browser/unknown), so it needs no token |

The document VERSION (`port_versions`) stays exactly as it is, for history and restore. It is not
the CAS token — see finding 1.

**Why input sequence and not output sequence for a PTY:** a redrawing TUI (claude's own UI, htop)
emits constantly, so an output token moves every frame and every write fails — protection too noisy
to use. Input sequence means exactly "has anyone typed into this since I looked", and redraw does
not perturb it. It also catches the dangerous case precisely: your keystrokes bump the sequence, so
a companion's write composed before you started typing is stale, without blocking it for 30 seconds
because you once touched the port.

**Presentation is not a type.** Inline/tiled/parked/background are positions of the same port and do
not change write semantics, so they do not touch the token. **A new port type must declare its
shape** — same discipline as `writesTarget`, so a future type cannot arrive with no answer to "what
does staleness mean here?".

#### What happens to the lease

**It stays, demoted to presence.** It records and broadcasts and displays who is driving; it stops
refusing writes. That removes the TTL-as-correctness problem entirely (the remaining TTL is display
freshness — when the chip should fade). Presence is worth keeping on its own terms: it is what makes
a companion's work visible, and it is what a remote peer will want to see in slice-02.

**The one place a token is REQUIRED, not optional:** streams. A token-less write to a terminal is
unguarded against the half-typed-line splice, and that case can execute something you did not type.
Everywhere else a missing token means last-write-wins, which is today's behaviour and breaks nothing.

#### Presence lifetime: events where they exist, a timer only where they do not

A single TTL cannot serve both actors, because they have opposite rhythms:

- **A companion** has 5–20s of model latency between related tool calls. A 10s decay flickers the
  chip off mid-turn and back on when it writes, reading as "stopped, started, stopped" when the
  truth is one continuous piece of work. This is what the original 30s was accidentally covering.
- **A human** pauses 1–3s between keystrokes and longer while thinking, but has no end signal at
  all. 30s claims they are driving something they walked away from half a minute ago — actively
  misleading once it is a REMOTE peer's name on the chip.

So: **a companion's presence is event-scoped** — held for the turn, dropped at its end. The signals
exist already (`llmDidFinish`, and `turnComplete` for terminal companions). No timer, no flicker,
and it is exactly true. **A human's presence is timed** at ~10s, because nothing tells us when they
stopped. The timer is the fallback for the actor with no end event, not the mechanism.

#### What of the built work survives

Almost all of it. L2.a's registry, L2.c's broadcast, L2.d/d.2's claim paths and L2.e's header all
serve presence unchanged. L2.b changes from `throw` to `record`. The new work is the token layer
(R2–R5) and, for terminals, the input counter — which the `onHumanInput` hook from L2.d.2 already
half-provides.

**Also still owed from the L2.d.2 finding:** the web claim must move to the native event monitor.
`isTrusted` stops accidental synthesis but a port can shadow it on an event it dispatches, so it is
a speed bump, not a boundary. Presence being advisory lowers the stakes of that hole — a forged
claim then misleads a human rather than blocking a companion — but it does not close it.

#### Verification against the codebase (2026-07-26, before any code)

**Finding 1 — the port version is the WRONG token, and would have shipped as a fake guarantee.**
`savePortVersion` (`DatabaseService.swift:1600`) is called from exactly two places, both in
`PortWindowManager` (`:299` persist, `:824` `updateHtml`). So the version bumps only when the HTML
SOURCE is replaced — i.e. `update`/`patch`. **`port.exec` and `port.push` do not bump it**: they
drive the port's live runtime (JS state, DOM) without touching source. Two companions exec'ing
against the same runtime would both read the same version, both pass CAS, and clobber each other
anyway. A token that cannot see the most common write is worse than no token, because it reads as
protection. Hence one activity `seq` per port, bumped by every mutation of any kind.

**Finding 2 — @mention into a terminal bypasses everything, and it is the COMMON path.**
`routeMentionsToTerminals` calls `controller.inject(line)` directly (`AppState.swift:1649`), never
touching `runBridgeMethod`. So the most-used way a companion reaches a terminal is neither recorded
as presence nor token-checked, while the rarer `port.push` is. GM caught this: it has to be handled,
not noted.
**The good news is the choke point already exists.** `inject` and `sendRaw` both funnel through
`injectToSurface` (`GhosttyTerminalController.swift:208/218`), so the CONTROLLER is the one place
every programmatic pty write passes. Bump and check there, not at the bridge, and every route is
covered by construction.

**Finding 3 — two pty writes bypass even the controller.** `Coordinator.typePrefill`
(`PortWindowManager.swift:136`) and the startup command both write straight to the Ghostty surface.
They are app-originated at spawn time, so they need no token check, but they DO change the pty and
must bump `seq` or a companion's first write races them.

**Finding 4 — human keystrokes never pass either seam.** `GhosttyInputView` writes to the surface
directly (`ghostty_surface_text_input`, `:445/493/505`). The `onHumanInput` hook from L2.d.2 is the
only observation point, which makes it load-bearing for correctness now, not just for presence.

**Finding 5 — appending `expect` to a verb's `paramNames` is safe.** `BridgeArgs(positional:names:)`
maps positional args in order, so an appended trailing name cannot disturb existing positional JS
callers. Adding it anywhere but the end would.

**Finding 6 — chat drops out entirely.** `PortSurfaceKind` is web/terminal/browser/unknown; chat
ports are not addressable by port verbs, so the "plain append" row was solving a problem that does
not exist.

**Finding 7 — a full sweep of "ways in" (GM asked: what else?). Five more, and the pattern matters
more than the list.**

Every site that changes a port's state, swept rather than recalled:

| Path | Covered by the plan as written? |
|---|---|
| `sendKey` ← human keydown (`GhosttyTerminalView.swift:230`) | yes — `onHumanInput` |
| ⌘V paste (`:192`) | incidentally — it routes through `keyDown` first |
| **file drop onto a terminal, pastes the paths (`:207`)** | **NO** — a drop is a write with no keystroke |
| `inject` / `sendRaw` writer (`:445`) | yes — R4's controller choke point |
| `typePrefill` (`:493`), startup command (`:505`) | yes — finding 3 |
| **file drop onto a WEB port → `handleFileDrop` → `port42:filedrop` (`PortBridge.swift:135`)** | **NO** — an external write into the runtime, never through the dispatcher |
| **the browser address bar (`ShellDesktop.swift:930`)** | **NO** — a user-typed URL replaces the whole page |
| **page-initiated navigation (a link, the page's own JS)** | **NO** — and Spike B is exactly whether we can even see it |
| **a REMOTE peer's @mention → `routeMentionsToTerminals` → `inject`** | path yes (R4), but the ACTOR is remote — cross-instance arriving early |
| a port's own JS mutating itself (a shader, a form) | must **NOT** count — see the rule below |
| debug harnesses writing straight to a surface (`GhosttyResizeSpike.swift:103`) | DEBUG-only; ignore, but know it exists |

**The pattern: enumerating ways in is a losing game.** I have now found new ones on three separate
passes, and the next reader will find a seventh. A guarantee that depends on someone having listed
every caller is not a guarantee — it is a to-do list that silently rots.

**So the rule changes: bump at the SURFACE, not at the API.** For a pty, every one of those seven
sites ends in `ghostty_surface_text*`. Funnel them through a single `write(_:)` on
`GhosttyInputView` that bumps `seq` and is the only thing permitted to call the C functions — then a
new path physically cannot write without counting, and a reviewer can verify it by grepping for the
raw call. The bridge and the controller become two callers among several rather than the boundary.

**And the counter-rule, or the shader problem returns:** a port's OWN internal mutation must not
bump `seq`. Only EXTERNAL writes and human input count. Otherwise an animating port invalidates
every token every frame, which is the same failure that ruled out an output-sequence token for
terminals.

#### Architecture spikes (read-only, before the step they gate)

- **Spike A — where does `seq` live, and can it be read cheaply at write time?** RUN 2026-07-26
  (read-only, no code). Answer: **yes, an in-memory `[portKey: Int]` on `AppState` works** — with
  four corrections to the sketch (A1–A4) and one confirmation (A5). Findings below.
  **Gates R2.**
- **Spike B — can a browser's committed navigation be observed?** `PortBrowserNavigation` overrides
  `decidePolicyFor` (`PortWindowManager.swift:1329`) but not `didCommit`. Confirm adding `didCommit`
  is enough to catch every page change (including in-page history API pushes, which do NOT fire it —
  and if they do not, say so rather than claim browser CAS is sound).
  **Gates R2's browser row.**

##### Spike A findings (2026-07-26)

**A1 — the O(1) claim is true of the LOOKUP and false of the KEY, and the key is the whole cost.**
The dict read is O(1) on a `@MainActor` class, no locking, no DB. But getting the key means
`resolvePortRef` (`AppState.swift:2880`), which rebuilds a terminals array and a panels array on
every call, so it is O(panels + terminals), and it can touch the DB — `dbHas` is a lazy probe, fired
only after the live tables miss, so the common push/exec path never reaches it.
**So: R3 must reuse the `PortRef` the seam already resolved for `recordDriving`, not resolve a second
time.** Resolve once at the dispatch seam, pass the key to both. Resolving twice per write would
double the one genuinely non-free part of the check.

**A2 — it must NOT be `@Published`.** Same reason `portLeases` is not (L2.e lesson 5), plus a
sharper one: R2b bumps on every human keystroke, and a `@Published` dict would invalidate the shell
once per character. Presence reaches the header through the Notify bus, and the token's only
consumer is the dispatcher, so nothing needs observability.

**A3 — activity and presence have OPPOSITE lifecycle rules, which is why `seq` is a separate type
and not a field on `LeaseRegistry`.** A close calls `portLeases.forget` (`PortWindowManager.swift:646`)
because a dead port has no driver. For the token the same move is BACKWARDS: if a closed id is reused
(the `closeForgetsTheLease` test does exactly this) a reset counter starts at 0 again, and a token
composed against the DEAD port passes CAS against the new one. Monotonic-per-id and never reset is
strictly safer — a stale token then mismatches by construction. **`PortActivity` must not forget on
close.** In-session unbounded growth is one Int per port id, which is nothing.

**A4 — a reset counter is NOT safe across a restart, and the fix is the one this codebase already
chose once.** `panel.id` and `udid` are both restored from the DB (`restoreFromDB:211-212`), so the
KEY survives a restart while the counter would not. Meanwhile every port's live state definitely
changed: a web port comes back from its persisted SOURCE with all `exec`/`push` runtime state gone,
and a terminal's pty is new. So a peer holding a pre-restart token of 0 against a post-restart
counter of 0 passes CAS against a port that has been wiped — a stale write admitted, which is the
exact failure the token exists to stop.

Nothing bites LOCALLY today (there are no cross-instance writers yet), but the shape to build is
already settled by precedent: `ActorRef` was made peer-qualified from day one specifically so local
was the degenerate form and no migration was needed. **Do the same here: qualify the token with a
per-launch epoch (`<epoch>:<seq>`), constant within a session so nothing local notices, and
mismatching by construction across a restart.** Deciding it now costs a string; deciding it at
slice-02 costs a wire-format migration.

**A5 — one counter covers every surface.** The gateway is a subprocess but its RPC re-enters
`runBridgeMethod`, and the port JS surface is a Proxy over the same registry, so there is no second
writer path with its own state. One dict on `AppState` is the whole system.

**Consequence for R2's gate.** The stated gate ("unknown port starts at 0") stands for the numeric
part. A4 adds a term to the token, so the gate reads: an unknown port starts at seq 0, and two
different launch epochs never compare equal.
##### Spike B findings (2026-07-26) — browser CAS is the weakest token, and now we know why

**Run late, and that is a process failure worth recording.** Spikes are declared "read-only, before
the step they gate". Spike B gates R2's browser row, and R2 *and* R2b were built without it. Nothing
caught that, because R2's own acceptance criteria never mentioned the browser — the gate table was
checkable in isolation and did not reference the spike list. **Cross-check the spike list against the
step being built, not just the step's own gate.**

**B1 — what exists today.** `PortBrowserNavigation` implements `decidePolicyFor` and nothing else. No
`didCommit`, no `didFinish`, no KVO on `webView.url`. So today a browser port's page can change
completely and no Swift code learns anything.

**B2 — `didCommit` is necessary but NOT sufficient, verified live.** In a running port:

```
before: http://port42.local/            history.pushState({},'','#probe1')
after:  http://port42.local/#probe1     DOM intact, 0 navigation entries
```

The URL changed with no document load. `didCommit` fires when a navigation COMMITS A NEW DOCUMENT;
none was committed, so it cannot fire. Every SPA route change is invisible to it — and SPA route
changes are most of what "the page changed under us" means on the modern web.

**So the plan's own instruction applies: say so rather than claim browser CAS is sound.** It is not,
with `didCommit` alone.

**B3 — the recommendation is KVO on `webView.url`.** WebKit updates that property for
same-document navigations as well as commits, so one observer covers both. `didCommit` can stay as a
belt for the cross-document case. **Verify with a live test when the browser row is built** — this
spike proved the JS-side fact (URL changes, no load) and did not instrument the native side, which a
read-only spike cannot.

**B4 — the spike also found a P0 security hole**, written up in `summer2026-todo.md`: the navigation
policy for NORMAL web ports permits script-initiated navigation, and the `window.port42` bridge
follows the port to the new origin. Live-verified: a page on `example.com` called `ports.list()` and
got the user's ports back. That is not a protocol problem, but it was found by pulling this thread
and it changes R7's priority.

##### Spike C findings (2026-07-26) — the input sweep, all surfaces (partial: needs a live probe)

Commissioned because finding 7's sweep was titled *"every way into a TERMINAL"*, while the property
we need is about every surface. GM's framing is the right one: **Port42 owns the membrane with the
user, so every input — key, pointer, voice, drop, any future device — should pass one seam.**

**C1 — there are SIX seams for "something entered a port", each added ad hoc:**

| seam | covers |
|---|---|
| `GhosttyInputView.sendKey` | terminal, human keys (`ghostty_surface_key`) |
| `GhosttyInputView.write` | terminal, all programmatic (R2b) |
| injected JS `keydown`/`pointerdown` | web, human |
| `PortBridge.handleFileDrop` | web, file drop |
| `ShellBrowserTile.navigate` | browser, address bar |
| `runBridgeMethod` | any type, programmatic |

They are split by SURFACE TECHNOLOGY — Ghostty, WKWebView, SwiftUI chrome each have their own input
plumbing, so each grew its own hook. That is the actual root cause of finding 7 repeating: R2b
funneled one of the six and left five.

**C2 — the web listener is two event names, which is not "input".** It reports `keydown` and
`pointerdown` only. Anything a user does that produces neither is invisible to presence AND to the
token: **dictation / voice, IME composition, context-menu paste, autofill, dragging text into a
field.** `beforeinput` is the canonical "the user is about to change content" event and covers these
cases; the current pair covers keys and clicks and calls it input.

**MEASURED 2026-07-26** with a live probe (GM at the keyboard, real input devices — the blind cases
are `isTrusted` by definition, so nothing about this could be simulated).

**Before: 11 real content changes, Port42 saw 8, THREE INVISIBLE.**

| events fired | what it was | old verdict |
|---|---|---|
| keydown, input | typing | seen |
| keydown, paste, input | ⌘V | seen |
| keydown, input (insertReplacementText) | accent hold (é) | seen |
| pointerdown, input (insertReplacementText) | a click-to-insert (picker or suggestion) | seen |
| **composition\*, beforeinput, input** ×2 | **the EMOJI PICKER** (see the caveat) | **INVISIBLE** |
| **composition\*, beforeinput, input** | **DICTATION** — measured separately, labelled run | **INVISIBLE** |
| **paste, beforeinput, input** | **right-click → Paste** | **INVISIBLE** |
| **drop, beforeinput, input** | **drag text in from another app** | **INVISIBLE** |

**METHODOLOGY CAVEAT, and it cost a wrong claim.** The probe recorded EVENTS, not which action
produced them, so the right-hand column is inference. I first wrote the two composition rows up as
"dictation". GM corrected it: on this machine `fn fn` opens the EMOJI PICKER, so those rows are the
picker, and **dictation was never tested at all**. The events are facts; the labels were my guess,
and a probe that needs the operator to remember what they just did is a badly built probe. A rerun
should let the operator name each action before performing it.

The finding survives the correction, because it is about MECHANISM not about which feature: a real
user action can change a port's content through composition, paste or drop events with **no key and
no pointer anywhere**. When that happens the port changed, presence lied, and the activity token
stood still while the document moved underneath it — a companion's stale write would have passed CAS
cleanly. **Dictation was MEASURED afterwards in a labelled run and is confirmed in this family**:
`insertCompositionText` / `deleteCompositionText` / `insertFromComposition`, with
compositionstart/update/end — no key, no pointer. Old listener: blind. New listener: sees it. So
GM's original "any interaction, key, voice, any input device" framing was exactly right, and voice
was the case the old two-event listener could never have caught.

Getting there took three probe revisions, and the reason is worth keeping: the first probe recorded
events but not actions, the second read its label 700ms late so labels slid between rows, and the
third finally captured the label when the burst STARTED. **A probe whose output depends on the
operator remembering what they just did is not evidence.**

**The fix is one event name.** `beforeinput` fired on ALL ELEVEN rows, seen and missed alike. One
signal covers what two were failing to. Added to the injected listener behind the same `isTrusted`
check. **Re-measured after the fix: 7 of 7 seen, zero invisible**, including a right-click paste and
a cross-app drag — the drag being a case nobody had enumerated, caught by construction rather than
by having listed it.

`beforeinput` does NOT replace the other two: it only fires for editable content, and a
canvas/game/shader port is driven by pointers with nothing editable in sight. Three narrow signals,
not one clever one.

**C2b — TERMINALS have the same hole, and no seam to fix it at.** `GhosttyInputView` implements no
`NSTextInputClient` — no `insertText`, no `setMarkedText`, no `interpretKeyEvents`. Dictation and IME
into a terminal port therefore either do not work at all or bypass `keyDown`, which is the only place
`onHumanInput` hangs. Code-verified; not probed live. A web port now has three signals and a terminal
still has one, which is the membrane argument in miniature.

**C3 — still entirely uncounted:** page-initiated browser navigation (B2), and `window.open` /
`target="_blank"`, which has no `WKUIDelegate` anywhere in the repo (already its own TODO).

**C4 — the conclusion, and why it blocks R4/R5.** *(The plan for this is now
`docs/plan-input-seam.md`; it is NOT called "the membrane" — that name belongs to the whole
experience layer in `docs/membrane/`.)* R5 makes a token MANDATORY for terminal writes.
That is only sound if every way in counts. On the current six-seam model it is provably not sound for
web and browser, and unproven for voice on any surface. **The membrane review (one `PortInput` seam
carrying `(port, kind, actor, trusted)`, with each surface technology reduced to translating its
native events into it) should be decided before R4**, not after. It is also where R7's trust boundary
belongs, and where slice-02's remote actors arrive.

#### Build order (revised 2026-07-26)

Ordered so the thing currently enforcing on a bad justification stops first, and so every step is
shippable green on its own.

| # | Step | Build | Automated gate | Manual gate |
|---|---|---|---|---|
| 1 | **R1 · demote** — DONE 2026-07-26, both gates PASSED | `claimWrite` → `recordDriving`: records + broadcasts, never throws. `writesTarget` stays (it now means "which port does this touch"). | The existing gate tests INVERT: a second principal's write SUCCEEDS and presence updates. `port_busy` is gone from the codebase. Full suite green. | A companion writing to a port you are in is no longer refused. |
| 2 | **R2 · seq** — BUILT 2026-07-26, gate PASSED | `PortActivity`: `seq(for:)` + `bump(_:)`, in-memory, beside `portLeases`. Bumped at the dispatch seam (all bridge writes) and from `humanInteracted`. | Pure: monotonic per port, independent per port, unknown port starts at 0, two epochs never collide. Wired: two bridge writes bump twice; a read does not; an unresolvable target does not; human input bumps per keystroke. | — |
| 2b | **R2b · one surface writer** (finding 7) — BUILT 2026-07-26, gate PASSED, manual gate open | Funnel all seven pty write sites through a single `GhosttyInputView.write(_:)` that bumps; it becomes the only caller of `ghostty_surface_text*`. Same for the web file-drop and browser address-bar paths. | A grep test: `ghostty_surface_text*` appears in exactly ONE place outside the harnesses. Drop-a-file and paste both bump. | Drop a file on a terminal; drop one on a web port; type a URL in a browser tile. Each bumps. |
| 3 | **R3 · CAS** — DONE 2026-07-26, gate PASSED + live-verified | Optional `expect` APPENDED to the write verbs' `paramNames` (finding 5); mismatch → `stale_write` carrying `current`. | Stale token refused; current token succeeds; ABSENT token succeeds (today's behaviour, nothing breaks); the error CARRIES `current` — without that, callers cannot self-correct. | A companion that reads then writes still works end to end. |
| 4 | **R4 · the pty choke point** | Move bump+check into `GhosttyTerminalController` (`inject`/`sendRaw`, finding 2), so @mention and `port.push` are covered identically. Bump on `typePrefill` + startup (finding 3). | An @mention-injected line bumps `seq` and is token-checked — the SAME assertions as `port.push`, run against both paths. Prefill bumps. | @mention a terminal companion; it still lands. |
| 5 | **R5 · streams require it** | Terminals reject a token-less write; conflict carries `current`, so a naive caller self-corrects in one retry. | Token-less `port.push` to a terminal refused; retry with `current` lands. The ONLY required-token surface. | Type a long command slowly while a companion writes — no splice. |
| 6 | **R6 · presence lifetime** | Companion presence dropped at `llmDidFinish` / `turnComplete`; human TTL → ~10s. | Presence survives a whole companion turn (no flicker across a tool-call gap); a human's clears ~10s after last input. | Watch the chip through a real multi-step companion turn. |
| 7 | **R7 · native claim** | Move the web claim off the injected listener onto the shell's `NSEvent` monitor. | A port dispatching a forged `isTrusted` event does not register as the human. | Re-run the shader idle test: zero claims. |

#### R1 as built (2026-07-26)

**Manual gate CLEARED live in Dev3.** GM clicked into a web port (taking presence via the L2.d.2
interaction claim), then a gateway `port.exec` against that port **landed** — it returned the
evaluated result, so it reached the webview. The same call on the pre-R1 build came back refused by
name. The keystone's old behaviour is gone from the running app, not just from the tests.

`LeaseRegistry.check` → `record`, and `LeaseDecision.denied` is **deleted**. The decision the caller
gets back is now only "did the driver CHANGE", which is all the Notify broadcast ever keyed off.

**The one design call R1 forced: LAST DRIVER WINS.** The step's own gate ("a second principal's write
SUCCEEDS *and presence updates*") is unsatisfiable while a live record refuses to move, so
`record` is unconditional. That is also the only reading that stays true: holding the driver still
would leave the chrome naming a companion that stopped while the human types underneath it, which is
the exact blindness L2.d.2 was added to fix. Two consequences, both wanted:

- **Focus now moves presence off a companion.** The old `focusDoesNotSteal` invariant existed
  because focus could seize the PEN; with no pen, refusing to update presence would just make the
  chip lie. Its test is inverted, not deleted.
- **A takeover no longer waits for the TTL.** A different driver publishes immediately.

The flicker this exposes (a companion re-taking the chip on each write across a tool-call gap) is
**R6's** problem, not a reason to keep a lock: R6 scopes companion presence to the turn.

`writesTarget` survived unchanged, which is what R3 hangs `expect` off. `port_busy` is gone from
`Sources/` and `Tests/`; grep confirms it. Suite **1067 green**.

#### R1b — the rename, and the throttle defect it exposed (2026-07-26, GM)

**GM: "I thought we got rid of leasing though, I am so confused."** Correct, and the confusion was
the code's fault: R1 changed the lease's JOB and kept every one of its NAMES. A type called
`LeaseRegistry` that leases nothing is a comment that lies, and it made the next conversation about
it unreadable. Renamed to match what it does:

| was | now |
|---|---|
| `PortLease.swift` | `PortPresence.swift` |
| `LeaseRegistry` / `portLeases` | `DriverRegistry` / `portDrivers` |
| `Lease` / `.holder` / `.holderName` | `Driver` / `.ref` / `.name` |
| `LeaseDecision.granted` | `DriverChange.changed` |
| `ClaimThrottle` / `humanClaimThrottle` | `PresenceThrottle` / `presenceThrottle` |
| `claimFocusForHuman` | `recordHumanFocus` |
| `HolderBadge` / `otherHolder` | `DriverBadge` / `otherDriver` |
| wire: `kind:"holder"`, `payload.holder` | `kind:"driver"`, `payload.driver` |

The WIRE changed too. It is a protocol surface, but nothing outside this app consumes it yet (no
gateway code, no port JS, only `ShellState` and the tests), so the migration cost is zero now and
non-zero the moment slice-02 exists.

**The defect the rename hunt surfaced, found live by GM: the human could never win the chip back.**
GM clicked continuously in a port while a companion wrote to it every 2s, and the header never
stopped naming the gateway. Not a plumbing failure — `window.webkit.messageHandlers.portInput` was
confirmed registered — but arithmetic: `PresenceThrottle` drops all but one claim per **5 seconds**,
so a 2s write cadence beat the human every time.

**The throttle's justification had died with the lock and nobody re-derived it.** Its comment read
"re-claiming a lease you already hold is noise" — true under a 30s lock, false under last-driver-wins,
where a companion's write means you do NOT still hold it and your next keystroke is a genuine change.

**Fix: throttle a REFRESH, never a TAKEOVER.** Already the driver → throttled. Anyone else, or
nobody → recorded immediately. That restores the throttle's original intent rather than tuning its
interval, which would only have moved the race instead of removing it. Two tests pin both halves: a
takeover inside the throttle window still wins; a ten-keystroke burst still publishes exactly once.

**The pattern worth carrying to R6:** R2 had already pulled the token bump out from behind this same
throttle, for the same reason, and the presence half was left behind. When a mechanism is demoted,
every rule justified by its old job has to be re-checked — not just the rule that was obviously
about it.

#### R2 as built (2026-07-26)

`PortActivity` (`Sources/Port42Lib/Services/PortActivity.swift`), pure, on `AppState` beside
`portLeases`. **Token = `<epoch>:<seq>`** (GM decided A4: epoch now, not at slice-02). Suite
**1079 green**.

Three things the build settled that the table row does not say:

**The seam resolves ONCE and shares the key** (A1). `runBridgeMethod` derives `portKey(for:)` and
hands the same key to both the bump and `recordDriving`; `recordDriving(on:)` survives as a thin
resolving overload for the focus and input callers, which hold a raw id. Presence, the token and the
Notify topic now provably key off one value.

**The bump fires BEFORE `method.run`.** The body is async and can suspend, so a token read mid-write
would be read against a port already moving. A body that then throws leaves a bump for a write that
did not land, costing a concurrent writer one self-correcting retry — wrong in the safe direction,
which is the only acceptable direction here.

**The presence throttle must not reach the token, and this is a correctness rule, not tuning.**
`humanInteracted` was one throttled call; it is now two signals. The `ClaimThrottle` (~5s) still
covers the presence claim, because re-recording a driver you already are is noise at keystroke rate.
The bump is unthrottled: throttled, a companion's write composed 4 seconds ago would pass CAS against
a port you had typed thirty characters into — exactly the splice R5 exists to stop. The bump also
does NOT require an identity (the port changed whether or not we know who the person is), while the
claim still does.

#### R2b as built (2026-07-26)

`GhosttyInputView.write(_:mode:)` is now the only caller of `ghostty_surface_text` and
`ghostty_surface_text_input`, and it fires `onSurfaceWrite` after every write. Five sites routed
through it: clipboard paste, file drop, a companion's `inject` (both halves), the startup command,
the first-run prefill. Suite **1086 green**.

**The seam is `GhosttyInputView`, not the controller, and that matters.** Finding 2 pointed at
`injectToSurface` as the choke point, which is true for the BRIDGE routes and false for the rest —
paste, drop, startup and prefill never touch the controller. Only the view is downstream of all of
them.

**Three things the build settled:**

1. **Human keystrokes are a DIFFERENT C entry point.** They reach the pty via
   `ghostty_surface_key` in `sendKey`, not the text functions, so the funnel does not and should not
   cover them — they have their own seam in `onHumanInput`. The grep test covers both entry points
   so neither can quietly grow a second caller.
2. **The `inject` Enter counts separately from its body.** They are two writes 80ms apart, and the
   human can type in the gap. Counting only the body would leave a token that looks current at the
   exact moment the line is submitted.
3. **Both terminal build paths had to be wired** (restore in `PortWindowManager`, spawn in
   `AppState`). The presence hook was already in both; a token wired in only one would make
   terminals count or not count depending on how they were created, which no user could ever see.
   There is a test for exactly that.

**`AppState.surfaceWrote(port:)` bumps but does NOT record presence**, unlike the bridge seam. This
path fires for writes the app itself makes at spawn time, and naming the app as the driver of a port
the user just opened would be a lie. Presence belongs to writes with a principal.

**The non-terminal ways in from finding 7 are covered too:** a file drop onto a WEB port
(`PortBridge.handleFileDrop`, resolved by bridge object identity rather than by threading a udid
through every construction site) and the browser address bar (`ShellBrowserTile.navigate`). Page-
initiated browser navigation remains uncounted — that is Spike B, still unrun.

#### R3 as built (2026-07-26) — the first step that refuses anything

Optional `expect` on every write verb; a mismatch throws `stale_write` carrying `current`. Suite
**1099 green**, and live-verified in Dev3 with the case the earlier loop could not produce:

```
slow companion reads token   → 9ba21a7e:0
   ...5 seconds of "thinking"...
someone else writes          → port moves to :1
slow companion writes with :0
   → {"code":"stale_write","expected":"9ba21a7e:0","current":"9ba21a7e:1"}
port content: v1-by-someone-else        ← the clobber never landed
```

**`expect` is injected CENTRALLY, not declared eight times.** `buildBridgeRegistry` ends with
`mapValues { $0.acceptingExpect() }`, so a write verb added tomorrow gets compare-and-swap by
construction. Declaring it per-method would make CAS depend on whoever adds the verb remembering —
the exact failure this phase exists to stop. Appended last, per finding 5.

**Three ordering rules, each with a failure behind it:**
- The check runs BEFORE the bump, or a write invalidates the token it is being judged against.
- A refused write does NOT bump. A rejection that moved the token would invalidate every other
  writer over a write that never happened. There is a test for it.
- The token is read at the seam off the SAME resolve as the bump and the presence record (A1).

**`BridgeError` gained `details: [String: String]`**, so `current` is machine-readable beside `code`
and also rendered into the tool text — a companion reads prose, and an error it cannot act on costs
a whole turn. An error that says only "you are stale" leaves the caller guessing; one that says what
the current value IS turns the failure into a one-retry self-correction.

##### The gap R3 exposed, and `port.getDom`

To write "against what I saw", a caller must first SEE. The only way to inspect a live port was
`port.exec` — correctly a write, since it runs arbitrary JS — so **looking at a port invalidated the
looker's own token.** Circular: the read was a write. `port.getHtml` was no help; it returns the
stored SOURCE, which does not reflect any `exec`/`push` since load.

**`port.getDom(id, selector?) → {html, token}`**, a read (`writesTarget: nil`, so no bump, no
presence). Two properties that matter:

- **No `js` parameter.** The expression is fixed in the method, so a caller cannot smuggle a mutation
  through a read verb. The classification is enforced by the method's SHAPE, not by trusting callers
  — the same discipline as the R2b funnel.
- **`html` and `token` come back together, from one instant.** Fetching the token separately leaves a
  gap in which the port can move, handing back a token that was never true of the html beside it.

Verified live: three consecutive `getDom` calls returned an identical token, then a write carrying it
landed.

##### What the generated-artifact gates caught (worth keeping)

Three gates fired on R3, all correctly: `BridgeParamConsistencyTests` (method count),
`BridgeSchemaParityTests` (golden fixture) and `BridgeDocsExportTests` (`llms.txt`). Each has a regen
path whose doc says to READ THE DIFF, and doing so caught a real defect: the `expect` description
pointed companions at `port_info`, which is `toolExposed: false` — a tool no companion can call. Now
points at `ports_list`. **The regen diff is a review surface, not a chore.**

**Sequencing rationale.** 1 first because it is live in Dev3 refusing writes on a justification we
have abandoned. 2 before 3 because CAS needs something to compare. 4 before 5 because requiring a
token on a path that half the callers bypass would fail open — the choke point has to exist before
it can be mandatory. 7 last because presence being advisory (step 1) lowers the stakes of the
forgery hole from "a port can block a companion" to "a port can mislead a human", so it stops being
urgent, but it is still owed.

### Phase L2 — right-of-way lease (keystone #2) — detailed (2026-07-24, SUPERSEDED ABOVE)

**STATUS: BUILT END TO END (L2.a–L2.e, 2026-07-24/25), full suite 1065 green. Only LIVE
VERIFICATION is left — every step's automated gate passes; none of it has been seen running.**

**Keystone #2 is closed in code.** Two local drivers cannot double-write: a companion's write to a
port the human is driving is refused by name, focus and native interaction both claim, the holder
rides the port's own Notify topic, and the tile header shows it when someone else is driving.
What remains is L2's manual column (a live human-vs-companion contention run) and, when it lands,
the same mechanism over the wire in slice-02.

| Step | State |
|---|---|
| L2.a pure lease | SHIPPED — `PortLease.swift`, `PortLeaseTests` (11) |
| L2.b dispatch gate | SHIPPED — `BridgeMethod.writesTarget` + `claimWrite`, `PortLeaseGateTests` |
| L2.c holder broadcast | SHIPPED — `kind:"holder"` on `port:<id>`, change-only |
| L2.d human principal | SHIPPED — `Principal.Kind.human`, zoom-to-focus claims |
| **L2.d.2 interaction claims** | SHIPPED — typing/clicking in a surface claims it (`ClaimThrottle`) |
| L2.e holder in the header | SHIPPED — subscribes to `holder` envelopes; shows only when it is SOMEONE ELSE |

#### L2.d.2 — interaction claims the pen (added 2026-07-25, GM)

§L2.4's honest limit is now closed on the human's side. The signal is not *keystrokes* but **input
reaching the surface**: keydown and pointerdown, both intent to ACT. Hover does not count (a mouse
crossing the desktop is not driving) and **scroll deliberately does not** — scrolling is READING,
and claiming on it would block a companion mid-write exactly while the user watches it work.

Reported by the surfaces, since none of it reaches the bridge: `GhosttyInputView.onHumanInput` for
terminals, and an injected keydown/pointerdown listener reporting through a `portInput` handler for
web ports (the same shape as console and height; the handler holds a closure, not the manager, so it
cannot become a retain path). Throttled ~5s per port by `ClaimThrottle`, because typing fires per
keystroke against a 30s TTL.

**Still open, deliberately:** the *uninvented gesture* GM raised — asking for a pen someone else
holds. That is a REQUEST (the knock in §L2.3), a different need from "who is driving now", which is
an observable fact. Kept separate rather than collapsed into one motion.

#### What building it taught us (integrate before L2.e)

1. **`focusKeyboard` was the wrong seam, exactly as the review suspected.** Keyboard focus also
   follows the MOUSE (hover raises a tile and hands it the keyboard), so acquiring there would let a
   mouse dragged across the desktop seize the pen from every companion it passed over, for a full
   TTL each. The claim hangs off the ZOOM transition instead: zooming into a unit is deliberate,
   hovering is not.
2. **Implicit acquisition is validated, not just argued.** The full suite went green with the gate
   live and **no existing test or flow needed a change** — the acceptance clause held on the first
   run, which is the evidence that a write-to-acquire model does not disturb single-driver use.
3. **`check` denies, never evicts — and that turned out to be the important property.** It is what
   lets the human's focus-claim be safe: focusing a port a companion is mid-write on leaves the
   companion driving. A "focus wins" rule would have made every glance a seizure.
4. **A write verb that no-ops on an unknown id exists** (`port.rename` resolves and shrugs), so
   "unresolvable targets are not gated" had to be asserted as *never `port_busy`* rather than as
   *throws notFound*. Worth knowing before relying on any write verb's error for control flow.
5. **L2.e cannot read the lease directly.** `LeaseRegistry` is a plain value on `AppState`, not
   `@Published`, so a header observing it would not update. It should SUBSCRIBE to the `holder`
   envelopes on `port:<id>` — which is the protocol-correct path anyway, and makes the header just
   another subscriber rather than a special case. Doing that first is what stops L2.e from becoming
   a reason to make lease state observable.

**Not built (deferred from §L2.3):** the explicit `port.lease({id, action:"take"|"release"})` verbs.
The implicit path carries the whole model today; the knock is only needed once a human wants to ask
for a pen a companion is holding, which is L2.e's UI question.

**Do.** A per-port holder ("who holds the pen") keyed on `Principal.id`, gating the Update verbs at
the dispatch seam. The holder is broadcast on the port's own Notify topic, so every surface already
watching the port learns who is driving with no side channel. Explicit handoff, pessimistic — no
CRDT, no OT (matching slice-02's deliberate choice, and for the reason in §L2.6).

#### L2.1 Where the gate lives — declare it, don't scatter it

`runBridgeMethod` (`BridgeDispatcher.swift:25`) is the ONE choke point every caller passes through,
and it already gates `method.permission` there. The lease is the same shape of decision, so it goes
in the same place and is DECLARED THE SAME WAY: `BridgeMethod` gains

```swift
/// The paramName carrying the port this method WRITES to. nil = a read (never gated).
let writesTarget: String?      // e.g. "id" for push/exec/patch/update
```

Registry-declared, like `permission`, so a new write verb cannot silently escape the gate — the
existing `BridgeParamConsistencyTests` source-scan can assert the write verbs all declare it.

**Gated (Update):** `port.push`, `port.exec`, `port.patch`, `port.update`, `port.rename`,
`port.move`, `port.restore`, `port.manage` (destructive actions).
**Never gated (Query/Temporal):** `port.getHtml`, `port.history`, `port.info`, `port.position`,
`port.subscribe`, `ports.list`. Reading is not driving.

#### L2.2 The lease itself — pure, headless, time-injected

New `Sources/Port42Lib/Services/PortLease.swift`, modelled on the pure-state discipline the shell
uses (`ShellState`'s statics, `PortPlacement`): no AppState, no clock of its own.

```swift
struct Lease: Equatable { let holder: String; let holderName: String; let expires: Date }
struct LeaseRegistry {                      // value type, one per app
    mutating func check(port: String, principal: String, now: Date) -> LeaseDecision
    mutating func release(port: String, principal: String)
    mutating func handoff(port: String, from: String, to: String, now: Date)
}
enum LeaseDecision { case granted(Lease), refreshed(Lease), denied(byName: String, until: Date) }
```

`now` is passed in, never read inside: expiry is the one behaviour that is miserable to test against
a real clock, and it is the behaviour most likely to be wrong.

#### L2.3 Acquisition — implicit, because nothing may break today

A write against a FREE port acquires the lease for its principal. A write by the CURRENT holder
refreshes the TTL. A write against a port held by someone else is rejected with a `BridgeError`
naming the holder. TTL ~30s, refreshed by use.

This ordering matters: implicit acquisition means every single-driver flow that works today keeps
working unchanged, and the lease only becomes visible at the moment there IS contention — which is
exactly when a user wants to know about it. A design that required an explicit `take` first would
break every existing port, script and companion on day one.

Explicit verbs come with it for the deliberate cases: `port.lease({id, action:"take"|"release"})`,
where `take` on a held port is a REQUEST (a knock the holder can answer), not a seizure.

#### L2.4 The honest limit: native input is not a bridge write

A human typing into a Ghostty terminal port, or clicking inside a webview, does **not** pass through
`runBridgeMethod`. Keystrokes go straight to the surface. So the lease cannot see local human input,
and a naive implementation would let a companion hold the pen while the human types underneath it —
the exact double-write the keystone exists to prevent, invisible to the mechanism meant to catch it.

**Resolution: focus acquires the lease for the human.** `portWindows.focusKeyboard(on:)` already
exists as the single seam for "the keyboard now belongs to this unit" (⌘\` cycling, ⌘↓, hover, tile
click all funnel through it). Hooking lease acquisition there unifies the informal right-of-way the
shell already has with the formal one the protocol needs, instead of running two ideas of "who is
driving" side by side. It also makes the felt behaviour correct: click a port, you hold the pen, and
a companion's write is rejected while you are in it.

#### L2.5 Broadcast — reuse the port's own topic

On every holder CHANGE (not on refresh — that would spam):
`notifyBus.publish(topic: "port:<id>", kind: "holder", payload: {holder, holderName, until})`.
Anything already subscribed to the port sees it: the tile header, another instance's mirror, an
agent deciding whether to wait. This is why L1 had to land first.

#### L2.6 Why reject rather than queue (GM asked, 2026-07-24)

A queued write is a STALE write: composed against the port as it was, applied against a port that
moved, with the author gone. That is the same failure that ruled out optimistic merge. A rejection
bounces back while the author still holds the context that produced it. It is worse with an agent in
the mix, which is the real case: a companion writes in bulk, fills the queue, and the flush lands on
the human as a jump nobody authored. And a queue is a scheduler — ordering policy, persistence,
per-waiter TTL, dead-waiter handling, progress/cancel UI. The lease is one fact: who holds it.

A queue is a POLICY OVER the lease and can be added later without touching the write path; it is not
a primitive that can be retrofitted underneath one. The thing usually wanted is not a queue anyway,
it is a knock (`take` → holder answers → handoff), which L2.3 provides.

#### L2.7 Cross-instance forward-compat — SETTLED (`decision-identity-model.md`, 2026-07-24)

The blocker is answered. Identity is three axes, not one: **person** (the `AppUser` P256 key),
**instance** (the libp2p PeerID, a per-device key signed by the person key), and **actor** (the
`Principal` — a human, a companion, a port). The lease holds an ACTOR.

**What that fixes here:** `Lease.holder` is a **qualified principal**, `<peerID>/<principalId>`,
with the local peer as the empty prefix — the same shape as slice-02's port address
(`port42://<peerID>/space/<id>/<portId>`). So the local lease is the DEGENERATE FORM of the remote
lease, not a different object, and cross-instance stays the prefix the plan claims it is.

Write holder strings peer-qualified from L2.a. It is one line now and a migration later.

#### L2.8 Code review of the seams (read 2026-07-24, before writing any L2 code)

**Confirmed — the design holds:**
- **Every write verb takes `id` as its first param.** `push(id,data)`, `exec(id,js)`,
  `patch(id,search,replace)`, `update(id,html)`, `rename(id,title)`, `move(id,x,y)`,
  `restore(id,version)`, `manage(id,action)`. So `writesTarget` is uniformly `"id"` and the
  declaration is mechanical, not a per-method judgement.
- **`runBridgeMethod` is genuinely the only choke point** (`BridgeDispatcher.swift:25`) and already
  does exactly this shape of gate for `permission` (`:34-43`). The lease check slots in beside it.
- **Remote callers already produce principals.** `ToolExecutor.swift:148/164` builds
  `Principal(kind: .peer)` for gateway/synced callers, so the holder being an actor rather than a
  connection is already true on the existing transport.

**Two findings that CHANGE the plan:**

1. **There is no human principal.** `Principal.Kind` is `port | companion | peer` — the local human
   typing has no principal at all, because until now nothing needed one (permissions are asked OF
   the human, not authorized FOR them). L2.d cannot "acquire for the human principal" until one
   exists. **Decision needed:** add `case human` with `id = AppUser.id`. It is small, but it is a
   change to the identity type the whole authorization layer keys on, so it is called out rather
   than slipped in. This is also the first place `AppUser`'s identity is used for anything
   (`decision-identity-model.md` predicted it would need to become real).

2. **A companion-made port authorizes AS its creator.** `PortBridge.portPrincipal.id` is
   `createdBy ?? messageId` (`PortBridge.swift:117-126`) — deliberate (P-260), and documented: `id`
   is shared across every port that creator made, while `portId` names the specific port and is
   excluded from `==` so it never splits a grant bucket. **Consequence for the lease:** keyed on
   `id`, two ports made by the same companion are the SAME holder and can never contend with each
   other. **That is the right default** (the actor is the companion, not each surface it spawned)
   and it keeps the lease consistent with grants, but it must be a stated choice: keying on
   `portId ?? id` instead would make each port its own driver and immediately diverge from how every
   permission in the app is bucketed.

**Reviewed:** the write-verb registry declarations and their params; `runBridgeMethod`'s gate site;
`Principal` and its three kinds; `PortBridge.portPrincipal`; `ToolExecutor`'s principal
construction; `NotifyBus.publish` and the four existing producer taps; `focusKeyboard(on:)`
(`PortWindowManager.swift:147` — the single seam, async-dispatched, with a special case for the
SwiftUI chat unit).

**NOT reviewed (do before the step that touches each):** whether any UI-driven write reaches
`runBridgeMethod` at all or bypasses it (L2.d depends on the answer); the terminal write path
(`port.push` → `controller.sendRaw`) and whether a lease denial there needs a visible surface;
browser ports; and parked/inline/background presentations, where "who is driving" may be meaningless
and the gate should probably no-op.

#### Build order + the gate at each step

Every step is shippable alone and green before the next starts.

| Step | Build | Automated gate | Manual gate (Dev3) |
|---|---|---|---|
| **L2.a** | `PortLease.swift`: `Lease`, `LeaseRegistry`, `LeaseDecision`. Pure, time-injected, no app changes. | `swift test --filter PortLease` — acquire when free; deny when held by another; the holder's write refreshes; expiry frees (inject `now`); explicit release; handoff moves the holder; release by a non-holder is a no-op. | none (headless) |
| **L2.b** | `writesTarget` on `BridgeMethod`, the eight declarations, the dispatcher check. | The pure tests still green + a dispatcher test: A holds, B's `push` throws a `BridgeError` naming A; A's own `push` succeeds; a READ by B succeeds (reads are never gated). Extend the `BridgeParamConsistencyTests` source-scan so a new write verb without `writesTarget` fails the suite. | Existing single-driver flows unchanged: a companion still makes and drives a port end to end. **This is the regression that matters** — if anything needed changing, implicit acquisition is wrong. |
| **L2.c** | Notify broadcast on holder CHANGE (not refresh). | A holder change publishes exactly one `{kind:"holder"}` envelope on `port:<id>`; a refresh publishes none. | Subscribe a second port to the first and watch the holder envelope arrive. |
| **L2.d** | `Principal.Kind.human` + `focusKeyboard` acquires for it. | Focusing a unit yields a human-held lease for that port; focusing away does not steal a lease held by someone else. | **The one that makes it real:** focus a port, have a companion write to it, the write is rejected and the human keeps driving. Then hand off and the companion proceeds. |
| **L2.e** | Holder in the tile header (a name — "gordon holds this" — not a lock icon). | none (pure visual) | Two drivers, the header names the right one, and it clears when the lease expires. |

**Done when:** two local drivers never double-write, both see the holder, and **no existing
single-driver flow needed a change** — the last clause is the real acceptance test of the implicit
acquisition design.

## 7. Local acceptance (Port42Dev :4243)

Address a real running port by `port42://space/<s>/<p>`; send it `getHtml`/`patch` by that address and it
executes through the existing bridge; subscribe and receive Notify deltas as it changes; do it for a web,
a terminal, and a browser port; (L2) two local drivers contend and neither double-writes. All inside one
instance.

## 8. Staging to cross-instance (what changes, what does not)

When the local slice is green, cross-instance is additive:
- **Address:** prefix `port42://<peerID>/space/<s>/<p>`. The resolver gains a "not-local → route to peer"
  branch; local resolution is unchanged.
- **Transport:** swap the local Notify fan-out for a wire (the current WebSocket gateway relay first, as a
  low-lift proof on substrate we already run; libp2p/gossipsub later to chase the sovereignty
  hole-punch number, per slice-02). The contract — address, Query/Update, Subscribe/Notify, lease — does
  not change.
- **Lease:** the per-port holder becomes the cross-wire ownership lease (slice-02's per-port right-of-way).

This is why local-first is the correct sequencing: it retires the contract risk (does the actor model
generalize across port types?) with zero transport risk, and leaves the transport bet (P2P sovereignty
vs. relay) to be measured on its own, later.

## 9. Doc debt flagged (not fixed here)

`CLAUDE.md` and `docs/bridge-architecture-and-mcp.md` still describe `browser_*` + `rest_call` as
hand-written holdouts in a `ToolDefinitions.swift`. That file is gone; browser methods are in the unified
registry (`BridgeMethods.swift:403-485`), schemas generate from the registry
(`AppState.generatedToolDefinitions()` `AppState.swift:936`). Correct these when convenient.
