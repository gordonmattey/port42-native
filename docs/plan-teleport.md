# Plan: `port42 teleport` (bring an existing CLI agent session into a Port42 port)

Status: approved, S1 in progress.
Roadmap item: `docs/summer2026-todo.md:2509`.
Scope: teleport-in from an outside terminal, plus install with the app.

---

## 1. The flow

1. Exit your Claude Code terminal.
2. Run `port42 teleport`. It was installed with the app.
3. It takes that terminal's working directory, resolves the session you were just in, and creates
   a Port42 terminal port in the current space that resumes it.

No flags for the common case. Teleport in, and the agent you were already talking to is in a room
you can share.

---

## 2. Naming

One binary called `port42`, with verbs. First verb is `teleport`.

A bare `teleport` collides with Gravitational's Teleport. A bare `port` collides with MacPorts'
CLI (`/opt/local/bin/port`), and worse, collides internally: `port` is the core noun in this
product and the roadmap already has a separate **port teleport** feature
(`docs/summer2026-todo.md:3569`) that moves a port between instances rather than a session. `p42`
is clear as a binary but loses to an existing shell alias on the primary dev machine.

`port42` matches what is already bundled (`port42-gateway`, `port42-claude-shim`) and gives later
verbs a home. `port42 handoff` is the fallback strategy in section 5, and `port42 install` is
where config packs land. The CLI is expected to grow, so it starts as a CLI rather than as a
single-purpose binary that has to be reorganized later.

---

## 3. It works today with no app or shim changes

The one real risk was the shim. Every `claude` inside a Port42 terminal routes through
`port42-claude-shim`, which injects its own session pin ahead of the caller's args
(`shim/main.go:120-128`), so a naive `claude --resume <id>` becomes:

```
claude --settings <hooks> --session-id <derived> --resume <teleported>
```

Verified against the real CLI, that combination is rejected outright.

```
Error: --session-id can only be used with --continue or --resume if --fork-session is also
specified.
```

Exit 1. A loud failure, not a silent one, so it could never have shipped broken unnoticed. And
the error names its own fix. Also verified against the real CLI, adding `--fork-session` makes
the same combination legal. It parses, and fails only on the nonexistent id used for the test.

So teleport passes `--fork-session` and the existing shim argv is already correct:

```json
{"type":"terminal","command":"claude",
 "args":["--resume","<session-id>","--fork-session"],
 "cwd":"<$PWD>","title":"teleport: <branch>"}
```

The teleported context continues in a new transcript pinned to the Port42 port. The original
transcript is untouched, so exiting the outside terminal first is good manners rather than a
correctness requirement. There is no dual-writer risk.

This removes the need for a `resumeSessionId` seam on `port.create`, and removes any need to
relax the rule that caller `env` cannot clobber Port42's own variables
(`TerminalHooksService.swift:215-233`). That invariant stays exactly as it is.

### 3.1 Everything else on the path is already open

- `/call` needs no credential (`gateway/gateway.go:802-856`). No token, no keychain, no setup.
- `port.create` is `permission: nil` (`BridgeMethods.swift:148`). No permission prompt fires.
- Space defaults to the current space (`BridgeMethods.swift:168`).
- With the app down, `/call` answers `{"error":"no host available — is Port42 running?"}`
  (`gateway.go:823`), which the CLI turns into a real message.
- The app is not sandboxed (`Port42.release.entitlements`), so it can write `~/.local/bin`.

### 3.2 Gateway port

`GatewayProcess.swift:12-18` reads `PORT42_GATEWAY_PORT`, else 4242. For an installed app there
is one instance on 4242, so the CLI defaults to 4242 with a `--port` override and that is the
whole story. Only a dev machine runs several at once, and the override covers it.

If juggling instances gets annoying in practice, the app can publish
`<AppSupport>/<PORT42_DATA_DIR>/gateway.json` at start, which namespaces per instance for free
(`PORT42_DATA_DIR`, see `TerminalHooksService.swift:350`) and follows the existing `liveCwdFile`
precedent. Nice to have, not a prerequisite.

### 3.3 Resolving the session

The default is the newest session for `$PWD`. Claude maps a cwd to `~/.claude/projects/<slug>/`
by replacing `/` with `-`, so the slug is a fast path. Rather than depending on that internal
convention, fall back to reading the `cwd` field recorded inside candidate transcripts, which is
present on every line and verified against a live one. The shim already sidesteps the slug rule
the same way, by globbing (`shim/main.go:82-88`).

`--session <id>` overrides. `--list` shows what it found.

### 3.4 Installing Port42 mid-session is exactly why this helps

The Port42 block in `~/.claude/CLAUDE.md` is only read at claude startup
(`InstructionService.swift:98-138`). Install Port42 while a session is running and that session
has no idea Port42 exists. Teleport starts a fresh claude process, so the forked session loads
CLAUDE.md and knows how to call the gateway. The onboarding step and the "make it pick up the
instructions" step are the same action.

---

## 4. Behavior decisions

Defaults chosen so the common case needs no thought. Each is cheap to reverse.

| Case | Behavior |
| --- | --- |
| No claude session for this cwd | Open a fresh `claude` port in that directory rather than erroring, so the verb also works as "get me into Port42 from here" |
| Port42 not running | Fail with a message telling the user to start it. Do not launch the app |
| Chat card | Keep it. `postPortCard` fires because the HTTP principal is non-nil, and a trace in the conversation is the point |
| Which space | Asked, with the current space marked and taken on Enter. `--space <name\|id>` skips the prompt. Piped or scripted runs never prompt and let the app apply its current-space default |
| Outside session still live | Print a reminder to exit it. Forking makes this cosmetic, so do not refuse |

---

## 5. Install

`port42` ships as a Go binary at `Contents/MacOS/port42`, built and signed by `build.sh` next to
the shim (`build.sh:215-262`, signed at `:318`), resolved with
`Bundle.main.url(forAuxiliaryExecutable:)`.

Install symlinks `~/.local/bin/port42` into the bundle, so an app upgrade needs no version logic:
replacing the app replaces the target. A boot-time check re-points the symlink if it dangles,
covering the user moving the app to /Applications. This mirrors
`InstructionService.refreshInstalled()`, which runs at every boot and touches only what the user
already opted into.

Install is a Settings action rather than automatic, matching how instruction files work. If
`~/.local/bin` is not on PATH, say so and print the line to add instead of failing silently. It
exists and is second on PATH on this machine, but that is not general.

---

## 6. Stages

**S1.** The `port42` binary with the `teleport` verb. Resolve session (slug fast path,
transcript-`cwd` fallback), call `port.create`. Flags: `--session`, `--port`, `--space`,
`--list`, `--dry-run`. Table tests for resolution.

**S2.** Bundle and sign in `build.sh`. Settings install action plus the boot symlink refresh.

**S3.** Live verification in Dev3. Run `port42 teleport` from an outside terminal against a real
session and confirm the forked transcript carries prior context rather than starting empty. This
is the acceptance test, and it is the one that catches any remaining shim interaction.

---

## 7. The alternative worth keeping

Extend the existing `session-handoff` skill for teleport instead of resuming. It grounds state
from git plus the status doc, writes a handoff prompt, and spawns a fresh claude in a Port42
terminal seeded with it. No resume, so no shim interaction at all, and it exists today.

The difference is what arrives. Resume-and-fork carries the literal transcript. Handoff carries a
summary someone wrote, which is lossy but often cleaner, and it drops the dependency on claude's
resume semantics entirely, which matters for gemini and codex later.

Build the fork path, since it is proven to work and it is what the roadmap promised, and keep
handoff as the fallback for CLIs with no resume. Not mutually exclusive: same CLI, different
strategy per CLI. Handoff becomes `port42 handoff`, and the skill it wraps is the first config
pack (task #4).

---

## 8. Out of scope

Companion registration and `@mention` addressability. A teleported port is a terminal port with
hooks, in the space and watchable, but not a space member: `createPort` passes no `companionId`
and never calls `joinCompanionToSpace`, which lives only on the `spawnTerminalAgentPort` path
(`AppState.swift:3081-3083`, `:3251-3274`). That is a separate follow-on.
