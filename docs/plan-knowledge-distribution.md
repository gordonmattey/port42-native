# Plan: knowledge distribution — one source, every agent (the release arc)

*2026-07-19, branch shell-s1. Status: AWAITING GM SIGN-OFF, no code. Goal owner: the release being
maximally usable by OTHER people's agents (GM, 2026-07-19). Discipline: an item is not touched
until its gate test exists and is recorded failing. Test in Port42Dev only (:4243). Exact suite
names in filters. Subsumes the packaging half of `plan-port42-ports-skill.md` (its craft content
survives as §B/§E input) and the "migrate injected context → installable skills" todo.*

## The model (agreed in conversation, 2026-07-19)

Two knowledge kinds, one source each:
- **API facts** — the registry. Cannot drift; every rendering is generated.
- **Port craft** — the authored manual (today `ports-context.txt`, 1,100 lines injected wholesale).

Four loading modes: runtime (`help`, tool schemas), install-time (instruction files, boot-refreshed),
publish-time (committed llms.txt at a public URL), resident (a slim core only).

Tiers by what an ecosystem can consume (cumulative):
- **T0 any HTTP agent**: `help` + published llms.txt.
- **T1 any instruction-file agent**: one generated markdown block → CLAUDE.md / GEMINI.md / AGENTS.md.
- **T2 any MCP agent** (Codex, Gemini, Cursor, Claude): a generated MCP server; knowledge travels in
  the protocol. The registry's self-description makes this an adapter, not a second implementation
  (`bridge-architecture-and-mcp.md` §6).
- **T3 Claude**: the `port42-ports` skill as packaging over the same files.

`ports-context.txt` dissolves: its API slice is generated, its craft prose becomes the manual served
by `help("ports")` + the skill, its resident footprint shrinks to a core of a few lines. In-app
companions lazy-load the manual through the same `help` mechanism as every external agent.

## Decisions needed from GM (blockers marked)

1. **BLOCKER — `help` becomes a tool.** Exposing `help` (with topics) as an LLM tool is what lets
   companions lazy-load craft like everyone else. Adds one tool to every companion's list and
   changes the golden fixture (deliberate). Recommend yes.
2. **BLOCKER — slim-core boundary.** I draft the resident core (target: under 40 lines: what a port
   is, the fence, "call help(ports) before building"); GM reviews at item B before the old
   injection dies. The acceptance eval: a companion cold-builds a correct port from core + topic
   call only.
3. llms.txt publish location: repo root, raw-GitHub URL (same pattern as the DMG). Default unless
   objected.
4. MCP distribution shape (bundled binary vs npx package) — decide at item D start, not now.

## The matrix

| # | Item | Gate (exists + recorded failing before code) | Depends on |
|---|---|---|---|
| A | **Exporter + freshness gates.** A test-target exporter renders the registry reference deterministically; regen mode (env flag) writes `llms.txt` (repo root); the gate asserts committed == generated. Determinism first: two renders byte-equal (today's `generateAPIReference` iterates dictionaries — likely needs a sort). | New `BridgeDocsExportTests`: (1) determinism gate, recorded failing if render is unordered; (2) freshness gate, recorded failing while llms.txt is absent. | nothing |
| B | **`help` topics + the craft split.** `help(topic?)`: no arg = API reference; `"ports"` = the craft manual. Split `ports-context.txt` → `ports-core.txt` (resident, slim) + `ports-manual.txt` (the topic's content). Companion system prompt injects core only. Flip `help.toolExposed` true (decision 1). | `BridgeHelpTests` new cases, recorded failing: unknown-topic errors cleanly; `help("ports")` serves manual markers. Prompt scan: the built companion system prompt no longer contains manual-only markers, still contains the core + pointer line. Existing ports-context claim tests repoint at the manual file. Golden updated deliberately for the help tool. | A (exporter carries the manual into publishable form) |
| C | **Instruction files: slim block + AGENTS.md + boot refresh.** `buildMarkdown` becomes the pointer block (how to call, `help`, `help("ports")`, llms.txt URL) instead of the full inventory. Add the AGENTS.md target (Codex convention; confirm exact paths at start). At app boot, any file already carrying a port42 block gets it rewritten from the live provider (kills the install-time drift class). | `InstructionServiceTests` (new), recorded failing: block contains the pointers and NOT the full inventory (line-count + marker asserts); an existing block is rewritten on refresh while a file without one is untouched; AGENTS.md path served. | A, B (the block points at what they built) |
| D | **The generated MCP server (T2, the adoption artifact).** An MCP stdio server whose tool list IS the registry's generated schemas, proxying calls to the gateway HTTP endpoint. Inspect the existing `port42-mcp.js` stub first; keep scope gated: tools/list + one round-trip before anything else. | First gates only, recorded failing: an MCP handshake harness asserts `tools/list` count == registry tool inventory (parity with `generatedToolDefinitions`), and one `tools/call` (`user_get`) round-trips through the dev gateway. Distribution decided at start (decision 4). | A; parallel-safe after C |
| E | **The `port42-ports` skill (T3 packaging).** `SKILL.md` (triggers per `plan-port42-ports-skill.md`) + references = `ports-manual.txt` + the generated api-reference, both written by the exporter so the freshness gate covers them. InstructionService installs the skill dir; boot refresh includes it. | Exporter gate extended (skill files committed == generated), recorded failing while absent; SKILL.md frontmatter validity scan; install-path unit test. | B (manual), C (installer) |
| F | **Acceptance + close-out.** The release-usability proof, then docs. | Live matrix: (1) fetch llms.txt from the public URL post-push; (2) fresh Claude Code session on a clean-ish config drives the API from the slim block alone; (3) the companion cold-build eval (GM present: one companion, core-only prompt, asked to build a port; correct on first try); (4) if available, a Codex or Gemini CLI smoke via AGENTS.md/MCP; (5) docs: this file marked done, handoff, todo entries closed. | A-E |

## Sequencing

A → B → C → E → D → F, with one exception: D can start any time after A if adoption timing makes
MCP more urgent than packaging; nothing in E blocks it. Each item lands individually: gate recorded
failing, implement, green, commit when asked.

## Risks

- **Companion regression from the slim core** (the manual stops being free). Bounded by decision 2's
  eval gate at F; the old injection is not deleted until that eval passes (the split can ship with
  core+manual both resident for one commit if needed — but no long-lived compat state).
- **Golden churn** from the help tool flip: one deliberate fixture update, same as ports.list.
- **Determinism** of the generated reference: gated first in A, before anything is committed.
- **MCP scope creep**: item D's gate is deliberately tiny (list parity + one call); everything
  further is a new item in a new plan.
- **Ecosystem conventions move** (AGENTS.md paths, skill formats): the block/skill content is
  generated, so a convention change is a renderer tweak, not a content rewrite.
