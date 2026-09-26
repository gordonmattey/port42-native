# Release note: Port42 no longer contains an LLM

Covers the in-app engine removal (nautilus Phase 1 step 3) and the decision not to reintroduce
`ai.complete` as a headless CLI call. Written 2026-09-26. Engineering record; go-to-market framing is
separate and marked as such at the end.

## What changed

Port42 no longer talks to a model provider. The in-app engine is deleted, and with it:

| Removed | What it was |
|---|---|
| `LLMEngine`, `GeminiEngine`, `LLMBackend`, `LLMStreamCollector` | the streaming clients |
| `BridgeServiceAI`, the `ai.*` methods | `ai.complete` and its registry service |
| `AgentRouterLLM` | picked which companion answered an unmentioned message |
| `AgentAuth` | read Claude Code's OAuth credential out of the Keychain |
| `AppState+PortAI` | let a port's JS ask a model at runtime |
| `ModelPicker`, `UsageView`, `token_usage` | model selection and spend reporting |

**The sign-in prompt is gone.** Port42 used to read Claude Code's Keychain credential so the app
could call Anthropic directly. Nothing reads a provider credential now, and `Port42AuthStore`
actively reaps the old account entries.

## What a port does instead

A port that wants a model asks a companion, through the chat that every port already has:

```js
await port42.chat.post({ port: myId, text: "@echo summarize this" });
// the reply arrives as a chat event to every subscriber of the port
```

The companion is a CLI agent running in a terminal port, signed in as itself. The call happens in a
process Port42 did not start, under credentials Port42 does not hold, and the whole exchange is
visible in a chat the user can read.

## Why not a thin `ai.complete` over the CLI

The obvious restoration is to shell out to `claude -p` and keep the old method. Measured on
2026-09-26, that is worse on every axis than the path that already exists:

| | wall | input tokens | cost |
|---|---|---|---|
| `claude -p`, lean flags | 2.32s | 441 | $0.000641 |
| `claude -p`, default flags | 4.16s | 22,738 | $0.028813 |
| `codex exec` | 7.67s | 15,177 | no flag reduces it |

Forty-five times the cost for the same answer on defaults, because the default invocation is an agent
harness rather than a completion. Peak resident memory is 264 MB per call, and nothing in the tree
bounds concurrency. Codex cannot take a system prompt, cannot disable its tools, and cannot stream.

The authorization problem is worse than the cost. `claude -p` on default flags is an autonomous agent
that can run shell commands, edit files, fetch the web and spawn subagents. A permission card reading
"this will use your AI subscription tokens" would be describing something that executes code. The
honest gate is at least `.terminal`, which is capped at 120 seconds and runs one named command, and
this is strictly more powerful than that.

**If a synchronous call is ever wanted**, the shape is `companion.ask(name, text, timeout)` over the
chat path that already works. No subprocess, no CLI detection, no second authentication story, and
the companion's own grants apply.

## Breaking change for port authors

Ports that called `ai.complete` stop working. This is deliberate and was decided as D7: there is no
backward compatibility, and older ports are not preserved. Rewrite them to post to a companion.

## One limit, stated plainly

"The CLI authenticates under its own sign-in" holds for the environment Port42 hands the child
process. Port42 passes its own environment through, and the terminal path runs `/bin/zsh -lc`, which
sources the user's profile. Measured: an inherited `ANTHROPIC_API_KEY` is used by the CLI. Port42
holds no credential, and it does choose the environment in which one may be found.

## Residue not yet cleaned

Not shipped with the removal, tracked in `docs/research/defects-found.md`:

- `Resources/port42-mcp.js:82` still advertises `ai.complete`, `messages.send`, `messages.recent` and
  `companions.invoke` to MCP clients. All four are deleted. Agent-facing and wrong.
- Settings still has a tab named "AI" (`SignOutSheet.swift:17`).
- `ai.cancel` and `suspendAI()` are misnamed rather than dead: they are the live cancel path for
  `port.subscribe`. The genuinely dead pair is `aiPaused` / `isSuspended`, whose comment claiming
  they gate new stream calls is false.

## Positioning (go-to-market, unvalidated)

The engineering facts above are measured. The following is a claim about how this reads to a user
and has not been tested with one.

Port42 is a shell, and a shell does not contain the programs you run in it. The claim is that an app
which holds no provider credential, starts no model process, and routes every model call through an
agent the user signed in themselves is a different product from one with a chat box wired to an API
key. The differentiation is unvalidated: no user has said this matters to them, and the competing
read is that people want the box and do not care where the tokens come from.
