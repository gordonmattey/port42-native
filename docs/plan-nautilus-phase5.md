# Nautilus Phase 5: skills, not a megaprompt

Detailed plan for Phase 5 of `plan-shell-only.md`. Scenario served: 2 (an agent in a terminal drives a
port it can see, as itself). Written 2026-09-26 against `nautilus` at `409fc70`, with Phases 1 to 3
built and the harness at five of five. Decisions 1, 3 and 4 settled by GM; 2 open. Nothing here is built.

## Goal

Port42 ships knowledge, not a prompt. An agent is briefed with who it is and how replies work, and
loads the rest on demand as skills: how to make and change a port, how ports feed each other, how to
work with other agents, how to use the machine's devices. Everything API-shaped in a skill is
generated from the registry, so a skill cannot describe a method that no longer exists.

## What changes, for a person and for an agent

- **A companion starts lighter.** Today every Claude companion carries the full chat guidance in its
  system prompt on every turn, and every Codex companion carries it in AGENTS.md. After this phase
  the brief is its identity, the reply protocol and one line pointing at the skills; the rest loads
  when the task calls for it.
- **The knowledge travels.** The same skills load in Claude Code and Codex, and are published so an
  agent Port42 did not start (in your own terminal, or on another machine) can install them.
- **Nothing is written into your own setup.** Skills load per session from the running app's bundle,
  never into `~/.claude/skills` or `~/.codex/skills`, so two instances cannot overwrite each other's
  (the defect fixed for instruction files in Phase 3).

## Decisions for GM

1. **Skills load in every Port42 terminal, per session; installing them permanently is the person's
   choice (decided, GM 2026-09-26).** Not only named companions: a `claude` typed into any Port42
   terminal already runs through the shim (a shell function, with a PATH fallback), which adds
   `--plugin-dir` for the app's own skills plugin; a `codex` typed there already uses the instance's
   Codex home through `CODEX_HOME`, whose `skills/` holds the user's skills plus Port42's. A session
   moved in with `port42 teleport` launches through the same shim. For sessions outside Port42,
   `port42 skills install` copies the skills into `~/.claude/skills` and `~/.codex/skills` (and
   again to update): opt-in, never at launch.
2. **The brief keeps six every-turn rules (recommended, open).** Who it is (name and space); a
   message arrives as `[@sender in <where>]: text` and the prefix is never copied into a reply; a
   reply is delivered to the chat it came from automatically, so it is not also posted; an @mention
   of an exact name is the only way to reach another agent; Port42 is called with the `port42`
   command, as yourself, never with another tool's token; load the port42 skills for the rest. The
   instruction block in CLAUDE.md and AGENTS.md becomes the same pointer.
3. **The skill set: by task, not by API namespace (decided, GM 2026-09-26).** Five skills, below.
4. **The port manual becomes the ports skill (decided, GM 2026-09-26).** `ports-context.txt` and
   `ports-core.txt` move into the ports skill's files, and `port42 help ports` prints the same files.

## What is measured

- **The per-turn brief.** A Claude companion's system prompt is the Port42 framing, the rules and the
  chat guidance (`CompanionProtocol.rules` and `.chats`, about 4 KB) plus its own prompt. A Codex
  companion reads the same through AGENTS.md. Exact token counts are taken in 5.0.
- **The on-demand references.** `port42 help api` prints `llms.txt` (39 KB: the preamble and the
  generated registry). `port42 help ports` prints the port manual (52 KB). Both are read whole, when
  read at all.
- **No skills ship today.** `plan-port42-ports-skill.md` (July) is the one prior design; its section
  of port-authoring gotchas (tile sizing, canvas feedback loops, blocked CDNs, black WebGL captures)
  is still true and goes into the ports skill.
- **Claude can load a plugin per session** (`claude --plugin-dir`, confirmed in `claude --help`).
  **Codex** has a `skills` directory in its home; that it loads skills from a redirected
  `CODEX_HOME` is to be confirmed in 5.0.

## The skills

| Skill | Loads when the agent is | Holds |
|---|---|---|
| `port42` (core) | calling Port42 at all | the command and its argument forms, identity and tokens, chats and @mentions, where to look things up, the error codes and what to do with each |
| `port42-ports` | making or changing a port | the port manual, the gotchas, checking a port works (console, DOM), live updates (`port42:update`), hidden ports, storage, versions |
| `port42-compose` | connecting ports, or reacting to one | publish and subscribe, pipes, hidden stages, what runs off screen, watches |
| `port42-team` | working with other agents | whoami, rooms and hand-offs, watching a port, making a companion (`companions.create`), the burst rule |
| `port42-devices` | using the machine | terminal, screen, camera, audio, clipboard, files, browser, automation, `rest.call` and secrets, each with its permission |

**Anatomy.** Each skill is a folder: `SKILL.md` (a description that decides when it loads, then the
concepts, written by hand and kept short), `reference.md` (the methods it covers, generated from the
registry: signature, arguments, permission, one example as a `port42` command), and where useful
`examples/` and small scripts (a port starter, a script that checks a port's console and DOM).

**Generated, not copied.** A map from registry method to skill covers every method exactly once, and
a gate fails when a method is added to the registry without a home. The references regenerate like
`llms.txt` (a freshness gate, `PORT42_REGEN_SKILLS=1`).

## Steps

Each step is its own commit: suite green, harness five of five, plans updated.

### 5.0 Spike and baseline

- A throwaway plugin with one skill, loaded with `--plugin-dir` by a Claude terminal in Dev4: does the
  skill load when its description matches, and can the session read its files?
- The same skill in a Dev4 Codex home's `skills/`: does Codex load it?
- The baseline: the brief's size in tokens, and scenario 2, `collaborate` and one team round on Dev4
  with today's brief (turns taken, time, calls made), to compare against in 5.5.

*Gates:* the findings recorded here. If either CLI does not load skills as expected, decision 1 is
revisited before 5.1.

### 5.1 Skill sources and the generator

- `Sources/Port42Lib/Resources/skills/<name>/`: hand-written `SKILL.md`, generated `reference.md`.
- The method-to-skill map; the generator; the freshness gate; a size budget per `SKILL.md`.

*Gates:* every registry method maps to exactly one skill (calibrated by adding an unmapped method);
the generated references equal the committed ones; each `SKILL.md` is under its budget.

### 5.2 Write the skills

- The five `SKILL.md` files, from the current brief, the port manual, the July gotchas and what the
  Phase 3 multi-agent tests taught (whoami first, exact names, work in the port's chat, check before
  saying done, files for HTML).
- The port manual moves into `port42-ports`; `port42 help ports` prints it from there.

*Gates:* every rule in today's brief appears in a skill or the new brief (a source scan over the
load-bearing phrases, like `CompanionProtocolTests`); `help ports` prints the skill's text.

### 5.3 Load them per session

- Claude: the shim adds `--plugin-dir` for the app's bundled `port42-skills` plugin.
- Codex: the per-instance home owns `skills/`, the user's skills plus Port42's.
- Typed CLIs: the same holds for a `claude` or `codex` typed into a plain Port42 terminal and for a session moved in with `port42 teleport`.
- `port42 skills install` copies the skills into `~/.claude/skills` and `~/.codex/skills`, for sessions outside Port42; opt-in.

*Gates:* a Claude session's command line names the plugin (shim test); a Codex home holds the skills
and the user's own (calibrated by removing each); the user's `~/.claude` and `~/.codex` are untouched
(fingerprinted, as in the multi-instance tests).

### 5.4 Shrink the brief

- `CompanionProtocol` keeps the per-turn rules and the pointer; the chat guidance moves to the core
  and team skills. The instruction block becomes the pointer.

*Gates:* the brief's size is under a budget set from the 5.0 baseline; the rules that must hold every
turn are still in it.

### 5.5 Verify against the baseline

- Scenario 2 with a fresh Claude session given no block and only the skills, then the same with Codex
  (the master plan's verify).
- `collaborate` and one team round, compared with the 5.0 baseline.

*Gates:* five of five; both CLIs pass scenario 2 on skills alone; the comparison recorded here. No
target is set before the baseline exists.

## Test plan

| Step | Automated (every build) | Harness (live, Dev4) | GM by hand |
|---|---|---|---|
| 5.0 | none | spike findings, baseline numbers | nothing |
| 5.1 | method map complete; references fresh; size budgets | none | nothing |
| 5.2 | brief rules all have a home; `help ports` from the skill | none | reads the skills |
| 5.3 | shim passes `--plugin-dir`; Codex home owns `skills/`; user dirs untouched | a Claude and a Codex companion each use a skill | nothing |
| 5.4 | brief under budget; per-turn rules kept | none | nothing |
| 5.5 | suite green | five of five; scenario 2 on skills alone, both CLIs; comparison with 5.0 | drives a port through a skills-only session |

## Not in this phase

The remote pipe (Phase 4). Antigravity (roadmap). Skills for agents other than Claude Code and Codex
beyond publishing the plugin folder.
