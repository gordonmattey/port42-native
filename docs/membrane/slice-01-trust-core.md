# Slice 01 · The Trust Core — Detailed Design

*2026-07-12 — the first **vertical slice**: a walking skeleton that runs end-to-end through the trust
core, building only the thin sliver of each role the slice needs. It validates the
[architecture's](membrane-architecture.md) contracts by making something that honors them — it does not
build any role in full. Traceable up the chain: this slice serves specific jobs
([`membrane-requirements.md`](membrane-requirements.md)) by cutting through specific roles.*

**Domain.** Code — because git makes *reversible* and *audit* nearly free, and the irreversible line
(push / deploy) is obvious.

**Hard constraint — standalone.** The reference implementation uses only: the **Anthropic Messages API**
(the agent), a **local git repo + filesystem** (the substrate it acts on), and **terminal stdin/stdout**
(the human seam). **No Port42** — no gateway, no ports, no companions, no `messages.*`. This slice is a
plain CLI harness.

---

## The slice in one line

> You hand an agent one real coding task **with a leash**. It works where it's allowed, **stops before
> the leash or anything irreversible** and asks. You approve, deny, or redirect. Everything it does is
> **reversible**, and you can **undo** it.

## Why this slice (what it validates)

1. **It pierces the make-or-break.** Adoption lives or dies on **Guard (recovery) + Controller (control)**
   ([`make-or-break.md`](make-or-break.md)). Both are load-bearing here.
2. **It proves the Runner contract** — *observable · steerable · bounded* — in the thinnest possible form.
3. **It retires interface-correctness risk.** Until something implements the Runner/Controller/Guard
   contracts, we don't know they're right. This is the slice's real job, beyond the demo.
4. **It needs zero personalization** — the Gatekeeper stays generic, so the parked **Keeper** and
   **Sensor** stay parked.

## Scope — jobs this slice touches

| Job | What the slice exercises | Kept thin by… |
|---|---|---|
| **J1** getting work started | hand off one task in a sentence + a leash | no intent-development; a direct handoff |
| **J3** knowing what's happening | see the one agent's state (running / blocked / done) | one agent, not a field of many |
| **J5** deciding & approving | the agent stops at a point only you can call; you approve | one decision type (the `ask`) |
| **J10** building & adjusting trust | the leash *is* latitude — free here, ask there | a single **static** leash; no trust rising/falling yet |
| **J15** recovering & staying safe | reversible actions + stop-before-irreversible + a record | undo one action; one irreversible class |
| **J6** *(optional)* steering in flight | redirect the running agent without restart | just redirect + stop; no fork |

## Scope — roles this slice cuts

*Build **only** the one thing named. Everything else in the role is out.*

| Role (ID) | Build only this | Skip |
|---|---|---|
| **Runner** (F1) | one agent loop exposing `{aim, status}`, accepting `stop` / `resume` / `redirect` | multi-agent, rich progress, fork |
| **Controller** (S3) | `check(action) → allow \| ask \| deny` over one declared leash; human reclaim always wins | trust rising/falling, area-×-stakes matrix, meta-authority UI |
| **Guard** (R2) | git-backed reversibility (undo last action) + irreversible-intercept + one audit line per action | overnight/long runs, cost tracking, history tree, digest |
| **Watcher** (S2) | a minimal readout of the single agent's state | the calm field of many, drill-in, returning digest |
| **Gatekeeper** (S1) | route any `ask` to the human and block until answered — **generic** | pressure grading, composition, learning, personalization |
| **Presenter** | render all of it to the **terminal** | voice / ambient, modality choice |

**Not in this slice at all:** Keeper, Sensor, Synchronizer, Coordinator, Librarian — and therefore
J2, J4-personalized, J7–J9, J11–J14, J16–J21.

---

## The reference implementation — one interceptor

The trust core collapses into a single structural idea: **an interceptor between the agent's *proposed*
action and its *execution*.** The agent proposes; the interceptor decides → wraps → logs → executes. The
Controller and Guard *are* that interceptor; the agent loop *is* the Runner; the terminal I/O *is* the
Watcher/Gatekeeper/Presenter. You are not building three subsystems — you are building one `mediate()`
plus a git-backed undo.

### The loop

```
loop until done or stopped:                       # ── Runner (F1)
  turn = model.step(tools=[edit(path,patch), run(cmd)])   # observable: harness reads {aim,status}
  for action in turn.tool_calls:
      result = mediate(action)                    # the whole trust core is here
      feed result back to model
  render(aim, status, last_action)                # ── Watcher + Presenter (terminal)

mediate(action):                                  # ── Controller (S3) + Guard (R2)
  verdict = controller.check(action, leash)       #   allow | ask | deny
  if guard.is_irreversible(action):               #   Guard override: egress always asks
      verdict = 'ask'
  if verdict == 'ask':
      verdict = ask_human(action)                 # ── Gatekeeper → you (blocks); Presenter shows it
  if verdict == 'deny':
      return refusal(action)                      # returned to the model as a tool error
  result = execute(action)                        # apply the edit / run the command
  guard.record(action, result)                    # ── Guard: git commit (=undo point) + audit line
  return result

# available to the human at any time:
stop()      # Runner is steerable — halts before the next action, agent yields
redirect(m) # inject a new instruction into the loop
undo()      # Guard — git reset --hard to the previous commit; audit the undo
```

### The three contracts, made concrete for this slice

- **Runner (F1) — observable · steerable · bounded.**
  - *observable:* the loop surfaces `{aim, status ∈ {running, blocked, done}}` every turn, read by the
    harness, not narrated by the agent.
  - *steerable:* `stop` is checked between actions and yields cleanly; `redirect` injects an instruction.
  - *bounded:* the agent has **no** filesystem/git access except the two tools, and **every** tool call
    goes through `mediate()`. There is no side-effect path around the interceptor.
- **Controller (S3) — the leash.** `check(action, leash) → allow | ask | deny` against a small declared
  policy (below). A human `stop`/reclaim always overrides the agent. No out-of-policy action ever
  executes without an `ask`.
- **Guard (R2) — reversible, guarded, recorded.**
  - *reversible:* work on a scratch branch; each executed action → `git add -A && git commit`; `undo`
    = `git reset --hard HEAD~1`. Git is the ground truth for "prior state."
  - *guarded:* an **irreversible denylist** (`git push`, publish, `deploy*`, `rm` outside the repo,
    network egress) forces `ask` regardless of the leash — the one gate before the irreversible.
  - *recorded:* every action appends one line — `{ts, action, verdict, reversible, commit}` — to an
    append-only audit log.

### The leash (task + policy) — the concrete shape

Declared once, at handoff. Concepts, not a fixed schema:

```
task: "Refactor the auth module to the new token format."
leash:
  allow_edit: ["src/auth/**"]              # paths the agent may change freely
  allow_run:  ["npm test", "npm run build"] # commands it may run freely
  ask:        everything else               # default: escalate to the human
  irreversible_always_ask:                  # Guard override, even if allow-listed
    ["git push", "npm publish", "deploy*", "rm -* (outside repo)", "curl|wget|network"]
```

## The human seam (terminal)

Generic and thin. When `mediate()` returns `ask`, the harness **blocks** and prints the pending action +
the agent's `{aim, status}`; you type `approve` / `deny` / `redirect <msg>`. At any time you can `stop`
or `undo`. That is the whole Watcher (state readout) + Gatekeeper (route the ask) + Presenter (terminal)
for this slice — deliberately dumb.

---

## Acceptance — the pass/fail bar per role

*A seam passes only if its bar holds; the slice passes only if all do plus the end-to-end demo.*

| Role | PASS | FAIL |
|---|---|---|
| **Runner** | harness reads `{aim,status}` without asking the agent; `stop` halts before the next action; agent has no side-effect path around `mediate()` | any action reaches disk/git without passing `mediate()` |
| **Controller** | every out-of-leash action is denied or escalated to `ask`; human reclaim always wins | any out-of-policy action executes silently |
| **Guard** | every executed action is individually undoable and `undo` restores prior state *exactly* (git-verified); the designated irreversible action is intercepted **even when the leash would allow it**; every action leaves one audit line | any action is unrecoverable, or unlogged, or an irreversible slips through |
| **Watcher** | the agent's state is legible at a glance at any moment | you must ask the agent what it's doing |
| **Gatekeeper** | every `ask` reaches you and blocks until answered | a decision proceeds without you |
| **Presenter** | all of the above is legible in the terminal | — |

**Slice-level acceptance (the demo below runs green):** hand a task with a leash → agent works inside it
→ agent stops at the leash / before an irreversible step and asks → you approve → it acts reversibly →
you `undo` one action and git confirms exact restoration.

**Bonus adversarial probe (cheap here):** give a task that *tempts* a push (“ship it when tests pass”).
PASS if the Guard still intercepts the `git push` for confirmation. This is early signal on
security/adversarial risk — not a full test.

## The demo script (walking skeleton)

1. Point the harness at a real repo; declare the task + leash.
2. Agent edits under `src/auth/**` (allowed) — each edit commits; audit log grows; Watcher shows `running`.
3. Agent tries to edit `src/config/db.ts` (outside leash) → Controller `ask` → you `deny` → agent re-plans.
4. Agent runs `npm test` (allowed) → passes.
5. Agent tries `git push` → Guard irreversible-intercept → you `approve` or `deny`.
6. You spot a bad commit → `undo` → git resets → audit records the undo → agent continues.

## What a green slice means — and doesn't

- **Means:** the Runner/Controller/Guard **contracts hold** and the trust core is **buildable**; the
  make-or-break seams are real code, not prose.
- **Does *not* mean:** the **jobs are validated**. Desirability comes only from the interview track — a
  green slice proves we *can* build it, never that anyone *wants* it.

## Explicitly out of scope

Personalization (Keeper), context-sensing (Sensor), co-holding (Synchronizer), multi-agent
(Coordinator), reuse (Librarian); trust that rises/falls over time; long/overnight runs; cost tracking;
modality beyond the terminal; and **all Port42 integration**. None is needed to walk this skeleton.

## Open questions (marked — not asserted)

- **O-1 · Irreversible, precisely.** The denylist is a first cut. What counts as irreversible is
  domain-deep (a `run` command can do anything); the slice uses a coarse allowlist-of-safe + denylist,
  and treats *unknown* `run` commands as `ask`. Whether that's the right default is open.
- **O-2 · Undo granularity.** One commit per action gives per-action undo; whether the person wants
  per-action or per-task undo is open (start per-action).
- **O-3 · What is an agent "need."** Here, a `need` is exactly "an action that hit `ask`." Richer needs
  (the agent proactively asking a question) are out of this slice.
- **O-4 · Leash format.** The policy shape above is illustrative; the real grammar (globs? predicates?)
  is left to the build.
- **O-5 · Bounding `run`.** True boundedness of arbitrary shell is unsolved in general; this slice bounds
  it by *interception + ask-on-unknown*, not by sandboxing. Sandboxing is a later concern.

## Risk — what this slice retires vs. leaves

- **Retires:** interface-correctness for Runner/Controller/Guard (risk #3) — the contracts meet an
  implementation.
- **Early signal on:** adversarial/boundary-evasion (risk #5) — via the bonus probe.
- **Leaves untouched (by design):** technical feasibility of the hard, deferred roles — Gatekeeper triage
  convergence, the Synchronizer's real-time surface, Keeper correctness (risk #2); and
  requirements-validation (risk #4), which needs interviews, not code.
