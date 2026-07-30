# Handoff: Slice-02 — one slice, local seams through libp2p

## Where this left off (2026-07-30)

**On `main`**, tree clean apart from one untracked file, `docs/plan-teleport.md`, which is GM's and
was left alone. Suite **1256 green** (plus the `gateway/` and `cli/` Go suites). Everything is
UNPUSHED, deliberately — GM: no shipping and no pushing until the slice completes.

### THE LOCAL HALF OF SLICE-02 IS COMPLETE. Next is milestone B, the wire.

Every row of Part 0 that the local half owns is built, so adding libp2p should now mean writing a
verifier and a transport and touching nothing above the seam. That claim is the thing milestone B
tests.

**Half one** (no authentication in it): port 0 exists and every grant names its object
(`portGrant.<grantee>.<object>.<zone>`, peer-qualifiable); the store is a TABLE with one row per
permission; the permission manager is Settings → Access, grouped by grantee, revocable per
capability; the card names its object; the `remoteAllow*` blanket pre-grant is deleted.

**Half two** (authentication): `ClientRegistry` is the only place a token is minted. Enrolment has a
route for every caller — a child at spawn, the `port42` CLI at install, anything else by hand in
Settings. `is_host` is proven by a per-spawn credential rather than believed. **`local-http` is
deleted and an unnamed caller is refused** with a message that names the fix.

**Verify like this, in Dev3:**

```
curl 127.0.0.1:4245/call -d '{"method":"space.current"}'
  → auth_required, naming Settings → Access

curl -H "Authorization: Bearer $(cat ~/.port42/port42dev3/tokens/port42-cli)" …
  → served
```

**READ `docs/membrane/slice-02-cross-instance.md` IN FULL FIRST.** It is now the single document for
this thread: the model, the requirements, the design D1-D14, the deliverables, the build order, the
verification matrix, the four spikes and the open questions. There is an HTML rendering beside it
(`slice-02-cross-instance.html`, self-contained, regenerate with pandoc if the markdown moves).

### THE RESCOPE (GM, 2026-07-28) — this is the thing that changed

**Gateway auth P1 is no longer a phase BEFORE slice-02. It IS slice-02's local half**, built in the
shape that lets libp2p slot in rather than land on a refactor. The permission manager rides with it.
One slice, one document. `plan-gateway-auth-tls.md` keeps P0 (shipped) and the TLS phases only; its
P1 section is a pointer.

**Part 0 of the slice doc is the spine**: per noun, what the local half must build and what libp2p
then adds, with the test written down — *adding libp2p should mean writing a verifier and a transport
and touching nothing above the seam.*

### THE MODEL (GM): the desktop is a port. PORT 0.

ONE primitive, a port. Port 0 is the Port42 window itself (its title is the user-facing name). Zones
(a space is the first) group ports ON TOP of the primitive and are never a kind of object. So
`caller -> port -> action -> permission` holds with no exceptions.

**The measurement that settles it:** production holds 143 grants, EVERY one a port 0 capability
(120 terminal, 21 rest, 18 screen, 18 filesystem, 12 ai, 8 clipboard, 6 automation, 2 microphone,
1 notification), and 140 of the 143 keys are space-scoped. So `portPerms.<grantee>.<spaceId>` names a
grantee and a space and **no object at all**. The object was always the machine; having no name it
left an empty slot and the space slid into it. Register entry: `architecture-invariants.md` §6.

### HALF ONE IS COMPLETE (2026-07-29, all three steps live-verified in Dev3). NEXT: half two.

**Step 3: the card names its object, and the blanket pre-grant is gone** (slice doc §10a3).
`scopeDescription` reads "Allow for Claude Code **in Port42**, everywhere. Take it back any time in
Settings → Access" — two things it could not say before, because until step 1 the object had no name
and until step 2 there was nowhere to take it back. `remoteAllow*` is deleted from the source tree
rather than defaulted off, and **verified by falsification**: with `remoteAllowFS` written back to
`1`, a gateway `fs.read` BLOCKED on a prompt for a full 12 seconds instead of returning the file.
A tree-wide grep gate keeps it out, calibrated by re-adding a flag read. The dead
`PortPermissionOverlay` (no call site) is deleted. Both generated docs lost the pre-approval line and
`llms.txt` was regenerated. Suite **1206 green**.

**GM's decision, 2026-07-29: grants are PERMANENT.** No expiry, no auto-reap; revocation is manual in
Settings → Access. `lastUsedAt` still records use (throttled, one write per key per minute) because
it cannot be backfilled if that changes, but nothing consumes it. Open question 3 is closed.

**NEXT IS HALF TWO** — the credential, and it is where authentication starts. §9's order: (4) store
and mint, root secret and token files, clients appear in the manager as a grantee kind, nothing
enforces yet; (5) the seam and verifier together, `principal_id` written only by the verifier, a call
without one refused, `local-http` DELETED rather than preserved; (6) per-child registration at spawn,
which is where the pooled bucket actually dies. Step 5 is the only one with a blast radius, and by
then every caller has a token and the refusal teaches the fix. **Verify per door and per caller** —
the failure mode this whole scope is built on is a fix verified on one caller path and assumed to
hold on the others.

### STEPS 1 AND 2 (2026-07-29, live-verified in Dev3)

**Step 2: the grant store is a TABLE and the permission manager exists** (slice doc §10a2). Migration
`v43-grants`, one row per permission, so revoking a single capability is a DELETE where the old
comma-joined key made the smallest withdrawable unit everything. `lastUsedAt` from the start,
throttled to one write per key per minute, because it is the only honest basis for reaping later and
cannot be backfilled. The hot path needed a cache: `grants()` is read on every gated dispatch and used
to hit `UserDefaults`, an in-memory dictionary. The defaults sweep is now unconditional, its
once-only flag deleted as reasoning guarding nothing. The manager is the Access tab in
`SignOutSheet.swift`; `PortGrantDisplay.zoneLabel` is pure and tested, renders a zone by SPACE NAME,
and says "in a space that no longer exists" when it is gone — the one rule that would have made the
135 dead grants visible. Suite **1204 green**.

**Step 3 is what remains of half one:** the card names its object ("Claude Code wants to read the
clipboard in Port42"), delete the dead `PortPermissionOverlay` (no call site), and delete the
`remoteAllow*` blanket pre-grant (D12, five sites listed there, all three flags ON in production).

**Method note worth keeping (slice doc §10a2):** calibration caught a weak TEST this time, not just
weak code. Breaking `saveGrants` to reset a grant's age left the test green, because two `Date()`
values microseconds apart land in the same stored millisecond. A gate that has never been broken is
not known to be a gate.

### STEP 1 (2026-07-29, live-verified in Dev3)

**Port 0 exists and the grant key has its object slot**: `portGrant.<grantee>.<object>.<zone>`, with
`PortObject.machine` as port 0 and an object peer-qualified by construction (`<peerID>/0`). The store
API is now `grants(grantee:on:zone:)` / `saveGrants(…)`, three parameters for three key parts, so no
site can read a grant without naming its object (tree-wide gate). Suite **1183 green**. Detail in the
slice doc §10a.

**THE STORE IS REAPED, not migrated** (GM, 2026-07-29). Re-measuring it is what changed the call:
144 grants, not 143, and only **9 of them could ever fire again**. A grant is read with the caller's
LIVE zone, and 135 named a deleted space, so they were unreachable rather than untidy. 43 of 58
grantees matched nothing live, including `"Claude Code"`, `"Gemini CLI"` and `claude1`–`claude101` —
§1's weaker door showing up in the data. Nothing reaps a grant (119 → 143 → 144 across three days),
so the store starts empty and every caller asks once more. The raw store was dumped to
`~/Library/Application Support/Port42/grants-before-reap-2026-07-29.txt` before the reap ran.

**What step 1 handed to step 2, and how it was answered:** the store could not be enumerated
(`grants(grantee:on:zone:)` was a point lookup, and the only walk lived inside the reap). Rather than
parse defaults keys back into three parts, the store moved to a table — taken deliberately because
the window was free while the store was empty, and it closes the moment real grants accumulate.

**Still open, and neither step fixed it:** nothing expires a grant. `lastUsedAt` now records use,
which is the input a reap would need, but no policy consumes it (slice doc §13.3).

**Learnings from step 1 are in slice doc §10b**, including two that change how later steps are run:
measure whether data is worth migrating before designing the migration (a count is not a census, and
the number that reversed the design was one nobody had asked for); and **a seam with one possible
value must be tested with a second one**, which recurs at the wire half where `principal_id` has a
single verifier until libp2p adds the next.

Half two (the credential, the `principal_id` seam, deleting `local-http`) follows. §9 has the order.

### DECIDED, do not re-litigate

- **`remoteAllow*` is REMOVED** (GM 2026-07-28). Three UserDefaults flags union terminal, filesystem
  and screen into every gateway call before the principal exists, and **all three are ON in
  production**. Everything goes through the permission request path. Five sites, listed in D12.
- **No root token.** Every token is minted by a named act (connect a tool in Settings, spawn a child,
  add by hand). Pairing was designed and then dropped as the only genuinely new machinery.
- **The Keychain stays.** Spike A proved a new RELEASE does not prompt.
- **The permission manager is IN**, as touchpoint 3, not a follow-on.

### MEASURED THIS SESSION, and two of them corrected an earlier claim

- **Two doors, not one.** A local WebSocket client that names itself in `identify` IS that principal,
  and inherited a standing grant to run AppleScript with no prompt. Gating `/call` alone would have
  left the weaker door open.
- **`ps -E` publishes a subprocess environment** to any process running as the user, so the gateway
  takes its secrets over stdin (spike C: both arrive, and the EOF-on-death watch still fires).
- **The idle burn was the dreamscape, not Ghostty** — the first diagnosis was wrong. `sample` counts
  a parked thread and a busy one identically, so a thread census is not a CPU measurement. Fixed and
  committed (`90c34d6`): 24fps default, 27.4% -> 9.6%.

### OPEN, and both have everything they need

- **The chat-input beachball.** Caught live with `sample`. Full stack, database counts and ranked
  fixes are in `summer2026-todo.md`. **One question decides which fix works and it is unanswered:**
  ONE unbounded layout pass, or a non-terminating LOOP? `MainLoopProbe` is built and armed for it
  (`defaults write com.port42.dev3 PORT42_MAINLOOP_PROBE -bool true`, then
  `tail -f /tmp/port42-mainloop.log`). It reports from a background queue so it keeps working while
  the main thread is wedged. Likely explains the undiagnosed 2026-07-16 "app froze mid-demo".
- **A BREAKING release is pending.** v0.5.50 predates R5, so every shipped install still has opt-in
  CAS. GM was testing before cutting it.

### HARD RULES (survive the boundary)

- **Test in Dev3 (`:4245`) only**, `./build.sh --dev3 --run`. Dev `:4243` and prod need GM's
  go-ahead. Dev3 builds do not.
- Every build runs the full suite and aborts on red. **Do not commit or refactor unless asked.**
- **A build that reported a signing or copy failure is NOT evidence.** A `./build.sh` run that hit a
  codesign error and `Operation not permitted` on a resource copy still produced a launchable app in
  which every bundled video rendered black. It read exactly like a regression and cost real time.
  Rebuild clean before debugging any behavior. (On the copy failure: `xattr -cr
  .build/arm64-apple-macosx/debug`, and quit a running Dev3 so signing is not blocked.)
- Generated artifacts (`llms.txt`, `Tests/Fixtures/tool-definitions-golden.json`) have regen paths —
  READ THE DIFF. Never pipe `build.sh` through head/tail.
- No em dashes, US spelling, report style in docs. Present choices to GM as plain text, never an
  option box.
- **Booting a dev instance rewrites the global `~/.claude/CLAUDE.md` port42 block** to that instance's
  port, so a Claude session leaning on it curls that instance.

### METHOD (earned, and it kept paying this session)

Measure before designing; calibrate every gate by breaking it (the Keychain spike was wrong on its
first run because `codesign` derives the identifier from the filename); a thread census is not a CPU
measurement; let the compiler produce the caller list; done means live-verified, not committed; and
when you claim something about GM's data or usage, go and look rather than assert.

---

# Handoff: Port42 Protocol — Address · Actor · Token

## Where this left off (2026-07-28)

**On `main`**, tree clean, HEAD `6cbcdc6`, **14 commits UNPUSHED**. Suite **1172 green**. Dev3
(`./build.sh --dev3 --run`, `:4245`) is running all of it, live-verified. **Dev3 builds no longer need
GM's go-ahead** (GM, 2026-07-26); Dev `:4243` and prod still do.

**THE PROTOCOL THREAD IS COMPLETE.** All three nouns are single-definition, honest and live-verified.
Slice-02 is now a transport change rather than a redesign. Four things were finished after it, each
scoped as one item and each with something larger underneath (see "the pattern", below).

**The ORDER of work lives in `docs/summer2026-todo.md` → WORKING ORDER**, added 2026-07-28 so it
survives a session boundary. Next item there: **gateway auth P1**, whose design is written up in that
same file (token file, Keychain store, per-instance path, Settings subsection, CLAUDE.md rewrite).

**A BREAKING RELEASE sits between here and slice-02, and GM is testing before cutting it.** v0.5.50
predates R5, so every shipped install still has opt-in CAS. The release carries: mandatory tokens on
every write, `port.exec` scalars reshaped to `{value, token}`, `port.push` no longer auto-submitting a
newline the caller did not send, port event kinds namespaced under `port.`, error codes across the
surface, and the P0 hardening (`ba6a8f6` + R7) that missed the v0.5.50 cut. **The P0 ESCAPE itself is
closed in the shipped build** — `df1b07f` predates the release; only the hardening is unshipped.

### What landed after R7 (2026-07-28)

- **The write-response contract** (plan §G). A response now describes the state AFTER its effect. The
  token is read after the body, the terminal's deferred Enter is awaited, scalar results carry a
  token, and `port.create`/`update`/`patch`/`restore` await the document (measured: create answered
  0.24s before the DOM existed).
- **The output namespace.** `PortEventKind` types every system kind; a port's own kind is prefixed
  `port.`, so a port cannot emit `driver` or `browser.load`.
- **The error taxonomy** (register §5, closed on the app side). A code is a value; ~90 device-bridge
  failures were being RETURNED AS SUCCESSES and now throw with a family or site code; codes are
  sharpened where the caller's action differs; published to both audiences and gated against drift.
- **`port.rename` on a missing port answered `{"ok": true}`.** Fixed.

### The pattern worth carrying into P1

**Every item was scoped as one thing and had a larger thing underneath, and the cause was always the
same: a fix verified on ONE caller path, assumed to hold on the others.** There are three — the JSON
caller (gateway/curl), tool use (an in-app companion), and port JS (`window.port42`). The error code
reached the first, then the second, and only after GM asked "is there any testing we need to do inside
a port?" did it reach the third, where the manual's own documented retry loop had never been able to
run. **P1 has three paths of its own** (a typed curl, the app's children, the gateway subprocess), so
verify each rather than one.

### READ THIS FIRST: the frame

**`docs/plan-port42-protocol-local-bus.md` §A is THE single plan** for this thread. Everything below
§A in that file is the detailed record (phases, spikes, findings 1–7) — accurate as history, but §A
governs. `docs/architecture-invariants.md` is the canonical REGISTER beside it: what must have one
definition and whether it does. **Ordering lives in the plan, status lives in the register.**

**A protocol write is three nouns: an ADDRESS, an ACTOR, and a TOKEN** — *port X, by Y, composed
against state Z*. That is the whole contract locally and over the wire; slice-02 changes the transport
and nothing else. Each noun must have exactly one definition or the protocol lies the moment there is
a second instance.

| Noun | State |
|---|---|
| **ADDRESS** | ✅ done — `PortRef.key`, one definition where there were three |
| **TOKEN** | ✅ done — the counter, CAS, every way in counting (I2/C6), and mandatory (R5). Known limit: a browser page mutating its DOM without changing its URL still does not count |
| **ACTOR** | ✅ **done 2026-07-27** (I1.1–I1.6). Measured first, which killed the defect both plans led with and found two nobody had named. One private `Principal` constructor; a gateway-created port authorizes as itself, not the shared `local-http`; no identity is a heap address. |

### NEXT: L2 R7, then slice-02

**Step 3 is DONE and live-verified (2026-07-27), and so is a defect sweep it provoked.** All three
nouns are now single-definition: ADDRESS, ACTOR (identity + presence) and TOKEN. Suite 1146 green,
running in Dev3.

**Step 3:** presence is no longer stored. `DriverRegistry`, `PresenceThrottle`, `release`, `handoff`
and the seam's second door are deleted; the driver is derived from whoever moved the port's token
last. GM's call: **focus stops conferring presence** — it named a driver without moving the token,
which under derivation asserts presence while proving nothing, and a peer cannot verify a focus at
slice-02. Zooming into a port and not touching it now leaves the chip naming the companion that is
actually writing. Clicking or typing inside the surface still names you.

**One rule that no test would have caught:** an unattributed write moves the counter and leaves the
attribution alone. A companion's terminal write counts twice (dispatch seam + pty funnel), so
clearing on nil would blank every companion's chip the instant it wrote.

**R6 is absorbed** — with a derived driver there is no expiry to tune, only a display fade.

### The sweep GM's instinct produced (plan §G) — three defects, all fixed

Told that a terminal write counts twice, GM said *"sounds like a bad smell"*. Measuring it live found
that **R5's central promise was false on terminals**: the response token was captured before the body
ran, so threading it was refused every single time. Also: `port.push` submitted an Enter the caller
never sent, contradicting its own schema; and a write returning a SCALAR (`port.exec`, the verb
agents use most) carried no token at all, forcing a re-read before every write. All three fixed and
live-verified; `port.exec` scalars are now `{value, token}`, a deliberate break taken while adoption
is near zero.

**The 80ms deferred Enter was measured, not deleted, and the measurement reversed the plan.** A plain
bash port submits on every form; claude's TUI depends on LENGTH (~60 chars submits any way, 1273
chars only as body-then-separate-Enter). Real prompts are long, so the split is load-bearing. The fix
was to AWAIT it.

**A fourth defect, found by pulling on that thread and now FIXED.** `port.exec` chose how to run
your JS by a SUBSTRING match for `return`/`throw`/newline on the raw source, so an id, a selector, a
comment or an identifier like `returnValue` skipped the wrap and the call **silently returned
nothing** — `document.querySelector('#returned').textContent` came back `{ok: true}` with the value
gone. Replaced with a scan that skips strings, comments and regex and counts only real keywords; a
compile trial in the page was rejected (ports ship a CSP with no `unsafe-eval`) and so was
run-then-retry (it re-executes side effects). Failures now carry `js_syntax` / `js_error` /
`js_timeout` plus `ran`, the body actually executed. Register §5 closed for this verb.

### R7 is DONE (2026-07-27), and measuring it killed its own premise (plan §H)

R7 was "move the human's claim off `isTrusted`, which a page can shadow". **A page cannot shadow it
in WebKit** — measured three ways: it is a non-configurable OWN property on each event instance. The
real hole needed no trickery: the input handler sat in the PAGE world for web ports, so a port's own
JS called `window.webkit.messageHandlers.portInput.postMessage(1)` and bumped its own token while
naming the human as driver. Precedent nobody connected: the onboarding shader that held the human's
presence forever, where the `isTrusted` guard closed the event path and left the door beside it.

Fixed as planned but for the other reason: the listener and handler now live in an isolated
`WKContentWorld` for EVERY port type (browser ports have since C6). The handler's origin pin is
deleted (it asked which SITE, and answered wrong in both directions) and so is
`PortInput.Trust.reportedByPage` (never constructed — every path already claimed `.native`, including
the forgeable one). `PortOriginSecurityTests` now asserts pinned OR isolated, which is the real
invariant; calibrated by a handler that is neither.

**Live-verified in full** (trusted input produced via System Events, which needs both Automation and
Accessibility): the forged `postMessage` throws a TypeError; a real click inside the tile counts once;
a click outside does not; four idle seconds do not; and really typing "hello" moves the token twelve
times while the characters arrive in the DOM (`keydown` + `beforeinput` per character, by design).

### What is left in the protocol thread

- **Slice-02**, which is now a transport change rather than a redesign: all three nouns are
  single-definition and honest.
- Nothing outstanding in the protocol thread. Step 3's chip check and R7's typing check are both
  done; every noun is single-definition, honest and live-verified.
- Carried forward: the output seam (six publish sites, GM deferred), orphaned `portPerms` grants,
  plan §D marketing copy, and the rest of the API parity sweep.

### What R5 changed, because it is the live contract now

**Every write must carry the port's `token`**, or it is refused with `token_required` carrying
`current`. No surface carve-out, no exemption for humans. This REVERSED R3's "nothing that works today
breaks", deliberately: opt-in CAS asked for discipline from the wrong party, since your work's safety
depended on the OTHER caller volunteering a token and almost nobody did.

It costs no extra round trips: `ports.list`, `port.create` and **every write** return a token.
`ports-context.txt` teaches the flow, so generated ports do it correctly.

**R1's reasoning survives, its slogan does not.** R1 removed a LEASE (refused you regardless, could not
be argued with, a vanished holder left a port stuck). R5 refuses only a caller who declined to declare
state and hands them the answer, so nobody is ever blocked. Two R1 gates were renamed, not deleted.

### Open decisions carried forward

- **Focus-confers-presence** (above) — blocks step 3.
- **The output seam.** Deferred by GM. Input has one door; output still has six publish sites, two of
  which accept an arbitrary caller-supplied kind. Register §4.
- **Orphaned `portPerms` grants.** Dev/prod hold keys nothing reads (`ObjectIdentifier(0x…)`,
  `http-caller-…`, `local-http.<space>`). Park-then-delete vs delete outright, GM's call.
- **Plan §D marketing copy** — the architecture page still promises right-of-way "decides who acts".
- **API parity sweep, not started.** Both holes GM found this session (browser ports uncreatable, chat
  unreachable) were capabilities the UI had and the API did not. Worth measuring the rest.

### Method rules this session earned (they keep paying)

- **Measure before designing.** I1.1 killed the defect both plans led with as unreachable and found two
  nobody had named. C6's first pass produced two findings that evaporated on re-measure.
- **A gate scoped to named files is not a gate.** Tree-wide walks only.
- **Calibrate every gate by breaking it.** Several were wrong on first write and passed anyway.
- **Green tests cannot see a lost closure.** Live-verify rewiring.
- **Done means live-verified, not committed.** P0 sat three days behind a doc that said SHIPPED.
- **Let the compiler produce the caller list.** Deleting a direct route found an eleventh site two
  careful hand-derivations had missed.

### Shipped this thread

- **L2 R1–R3**: the lease demoted to presence (last-driver-wins), the `<epoch>:<seq>` activity token,
  one pty surface writer, CAS with `stale_write` carrying `current`, and `port.getDom`.
- **A SECURITY P0**: a web port's JS could navigate to any site and the `window.port42` bridge went
  with it — live-verified, a page on example.com called `ports.list()` and got the user's ports back.
  Fixed by origin-pinning every message handler plus a destination allowlist.
- **Input coverage**: `beforeinput` added. Measured — the old two-event listener saw 8 of 11 real
  content changes; dictation, the emoji picker, right-click paste and a cross-app drag were invisible.
- **`PortRef.key`**: inline ports had no token, no presence and no CAS at all.

**v0.5.49 shipped** — notarized, stapled, GitHub Release, appcast pushed. Onboarding runs inside the
shell; all six phases of `plan-unify-onboarding-shell.md` are done.

### 1. DONE — the pre-boot cinematic regression (`summer2026-todo.md`, top item)

Fixed and live-verified on a fresh-data Dev3 launch (GM: "works great"). The cinematic had only ever
been triggered by `LockScreenView.diveIn()`, which first boot no longer renders, so it now runs from
the root instead: `RootScreen.playsBootCinematicAtLaunch(hasIdentity:isSetupComplete:)` is a pure
launch decision, and `TransitionRoot.onAppear` leaves `bootCinematicDone` **false** across it (so
`decide` returns `.none` and the overlay covers the gap, rather than the setup terminal rendering
under the video). `OnboardingShellTests` +2. Suite **1067 green**.

### 1b. THE FLAT SEQUENCE — read this before the section below

Plans had nested three deep (L2 → the input seam → identity). **`plan-port42-protocol-local-bus.md`
§A holds the one ordered line of work**, and nothing nests below it (the register carries status, not
order). **I1 · Identity is COMPLETE** and I2 (the input seam) is under way at C2.0. I1 went first
because presence and CAS are both built on `principal.id`, so anything identity got wrong would have
been inherited by both. See the section above for what it measured and what shipped.

The section below is the L2 thread's own detail and stays accurate; the sequence above governs order.

### 2. The L2 protocol revision, R1–R7

`docs/plan-port42-protocol-local-bus.md` §"Phase L2 REVISED" is the current design; the section below
it is superseded and says so. Read the REVISED section, its **Verification** findings 1–7, and the
two spikes before writing code.

- **What L2.a–e originally built (now SUPERSEDED by R1–R3 below, kept for the history):** a per-port
  lease, a dispatch gate that REFUSED writes, the holder broadcast, a `human` principal,
  interaction-claims, and the tile-header chip. The refusal is gone; everything else became presence.
- **What the design became:** the lease conflated correctness with coordination. Correctness moves to
  **state tokens (CAS)** — one activity `seq` per port, bumped by every external mutation — and the
  lease is **demoted to presence** (shows who is driving, refuses nothing).
- **R1 (demote) is DONE**, both gates passed — including the manual one live in Dev3: GM clicked into
  a port (taking presence) and a gateway `port.exec` against it LANDED, where the pre-R1 build
  refused it by name. `claimWrite` → `recordDriving`,
  `LeaseRegistry.check` → `record`, `LeaseDecision.denied` deleted, `port_busy` gone from the
  codebase. The call it forced: **last driver wins** — the step's gate requires presence to MOVE on
  a second writer, and a record that refuses to move would leave the chip naming a companion that
  stopped while you type. See the plan's §"R1 as built". Suite **1067 green**.
- **Spike A is RUN** (see the plan's §"Spike A findings"). An in-memory dict on `AppState` works, with
  four corrections: resolve the port ONCE at the seam and share the key (the resolve is the only
  non-free part, not the lookup); do NOT make it `@Published` (R2b bumps per keystroke); do NOT
  forget it on close (opposite lifecycle to presence — a reset counter lets a token from a dead id
  pass against a reused one); and **a bare counter is unsafe across a restart**, so qualify the
  token with a per-launch epoch the way `ActorRef` was made peer-qualified from day one.
- **R2 is BUILT**, gate passed. `PortActivity` on `AppState`, token = **`<epoch>:<seq>`** (GM took
  A4: epoch now, not a wire-format migration at slice-02). The seam resolves the port once and hands
  one key to both the bump and `recordDriving`. The bump fires before the async body (wrong in the
  safe direction). The presence throttle deliberately does NOT reach the token — throttled, a
  4-second-old companion write would pass CAS against a line you are mid-way through typing.
- **R1b — rename + a throttle fix.** The lease was demoted but kept every one of its names, which
  made the whole subsystem unreadable (GM: "I thought we got rid of leasing"). `PortLease.swift` →
  `PortPresence.swift`, `LeaseRegistry` → `DriverRegistry`, `ClaimThrottle` → `PresenceThrottle`,
  wire `kind:"holder"` → `kind:"driver"`. Renaming it surfaced a live defect GM had already spotted:
  the 5s presence throttle meant a human clicking against a companion writing every 2s could NEVER
  win the header chip back. The throttle's premise ("re-claiming a lease you already hold is noise")
  died with the lock. Now it throttles a REFRESH and never a TAKEOVER. Suite **1081 green**.
- **R2b is BUILT**, gate passed, manual gate open. `GhosttyInputView.write(_:mode:)` is the ONLY
  caller of `ghostty_surface_text*`; five sites route through it (paste, file drop, inject's two
  halves, startup command, prefill), plus the web file-drop and browser address-bar paths. Pinned by
  `TerminalWriteFunnelTests`, a grep gate — the property is structural, not a list. Human keystrokes
  are a separate C entry point (`ghostty_surface_key`) with their own seam; the gate covers both so
  neither grows a second caller. Suite **1086 green**.
- **Spike B is RUN** (late — it gates R2's browser row and R2/R2b were built without it; the process
  lesson is in the plan). Answer: `didCommit` is necessary but NOT sufficient. Verified live that
  `history.pushState` changes the URL with no document load, so no commit fires and every SPA route
  change is invisible. Use **KVO on `webView.url`**. Browser CAS is the weakest token, with a reason
  now rather than a suspicion.
- **Spike B also found a SECURITY P0** (`summer2026-todo.md`, top): a normal web port's JS can
  navigate to any site and the `window.port42` bridge FOLLOWS IT. Live-verified — a page on
  `example.com` called `ports.list()` and got the user's real ports back. The nav policy allows
  `.other` (script-initiated, the hostile case) and cancels `.linkActivated` (a human clicking), the
  inverse of its stated intent. Browser ports carry the bridge onto every site by construction.
- **Spike C is RUN and MEASURED live** — the input sweep across all surfaces. Six ad-hoc seams for
  "input reached a port", split by surface TECHNOLOGY, which is the root cause of finding 7
  repeating. The web listener was `keydown`+`pointerdown`: **it saw 8 of 11 real content changes.**
  The three misses (emoji picker via composition, right-click paste, cross-app drag) involve no key
  and no pointer, so the port changed while presence lied and the token stood still.
  **FIXED: `beforeinput` added** — it fired on all 11, and a re-measure came back 7/7 seen, zero
  invisible. It does not replace the other two (it only fires for editable content; a canvas port is
  pointer-driven). Suite **1100 green**.
- **Two caveats on Spike C, both worth carrying:** (1) **dictation is still UNMEASURED** — the probe
  logged events but not which action produced them, so I inferred the labels and got one wrong
  (`fn fn` is the emoji picker on GM's machine, not dictation). The mechanism finding survives; the
  feature labels were a guess. A labelled probe (operator names the action first) is the right shape.
  (2) **Terminals have the same hole with no seam to fix it at**: `GhosttyInputView` implements no
  `NSTextInputClient`, so dictation/IME either do not work there or bypass `keyDown`, which is where
  `onHumanInput` hangs. A web port now has three input signals; a terminal still has one.
- **MEMBRANE REVIEW is on the backlog** (`summer2026-todo.md`) and **should be decided before R4/R5**:
  one `PortInput` seam carrying `(port, kind, actor, trusted)`, each surface technology reduced to
  translating into it. R5 ("terminals require a token") is only sound if every way in counts.
- **R3 (CAS) is DONE**, gate passed and live-verified — the first step that REFUSES anything, and the
  replacement for the lock R1 removed. Optional `expect` on every write verb; a mismatch throws
  `stale_write` carrying `current`, so a caller self-corrects in one retry. `expect` is injected
  centrally (`mapValues { $0.acceptingExpect() }`), so a write verb added tomorrow gets CAS by
  construction. Live: a 5-second-stale write was refused and the clobber never landed.
- **`port.getDom` is NEW, and came out of a gap R3 exposed.** `port.exec` is correctly a write, so
  inspecting a live port bumped its token and a caller invalidated its own read — "write against what
  you saw" was not expressible. `getDom(id, selector?) → {html, token}` is a true read: no bump, no
  `js` parameter (so a mutation cannot be smuggled through a read verb), and html+token from one
  instant. `port.getHtml` remains the stored SOURCE, which does not reflect live `exec`/`push`.
- **Next: the MEMBRANE decision**, before R4/R5 (see Spike C and the backlog item). Then R4–R7.
  Suite **1099 green**.
- **The rule that came out of it:** *bump at the SURFACE, not the API*. Enumerating callers failed
  three times (finding 7); the guarantee has to be structural, verifiable by grep.

### 3. Security thread (open)

`docs/plan-gateway-auth-tls.md`: **P0 is fixed in `main` but NOT SHIPPED** (corrected 2026-07-27: the
fix landed 53 minutes after the v0.5.49 release commit, so every shipped install binds every
interface; verified live). A release is the fix. P1, authenticating `/call`,
which today authenticates nobody — is open, and the callers are the work.
`docs/decision-identity-model.md` settles person/instance/actor and is the shared input to L2, the
gateway, and slice-02. **A port can still forge the human's presence claim** (`isTrusted` is
shadowable); R7 moves the claim to the native monitor.

---

# Handoff: The Conversation Surface → Onboarding Into The Shell

Living status. The thread: making the chat a real surface for ports, and the onboarding around it. This
session shipped the generic port-card work and pivoted to a bigger piece: unifying the first-swim
onboarding into the real shell. Grounded from git, not memory.

## Where things are

- Branch `main`, HEAD `745e495`. **The working tree is intentionally DIRTY** — everything below is
  uncommitted (GM has not asked to commit). Do NOT commit unless asked.
- Dev3 (`:4245`) is the test instance this session (`build.sh --dev3`, isolated `com.port42.dev3`).
  Dev (`:4243`) may be running GM's Maker/Critic loop — **test in Dev3 only.** Note: booting a dev
  instance rewrites the global `~/.claude/CLAUDE.md` port42 block to that instance's port (currently
  `:4245`), so a Claude session leaning on it curls Dev3, not prod.

## Shipped this session (committed 2026-07-24; tested-working in Dev3 unless noted)

- **Generic port cards.** Any surface-type port created from chat leaves a `[portref:<kind>:<id>:<title>]`
  card inline; its open action = open water + focus the port. `PortCardKind` (public) + `portRefInfo` /
  `portRefCard` in `ConversationContent.swift`; `postPortCard` + `openPort(id:kind:)` in `AppState.swift`
  (createPort emits for terminal + tiled web, gated on `createdBy != nil`). Terminal card **confirmed
  working by GM.** Supersedes the per-type `[terminal:]`/`[port:]` cards (kept for old messages).
- **Companion multi-message split.** A reply splits on a `[[SPLIT]]`-only line into separate chat
  messages (`splitIntoMessages` + rewritten `llmDidFinish` in `AppState.swift`). Onboarding uses it:
  welcome+port, then a separate terminal nudge. Confirmed working.
- **Inline port height floor.** `InlinePortLayout.minHeight = 300` (inline-only; ports stay resizable on
  the desktop) — fixes the collapsed-strip shader. Confirmed.
- **Ports beside the response (chat-UI step 2).** `MessageRow` renders text-left / ports-right when wide
  (`portsRegion`, `MessageWidthKey`, 720pt threshold), stacked when narrow.
- **Pop-out / card-open → open water.** All three pop-out paths + the card open call
  `ShellState.enterOpenWater()` (zoom → `.space`).
- **`echo-prompt.txt`** rewrite: welcome grounded in `port42-growth/positioning-core.md` (live surfaces,
  yours/local; NO "open water"/multiplayer wording); a bolder full-bleed alive shader port; the terminal
  nudge as a separate `[[SPLIT]]` message telling the user to type, verbatim, "create a terminal port and
  run claude".
- **Terminal prefill (`initialInput`), GM 2026-07-24: prefill WITHOUT send.** A terminal port can
  open with a line waiting, unsent, in the CLI's input box — the user presses Enter. Teaches the
  grammar (plain language → a live surface) instead of describing it, and keeps the action theirs;
  auto-run was rejected because it spends the first impression on an action the user did not take
  and lands on claude's own first-run friction (folder-trust, auth). `TerminalPortConfig.initialInput`
  (tolerant decode) → `Coordinator.typePrefill` (types the burst with NO trailing `\r`, once per
  surface) → `PortWindowManager.prefillTerminal` → fired from `makeTerminalController`'s
  `onSessionStarted`, the only honest "the TUI is up" signal (a timer races claude's boot). Exposed
  as `initialInput` on `port.create`; `echo-prompt.txt` tells Echo to pass one on the onboarding
  terminal and to point the CTA at it. NOT carried by `terminalSpawnRecords`, so a respawn does not
  re-prefill — deliberate, a prefill is a first-run gesture.
- **Tool-loop context fix (`LLMEngine.continueWithToolResults`).** Each continuation rebuilt from
  the caller's original messages, so every round but the current one was dropped: the model
  re-called tools it had already run and burned the depth limit mid-reply. The engine now carries a
  running `continuationMessages` transcript. Found via onboarding (Echo stopping after its
  preamble), but it affected EVERY multi-round tool turn. Note: tool-heavy turns now carry their
  full context, so a turn that calls `help` keeps that ~15k for the rest of the round trip.
- **`build.sh --dev3`** (`com.port42.dev3` / `:4245` / `Port42Dev3`).
- **`docs/summer2026-todo.md`**: two roadmap items — claude turn-detection → cross-space port peek;
  gemini + codex CLI-companion parity (the loop is claude-specific today).

## Unify onboarding into the shell — phases 1-4 BUILT + COMMITTED (2026-07-24)

Onboarding now runs inside the real shell. `SetupView.startTransition` ends in
`AppState.enterShellFromSetup()`; the shell opens focused on the space's chat tile (applied
reactively, latched) and seeds the first message there. `SetupView.swim` is unreachable and
retires with phase 6. Also: first boot goes straight to the BIOS (no lock screen, no dreamscape
loop, black plate behind the terminal), the seam takes a black reveal plus a scale/opacity
materialize rather than the blue dive tint, and the first space is named `genesis`. The opening
line is PREFILLED in the input, not sent — the user presses Enter (same call as the terminal's
`initialInput`). Phase 4's nudge is resolved as prompt text in `echo-prompt.txt` (zoom out to the
terminal, where claude waits with a line already typed), not shell chrome. Full detail, including
the GM decisions and the THREE root-cause bugs found while testing it (LLMEngine tool-loop context
loss, double companion turn per message, welcome port posted as a tool card ahead of the text), is
in `docs/plan-unify-onboarding-shell.md` §Phases. New suite: `OnboardingShellTests` (11).

**Phase 5 BUILT but UNCOMMITTED** (in the tree, seen and approved by GM): inline ports are capped
at 520 (`InlinePortLayout.maxWidth`, a port's default width) while the TEXT keeps the full width of
the chat, and ports-beside-response is deleted outright. The centered-column layout the plan
originally called for was built, shown, and rejected — see the plan's phase 5 for what replaced it.

**ALL SIX PHASES DONE (2026-07-24).** Phase 6 deleted the `.swim` phase, the 🐬 button, the branded
bar, `sendFirstMessage`, `.enterAquariumRequested` + its transition, and the orphaned Settings sheet.
The breakout moved onto the first zoom-out: it starts on the focused port's frame, grows to full
screen over 2.6s, and any ladder move skips it. Setup is now the BIOS and the handover, nothing else.

## Original next-steps note (superseded by the section above)

Read **`docs/plan-unify-onboarding-shell.md`** in full — resolved flow, six phases, testing spine, the
component/interface/invariant review, and Spike 1's verified finding. Summary of the target flow (GM,
2026-07-24): boot terminal with NO background video → drop into the **focused shell chat** in the first
space (the swim = focus view on the chat tile) → after the first terminal port, a text hint "zoom out to
see your space (or the top-right arrow)" → **kill the 🐬 "swim in open water" button** → the first
zoom-out (focus→space) plays the breakout video and lands you in open water. Centered-column layout = the
focus view.

**Immediate next step: Phase 1 (entry seam).** After `completeSetup`, flip `isSetupComplete` + set a
one-shot `isOnboarding`, drop into `ShellView` instead of `SetupView.swim`, focus the chat tile
**reactively when the chat panel appears** (Spike-1 caveat — `switchToSpace`→`ensureChatPort` guarantees
it exists, but not at a fixed `onAppear`), seed the first message in-shell, and drop the boot-terminal
background video. Not yet: breakout-on-zoom-out, the hint, killing the 🐬 button, centered-column. Build
Phase 1, fresh-reset Dev3, verify onboarding lands in the focused shell chat with Echo playing and no
blank frame — that proves the risky part.

## Hard rules (survive the boundary)

- **Test in Dev3 (`:4245`) only** (`./build.sh --dev3 --run`), never prod. Fresh onboarding needs a data
  reset: move `~/Library/Application Support/Port42Dev3` aside, then relaunch.
- **Never run `./build.sh` or relaunch Dev without asking.** **Do not commit or refactor unless asked.**
- Build gotchas: on cp "Operation not permitted", `xattr -cr .build/arm64-apple-macosx/debug`. Never pipe
  `./build.sh` through head/tail (redirect to a file). `ConversationContent.body` is at the type-check
  limit — extract subviews before adding. `AppState` has no SwiftUI import (put view animation in
  `ShellState`). Run test suites by EXACT name (bare "Port" once SIGTERMed prod); keep `completeSetup`
  behind `isTestProcess`; never interrupt a build/test (wedges the `.build` lock).
- No em dashes in prose; US spelling; report style in docs.
