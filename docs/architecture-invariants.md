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

**Status: ✅ RESOLVED 2026-07-27** (I2 · C0–C6), and measured surface by surface rather than argued. Six seams split by surface technology,
which is why three sweeps each missed a path and why dictation, the emoji picker, right-click paste
and a cross-app drag were all invisible until measured. The web listener is fixed (`beforeinput`);
One door (`PortInputSeam`), three mutating entry points, the tables private, enforced by the
compiler. C6 measured coverage with the operator naming each action first: **web 7/7**; browser now
counts typing (an isolated `WKContentWorld`, since the origin pin correctly rejected page-reported
input) and reload (`didCommit`, which KVO cannot see); terminals gained dictation, the emoji picker
and IME (`NSTextInputClient` — one missing conformance, not three broken features).

**Known and stated:** a browser page that mutates its DOM without changing its URL still does not
count. Spike B called browser CAS the weakest token and it remains so.

**Scope correction:** making the tables private breaks the four READ sites as well as the six
mutations, so this is ten sites, not six.

**This is not a separate concern from the token — it is what makes the token honest.** A token claims
"has this port changed since I looked", and that claim is false for any mutation that does not count.

**Phases are in the plan** (`plan-port42-protocol-local-bus.md` §C). Unblocks R5.

**Two failure classes, and only one is a compiler's job.** Both were closed by different means. A WRONG CALLER mutates the tables directly
instead of through the door; deleting the direct route makes the compiler name every one, which C2.0
proved by accident when it surfaced an eleventh site two hand-derivations had missed. A MISSING CALLER
changes the port and touches the seam not at all (dictation, the emoji picker, right-click paste, a
cross-app drag, an SPA route change); **nothing fails to compile, so only measurement finds those** and
Spike C measured the web listener at 8 of 11.

**It was NOT resolved when C4 landed**, and that distinction is the entry's lesson: C4 proved nothing
bypasses the door, C6 proved things arrive at it. Two of C6's four candidate findings evaporated on
re-measure (web dictation, the emoji picker), which is why the run is trustworthy — the first pass
would have shipped both as holes.

---

## 3. Trust — how we know who did it · **INPUT RESOLVED**

**Status: ✅ input resolved 2026-07-27 (R7); reads and the gateway still open.**

R7 was planned as "move the human's claim off page-reported `isTrusted`, which a page can shadow".
**Measuring it killed the premise and found a plainer hole underneath.**

| claim | measured |
|---|---|
| ~~a page can shadow `Event.prototype.isTrusted`~~ | **False in WebKit.** `isTrusted` is an OWN property on each event instance, so the prototype is not in the path, and redefining it on the instance throws: it is non-configurable. Three attacks, all refused. |
| the injected listener is the only way in | **False.** The handler itself was registered in the PAGE world for web ports, so a port's own JS called `window.webkit.messageHandlers.portInput.postMessage(1)` and bumped its own token while naming the human as driver. No event, no trickery. |

**The origin pin was the wrong instrument here, in both directions.** It asks WHICH SITE is calling. A
web port forging its own input genuinely is `port42.local`, so the pin passed; a browser port's honest
keystroke carries the foreign site's origin, so the pin rejected it, which is the C6 defect where
typing in a browser port counted for nothing.

**Now: one mechanism for input, for every port type.** The listener and its handler live in an
isolated `WKContentWorld`, so a page cannot see the handler, cannot call it, and cannot reach the
listener's prototypes. `PortInput.Trust.reportedByPage` is DELETED — nothing ever constructed it, so
the type was promising a distinction the code never made.

| mechanism | where | strength |
|---|---|---|
| isolated content world | port input | native; the page has no handle to forge with |
| origin pin (`port42.local`) | the bridge's own handlers | native, unforgeable by page content |
| an authenticated principal | bridge dispatch | only as good as §1 |

**Still open, and neither is input:** reads are uncovered, and the gateway authenticates nobody
(`plan-gateway-auth-tls` P1). P0 shipped in v0.5.50 after three days in `main` behind a doc that said
it already had; `/call` still assigns the shared `local-http` identity with no `RemoteAddr` check, and
P1 must RETIRE that principal rather than gate it.

## 3b. Presence — who is driving · **RESOLVED**

**Status: ✅ RESOLVED 2026-07-27** (L2 step 3). It had two homes: a `DriverRegistry` storing who
acted on a port, beside an activity counter that already moved when someone did. Now one — the
driver is **derived** from whoever last moved the port's token, so a stored copy cannot disagree with
it and a peer can check the claim against the token itself.

Focus stopped conferring presence with it (GM's call): it named a driver without moving the token,
which under derivation asserts presence while proving nothing.

**The rule that is not obvious:** an UNATTRIBUTED write moves the counter and leaves the attribution
alone. A companion's terminal write counts twice, attributed at the dispatch seam and unattributed at
the pty funnel, so clearing on nil would blank every companion's own chip.

---

## 4. Output — what leaves a port

**Status: ten publish sites**, emitting `console`, `terminal.output`, `push`, `driver`, plus
`port.publish`. Identical shape to §2, deliberately out of its scope (GM: input only, so a
consolidation does not become a rewrite).

Worth naming now because the input seam will make the asymmetry obvious: input will have one door and
output will still have ten.

---

## 5. Errors — what a caller can act on · **CODED SURFACE RESOLVED, DICT SURFACE OPEN**

**Status: ✅ every `BridgeError` carries a typed code (2026-07-28). ⚠️ ~90 device-bridge errors are
still built as bare dictionaries and carry NO code at all.**

**What was fixed.** Twenty codes had accumulated as string literals at their throw sites, which is
how `bad_args` came to sit beside `bad_arg` and `no_port` beside `not_found` — same meaning, two
spellings, so a caller matching one silently missed the other. A code is now a VALUE
(`BridgeErrorCode`), `BridgeError(code:)` takes it, and the set is enumerable, which is what lets it
be documented without going stale. Published in `ports-context.txt`, grouped by what a caller should
DO: retry with `current`, fix your call, the target, ask the user, something failed.

**Two collapses, and one that was reverted by its own criterion.** `bad_args` → `bad_arg` and
`no_port` → `not_found` merged as true synonyms. `access_denied` → `permission_denied` was made and
then undone, because the suite caught it and the test is the caller's FIX, not the English: a
capability is granted by the user, a path is picked with a file picker. Two repairs, two codes.
`no_surface` stayed apart from `not_found` for the same reason.

**`isRetryableWithCurrentState` is the useful part**, not the enum. It answers the single question an
agent asks of a failure, so nobody has to keep their own list of which codes self-correct. Pinned to
exactly `stale_write` + `token_required`.

**The ~90 hand-built `["error": …]` dictionaries are CLOSED (2026-07-28), at the boundary rather
than at the sites.** Across Screen, Camera, Audio, Browser, Automation, Notification, Clipboard and
ScreenRecorder, a failure was built as a dictionary and returned through
`return .fromJSONObject(result)` — **as a success**. Not merely uncoded: a caller that caught saw
nothing thrown, a caller that checked `code` found none, and a caller that asked "did it work" was
told yes. `screen.capture` with no display available answered like a capture that worked.

Converted in ONE place (`failIfErrorResult`, at the dispatcher every registry method already funnels
through), because the ninety share one boundary and each would otherwise need its own signature
change and its own judgment. The code comes from the method's FAMILY, which is the only thing
derivable without guessing at a message: `screen`/`camera`/`audio`/`clipboard`/`notify` →
`device_error`, `browser` → `browser_error`, `ai` → `ai_error`, `fs` → `io`, `automation` →
`script_error`, anything else → `method_failed`.

**Deliberately coarse, and that is the floor rather than the ceiling.** A permission failure inside
`ScreenBridge` deserves `permission_denied` rather than `device_error`; sharpening one is now a
one-line change on a surface that carries a code at all.

**`script_error` came out of the live check**, not the design: `run_applescript` with `error "boom"`
fell through to `method_failed`, which told a caller nothing about whose fault it was. `automation.*`
runs caller-supplied source exactly as `port.exec` does, so it earns the parallel of `js_error`.

**The rule is narrow on purpose:** only when `error` holds a String and the object carries no other
data. A `browser.error` payload carries `sessionId`, `url` and `error` together — that is data about
something that happened, not this call failing. Pinned by a test in both directions.

**Still uncoded, and it is not Swift: the GATEWAY's own errors.** `{"error":"timeout waiting for host
response"}` comes from the Go gateway, which has no taxonomy of its own. Small surface, real, and it
belongs with the gateway auth work since that is the next thing to touch that file.

**A defect found by looking, not by the taxonomy:** `port.rename` against a port that does not exist
answered `{"ok": true}`. **Fixed 2026-07-28.** Worse than a missing code — a caller is told its write
landed when nothing happened, and nothing looks wrong enough to retry. Same class as `port.push` with
a missing `data` typing the string `null` into a live shell (`summer2026-todo.md`), and the reason
that class matters is that a verb whose declaration and behaviour disagree cannot be reasoned about
by a caller at all.

## Not primitives

Kept here so they are not mistaken for the list.

- **Time.** `PortPresence` takes `now` as a parameter, which is the right discipline, but callers use
  `Date()` directly and there is no injected clock. Real, low value, no guarantee rests on it.
- **Space scoping.** Suspected, unverified. Not listed until counted — the register does not carry
  hunches.
- **The Crew / the Face** (`docs/membrane/`). Retired as an organizing frame: they name capabilities
  that map to nothing enforced, and no test fails if one disappears. History, not structure.
