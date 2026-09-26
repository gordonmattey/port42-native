# Nautilus Phase 5: skills, not a megaprompt

Detailed plan for Phase 5 of `plan-shell-only.md`. Scenario served: 2 (an agent in a terminal drives a
port it can see, as itself). Written 2026-09-26 against `nautilus` at `409fc70`, with Phases 1 to 3
built and the harness at five of five. All four decisions settled by GM. **Built 2026-09-26** (see 5.5).

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
2. **The brief keeps six every-turn rules (decided, GM 2026-09-26).** Who it is (name and space); a
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

**Spike, 2026-09-26 on Dev4.** A throwaway plugin held one skill whose only content was a word no
agent could know ("the Port42 spike word"), described as "use when anyone asks for the Port42 spike
word". Both CLIs answered "what is the Port42 spike word?" with it, without being told the skill's
name:

- **Claude**: a terminal running `claude --plugin-dir <plugin>` (the shim passes extra arguments
  through, which is where 5.3 adds it) loaded the skill and replied in the space's chat.
- **Codex**: the skill in `skills/` of the instance's Codex home, with `codex` typed into a plain
  Port42 terminal, loaded it; the answer came back through its Stop hook.

Decision 1 holds. Seen on the way: the typed `codex` stopped at a startup dialog GM had to accept,
and did not register as a companion (no SessionStart reached the app), so a typed Codex could not be
@mentioned. That is the restarted-Codex dialog already noted in Phase 3, now also on a fresh start;
to fix with 5.3, since skills in the home change what Codex sees at startup.

**Baseline, 2026-09-26 on Dev4 (today's brief).** A Claude companion's brief is 4,230 characters
(704 words) on every turn; Codex's AGENTS.md in its home is 7,089 bytes (the user's own file plus the
block). `collaborate` (a Claude maker, a Codex reviewer): 9 of 9 in 178 s. One team round (a Claude
lead, a Claude and a Codex engineer): the lead's DONE after 362 s, 4 versions, one port, all three in
the port's chat, 11 of 12 (the miss is the harness expecting the lead's answer in the space chat).
Scenario 2 as the harness runs it is driven by the harness, not an agent (0.4 s), so 5.5 adds an
agent-driven run.

### 5.1 Skill sources and the generator

- `Sources/Port42Lib/Resources/skills/<name>/`: hand-written `SKILL.md`, generated `reference.md`.
- The method-to-skill map; the generator; the freshness gate; a size budget per `SKILL.md`.

*Gates:* every registry method maps to exactly one skill (calibrated by adding an unmapped method);
the generated references equal the committed ones; each `SKILL.md` is under its budget.

**Built 2026-09-26.** `SkillCatalog` maps every method to one of the five skills and renders each
skill's `reference.md` (what the method does, its arguments, its permission, and a `port42` command
example; streaming methods get none, since a stream cannot come back through the command). The
plugin is `Sources/Port42Lib/Skills/port42-skills` (`.claude-plugin/plugin.json`, `skills/<name>/`),
declared with `.copy` so its tree arrives intact in the bundle (checked, hidden folder included).
Gates in `SkillCatalogTests`: every method has exactly one skill (calibrated by dropping a
namespace), the committed references equal the generated ones (`PORT42_REGEN_SKILLS=1`), each
`SKILL.md` opens with its name. The `SKILL.md` files are placeholders until 5.2; the size budget
lands with them.

### 5.2 Write the skills

- The five `SKILL.md` files, from the current brief, the port manual, the July gotchas and what the
  Phase 3 multi-agent tests taught (whoami first, exact names, work in the port's chat, check before
  saying done, files for HTML).
- The port manual moves into `port42-ports`; `port42 help ports` prints it from there.

*Gates:* every rule in today's brief appears in a skill or the new brief (a source scan over the
load-bearing phrases, like `CompanionProtocolTests`); `help ports` prints the skill's text.

**Built 2026-09-26.** The five `SKILL.md` files, from today's brief, the port manual's core
(`ports-core.txt`, which nothing had read since the in-app engine went, so its lines on live updates
and hidden ports had never reached an agent) and the July gotchas. The port manual is the ports
skill's `manual.md`, generated from `ports-context.txt`; `port42 help ports` prints the ports skill
and then the manual. `ports-core.txt` is gone. Gates in `SkillCatalogTests`: every rule the brief
teaches has a home (phrase scan, whitespace-normalized), each `SKILL.md` under 6,000 bytes, the
manual fresh, and every `port42 …` example naming a real method and only its real arguments (it
caught four wrong arguments while the skills were written: `script=` for `source=`, `session=` for
`sessionId=`, `text=` for `data=`, and a missing `token=`). `ManualAccuracyTests` now reads the skills
too. Each gate calibrated.

### 5.3 Load them per session

- Claude: the shim adds `--plugin-dir` for the app's bundled `port42-skills` plugin.
- Codex: the per-instance home owns `skills/`, the user's skills plus Port42's.
- Typed CLIs: the same holds for a `claude` or `codex` typed into a plain Port42 terminal and for a session moved in with `port42 teleport`.
- `port42 skills install` copies the skills into `~/.claude/skills` and `~/.codex/skills`, for sessions outside Port42; opt-in.

*Gates:* a Claude session's command line names the plugin (shim test); a Codex home holds the skills
and the user's own (calibrated by removing each); the user's `~/.claude` and `~/.codex` are untouched
(fingerprinted, as in the multi-instance tests).

**Built 2026-09-26.** Every terminal carries `PORT42_SKILLS_DIR` (the running app's bundled plugin),
and the shim turns it into `--plugin-dir` for every `claude` (a missing folder is skipped, since
claude would refuse to start). The Codex home's `skills/` is its own folder: the user's skills linked
in and the app's beside them, the app's winning a clash. `port42 skills install|uninstall|status`
copies them into `~/.claude/skills` and `~/.codex/skills` with a marker, replacing and removing only
its own copies. Gates: `SkillLoadingTests`, the shim's `TestPluginDirArgs`, the CLI's
`TestSkillsInstallOwnsOnlyItsOwn`, each calibrated. Verified live on Dev4: a `claude` and a `codex`
typed by hand into plain Port42 terminals were asked which argument `clipboard.write` takes, which
only the skills say, and both answered `data`; the claude process carried `--plugin-dir` for Dev4's
own plugin.

### 5.4 Shrink the brief

- `CompanionProtocol` keeps the per-turn rules and the pointer; the chat guidance moves to the core
  and team skills. The instruction block becomes the pointer.

*Gates:* the brief's size is under a budget set from the 5.0 baseline; the rules that must hold every
turn are still in it.

**Built 2026-09-26.** `CompanionProtocol.pointer` holds rules 5 and 6 (call as yourself with the
`port42` command and your own token; the skills for the rest); Claude's brief is its name and space,
`rules` and `pointer`; Codex's AGENTS.md section is the same; the instruction block names the skills.
The long chat guidance (`CompanionProtocol.chats`) is gone from both, and so is the self-post line,
which the core and team skills cover. Gates: both surfaces carry the six rules and none of the moved
how-to, and the brief is under 2,000 characters (calibrated by padding it). Measured live on Dev4: a
new companion's brief is 1,298 characters (208 words), from 4,230 (704) at the baseline; Codex's
AGENTS.md is 4,606 bytes, from 7,089.

### 5.5 Verify against the baseline

- Scenario 2 with a fresh Claude session given no block and only the skills, then the same with Codex
  (the master plan's verify).
- `collaborate` and one team round, compared with the 5.0 baseline.

*Gates:* five of five; both CLIs pass scenario 2 on skills alone; the comparison recorded here. No
target is set before the baseline exists.

**Verified 2026-09-26 on Dev4, against the 5.0 baseline:**

| | Baseline (old brief) | Skills (new brief) |
|---|---|---|
| Brief per turn | 4,230 characters | 1,298 |
| Scenario 2, driven by an agent on skills alone | not run | Claude: pass, 68 s, 7 versions; Codex: pass, 56 s |
| `collaborate` | 9 of 9, 178 s | 9 of 9, 148 s |
| One team round | DONE at 362 s, 4 versions, 11 of 12 | DONE at 850 s, 11 versions, 10 of 12 |
| Harness | five of five | five of five, all seven rows |

The team round did nearly three times the work, so its time is not a like-for-like comparison. Its
new miss, "final version logged 5 errors: {}", led to two fixes: a port's `console.error(err)` reached
Port42 as `{}` (an Error's message and stack are not enumerable), and the injected scripts now have a
compile gate (`InjectedScriptSyntaxTests`) after the first version of that fix put a raw newline in a
JS string and stopped all console capture, which the new test caught. Verifying also found Dev4 hung
creating a web view: every port made its own WebKit process pool, whose setup blocks on a system
service; all ports now share one (`SharedProcessPoolTests`). A bundled-resource gate
(`BundledResourcesTests`) removed two more dead files. Each calibrated.

**Phase 5 status: built.**

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
