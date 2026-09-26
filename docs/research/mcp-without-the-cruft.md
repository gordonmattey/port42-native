# MCP without the cruft

Against `nautilus` merged with `research`, 2026-09-26. Token counts from Claude's `count_tokens`
against `claude-opus-5`.

## The plan

Serve the Port42 registry to MCP clients from the gateway, as a name roster with schemas fetched on
demand.

Port42 holds no provider credential and starts no model. A client (Claude Code, Codex) calls the
provider; Port42 answers tool invocations. This is compatible with D9.

## Why a roster rather than a manifest

The registry's 54 generated tool schemas total **11,380 tokens**: 7,345 of description, 4,035 of
structural JSON. Shipping them up front puts that resident in every request of every session,
including sessions that never touch Port42. Current resident cost is 1,273 tokens for the instruction
block.

A roster plus search and fetch costs **758 resident** (461 search tool, 297 roster), with fetches at a
median of 148 tokens. A realistic port build reached 2,949 against 11,380.

It also appends rather than swaps, so the prompt cache survives. Per-request tool arrays, whether
selected by keyword or by embedding, invalidate the cache prefix because tools render first, and past
a couple of turns cost more than the schemas they remove. They also fail invisibly: a model cannot
see what it was not given, so a missed selection reads as a missing capability and the agent works
around it rather than asking.

## Four moves

1. **Serve from the gateway, not a node process.** The gateway speaks HTTP, holds the registry and
   authenticates callers already.
2. **Roster, not manifest.** Names and one-line purposes; schema on demand.
3. **Namespace it.** `help` groups its output already and the slices are small (`### port` 4,631,
   `### terminal` 113, `### user` 25) but it takes no namespace argument. One `switch` at
   `BridgeMethods.swift:1122`, and the same grouping is what the roster exposes.
4. **Generate it from the registry.** `Resources/port42-mcp.js:82` advertises `ai.complete`,
   `messages.send`, `messages.recent` and `companions.invoke`, all deleted in Phase 1. Anything served
   by hand drifts; the `PublishedDocs` rule applies.

## Open

- **MCP and the CLI are two surfaces.** The CLI is cheaper and human-readable; typed tools cannot be
  typo'd into a gateway round trip (`isMethod` accepts any dotted string, `cli/method.go:28`).
  Shipping both means maintaining both from the one registry.
- **Whether a roster stays discoverable.** The saving assumes an agent searches for what it needs
  rather than giving up. Untested against Port42's method names.
