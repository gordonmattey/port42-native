# Summer 2026 — north-star notes (TODO)

Forward-looking architecture direction. **Not built yet.** These are decisions about where the
model is heading, written down so they survive reboots and *steer* current work (don't entrench
patterns we've decided to collapse). Each item is tagged TODO.

---

## TODO: a swim *is* a space (collapse the swim special-case)

**Decision:** there is no separate "swim" construct. A swim is just a **space** whose membership
is small/private. "Swim" / "DM" is a **presentation label** for that, not a data structure.

- Member count is not load-bearing. The machinery is N-member; the 2-member DM is just the
  common private case we *call* a swim.
- Today: swim id is the string `"swim-\(companion.id)"` (`Space.swift:47`), and relationship
  state (fold / creases / engravings) keys off `companionId` + that string
  (`AppState.swift:450` and the `db.fetch*` calls). That's the special-case to remove.

**Consequence — relationship memory becomes space-scoped, not companion-special.**
Fold/creases/engravings attach to a **space** (any space), looked up by `spaceId`. A 2-member DM
accumulates relationship memory; so could an N-member project channel. One mechanism.

**Consequence — the "swim id" question dissolves.**
- A swim is a normal space → a plain `UUID().uuidString` id (created the usual way).
- "Find the DM between A and B" = a **membership query** (the space whose members are exactly
  {A, B}), not a derived id. An optional derived-id index — `UUIDv5(sorted(partyA.id, partyB.id)
  + spaceContext)` — is a lookup optimization, *not* the architecture. This supersedes the
  earlier "derive a clever swim id" idea: the destination is "there is no swim id, just space
  ids."

**Steer current work:** do not deepen the `swim-\(companion.id)` special-casing; bias new code
toward space generality (membership + space-scoped state) so the eventual collapse is a
*deletion*, not a rewrite.

---

## TODO: per-(companion, space) terminal session ids

**Problem:** a terminal companion spawns `claude` and resumes with `--continue`, which grabs the
most-recent session for the cwd — ambiguous when sessions overlap (caused a real "resumed the
wrong session / jumped back in time" bug; see the `dev-reboot.sh` flush fix already landed).

**Decision:** give each terminal companion a **stable, deterministic** session id, and resume by
it explicitly.

- `PORT42_SESSION_ID = UUIDv5(namespace, "<companion.id>:<space.id>")`
  - Per **(companion, space)** — a companion in multiple spaces gets an *isolated* thread each.
    (`companion.id` alone is wrong: it collides across spaces.)
  - **Stable** across relaunches and close/respawn (unlike the panel id, which is regenerated).
  - A valid UUID → usable with `--session-id`.
- Spawn logic: first launch `claude --session-id $PORT42_SESSION_ID`; thereafter
  `claude --resume $PORT42_SESSION_ID` (the `--session-id` flag errors if the id already exists).
  Port42 picks based on whether the transcript exists.
- **UX:** don't expose this as a user-editable arg — it's plumbing. Drop `--continue` from the
  default LLM-companion args; Port42 injects the session-id logic automatically at spawn (it
  already injects env + hooks).

**Prereq it interacts with:** routing is currently by companion *name* (one terminal per
companion, `routeMentionsToTerminals` scans `terminalControllers` by `config.companionName`). For
per-(companion,space) sessions to mean anything, terminal routing must become
per-(companion,space) too. Sequence the session-id change with that.

---

## TODO: dev-reboot session-resume robustness (partially done)

- **Done:** `dev-reboot.sh` now sleeps `${DEV_REBOOT_SETTLE:-8}` before `pkill` so the companion
  that triggered the reboot can flush its transcript (the fast cached build was killing it within
  ~2s).
- **Still open:** with concurrent claude sessions in one cwd, `--continue` can still resume a
  sibling session. The per-(companion,space) `--session-id`/`--resume` change above removes this
  class of bug entirely. Until then, the settle delay is a mitigation, not a guarantee.

---

## TODO: shim `.zshenv` recursion / job-table error on terminal startup

Observed on every native-terminal spawn (e.g. during `dev-reboot`):

```
/tmp/port42-shim-<id>/.zshenv:1: job table full or recursion limit exceeded
```

The per-session shim `ZDOTDIR` (`TerminalSessionBootstrap`) writes startup files that source the
user's real equivalent (`$PORT42_REAL_ZDOTDIR`, default `$HOME`). The error means the generated
`.zshenv` is **re-sourcing itself** (or the user's `.zshenv` re-enters the per-session dir) →
infinite recursion until zsh's job table fills. Non-fatal (the shell still comes up), but it
spams every terminal and risks subtle env breakage.

Fix direction: guard against re-entry — e.g. set a sentinel env var the first time the generated
`.zshenv` runs and bail if it's already set, and ensure sourcing the real `ZDOTDIR` can't point
back at the per-session dir. Verify with a clean spawn (no error line) + `which claude` still
resolves the shim function.

---

## Sequencing (rough)

1. **First-class terminal ports** (in progress — `docs/plan-first-class-terminal-ports.md`,
   Step 1 ready). Re-point `terminal.*` onto native `terminal` ports; D1 native-only.
2. **Per-(companion,space) terminal session ids** + per-(companion,space) routing.
3. **Swim → space collapse** + space-scoped relationship memory.

(2) and (3) are the Summer-2026 items above; (1) is the active build.
