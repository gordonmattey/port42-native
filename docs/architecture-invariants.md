# The invariant primitives — what has one home, and what does not

*2026-07-26. Owner: this document. The register of concepts that must have a single definition, which
ones do, which ones do not, and the order we fix them in. **This is also the flat sequence** — it
exists partly to stop the plan-within-a-plan nesting that produced it (§0).*

## 0. Where we are, flat

Three levels of nesting had accumulated: the L2 protocol plan gated R4/R5 on the input seam, the input
seam turned out to be gated on identity, and each level was a separate document. Three levels of
"cannot do X until Y" is how work stops shipping.

**So there is one sequence, here, and plans do not nest below it.** Each line ships on its own.

| | Work | State | Why here |
|---|---|---|---|
| ✅ | L2 R1–R3 + `port.getDom` | **done, live** | presence, activity token, CAS |
| ✅ | Port sandbox (origin pin) | **done, live** | a P0 found while spiking |
| ✅ | Input coverage (`beforeinput`) | **done, live** | dictation/paste/drop were invisible |
| ▶ | **I1 · Identity** | **next** | §1 — a live permission-pooling hole, and everything else keys on it |
| | I2 · Input seam (`plan-input-seam.md`) | planned | §2 — unblocks R4/R5 |
| | L2 R4, R5 | planned | needs I2 to be honest |
| | I3 · Trust | planned | §3 — R7 is one instance of it |
| | L2 R6, R7 | planned | |
| | I4 · Output seam | later | §4 — the twin of I2 |
| | I5 · Error taxonomy | later | §5 |
| | Desktop rearranging | after the protocol thread | GM's scope call |

Everything else stays on `summer2026-todo.md` and is not part of this line.

## The test

A primitive belongs here when it is **one concept with several homes, where a reader cannot tell a
deliberate difference from an omission.** Not "duplicated code" — duplication is cheap to fix and
usually harmless. The failure mode is a *guarantee* that depends on every site having remembered.

This session produced four instances in a row (one funnel, one key, one origin, one token), which is
why the register exists rather than a note.

---

## 1. Identity — who is calling · **NEXT**

**Status: BROKEN, live.** Six `Principal` construction sites. Two of them:

```swift
Principal(id: createdBy ?? "anonymous-tool-caller", …)   // ToolExecutor:75, :92
```

**Permissions are keyed on `principal.id`.** So every unattributed tool caller shares one bucket:
grant `filesystem` to one and all of them have it, persistently. Presence names them identically, and
the activity token attributes their writes to one actor. `decision-identity-model.md` settles
person/instance/actor in prose; nothing enforces it in code.

**Why it goes first.** It is small, it is a live hole, and **both guarantees shipped this session are
built on `principal.id`** — presence records it and CAS attributes by it. Anything identity gets wrong
is inherited by everything above it.

### Plan

| # | Step | Gate |
|---|---|---|
| I1.1 | **Find out what actually calls in unattributed.** Log every `createdBy == nil` dispatch with its method and surface, run Dev3 normally, read it. | A list of real callers, not a guess. Do not design against an imagined set — that mistake is on record twice this session (finding 7, Spike C's labels). |
| I1.2 | **One constructor.** `Principal.for(surface:…)` as the only way to build one; the initializer becomes private to the type. Compile error at every site that improvises. | No `Principal(` outside `Principal.swift`, asserted by a source scan. |
| I1.3 | **Decide what an unattributed caller IS** — informed by I1.1. Either it cannot call (refuse), or it gets a per-surface synthetic identity that never pools. **Not one shared string.** | Two distinct unattributed callers cannot see each other's grants. |
| I1.4 | **Presence and token attribute correctly** for whatever I1.3 decides. | A write from an unattributed caller names something a human can act on. |

**Open question for I1.3, deliberately not pre-decided:** refusing is the safe answer and may break a
real path that works today. I1.1 exists to find out which, before choosing.

---

## 2. Input — every way into a port · `plan-input-seam.md`

**Status: planned, not started.** Six seams, split by surface technology, which is why three sweeps
each missed a path and why dictation was invisible. Full plan in its own doc; it is the one exception
to "no nesting", because it is large enough to need phases and is already written.

Unblocks **R4/R5** — "terminals require a token" is only sound if every way in counts.

---

## 3. Trust — how we know who did it

**Status: three mechanisms, no single expression.**

| mechanism | where | strength |
|---|---|---|
| `isTrusted` on an injected listener | web input | page-reported; a page can shadow it |
| origin pin (`port42.local`) | every bridge message | native, unforgeable by page content |
| an authenticated principal | bridge dispatch | only as good as §1 |

**R7 is one instance of this**, not the whole of it. `PortInput.trust` unifies them for input only —
reads are uncovered, and the gateway authenticates nobody (`plan-gateway-auth-tls` P1, open).

*Asserted from structure. Unlike §1 and §4, no live defect is proven — the origin pin closed the one
that was.*

---

## 4. Output — what leaves a port

**Status: ten publish sites**, emitting `console`, `terminal.output`, `push`, `driver`, plus
`port.publish`. Identical shape to §2, deliberately out of its scope (GM: input only, so a
consolidation does not become a rewrite).

Worth naming now because the input seam will make the asymmetry obvious: input will have one door and
output will still have ten.

---

## 5. Errors — what a caller can act on

**Status: ~20 ad-hoc code strings.** `bad_args` and `bad_arg` coexist; `no_port` sits alongside
`not_found`. `BridgeError` has canonical helpers (`missingArg`, `notFound`, `badArg`) that nothing
enforces.

**This got more important on 2026-07-26**, not less: R3 made errors machine-actionable
(`details.current`), and CAS depends on a caller recognizing `stale_write`. An agent that cannot
branch on failure cannot self-correct, which is the entire premise of the conflict-then-retry design.

Also on record: `port.push` with a missing required `data` returns `ok:true` and types the string
`null` into a live shell (`summer2026-todo.md`). A verb whose schema says "required" and whose body
defaults is the same class of defect — the declaration and the behaviour disagreeing.

---

## Not primitives

Kept here so they are not mistaken for the list.

- **Time.** `PortPresence` takes `now` as a parameter, which is the right discipline, but callers use
  `Date()` directly and there is no injected clock. Real, low value, no guarantee rests on it.
- **Space scoping.** Suspected, unverified. Not listed until counted — the register does not carry
  hunches.
- **The Crew / the Face** (`docs/membrane/`). Retired as an organizing frame: they name capabilities
  that map to nothing enforced, and no test fails if one disappears. History, not structure.
