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

## 1. Identity — the ACTOR noun · **RESOLVED**

**Status: ✅ RESOLVED 2026-07-27** (I1.1–I1.6). Measured first, which found two holes neither plan
had named and killed the one both led with. One private constructor, so identity policy has one home.
**Permissions are keyed on `principal.id`**, presence names the principal, and the activity token
attributes writes by it. `decision-identity-model.md` settles person/instance/actor in
prose; nothing enforces it in code.

Two holes were found. **Neither is the one this entry used to name**, and both are now closed.

| what | where | how it fails |
|---|---|---|
| ~~a gateway-created port inherits the shared `local-http` id~~ | `Principal.forPortBridge` rung 1 | ✅ **FIXED I1.3 (2026-07-27), GM chose to un-pool.** A SHARED creator is not an author, so the port authorizes as itself. `createdBy` stays the provenance record: "who made this" and "what it may do" are no longer the same field. |
| ~~a chat or ambient port authorizes as a heap address~~ | `ObjectIdentifier` at three sites | ✅ **FIXED I1.4 (2026-07-27).** `PortBridge.stableIdentity` feeds the principal's last rung, kept separate from `messageId` so addressing and authorization do not share a field. |

**`anonymous-tool-caller` was this entry's headline until it was measured, and it is now GONE**
(I1.5, 2026-07-27), deleted as dead rather than fixed. `ToolExecutor.createdBy` is non-optional, so a
caller that cannot name its companion fails to compile instead of pooling grants.

**One construction site remains, and it is the register's own invariant:** `Principal`'s memberwise
init is private (I1.2), so every identity comes from a named factory and all identity POLICY is in one
file. Enforced by the compiler, with a package-wide source scan as the backstop.

**Why it goes first.** Both guarantees shipped this session are built on `principal.id`: presence
records it and CAS attributes by it. Anything identity gets wrong is inherited by everything above it.

**Register note on method.** This entry was originally written from a count of `Principal(`
construction sites and fallback strings, and **that method could not have found either live hole** (one
has no fallback, the other needed a caller list). A primitive's STATUS here is only as good as the way
it was established, so an asserted-from-structure status is weaker evidence than a measured one. The
register now treats those as different grades; §3 is the remaining asserted entry.

**Left open, and neither is an identity defect:** a migration question (orphaned
`portPerms.local-http.<space>` grants that nothing reads any more; Dev3 holds an `automation` one),
and gateway auth P1, after which `Principal.isSharedIdentity` is the single place that changes.

---

## 2. Input — every way into a port · the TOKEN noun

**Status: IN PROGRESS** (I2 · C0 and C1 done 2026-07-27). Six seams split by surface technology,
which is why three sweeps each missed a path and why dictation, the emoji picker, right-click paste
and a cross-app drag were all invisible until measured. The web listener is fixed (`beforeinput`);
terminals now have one build path (C0, which found a third site doing one of five steps); the door
exists and nothing calls it yet (C1). Browser navigation is open.

**Scope correction:** making the tables private breaks the four READ sites as well as the six
mutations, so this is ten sites, not six.

**This is not a separate concern from the token — it is what makes the token honest.** A token claims
"has this port changed since I looked", and that claim is false for any mutation that does not count.

**Phases are in the plan** (`plan-port42-protocol-local-bus.md` §C). Unblocks R5.

**Two failure classes, and only one is a compiler's job.** A WRONG CALLER mutates the tables directly
instead of through the door; deleting the direct route makes the compiler name every one, which C2.0
proved by accident when it surfaced an eleventh site two hand-derivations had missed. A MISSING CALLER
changes the port and touches the seam not at all (dictation, the emoji picker, right-click paste, a
cross-app drag, an SPA route change); **nothing fails to compile, so only measurement finds those** and
Spike C measured the web listener at 8 of 11.

**This entry is not RESOLVED when C4 lands.** C4 proves nothing bypasses the door; it never proves
everything arrives at it, and the token's honesty (and therefore R5) depends on the second. Declaring
it done on C4's evidence would repeat the "asserted rather than measured" error this register already
carries a caveat about in §1 and §3.

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

**P0 SHIPPED in v0.5.50 (2026-07-27)** after three days in `main` behind a doc that said it already
had. Verified on the artifact: a LAN request that returned the real port list before the update is
refused after it, and loopback is unaffected. `/call` still assigns the shared `local-http` identity
with **no `RemoteAddr` check**, so the constant's name is doing work its code does not; that is P1,
open, and it must RETIRE the shared principal rather than gate it.

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
