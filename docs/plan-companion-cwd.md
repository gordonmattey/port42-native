# Plan: per-space working directory + unique command-companion sessions

*2026-07-20, branch shell-s1. Status: DECISIONS LOCKED (GM), no code. Fixes the `.command` companion
reply-post bug (root cause + evidence in `summer2026-todo.md`: all command companions default to
cwd `/Users/gordon`, claude 2.x keys its transcript on project=cwd, so they share one stale
transcript; the reply on screen is never in the file the Stop hook reports). Test in Port42Dev
only. Gate discipline: an item is not touched until its gate test exists and is recorded failing.*

## RESULT (2026-07-20) — FIXED and live-validated end to end

Steps 1-3 implemented, all unit + shim gates green, and the literal bug reproduced-then-fixed live in
Port42Dev: Maker + Critic, both in `/Users/gordon` (the original collision dir), driven from chat, each
wrote its OWN distinct transcript (`737f3e18…` vs `f0497438…`) and **posted its own reply** ("Maker
here" / "Critic here") — previously both were `NOT posted (skip=empty)`. Two companions sharing one
`workingDirectory` (`/private/tmp/p42spacedir`) likewise wrote distinct transcripts with correct
content ("alpha-ok" / "bravo-ok"), Stop hook `len>0`.

**Critical second root cause found during validation — the shim env-scrub (the missing piece).** A
Port42 app launched from inside a Claude Code session inherits `CLAUDE_CODE_SESSION_ID` /
`CLAUDE_CODE_CHILD_SESSION` / `CLAUDE_CODE_BRIDGE_SESSION_ID` and passes them to every `claude` it
spawns. The spawned claude then behaves as a NESTED CHILD of the launching session: it replies on
screen but NEVER persists its transcript at the path its Stop hook reports, so every companion reply
reads empty — masking the whole fix. The shim now scrubs those three vars before exec
(`sanitizeEnv`, gated by `TestSanitizeEnv`), keeping the OAuth token and everything else. This is a
real robustness fix independent of the dev harness (any user launching Port42 from a claude terminal
hit it). Without it, the session-id isolation is invisible because no transcript is written at all.

Delivered:
- `Space.workingDirectory` + migration `v41` + `normalizeWorkingDirectory` (`SpaceWorkingDirTests`).
- `TerminalCwd.resolve(override ?? spaceDir ?? home)`, wired into both spawn paths (`TerminalCwdResolutionTests`).
- `ClaudeSessionId` UUIDv5 derivation + `companionId` plumbed to `PORT42_CLAUDE_SESSION_ID`; shim
  `sessionIDArgs` (`--session-id`/`--resume`) + `sanitizeEnv` (`ClaudeSessionIdTests`, shim tests).
- `space.setWorkingDirectory` bridge method (the setter the picker UI will call).

Remaining (step 4 tail): the Settings picker UI; drop `--continue` from saved command-companion args;
docs + summer-todo bug close. Uncommitted pending the commit ask.

## The bug in one line

`.command` companions share a transcript because they share a cwd (home); the shim reads the wrong
file and posts empty or stale. `.llm` companions have no cwd/transcript and are unaffected.

## Decisions locked (GM, 2026-07-20)

1. **Working directory is USER-PICKED per space.** The space carries a working dir the user chooses;
   it is not auto-located under a convention. Sub-decision for step 1: when unset, command
   companions fall back to today's behavior (home) but the UI nudges the user to pick one — no
   silent auto-dir.
2. **A command companion's cwd defaults to the space dir** (the port-level `cwd` override on
   `port.create` stays as the escape hatch). One change: the default in `spawnNativeTerminalPort`
   stops being home.
3. **Unique claude session id per command port** (confirmed by step 0). This is what isolates two
   companions that SHARE the space dir (the intended model: companions collaborate on the same
   files, but each has its own conversation).
4. **Nothing for `.llm` companions.** No cwd, no transcript, no change.

## Decisions refined 2026-07-20 (session 2, GM) — how the session id works

- **Derivation:** deterministic `UUIDv5(port42Namespace, "<spaceId>:<companionId>")` for saved
  companions; ad-hoc `port.create` terminals (no companion) key on `"<spaceId>:<panelId>"`. Note the
  ORDER: `spaceId:companionId` (GM). Deterministic, not random, so a respawn/relaunch recomputes the
  same id and `--resume`s the same thread instead of starting an empty session. Per-(companion,space)
  isolation; no storage needed (recomputable at every spawn). This subsumes the separate
  "per-(companion,space) terminal session ids" todo and retires the `--continue` wrong-session bug.
- **Injection PATH (traced):** the id enters as an ENV VAR and the shim turns it into a flag, mirroring
  `--settings` and `--append-system-prompt` exactly.
  1. `AppState.spawnNativeTerminalPort` (`AppState.swift:2624`) computes the id (has `spaceId`;
     `companionId` must be threaded into `TerminalPortConfig`, which today carries only `companionName`).
  2. `GhosttyTerminalController.init` (`GhosttyTerminalController.swift:102`) →
     `TerminalSessionBootstrap.make(sessionId: panelId, …, customEnv: config.env)`. (That `sessionId`
     param is the panelId / hooks-socket id, NOT the claude id — name clash to watch.)
  3. `TerminalSessionBootstrap.make` (`TerminalHooksService.swift:199-278`) exports
     `env["PORT42_CLAUDE_SESSION_ID"] = <id>`, one line next to `PORT42_COMPANION_PROMPT` (:224).
  4. zsh `claude()` function (`TerminalHooksService.swift:308`) forwards args untouched.
  5. shim `runClaude` (`shim/main.go:54-77`) reads `PORT42_CLAUDE_SESSION_ID`, stats
     `~/.claude/projects/<slug(cwd)>/<id>.jsonl`: exists → append `--resume <id>`, else
     `--session-id <id>`; appended next to the existing `--append-system-prompt` block.
  The new-vs-resume decision lives in the shim (Go) because it execs with the terminal's real cwd, so
  the slug + stat are local and correct; this also keeps the raw id out of the typed command / `ps`.
- **UI placement:** "wire the UI when it makes sense in the sequence" (GM). Field + migration +
  resolver land headless (steps 1-2); the step-3 live proof sets the space dir via curl (no UI); the
  Settings picker (NSOpenPanel, directory; unset = home + nudge) wires in at step 4, once the plumbing
  is proven and a human drives acceptance.

## Test plan (per step)

- **Step 1** — `SpaceWorkingDirTests` (in-memory DB): `roundTripsWorkingDirectory`,
  `unsetResolvesToHome`; append-only-migration no-data-loss on a pre-migration row.
- **Step 2** — extract `resolveTerminalCwd(override:spaceDir:)`; `TerminalCwdResolutionTests`:
  `overrideWins`, `elseSpaceDir`, `elseHome`. (`elseSpaceDir` fails first — today hardcodes home.)
- **Step 3, unit (id):** `ClaudeSessionIdTests`: `deterministic`, `distinctPerCompanion`,
  `distinctPerSpace`, `adHocKeysOnPanel`, `isValidV5Uuid`, `knownAnswer` (pinned UUID, drift guard).
- **Step 3, unit (shim):** add to `shim/main_test.go` a table on `runClaude` arg assembly: id + file
  exists → `--resume`; id + no file → `--session-id`; empty id → neither.
- **Step 3, live (Dev :4243, shim instrument):** two saved command companions in one space with a
  shared `workingDirectory`, from chat → distinct `transcript=`/`sid=`, each posts its own reply; then
  relaunch one → it `--resume`s the same id (history intact, not empty).
- **Step 4, live:** two command companions in one space, each replies with real text (`len>0`), no
  empty/stale/cross-talk; `.llm` regression guard (untouched, still works); name-collision gone
  (`basename $PWD != "gordon"`); Settings picker wired; docs + summer-todo bug closed.
- **Rules:** unit suites headless (no live Anthropic); `--filter` exact suite names only; every gate
  recorded failing before its code.

## The model

Space dir = the shared workspace (companions work on the same files). Session id = what isolates
each companion's conversation. This beats per-port subdirs, which would stop companions
collaborating. Confirmed tonight: distinct DIRS give distinct transcripts. NOT yet confirmed:
distinct SESSION IDS in the SAME dir give distinct transcripts — that is the blocker.

## STEP 0 RESULT (2026-07-20, live in Port42Dev) — ANSWER: YES, the model holds

Probe: two ad-hoc terminal ports created via `port.create` with the SAME `cwd` override
(`/private/tmp/p42cwdspike`), each launched as `claude --session-id <distinct uuid>` (args on
`port.create`, which the shim shell-function forwards to the real claude after prepending
`--settings`). A prompt was pushed to each via `port.push`; both Stop hooks fired. The instrument
reported:

```
turnComplete: transcript=~/.claude/projects/-private-tmp-p42cwdspike/aaaaaaaa-1111-…​.jsonl sid=aaaaaaaa-1111-…
turnComplete: transcript=~/.claude/projects/-private-tmp-p42cwdspike/bbbbbbbb-2222-…​.jsonl sid=bbbbbbbb-2222-…
```

SAME project-dir slug, DISTINCT transcript files. The transcript path is deterministically
`~/.claude/projects/<cwd-slug>/<session-id>.jsonl` — the FILENAME is the session id. So a pinned
`--session-id` isolates two claude terminals that share one cwd. The Maker/Critic collision (both
reporting `.../-Users-gordon/7aacc5af….jsonl`) is exactly the failure mode this removes: `--continue`
in a shared cwd resumes the same most-recent session, so they collapse onto one transcript; a
distinct pinned id per port gives each its own file.

Decision 3 stands as written: **pin a unique session id per command port** (NOT per-port subdir).
Downstream steps 1–4 proceed on the shared-space-dir + per-port-session-id model.

(Orthogonal, not what step 0 tested: both probe turns logged `len=0` — fresh sessions the shim read
before claude flushed. That is the retry/flush timing, already handled by `lastAssistantTextWithRetry`
in real use; it does not affect path isolation, which is what this blocker asked.)

## The matrix

| # | Item | Gate (recorded failing before code) | Notes |
|---|---|---|---|
| 0 | **DONE (2026-07-20) — session-id isolation CONFIRMED.** Two `claude` terminals in the SAME cwd, each pinned a distinct `--session-id`, got DISTINCT transcript paths (`projects/<cwd-slug>/<session-id>.jsonl`; filename = session id). See "STEP 0 RESULT" below. | Live probe in Dev, documented. Distinct → the shared-space-dir + session-id model holds. | No commit (spike). Model confirmed; decision 3 stands (pin a session id per port, not per-port subdir). |
| 1 | **Space carries a user-picked working dir.** `Space` gets an optional `workingDirectory`; a Settings affordance to pick it (NSOpenPanel, directory). Unset = home fallback + a nudge. | `SpaceModelTests` / a new suite: a space round-trips its workingDirectory through the DB; unset resolves to the home fallback. Recorded failing (field absent). | New migration (append-only). |
| 2 | **Command companion cwd defaults to the space dir.** `spawnNativeTerminalPort` resolves cwd = explicit override ?? space.workingDirectory ?? home. | Unit on the resolution helper: override wins; else space dir; else home. Recorded failing. | The port-level `cwd` override already exists. |
| 3 | **Unique session id per command port** (gated on step 0 = yes). The shim pins a per-port session id so same-dir companions don't collapse. | Live: two command companions in one space (shared dir) get distinct transcripts + both post their own reply. Plus a unit on the id-derivation if any lands app-side. | Depends on step 0. |
| 4 | **Live acceptance + close-out.** | Two command companions in one space, driven from chat, each replies correctly (no empty, no stale, no cross-talk). The join-instructions name collision is gone (cwd ≠ home → `basename $PWD` ≠ "gordon"). Docs updated. | Closes the summer-todo bug + the join-prompt collision. |

## Sequencing

0 (blocker spike) → then 1 → 2 → 3 → 4. Step 0 decides whether 3 is "pin a session id" or "per-port
subdir." Do NOT build 1–3 before step 0 answers.

## Files (expected)

`Sources/Port42Lib/Models/Space.swift` (+ field), `DatabaseService.swift` (+ migration),
`AppState.swift` (`spawnNativeTerminalPort` cwd resolution), the shim launch path / `claude()`
shell-function (session-id pin), a Settings view for the picker. Tests as above.

## Out of scope (separate todo items, do not fold in)

- Auto-registering an ad-hoc `claude` terminal port as a space companion (depends on this landing).
- The join-instructions generator itself (external tool, not in this repo) — this fix removes the
  name collision at the source (cwd), but the prompt text lives elsewhere.
