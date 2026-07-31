# Caller identity: the defects the 0.5.52 soak found, and the order to fix them

**Opened 2026-07-31**, during the soak of the first release build since slice-02's local half. Every
item here is a defect in milestone A (`membrane/slice-02-cross-instance.md`), found by using the
product rather than by reading it. Nothing here is wire-half work.

**The trigger.** A Claude Code session tried to create an HTML port over the gateway and could not
authenticate. It borrowed the CLI's token, which worked. A second session, told not to borrow,
reached for `~/.port42/port42/tokens/claude-code` and got `auth_revoked`, a token whose MAC verifies
against prod but whose client row does not exist.

**Both are symptoms of one thing: a caller that should have an identity does not have one, so it uses
somebody else's.** That is the exact failure §1 measured before half two, arriving by a new route.
Instead of a caller naming itself, a caller wears a real client's name, which is harder to see than
`claude101` was.

---

## What is actually true, measured 2026-07-31

| | |
|---|---|
| prod `clients` table | ONE row: `port42-cli`, created 07:17:29, which is the 0.5.52 boot |
| prod `tokens/` | THREE files, all written 07:30:31: `claude-code`, `port42-cli`, `scripts` |
| prod `grants` table | THREE rows, all keyed to `local-http`, an identity 5b deleted. Inert |
| `port42dev4/tokens/` | `port42-cli` only. No `child-*`, though Dev4 runs companion sessions |
| `port42dev3/tokens/` | two `child-*` files plus `port42-cli`. Enrolment DOES work there |
| this companion's env | `PORT42_COMPANION_PROMPT` and `PORT42_SPACE_ID` set; **no `PORT42_CLIENT_ID`, no `PORT42_TOKEN_FILE`** |

The two orphan files are inert: no row, no grants, nothing references them. Deleting them changes a
caller's answer from `auth_revoked` to `auth_required`, which is the more accurate one.

## Root causes, and each is separate

**RC1 · The test suite writes into the daily driver's credential store.** `register()` writes a
database row and a token file. In a test the database is in-memory and disappears; the file is on
real disk and does not. `AppState.clientRegistry` (`AppState.swift:1185`) is the only registry in the
tree built without an explicit instance, so it resolves to `currentInstance`, which is `"Port42"`,
which `tokenDirectory` lowercases to `port42`, which is prod. So a test that builds an `AppState` and
registers anything mints with **prod's real Keychain root secret** and writes into **prod's token
directory**. That is where `claude-code` and `scripts` came from, at 07:30:31, during a `swift test`
run. `ClientRegistryTests` already does this correctly with throwaway UUID instance names, so the
pattern exists and `AppState` is the one place that bypasses it.

*Worse than the orphans it left:* `revoke` deletes a token file, so a test revoking `port42-cli`
would delete the running app's CLI credential.

**RC2 · A spawned terminal can be a companion and have no identity.** The credential is issued only
`if let companionId` (`TerminalHooksService.swift:246`), while everything else that makes a session a
companion arrives via `companionPrompt` (`:255`). `spawnNativeTerminalPort` takes
`companionId: String? = nil`, so a caller can spawn a terminal with a companion name, prompt and
space and omit the id. Two parameters for one fact, and they can disagree. Dev3 has child tokens;
prod and Dev4 have none.

**RC3 · The first thing every companion reads teaches the unauthenticated call.** The baked companion
prompt carries a bare `curl` with no `Authorization` header and no mention of `$PORT42_TOKEN_FILE`.
`InstructionService.buildMarkdown` has no credential text at all. The slice's own Docs deliverable
said the curl examples gain the header; it was never shipped. So the credential a child already holds
goes unmentioned, and the refusal becomes the only teaching surface.

**RC4 · The refusal is addressed to a human.** "Add a client in Settings → Access" is correct for a
person and useless to a process, and it never says WHICH instance refused. A token that is valid for
one instance fails another by design (NFR4), and that is invisible from outside.

**RC5 · Nothing reaps a credential or a grant whose owner cannot exist.** Two orphan token files and
three `local-http` grants, all inert, all sitting there looking real.

## Decided (GM, 2026-07-31)

- **Every terminal Port42 spawns is enrolled**, companion or not. §10a5's "ad-hoc terminals get no
  identity rather than sharing one" is too weak inside Port42: the spawn IS the named act. Only a
  terminal outside Port42 is a stranger.
- **Teach it in the prompt**, not only in the refusal.
- **The refusal names the instance that refused.** Cross-instance routing is a p2p concern and will
  be handled there; until then the refusal has to be legible.

## Not in this pass

- A unix socket with kernel peer credentials, the only real fix for same-uid impersonation. Any
  process running as the user can read any token file, which §9 already concedes. Large, out of slice
- A CLI verb that raises an in-app consent prompt, which reopens the dropped pairing decision (D5)
- A Settings row for `blockedBy` and `notOnPath`, both published and neither rendered

---

## The work, in order. A first, because it is currently making things worse.

Status: ☐ open · ☑ done. Every gate calibrated by breaking it, per the thread's standing rule.

### A · Test isolation — ☑ DONE 2026-07-31, suite 1290 green

- ☑ **A1** `tokenDirectory` roots at a per-process temp dir under a test runner. **The instance NAME
  was never the protection**, which is how this broke: `AppState` passes no name, so it resolved to
  `"Port42"` and lowercased into prod. Rooting the whole path covers callers nobody has written yet
- ☑ **A1b** The defect itself, reproduced: a registry built with NO instance, registering, must write
  outside the home. A1 and A2 pin path *resolution*, which is not what broke, so this one runs the
  actual sequence `AppState` runs
- ☑ **A2** `rootSecret()` is per-process and in memory under a test runner. Same-instance registries
  still share a secret and different instances still differ, so NFR4 stays exercised
- ☑ **A4** Both gates test `ClientRegistry.currentInstance` FIRST, which is the value `AppState` gets
- ☑ **A5** Calibrated with `PORT42_FORCE_REAL_INSTANCE_IN_TESTS=1`. The gate reports
  `a.rootSecret()` **equal to prod's real root secret**, and A1b re-creates
  `~/.port42/port42/tokens/claude-code`, the exact file this plan opened on. Demonstrated, not argued
- ☑ **A-note** Calibration also caught the new test violating NFR2: `#expect` prints both operands on
  failure, so the first version printed the root secret into the log. Compared into a Bool first.
  **Fourth time in this thread that calibration caught the test rather than the code**

*Proof it holds: after a full suite run, the mtimes in `~/.port42/port42/tokens/` were unchanged, and
the writes landed in `/var/folders/…/T/port42-tests-<pid>/`.*

### B · Enrolment (RC2) — ☑ DONE 2026-07-31, live-verified in Dev3 and again on Dev2's first boot

- ☑ **B1** A companion spawn produces `PORT42_CLIENT_ID` + `PORT42_TOKEN_FILE` and a row, registered
  before the controller is built so the file exists when the child looks
- ☑ **B2** A terminal Port42 spawned with no companion is enrolled too, keyed on the port id.
  **This REVERSES §10a5's rule**, which said an ad-hoc terminal gets no identity rather than sharing
  one. That was right about sharing and wrong about nothing. The existing test asserting the old rule
  was rewritten rather than deleted, and it still pins the anti-pooling property the old rule was
  really protecting
- ☑ **B3** Pooling is still impossible: an ad-hoc terminal's id differs from a companion's, from
  another terminal's, and from the same terminal in another space
- ☑ **B4** The exact defect as a test: a spawn with a companion PROMPT and no id still gets an
  identity. One resolver, `spawnedTerminalId`, used by both the env and the registration, so the two
  cannot disagree about who the child is
- ☑ **B5** Respawn lands on the same id, for a companion and for an ad-hoc terminal
- ☑ **B-calibration** Gate restored to `if let companionId` and all three tests fail, B4 on exactly
  the live symptom: prompt present, `PORT42_CLIENT_ID` nil
- ☑ **B6** Live. In Dev3 a created terminal got a row, a 0600 token file, and its own token
  authenticated against the gateway and was served. GM then ran `echo $PORT42_CLIENT_ID` in a real
  terminal and it printed `terminal-ecef7daa-…-4b60409c-…`, which is the variable reaching the shell
  where an agent can actually read it. Confirmed again on Dev2's clean first boot, where a restored
  companion terminal enrolled as `terminal-40999e56-…` named "claude code".

  **Two of my probes returned confident wrong answers before that one line settled it.**
  `terminal.exec` against a port with no live shell ran as a subprocess of the app and reported
  success with output from the wrong environment (now G), and a `ps -E` sweep found nothing because
  no shell had spawned for an API-created tile. A probe that cannot fail loudly is not a measurement.

### C · Instructions (RC3) — ☑ DONE 2026-07-31, live-verified on Dev2

- ☑ **C1** The companion prompt carries the header, names `$PORT42_TOKEN_FILE` and
  `$PORT42_CLIENT_ID`, and says not to read another tool's token file. Its text was extracted to a
  pure `AppState.companionPromptText` so the gate can scan it without an app, the same shape as
  `PortGrantDisplay.zoneLabel`
- ☑ **C2** `InstructionService.buildMarkdown` gained a "Who you are when you call" section and the
  header on every example; `llms-preamble.txt` the same; `llms.txt` regenerated through
  `PORT42_REGEN_DOCS=1` and the diff read, 18 insertions and 8 deletions, all of them the header and
  the new paragraphs
- ☑ **C3** Gate scans every generated surface for a `curl` at `/call` without an `Authorization`
  header, judging continuation lines as one command so a header on the next line still counts. It
  also asserts the scan found some curls at all, so it cannot pass vacuously
- ☑ **C-calibration** Stripped the header from one preamble example; the gate failed naming the file
  and the exact line
- ☑ **C4** Live on Dev2 (4244), chosen because its database predated the `clients` table, so this
  was a clean first boot rather than an upgrade. The block written at boot carries the header and
  the new section, where it had ZERO `Authorization` lines before. First boot created the table,
  enrolled `port42-cli`, and enrolled a restored companion terminal as `terminal-40999e56-…` named
  "claude code" — the population that had nothing this morning. Then, seconds apart on the same
  instance: the documented call using that terminal's OWN token was SERVED, and the call the old
  docs taught, with no credential, was REFUSED with `auth_required`

**What C does NOT do, deliberately.** It cannot stop a caller reading another tool's token file,
because §9 concedes that any process running as the user can. It removes the REASON to: the honest
path is now the documented one, and the borrow is named as a wrong answer rather than left as the
only working example.

### D · Refusal (RC4) — ☑ DONE 2026-07-31, all four verified live on Dev2

- ☑ **D1** Every refusal names the instance and the port that refused. **Worth its weight only on a
  machine like this one** (GM, 2026-07-31): five instances run here, and a token valid three ports
  away fails with nothing to distinguish it from a broken one. A user with ONE Port42 gets little
  from this line, and the claim should not be oversold
- ☑ **D2** A token from another instance says so, rather than reading as a broken credential
- ☑ **D3** The remedy a PROCESS can execute comes first: read `$PORT42_TOKEN_FILE`. Settings →
  Access survives for a caller Port42 did not start. This is the part that carries for a single
  install, together with D4
- ☑ **D4** Orphan and revoked used to read the same and now differ, because the repair differs:
  "this is a leftover file, stop using it" versus "a person withdrew this, ask them"
- ☑ **D-calibration, and it caught the TEST for the fifth time in this thread.** The first D1 gate
  compared each message against `refusingInstanceLabel()`, the very function under test, so
  replacing the label with the bare word "Port42" left it passing: both sides moved together. It now
  asserts the facts a caller needs, the instance name and the port number, derived independently.
  Broken again, it fails naming both messages and the missing port
- ☑ **D-live** All four on Dev2 (4244). The orphan was reproduced faithfully: a token that served a
  request seconds earlier, then refused after deleting only its row, leaving the file — the exact
  state `~/.port42/port42/tokens/claude-code` was in. Dev2 was restored afterwards. Prod, which
  predates this, still answers the same orphan with "Client 'claude-code' no longer exists", which
  is what the session actually hit and reads like the user revoked something

### E · Hygiene (RC5) — ☑ DONE 2026-07-31, live-verified on Dev3

**The census that shaped it** (2026-07-31, every instance). Orphan files exist only in prod:
`claude-code` and `scripts`, the test residue. Dead grants total five, all `local-http`: three in
prod, two in Dev3. Dev2 clean, Dev4 one live grant. **And the reverse case exists:** Dev3 has a row
with NO file, a manual client named `test`.

*The census itself was wrong on its first run and said prod had no orphans.* zsh does not word-split
unquoted variables, so each list collapsed into one multi-line grep pattern that always matched. A
probe that returns a reassuring answer is the dangerous kind.

- ☑ **E1** Token files naming no client are reaped at boot, **after** the boot enrolments, because
  the CLI enrols there and reaping first would delete a file about to be rewritten
- ☑ **E1b** Only ever FILES with no row, **never rows with no file**. D9 makes deleting a token file
  a supported act: the row survives on purpose so re-enrolling lands on it and keeps its grants.
  Deleting the row would discard consent; re-minting the file would resurrect a credential the user
  may have removed deliberately. Dev3's `test` is that case, working as designed
- ☑ **E2** BR5 holds and was read rather than assumed: `revoke()` calls `db.revokeClient` then
  `removeTokenFile`. The guess that revocation leaves files behind was wrong; those files were tests
- ☑ **E3** `local-http` grants reaped in migration `v45`, approved by GM. **This does not reopen
  "grants are permanent"** (open question 3): that decision is about consent and expiry, this is
  garbage collection of a row nothing can match. Scoped to ONE grantee that provably cannot return,
  and deliberately NOT generalized to "no client row" — a grantee may be a companion, a PORT or the
  human, none of which are rows in `clients`, so a general sweep would delete live consent
- ☑ **E-calibration** The reap inverted: it destroys the live client's credential and keeps the
  orphan, and the test says exactly that
- ☑ **E-live** Dev3, with a planted orphan: the orphan file deleted, both `local-http` grants gone,
  `port42-cli`'s grant intact, and the `test` row untouched
- ☐ **E4** Prod's two orphans. 0.5.52 predates E1, so they stay until prod is rebuilt or they are
  removed by hand. GM's call, mid-soak

### H · `build.sh` continues after a half-failed teardown

Three failures on 2026-07-31, twice on Dev3 and once on Dev2, always right after the kill:
`Operation not permitted` on a copy, and once `internal error in Code Signing subsystem` naming the
still-running binary. The wait loop runs BEFORE `kill -9`, and after it there is only a flat
`sleep 0.3`. Then `rm -rf "$APP"` runs unchecked, so a partial removal leaves a half-deleted bundle
and the next `mkdir`/`cp` fails inside it.

- ☑ **H1** DONE. The wait now runs after `kill -9`, polling until the process is really gone, and
  gives up loudly after 10s rather than proceeding. It was a guess (`sleep 0.3`) in the one place
  where the answer is knowable
- ☑ **H2** DONE. `rm -rf "$APP"` is checked, and a bundle that would not go aborts the build naming
  the cause. **This is the one that matters**: the project's own rule is that a build reporting a
  copy or signing failure produces a bundle that runs and lies, and every symptom used to appear one
  step later, inside a bundle half old and half new
- ☑ **H-calibration** A bundle made un-removable (`chflags uchg`) produces the FATAL message and
  exit 1; a normal one passes through
- ☑ **H-live** A Dev3 build against a RUNNING Dev3, which is the exact condition that failed three
  times today, succeeded first time with no retry

### F · A dev instance inherits the launching terminal's identity

Launching Dev3 from inside a Port42 terminal gives it that terminal's `PORT42_*` variables, and
since B those include a `PORT42_CLIENT_ID` belonging to another instance's client. Measured
2026-07-31: Dev3's own process carried this session's `PORT42_SPACE_ID`, `PORT42_HOOKS_SOCKET` and
`ZDOTDIR`.

- ☐ **F1** A spawned instance does not inherit `PORT42_*` from whatever launched it
- ☐ **F2** Anything it spawns gets its own values, never the launcher's

### G · `terminal.exec` runs somewhere else and reports success

Addressed at a port with no live shell, it executed as a subprocess of the app and returned output
from the app's environment, with `ok`. Two probes on 2026-07-31 returned confident wrong answers
before GM checked by hand in one line.

- ☐ **G1** `terminal.exec` against a port with no live shell REFUSES, naming the reason
- ☐ **G2** It never runs anywhere but the addressed port

**F and G compound:** F puts a foreign identity into the app's environment, and G is what hands that
environment to a command someone believed was running somewhere else.

---

## Why this order

A is first because every test run currently writes into the live credential store, so any other work
keeps adding residue while we clean it.

B is next because C points at a file that must already exist. Instructions telling an agent to read
`$PORT42_TOKEN_FILE` when the variable is unset are worse than silence: the agent improvises, and
improvising is what produced the borrow.

D and E are independent of both and can be taken in any order.
