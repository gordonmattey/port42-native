# MCP without the cruft

Written 2026-09-26, against `nautilus` merged with `research`. Records a correction and a direction.
GM, 2026-09-26: "MCP without the cruft is my vision."

## The correction that opens this

An earlier note in this branch listed four ways an agent can reach Port42 and said in-app tools were
"closed by D9". That was stated in a way that read as closing MCP too. It does not, and the two point
in opposite directions.

| | Who calls the model | Who holds the credential | D9 |
|---|---|---|---|
| **In-app tools** | Port42 | Port42 | **closed.** This is what `LLMEngine` did and what Phase 1 deleted |
| **MCP** | the client (Claude Code, Codex) | the client | **open.** Port42 is called, and answers |

D9 says Port42 never calls a model provider. Under MCP, Port42 starts no model, holds no key and
makes no provider request. It answers tool invocations from a client that does all three. So MCP is
compatible with D9 as written, and the roadmap item that reads as rejecting MCP was rejecting the
cost, not the protocol.

## What the cruft actually is, measured

From `token-efficiency.md`, counted with Claude's `count_tokens` against `claude-opus-5`:

- The registry's 54 generated tool schemas total **11,380 tokens**, of which **7,345 is the
  descriptions** and 4,035 is structural JSON.
- Today that is paid by nobody: the generator has no consumer, because the CLI was chosen over MCP
  and the in-app model was deleted. The current resident bill is **1,273 tokens** for the instruction
  block.
- So adopting MCP naively means adding roughly 11,380 resident tokens to every request of every
  session, including the ones that never touch Port42.

That is the cruft. Not the protocol, the manifest.

Three further costs that are real but smaller: a separate server process to install and keep
running, per-client configuration, and a tool list that goes stale (`Resources/port42-mcp.js:82`
currently advertises `ai.complete`, `messages.send`, `messages.recent` and `companions.invoke`, all
four deleted in Phase 1).

## The shape that avoids it

The token work measured three ways to stop shipping every schema. Two of them are worse than the
problem:

- **Keyword or prompt-based selection** and **embedding-based selection** both send a different tool
  array per request. Tools render first in the prefix, so a changing array invalidates the prompt
  cache for everything after it. Past a couple of turns that costs more than the schemas removed. Both
  also fail in the way that matters: a model cannot see what it was not given, so a missed selection
  is indistinguishable from a missing capability, and the agent will work around it silently rather
  than ask.
- **A roster plus search and fetch** appends rather than swaps, so the cache survives. Measured at
  **758 resident** (461 for the search tool, 297 for a name roster), with fetches at a median of 148
  tokens each; a realistic port build reached 2,949 against 11,380 for shipping everything.

So the direction is: **serve the registry over MCP with a name roster, and hand over a schema when a
tool is actually reached for.**

Concretely, against what already exists:

1. **Serve it from the gateway, not a node process.** The gateway already speaks HTTP, already holds
   the registry, and already authenticates callers. `port42-mcp.js` is the crude version of this and
   is already stale.
2. **Roster, not manifest.** Names and one-line purposes, with the schema fetched on demand. The
   spike measured the roster at 297 tokens.
3. **Namespace it.** `help` already groups its output and the slices are small (`### port` 4,631,
   `### terminal` 113, `### user` 25) but it takes no namespace argument, which is one `switch` at
   `BridgeMethods.swift:1122`. The same grouping is what a roster would expose.
4. **Generate it, do not write it.** The stale advertisement in `port42-mcp.js` is the `PublishedDocs`
   failure in a third place, after the manual and `ports-core.txt`. Whatever is served must come from
   the registry.

## What this does not settle

**MCP and the CLI are two surfaces, and this note does not choose between them.** They answer
different questions. The CLI is cheaper and readable by a human; typed tools are more reliable and
cannot be typo'd into a gateway round trip (`isMethod` accepts any dotted string, `cli/method.go:28`).
Shipping both means maintaining both, and the registry is the single source for either.

**Whether anyone wants it.** No user has asked for Port42 tools inside their own agent. The case for
MCP is reliability and reach into clients Port42 does not control, and neither has been tested.

**Whether a roster is enough to be discoverable.** The measured saving assumes an agent will search
for what it needs rather than give up. That is the same assumption the deferred-tool design in
Claude Code makes, and it holds there, but it has not been tested with Port42's own method names.
