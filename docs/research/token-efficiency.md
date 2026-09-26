# Where Port42 spends tokens, and what actually reduces it

*Measured 2026-09-26 against `nautilus` merged with `origin/research` (this worktree). Research note,
not an approved decision. Every figure below carries the command that produced it.*

## Method

Token counts are Claude's own, from `POST /v1/messages/count_tokens` against `claude-opus-5`, which
is free of charge. Each artifact was counted as the `system` field of an otherwise identical minimal
request and the empty-system baseline (7 tokens) subtracted; tool arrays were counted in `tools`.
Scripts: `count.py`, `permethod.py`, `helpslice.py`, `manualsplit.py`, `shorten.py`, `designs.py` in
the session scratchpad, reproduced inline below.

`cl100k_base` via `tiktoken` was run first and undercounts these artifacts by roughly a factor of
1.7 (instruction block 850 against 1,273; ports manual 12,111 against 18,106). Figures from it are
not used. The measured character density of Port42's own documents is 2.66 to 2.95 characters per
Claude token.

Two artifacts could be measured exactly without building the app, because both are committed
generated artifacts under a freshness gate:

- `llms.txt` is byte-identical to the `help` bridge method's output. `BridgeDocsExportTests`
  asserts `llms.txt == generateAPIReference(...)` and fails otherwise
  (`Tests/Port42Tests/BridgeDocsExportTests.swift:40`).
- `Tests/Fixtures/tool-definitions-golden.json` is the last reviewed output of
  `AppState.generatedToolDefinitions()`, and `BridgeSchemaParityTests` verifies generation against
  it on every run (`Tests/Port42Tests/BridgeSchemaParityTests.swift:85`).

The generated set holds 54 tools. The registry holds 76 methods; 23 carry `toolExposed: false`.

```
python3 -c "import json;d=json.load(open('Tests/Fixtures/tool-definitions-golden.json'));print(len(d))"
# 54
grep -c 'toolExposed: false' Sources/Port42Lib/Services/BridgeMethods.swift
# 23
awk '/^## Available Methods/{f=1} f&&/^  [a-z][a-zA-Z0-9_.]*\(/{n++} /^### Aliases/{f=0} END{print n}' llms.txt
# 76
```

## Three things are not paid at all

Before the table, three sources named in the brief cost zero tokens on this branch. Each was
verified by finding no production consumer.

**The 54 generated tool schemas reach no model.** `generatedToolDefinitions()` has five callers and
all five are tests.

```
grep -rn "generatedToolDefinitions" Sources Tests
# Sources/.../AppState.swift:383  (the definition)
# Tests/Port42Tests/ManualAccuracyTests.swift:51
# Tests/Port42Tests/BridgeParityHarness.swift:72
# Tests/Port42Tests/BridgeSchemaParityTests.swift:68, :142
```

The in-app model was deleted in nautilus Phase 1 step 3 (`docs/release-no-llm-in-port42.md`), and
with it the only path that sent these schemas to an LLM. Their remaining job is to be the vocabulary
against which `ManualAccuracyTests` checks that the manuals teach only real tool names. The 11,380
tokens they would cost are a liability if a consumer returns, not a current bill.

**`port42-mcp.js` is not installed.** No Swift, Go or shell code registers it as an MCP server.

```
grep -rn "port42-mcp" Sources docs cli | grep -v '^docs/'
# Sources/Port42Lib/Resources/port42-mcp.js:23  (its own identify frame)
```

If it were installed, a client would receive one tool, not 54: the whole bridge is exposed as a
single `port42` tool with a static method list in its description, measured at **612 tokens**
(`count.py`). `CompanionProtocol`'s own comment records the decision (`AgentRouting.swift:31`,
"GM, 2026-09-26: tools by the CLI, not MCP").

**`TerminalOutputProcessor`'s cleaned output reaches no agent.** Its own header says so
(`TerminalOutputProcessor.swift:10`), and the constructor confirms it: the `onFlush` closure is
gated off for every hooks-capable tool, which is every companion CLI
(`GhosttyTerminalController.swift:226`). Only `<p42>` tags pass through. Terminal output that does
reach an agent's context does so because the agent asked for it, which is the next section.

## The measurement table

One Port42-spawned Claude Code companion session. "Resident" means it is loaded once at session start
and is present in the input of every request thereafter. "One-off" means it lands in the message body
once, as a tool result, and is then carried in the input of every later turn in the same session.

Resident items sit ahead of the conversation, so they fall inside the cached prefix whether the
harness places them in `system` or in the first turn; which of the two it is changes the breakpoint,
not the per-turn cost. That placement was not verified against Claude Code's request bodies and is
the one assumption in the table that is not measured here.

| Source | Tokens | How often paid | Per turn | Per 10-turn session |
|---|---|---|---|---|
| `InstructionService.markdown` block in `~/.claude/CLAUDE.md` | **1,273** | resident, whole session | 1,273 | 12,730 |
| the same block for codex (`~/.codex/AGENTS.md`, includes the companion section) | **2,448** | resident, whole session | 2,448 | 24,480 |
| `bakeCompanionPrompt` via `--append-system-prompt` | **1,362** | resident, whole session | 1,362 | 13,620 |
| &nbsp;&nbsp;of which `CompanionProtocol.rules` | 258 | " | " | " |
| &nbsp;&nbsp;of which `CompanionProtocol.chats` | 823 | " | " | " |
| `help topic:"ports"` (the manual the block calls REQUIRED READING) | **18,106** | once per session, if obeyed | 18,106 after turn 1 | 162,954 |
| `help` with no topic (`port42 help api`, == `llms.txt`) | **12,483** | once, if the agent reads it | 12,483 after turn 1 | 112,347 |
| the 54 generated tool schemas | **0** (would be 11,380) | never, no consumer | 0 | 0 |
| `port42-mcp.js` tools/list | **0** (would be 612) | never, not installed | 0 | 0 |
| `TerminalOutputProcessor` cleaned output | **0** | never, gated off for CLI tools | 0 | 0 |
| `ports-core.txt`, the intended resident core | **1,425** | never, no consumer | 0 | 0 |
| `llms-cli.txt` (stale: documents a Python CLI that is not the Go one) | **538** | never, no consumer | 0 | 0 |
| `echo-prompt.txt` (Echo's first-run brief) | **526** | once, first run only | 0 | 0 |
| `port42` CLI usage text | **577** | only if the agent runs `port42 help` | 0 | 0 |

**A claude companion session pays 2,635 tokens resident and 18,106 once.** Across ten turns that is
`10 x 2,635 + 9 x 18,106 = 189,304` input tokens before any of the user's actual work. If the agent
also reads the API reference, `+ 9 x 12,483 = 301,651`.

The manual is 86 percent of that figure by arithmetic (`162,954 / 189,304`), and it is not a
by-product: the instruction block instructs it, in capitals.

```
# the REQUIRED READING line, in the block that is installed to every CLI's instruction file
grep -n "REQUIRED READING" Sources/Port42Lib/Services/InstructionService.swift
# 162:  # The port-authoring manual — REQUIRED READING before building or updating any port
```

### What is inside the 18,106

The manual splits cleanly at two headings (`manualsplit.py`).

| Section | Lines | Tokens | What it is |
|---|---|---|---|
| port craft | 262 | **4,111** | the tile constraint, ES-module scripts, CSP, versioning, the stateful pattern, the gotchas |
| `BRIDGE API REFERENCE:` | 648 | **11,830** | every `window.port42.*` method, hand-written, one entry per registry method |
| `## Interacting With Ports From Conversation` | 129 | **2,165** | the same registry methods again, under their snake_case tool names |

```
grep -n "^BRIDGE API REFERENCE:\|^## Interacting With Ports From Conversation" \
  Sources/Port42Lib/Resources/ports-context.txt
# 264:BRIDGE API REFERENCE:
# 881:## Interacting With Ports From Conversation
```

**13,995 of the manual's 18,106 tokens restate what the registry already declares.** `help`'s
generated inventory covers the same 76 methods in 9,758 tokens (`helpslice.py`). Section 3 is worse
than redundant: it teaches an agent to call `ports_list()` and `port_push(id, data)` as tools, and a
CLI-driven agent on this branch has no tools, only `port42 ports.list`.

The `PublishedDocs` rule exists to stop exactly this. It is applied to three blocks (error codes,
the notify envelope, the event kinds), which together are a few hundred tokens of the manual, while
13,995 tokens of the same class sit hand-written beside them.

### The bill for the registry's self-description

The 54 generated tool schemas, split (`count.py`, `permethod.py`):

| | Tokens |
|---|---|
| the full array | **11,380** |
| the same 54 with every `description` removed (names, types, `required`, enums) | **4,035** |
| therefore the human-written prose | **7,345** |
| just the 54 tool names, as a flat roster | 297 |

Method-level and parameter-level prose are close to equal: cutting every method description to its
first sentence gives 8,981 (saves 2,399); dropping every parameter description and keeping the
method ones gives 7,645 (saves 3,735).

Marginal cost per method, measured by removing one method from the array and re-counting
(`permethod.py`). The top ten are 4,596 of the 11,380; the median method is 148.

```
  984  port_create      399  ports_list       339  screen_record
  480  port_push        388  port_exec        323  port_publish
  445  port_patch       374  port_manage      294  port_restore
  409  rest_call        371  port_move        285  port_rename
  401  port_update      345  screen_record_start
```

One string dominates the duplication: the `token` parameter description, applied centrally by
`BridgeMethod.acceptingExpect()` (`BridgeRegistry.swift`), is **106 tokens** and is carried by 8 of
the 54 tools, for **848 tokens**.

### Could the prose be shorter without becoming wrong

Partly, and the ceiling is low. Three rewrites, measured in the real array (`shorten.py`):

| | Now | Shortened | Saved |
|---|---|---|---|
| `port_create` | 293 | 157 | 136 |
| `port_patch` | 160 | 110 | 50 |
| `port_push` | 149 | 59 | 90 |
| **array total** | **11,380** | **11,095** | **285** |

`port_push` now:

> Send input to a port — one verb, dispatched by the port's type. A WEB port receives the data as a
> 'port42:data' CustomEvent with the payload in event.detail. A TERMINAL port receives the data as
> raw keystrokes typed into the shell: end with a newline (e.g. "ls\n") to run the command, or omit
> it to leave the line waiting unsubmitted. Use the id from ports_list. Prefer this over port_exec
> for data transfer.

Shortened:

> Send input to a port. One verb, dispatched by the port's type; see `data` for what each type
> receives. Use the id from ports_list. Prefer this over port_exec for data transfer.

That is safe because the `data` parameter's own description already states the web/terminal split
verbatim, at 68 tokens. The method description was a second copy.

`port_create` now spends most of its 293 tokens enumerating which parameters belong to which
`type`, and every one of those parameters already opens with `type:"terminal" —` or `type:"web" —`.
Replacing the enumeration with "each parameter below names the type it belongs to" keeps the
behavioral facts a parameter cannot carry (a terminal runs in `/bin/zsh`, claude and gemini get the
hooks, a browser tile follows links, `type:"chat"` is idempotent) and drops the rest.

`port_patch` loses its procedural walk-through ("Use port_get_html first to read the current HTML,
find the exact string to replace, then call port_patch") and keeps the two facts a model acts on:
only `search` is replaced, and the call is refused rather than silently mangling the port.

**The honest ceiling on this lever is 3,735 tokens** (every parameter description deleted), and
that is not a real option. The prose exists because parameters are not self-evident. The single
largest duplicate, the 106-token `token` description, is the clearest case against shortening: its
source comment records that it said "Optional" until 2026-07-28, that the schema and the rule
disagreed, and that a model following the schema wrote a call the app refused
(`BridgeRegistry.swift`, in `acceptingExpect()`). Cutting it back is re-running an experiment that
already failed once. And since nothing sends these schemas to a model today, the entire lever is
worth 0 tokens until a consumer returns.

### Terminal output into an agent's context: unbounded by construction

The 200,000-byte cap on tool results (`ToolExecutor.maxToolResultBytes`, commented "~200KB ≈ ~50K
tokens") applies to one path, and its own comment names it: "only this path, the in-app LLM
tool-result". That path is deleted. `capForModel` has two callers, both inside the dead
`ToolExecutor.execute`.

```
grep -rn "capForModel" Sources
# Sources/Port42Lib/Services/ToolExecutor.swift:54, :84, :112   (definition + the two dead callers)
grep -rn "ToolExecutor(" Sources
# Sources/Port42Lib/Services/AppState.swift:873   -> RemoteToolExecutor, which does not call it
```

The live path is `RemoteToolExecutor`, which serves the gateway, `/call`, and therefore the `port42`
CLI. It applies no cap. Three defaults are consequently unbounded in an agent's context:

- **`terminal.exec`** returns `ShellExec.run`'s full output. `ShellExec`'s header states the cap
  lives in `ToolExecutor`, "not this shared base, since a port or gateway caller is not
  token-limited". A CLI agent is a gateway caller and is token-limited.
- **`port.console`** defaults to `tail=100` and `PortConsole.maxLineLength` is 4,000, so the
  documented default can return 400,000 characters. At the measured 2.76 characters per token for
  Port42's own text, that is on the order of 145,000 tokens from one call whose argument the manual
  tells the agent to omit.
- **`port.getHtml`** returns the whole port. The manual itself notes that three.js minified is about
  613KB and fits under the gateway's 2MB payload cap, so reading such a port back is on the order of
  220,000 tokens.

This is the one finding here that is a defect rather than a design trade. `port.console` is the call
the companion prompt explicitly instructs every companion to make after building a port
(`AgentRouting.swift`, "read its console (port42 port.console id=<port id>) for errors").

## Prompt caching

Mechanics, from the Anthropic reference: caching is a prefix match, render order is `tools` then
`system` then `messages`, any byte change anywhere in the prefix invalidates everything after it,
there are at most 4 breakpoints, and the minimum cacheable prefix on Claude Opus 5 is 512 tokens.

Port42's resident block sits in a good position and, on this branch, is already designed for it,
apparently for a different reason. `InstructionService` writes the gateway port as the shell
expression `${PORT42_GATEWAY_PORT:-4242}` rather than the live port number
(`CompanionProtocol.envGateway`), and `MultiInstanceInstructionsTests` gates it:

```
grep -n '@Test' Tests/Port42Tests/MultiInstanceInstructionsTests.swift
# 34:  @Test("no instruction file names an instance's port")
```

That test was written so one file serves every instance. Its side effect is that the block is
byte-identical across boots and instances, so `refreshInstalled()` at app boot rewrites it to the
same bytes and does not invalidate any session's cache. Had the live port been baked in, every
Dev/prod boot would have moved a byte in the prefix of every agent on the machine.

Two consequences worth stating:

- **At 1,273 tokens the block clears the 512-token minimum on Claude Opus 5** and caches on its own
  merits. It is charged at cache-write price once and cache-read price thereafter. The resident
  block is therefore the cheapest thing in the table, and shrinking it is the lowest-value lever
  available.
- **The 18,106-token manual arrives in the message body, after the prefix.** It is cached from the
  turn after it arrives and is never evicted for the rest of the session. Caching makes it cheaper;
  it does not make it small, and it occupies context the user's work then competes for.

## Lean invocation

`docs/research/headless-cli-ai.md` measured `claude -p` at 22,738 input tokens with default flags
against 441 lean, because the default is an agent harness.

**That shape does not appear in Port42's own spawning.** Port42 launches `claude` interactively
inside a terminal port, through the shim, which adds `--settings` (hooks),
`--append-system-prompt`, and a session pin, and nothing else.

```
grep -n 'argv = append' shim/main.go
# --settings, --append-system-prompt, the session pin, then the user's own args
grep -rn -- '"-p"' Sources cli shim gateway
# shim/main_test.go only, as a fixture for "the user chose their own session"
```

There is no `-p` call, no `--output-format json`, no tool-restriction flags, and no `codex exec`
path. The lever has nothing to act on unless the headless `ai.complete` in `headless-cli-ai.md` is
built, which that note already recommends against.

The lean-invocation *principle* does apply, one level up: the 22,738 tokens in that measurement are
a harness a caller did not ask for, and Port42's 18,106-token manual is the same shape of cost. The
difference is that Port42 writes the instruction that buys it.

## Before and after, on one workload

Workload: one Port42-spawned Claude Code companion, 10 turns, building one web port and iterating
once. Resident items are charged every turn; one-off items are charged from the turn after they
arrive. Figures are input tokens attributable to Port42, before any of the user's work.

| | now | A: skills | B: the CLI, finished | A+B |
|---|---|---|---|---|
| instruction block | 1,273 | **227** (pointer) | 1,273 | **227** |
| six skill listing lines | 0 | **554** | 0 | **554** |
| companion prompt | 1,362 | 1,362 | 1,362 | 1,362 |
| tool schemas | 0 | 0 | 0 | 0 |
| **resident, per turn** | **2,635** | **2,143** | **2,635** | **2,143** |
| port manual / port skill | 18,106 | **4,111** | **4,111** | **4,111** |
| API reference read | 0 (12,483 if read) | 0 | **7,356** (`### port` + preamble) | **4,631** (`### port`) |
| **one-off** | **18,106** | **4,111** | **11,467** | **8,742** |
| **10-turn session total** | **189,304** | **58,429** | **129,553** | **100,108** |
| saving against now | | **130,875** | **59,751** | **89,196** |

Sources for each cell: resident figures from `count.py` and `designs.py`; 4,111 is the measured
craft section of the existing manual (`manualsplit.py`); 4,631 and 2,725 are the measured `### port`
namespace slice and preamble of `help` (`helpslice.py`).

Two caveats on the table. The 4,111 for a port skill assumes the skill carries the craft and nothing
else, which is what the `PublishedDocs` rule requires of it and what Phase 5's verify step implies;
it is the existing text, not an estimate. The 554 for six skill descriptions is calibrated against
the six real skills installed on this machine, which cost 883 tokens for six listing lines and 2,069
tokens for a mean `SKILL.md` body (`count.py`), so the port42 descriptions were written to that
density rather than assumed shorter.

## The three candidate designs

### A. Skills instead of a megaprompt (nautilus Phase 5)

**Applies, and saves more than the plan's framing suggests, for a different reason than the plan
gives.** Phase 5's stated target is the instruction block: "the instruction block shrinks to a
pointer" (`docs/plan-shell-only.md:330`). Measured, that part is worth **492 tokens per turn**
(1,273 + 0 becomes 227 + 554), or 4,920 across a ten-turn session. Six skill descriptions cost 554
tokens resident whether or not any of them fires, so more than half of the block's saving is handed
straight back.

The part of Phase 5 that pays is the sentence next to it: "Everything API-shaped is generated from
the registry." That is what deletes 13,995 tokens from the manual, and it is worth **125,955 tokens
across the same session**, twenty-five times the megaprompt saving.

**The plan's design captures it, but its own summary does not.** "Skills, not a megaprompt" names
the small half. The gate row for Phase 5 names the large half correctly ("Skills are generated from
the registry: a method that exists is documented and one that does not is not, the `PublishedDocs`
rule applied to skills"). Anyone reading only the heading would build six skills, shrink the block,
and leave the 18,106-token manual in place, because nothing in the phase says the manual is the
thing being replaced.

Two facts the plan should absorb, both measured here:

- `ports-core.txt` already exists at 1,425 tokens, is described in `AppState.swift:141` as "the ONLY
  port knowledge that rides in every companion system prompt", and has **no consumer**
  (`grep -rn "portsCore" Sources Tests` returns the declaration only). The resident core the plan
  wants is written and disconnected.
- A skill costs its description every turn. The design should minimize the number of skills, not
  the size of each. Six skills at the measured density cost 554 tokens resident; three would cost
  roughly half that and the craft is not obviously divisible six ways.

**Cost in discoverability: low, and possibly negative.** A skill description is a trigger list, which
is a better index than a wall of prose. The real risk is that a skill does not fire when it should,
and the port skill is the one that must: a companion that builds a port without the CSP rule and the
tile rule produces a blank rectangle. The mitigation is already in the current design and should
survive, which is that the pointer block states the rule in one line rather than relying on the
skill's trigger words alone.

### B. The CLI

**Already shipped, and it is why the resident bill is 1,273 rather than 12,000.** Teaching one
command with subcommands costs, measured:

| | Tokens |
|---|---|
| the whole instruction block, which is mostly the CLI's calling convention | 1,273 |
| `port42` full usage text, if the agent runs `port42 help` | 577 |
| the 54 method names as a flat roster | 297 |
| 54 typed tool schemas | 11,380 |

So yes, decisively: the CLI surface is between 20 and 40 times cheaper resident than typed schemas.

**But the discoverability is paid for later, and at the current design it costs more than the
schemas did.** `port42 help api` is 12,483 tokens, against 11,380 for shipping all 54 typed schemas
up front. An agent that reads the full reference once has spent more than an agent that was handed
every schema, and it has spent it in the message body rather than the prefix.

Two measurable gaps make that worse than it needs to be:

- **`help` has no namespace argument.** The output is already grouped by namespace and the slices
  are small: `### port` is 4,631, `### terminal` is 113, `### clipboard` is 100, `### user` is 25
  (`helpslice.py`). `port42 help api port` is a change to one `switch` in `BridgeMethods.swift:1122`
  and `generateAPIReference`'s grouping loop, and it turns 12,483 into 4,631 for the common case.
- **`isMethod` accepts any dotted string** (`cli/method.go:28`:
  `strings.Contains(verb, ".") || verb == "whoami"`). There is no name validation and no parameter
  schema at the CLI, so a typo is a round-trip to the gateway and a refusal. A typed tool surface
  catches that before the call. This is the genuine correctness cost of the CLI, and it is
  mitigated by the error codes being a closed, documented set rather than by shipping schemas.

**What the agent loses against typed tools:** parameter shape at composition time, and enum values.
The refusal is well-designed (`{error, code}`, exit 1, `current` on a stale write), so the loss is
one round trip rather than a wrong action. That is an acceptable trade at 297 tokens against 11,380,
and it stops being acceptable if `help api` is the only way to recover the shape.

### C. A tool selector

**Against the current design all three flavors save zero, because the resident tool bill is zero.**
They are only a question if Port42 re-adds a consumer for `generatedToolDefinitions()`, for example
a hosted companion or an installed `port42-mcp`. Costed against that hypothetical 11,380:

**C1, keyword or prompt matching.** Select a subset per request from the user's text. Saves
`11,380 - subset`. **Breaks prompt caching completely.** Tools render first in the prefix, so a
different tool array on turn N invalidates the entire prefix, including the 2,635 resident tokens
and the whole accumulated conversation. For any session past a couple of turns that costs more than
the schemas it removed. Failure mode: the model cannot see what it was not given, so a missed
selection is indistinguishable from a missing capability, and the model will tell the user Port42
cannot do the thing. Unrecoverable within the turn.

**C2, semantic or embedding selection.** Same cache invalidation as C1, plus two Port42-specific
costs. There is no embeddings endpoint in the Anthropic API reference, so this requires a second
provider. Port42 deleted every provider credential on this branch and `Port42AuthStore` actively
reaps the old Keychain entries (`docs/release-no-llm-in-port42.md`). Reintroducing a provider
credential to pick tool schemas would undo the branch's most deliberate simplification to solve a
problem that does not currently exist. Same failure mode as C1, with a worse story about why a
capability vanished.

**C3, a skill that teaches the agent to ask.** This is what the harness this note was written in
does, and it is a shipped API feature, not a proposal: `tool_search_tool_regex_20251119` and
`tool_search_tool_bm25_20251119`, with `defer_loading: true` on the deferred tools. Measured cost of
the Port42 shape:

| | Tokens |
|---|---|
| one `tool_search` tool | 461 |
| the 54 method names as a deferred roster | 297 |
| **resident** | **758** |
| plus each method actually fetched | median 148, `port_create` 984 |
| a realistic port build (create, list, update, console, getHtml) | 2,191 |
| **total for that session** | **2,949** against 11,380 |

**And it does not break the cache.** Tool search *appends* schemas rather than swapping the array,
so the existing prefix survives, which is precisely the property C1 and C2 lack. Failure mode: the
model searches again with different words. Recoverable within the turn, visibly, without the user
seeing a capability disappear.

**Ranked: C3, then nothing.** C1 and C2 trade a resident cost for a per-turn cache invalidation that
is larger, and they fail in the one way that matters. C3 is the correct shape if a tool consumer
returns, and is worth 0 until one does.

### Ranking the three, by measured saving against measured cost

| | Saving on the 10-turn workload | Cost |
|---|---|---|
| **A, skills** (specifically: the API-shaped half) | **130,875** | six resident descriptions (554/turn); a skill that does not fire when it should |
| **B, the CLI finished** (`help` takes a namespace) | **59,751** | one round trip when a parameter shape is wrong; no name validation at the CLI |
| **C, a tool selector** | **0** | not applicable; 8,431 against a hypothetical consumer, and only in flavor C3 |

**A is obviously right, with one correction to its framing.** It is the only candidate that touches
the 18,106-token item, which is 86 percent of the bill. A and B compose and should be done together:
the skill carries the craft, `help api <namespace>` carries the method facts, and neither restates
the other. C should be recorded as the answer to a question Port42 does not currently have.

## The fundamentals, in Port42's terms

1. **Port42 pays 18,106 tokens per session because its instruction block says REQUIRED READING, and
   13,995 of those tokens are the registry describing itself for the third and fourth time.** The
   lever is `PublishedDocs` applied to the manual, which is already the stated rule and is already
   enforced on three small blocks beside the large ones. Nothing else on the list is within an order
   of magnitude.

2. **Port42 pays almost nothing for tools because it chose a CLI over MCP and deleted its own
   model.** Progressive tool disclosure, tool selectors and MCP schema trimming all save zero here.
   That is not a gap; it is the consequence of two deliberate decisions, and the numbers should be
   used to stop those levers being reopened.

3. **Port42's resident block is small and cacheable because a multi-instance test forced the gateway
   port to be a shell expression.** 1,273 tokens in a stable prefix is the cheapest line in the
   table. Shrinking it is the lever with the best story and the worst return, and Phase 5's heading
   points at exactly that.

4. **Port42's real unbounded cost is the output of the calls it tells agents to make.** The only
   tool-result cap in the tree guards a path that no longer exists, and `port.console`'s documented
   default can return 400,000 characters into the context of an agent the companion prompt
   instructed to call it. Bounding `RemoteToolExecutor` is a smaller change than any of the three
   candidate designs and is the only one that fixes a defect rather than a trade.

5. **Every document Port42 ships that is not generated is a document that is already drifting and
   already being paid for twice.** `ports-core.txt` (1,425 tokens, no consumer), `llms-cli.txt` (538
   tokens, documents a CLI that does not exist), and the manual's 13,995 tokens of API restatement
   are the same failure in three sizes. The rule that would have prevented all three is written in
   `PublishedDocs.swift` and applied to three blocks.

## What could not be determined

- **Whether an agent actually reads the manual.** The instruction block tells it to, in capitals,
  and the companion prompt reinforces it. Nobody has measured how often a session issues
  `port42 help ports`. Settled by counting `help` calls with `topic == "ports"` per session at the
  gateway, over a week of real use. Everything in this note that depends on that number is
  conditional on it, and it is the single most valuable measurement not taken here.
- **What a port skill would actually contain.** 4,111 tokens is the existing craft section, which is
  the right content by the `PublishedDocs` rule. A real skill would be written, not sliced, and
  could be larger or smaller. Settled by writing one.
- **Whether shortened descriptions degrade tool-call accuracy.** The three rewrites above are
  measured for size and argued for correctness; no eval was run. Settled by an eval over real port
  builds, and it is not worth building until a tool-schema consumer exists.
- **Whether an Anthropic embeddings endpoint exists.** The bundled API reference documents none.
  This affects only C2, which is ruled out on other grounds. Settled by the live API docs.
- **The exact rendered size of the ports manual as `help` serves it.** 18,106 is the manual with all
  three `PublishedDocs` markers substituted, with the error-code block reproduced from the rendered
  copy in `llms.txt` and re-indented rather than re-wrapped at the wider indent. The word wrap at
  indent 6 would differ by a handful of lines. Settled by
  `PORT42_REGEN_GOLDEN=1 swift test`, or by calling `help topic:"ports"` on a dev instance.
- **What a remote peer's companion pays.** `RemoteToolExecutor` serves calls from another instance,
  and the tokens are spent in that peer's context, not this machine's. Not measured.
