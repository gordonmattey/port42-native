# Plan: one bridge, for the human too (the input seam)

*2026-07-26. Owner: this document. `docs/membrane/*` predates it and is superseded on structure —
see §0. The step it gates is L2's R4/R5 (`plan-port42-protocol-local-bus.md`).*

## 0. What this is NOT called, and why that matters

Earlier drafts of this work called it "the membrane". That name is taken: `docs/membrane/` uses it
for the entire experience layer, organized into a **Face** (Sensor / Synchronizer / Presenter) and a
**Crew** of six capabilities. Reusing it for one input seam would collide with the name of the whole
product.

**Those taxonomies are retired as an organizing frame.** They name capabilities that map to nothing
enforced in code — a reader cannot point at the Watcher, and no test fails if it disappears. This
plan organizes by **invariants that are actually enforced**: if it cannot be broken, it is structure;
if it is only a noun in a diagram, it is positioning. The membrane docs stay as history.

The public architecture page already states the real frame:

> Every surface an actor. A human and an agent reach the same surface through **one bridge**, with the
> same methods and the same permissions.

Five caller types are named there: you via the UI, an agent as tools, the CLI, the REST API, another
gateway. **Every one of them is programmatic.** A person typing, dictating, pasting or dropping into a
port reaches the surface directly and touches no bridge at all.

**So this is not a new layer. It is the missing half of a promise already made.**

## 1. The one line

**Every way into a port arrives at one seam, so the guarantees hang off one place instead of six.**

## 2. Why, in measurements rather than argument

Nothing here is speculative; each was found this session.

| Evidence | What it cost |
|---|---|
| The web listener reported `keydown` + `pointerdown`. Measured against 11 real content changes, it saw **8**. | Dictation, the emoji picker, right-click paste and a cross-app drag changed a port while presence named the wrong driver and the token stood still. A stale write would have passed CAS clean. |
| **Three** separate sweeps for "every way into a terminal", each finding a path the last missed. | The guarantee depended on someone having enumerated correctly. It rotted three times. |
| The per-port key was written **three** times, three ways, none handling inline ports. | A whole class of port — a `port` fence before adoption — had no token, no presence and no CAS at all. |
| Every terminal hook wired **twice**, because building a surface was never factored into a function. | A test exists purely to catch someone wiring one and forgetting the other. |

**The pattern, and the actual thesis of this plan: every one of these was one concept with several
homes.** None was a logic error. The fixes that held were structural — one funnel, one key, one origin
check, one central `expect` injection — and the fixes that failed were rules someone had to remember.

## 3. The shape

```
  terminal keys + clicks ┐
  terminal writes        │
  web input              │
  web file drop          ├──▶  received(PortInput)  ──▶  activity token
  browser address bar    │            │                  presence
  browser navigation *   │            │                  trust boundary
  programmatic writes    │            └── the ONLY door
  dictation *            │
  a remote peer *        ┘                        * to build
```

```swift
struct PortInput {
    let port: String        // PortRef.key — udid ?? id ?? messageId
    let kind: Kind          // .text(String) | .gesture | .navigation(URL) | .programmatic
    let actor: ActorRef     // human / companion / port / a peer
    let trust: Trust        // .native | .reportedByPage | .principal
}
```

### The enforcement is privacy, not discipline

`portActivity` and `portDrivers` become **private to the seam**. Nothing outside can bump a token or
record a driver; any path that wants to must construct a `PortInput`. That is a compile error rather
than a code review — which is the whole point, because "remember to call the thing" has now failed
four separate times in this subsystem alone.

### Why `trust` is a field

It is where R7 lives. `.reportedByPage` means an injected listener said `isTrusted`, which a page can
shadow — a speed bump. `.native` means we observed it in AppKit ourselves. **R7 stops being a rewrite
and becomes "change which translator emits the event."**

## 4. The count

**6 mutation sites** — the compile-error surface when the fields go private:

| site | what |
|---|---|
| `BridgeDispatcher` ×3 | bump: bridge write, human input, surface write |
| `BridgeDispatcher` ×1 | record: presence |
| `PortWindowManager` ×2 | forget: port close |

Plus **4 read sites** (`ports.list`, `port.info`, the CAS check, the takeover check) which stay reads
behind a public accessor.

**8 translators**, 7 existing and 1 to build:

| # | translator | note |
|---|---|---|
| 1 | terminal keys + clicks | `onHumanInput` |
| 2 | terminal programmatic writes | the R2b funnel |
| 3 | web input | keydown / pointerdown / **beforeinput** |
| 4 | web file drop | |
| 5 | browser address bar | |
| 6 | zoom-to-focus | the human's deliberate claim |
| 7 | all programmatic writes | the dispatch seam |
| **8** | **browser page navigation** | **does not exist — KVO on `webView.url`, per Spike B** |

Then **dictation** and **a remote peer** arrive as 9 and 10 with no consumer change. That they fit
without bending the seam is the best evidence available that the shape is right — and it is weak
evidence, because I chose both test cases.

## 5. Decisions

| Decision | Call | Why |
|---|---|---|
| Does a gesture bump the token? | **Yes** (GM) | A click on a canvas port can change everything with no `beforeinput`. Over-invalidating costs one self-correcting retry; under-invalidating admits a stale write. |
| Input only, or input and output? | **Input only** (GM) | Output has the Notify bus. Merging turns a consolidation into a rewrite. |
| Where does dictation live? | **Port42's own layer** (GM) | Captured once, injected as a translator, lands on every surface, counts by construction. Beats per-surface system text services. |
| Per-port or per-element right-of-way? | **Per-port** | Matches what is shipped and what is published. `docs/membrane/` says per-element; that is superseded. |
| Build the explicit knock (`take` / `release`)? | **No — change the copy** | See §6. |
| Big bang or strangler? | **Strangler** | Six mutation sites. Add the door, move translators one at a time, flip to private LAST. That flip is when the guarantee bites, and it fails loudly at compile time. |
| Does the streaming registry join? | **Yes, at the end** | `BridgeStreamMethod` has no `writesTarget` and no write seam. Nothing writes through it today, so there is no bug — only an unguarded hole, and the seam is the place to close it rather than bolting the field on. |

## 6. A published promise that R1 made untrue

The architecture page says:

> When two callers hold the same port at once, **right-of-way decides who acts**, so you can **take the
> pen from an agent mid-task and hand it back.**

Both halves are now false. R1 removed the deciding; the explicit handoff verbs were deferred in L2 and
never built.

**The call: change the copy, do not build the knock.** "Take the pen" was designed for a lock world.
Under CAS you do not need to take anything — your write cannot be clobbered, so seizing control is a UX
affordance rather than a correctness mechanism. Building it now would re-add a lock's ergonomics on top
of a system that deliberately no longer has a lock.

Suggested replacement, weaker-sounding and actually stronger, because it is a guarantee rather than an
arbitration:

> When two callers reach the same port, you can see who is driving — and a write composed against stale
> state is refused, not applied.

## 7. How to judge this design

Four tests. Failing any one makes this a tidy-up rather than an architecture.

1. **Can the guarantee be broken by forgetting?** If a new surface can reach a port without the door,
   nothing has changed. The answer must be a compile error, not a convention.
2. **Does a new input source have exactly one obvious home?** Voice and a remote peer are the cases.
   A special case for either means the seam is shaped wrong.
3. **Are the translators dumb?** A translator turns a native event into a `PortInput` and nothing else.
   Policy inside a translator is policy that drifts between surfaces — the bug being fixed.
4. **Does it survive the surface type after next?** Not web/terminal/browser. The one nobody has
   thought of. If adding it means touching the door, the door is too specific.

**The honest risk, recorded now rather than discovered later:** `PortInput` carries four fields because
four things need it today. If a fifth consumer wants something it does not carry, the struct grows —
and a struct that grows per consumer is a bag, not a seam. The test is whether field five is ever added
for a *consumer* rather than for a *source*.

## 8. Phases

Each phase ships green on its own.

| # | Phase | Gate |
|---|---|---|
| P0 | **Collapse the terminal duplication.** One factory taking `(panel, config)`; both callers pass their own config. Deletes `bothHostsWireIt`, whose only job is catching a forgotten second wiring. | Suite green with the test removed, not skipped. |
| P1 | **The door.** `PortInput` + `received(_:)` + `portClosed(_:)`, fields still internal. Nothing calls it yet. | Pure tests on the type and the routing decision. |
| P2 | **Move the 7 translators**, one commit each. | Each independently green; behaviour identical. |
| P3 | **Translator 8** — browser navigation via KVO on `webView.url` (Spike B: `didCommit` misses SPA route changes). | A page-initiated navigation bumps the token. |
| P4 | **Flip the fields private.** | The compiler names every path missed. This is the phase that matters. |
| P5 | **The streaming registry** joins the seam. | A streaming write verb cannot escape. |

Dictation and remote peers are then translators, not phases.

## 9. What this does NOT cover

Kept visible so the seam does not quietly absorb them.

- **Terminal `NSTextInputClient`** (low). Voice is superseded by Port42's own dictation layer, but
  **CJK input into a terminal port does not work at all** and no seam work changes that.
- **The Sensor's job** — attention and availability (focused app, at desk, away). Different
  granularity, different consumer. `PortInput` has no attention dimension and must not grow one.
- Output, the Notify bus, and rendering.
