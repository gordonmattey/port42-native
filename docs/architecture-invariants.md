# The invariant primitives — what has one home, and what does not

*2026-07-26. Owner: this document. The canonical register of concepts that must have a single
definition, and whether they do.*

## This is a REGISTER, not a plan

It says what must have exactly one definition and whether it does. **It does not say what we build or
in what order** — that is `plan-port42-protocol-local-bus.md` §A, which is the single plan for the
protocol thread and maps each primitive to one of the protocol's three nouns (address · actor · token).

One question, one home: ordering lives in the plan, status lives here.

## The test

A primitive belongs here when it is **one concept with several homes, where a reader cannot tell a
deliberate difference from an omission.** Not "duplicated code" — duplication is cheap to fix and
usually harmless. The failure mode is a *guarantee* that depends on every site having remembered.

This session produced four instances in a row (one funnel, one key, one origin, one token), which is
why the register exists rather than a note.

---

## 1. Identity — the ACTOR noun · **IN THE PLAN, NEXT**

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

**Steps I1.1–I1.4 are in the plan** (`plan-port42-protocol-local-bus.md` §B).

---

## 2. Input — every way into a port · the TOKEN noun

**Status: partly fixed, planned.** Six seams split by surface technology, which is why three sweeps
each missed a path and why dictation, the emoji picker, right-click paste and a cross-app drag were
all invisible until measured. The web listener is fixed (`beforeinput`); terminals and browser
navigation are open.

**This is not a separate concern from the token — it is what makes the token honest.** A token claims
"has this port changed since I looked", and that claim is false for any mutation that does not count.

**Phases C0–C5 are in the plan** (`plan-port42-protocol-local-bus.md` §C). Unblocks R5.

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
