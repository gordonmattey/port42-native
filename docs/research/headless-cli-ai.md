# `ai.complete` as a headless CLI invocation

Spike, 2026-09-26. Measured against `nautilus` merged with `origin/research` in a worktree. Nothing
was built. Every CLI figure below is a command run on this machine today; every code claim carries a
file:line. Not an approved decision.

**Question (GM):** Port42 no longer prompts for a Claude subscription sign-in, and it should not. If a
port needs a model, implement `ai.complete` by invoking the installed CLI agent headlessly, so the CLI
authenticates under its own sign-in and Port42 holds no credential. Decision D9 already says Port42
reads no provider credential (`plan-shell-only.md:117`), and the engine section says a thin
`ai.complete` capability is the way back (`:84-86`).

## Recommendation

**Do not build `ai.complete`. The plan already shipped its replacement, and it is better.**

`plan-shell-only.md:78-80` says a port that wants a companion "writes to its terminal chat and
subscribes for the reply, so no replacement method is needed." That is not a deferral, it is built and
live. `chat.post` (`PortChat.swift:264`) wakes the companion, terminal or headless
(`PortChat.swift:111-144`), and every subscriber of the port receives a `chat` event carrying the
reply (`PortChat.swift:265`). A port already has a model. The reply arrives under the companion's own
sign-in, in a process Port42 did not have to start, with the exchange visible to the user in a chat
they can read, and with the port's request attributed to the port.

A headless `ai.complete` would buy one property that path lacks, a synchronous return value, and pay
for it with a 264 MB process per call, 2.3 to 5.4 seconds of latency, a token floor between 441 and
22,738 input tokens depending on flags, and a new permission whose honest wording is not "AI access".

**If a synchronous call is wanted anyway, the shape is `companion.ask(name, text, timeout)` over the
existing chat path, not a subprocess.** Post to the chat, wait for the matching reply, return it, time
out. No process spawn, no CLI detection, no second auth story, no new failure taxonomy, and the
companion's own permission grants apply to whatever it does. The subprocess version is a second
implementation of a thing the tree already has.

**If a subprocess version is built despite that, it must be gated `.terminal` or stronger, not `.ai`,
unless it is invoked with `--tools ""`.** That distinction is the load-bearing finding and §4 below is
the evidence.

## 1 · What is actually gone, and what remains

### Gone, verified absent from `Sources` and `Tests`

`find Sources Tests -name "*<X>*"` returns nothing for any of: `AgentAuth`, `LLMEngine`,
`GeminiEngine`, `BridgeServiceAI`, `ModelPicker`, `UsageView`, `LLMBackend`, `LLMStreamCollector`,
`AppState+PortAI`, `AgentRouterLLM`.

No provider credential is read. The Keychain surface that remains is Port42's own named-secret store
for `rest.call` (`Port42AuthStore.swift:4`), and it actively reaps the old provider accounts
(`Port42AuthStore.swift:18`: `manual-anthropic`, `oauth-cache-anthropic`, `manual-gemini`,
`manual-compatible-url`). `CLIHookProducerClaude.swift:56` states the rule in code: "NO CREDENTIAL IS
INJECTED (D9, nautilus Phase 1 step 3)."

No registry method declares `permission: .ai`. Twenty-seven declarations carry a permission
(`BridgeMethods.swift:415` through `:1083`) and none is `.ai`.

### Residue, with the correction the brief needs

The brief's premise is right about the comments and wrong about two of the mechanisms. `ai.cancel` and
`suspendAI()` are not dormant. They are the live cancel path for `port.subscribe`, under an `ai` name
that no longer describes them.

| # | Item | Evidence | What it actually is |
|---|---|---|---|
| R1 | `ai.cancel` handled at the port-JS adapter | `PortBridge.swift:461-474` | **Live, misnamed.** It cancels any tracked stream task by JS callId, and the only stream method left is `port.subscribe` (`BridgeMethods.swift:46`). `PortBridge.swift:704` wires `subscribe(...).cancel()` straight to it, and `:676-679` says so. A rename, not a deletion. |
| R2 | `suspendAI()` | `PortBridge.swift:285-290`, called at `PortWindowManager.swift:540`, `:737` and `PortBridge.swift:300` | **Live, misnamed.** Cancels every in-flight stream on park, background and close. The comments call it "stop billing the model" (`PortWindowManager.swift:737`) when it now stops a subscription. |
| R3 | `PortPermission.ai` | `PortPermission.swift:7`, `:29`, `:46-50` | **Truly dead.** Gates nothing. Its card text is "This will use your AI subscription tokens", which would be the wrong sentence for anything §4 recommends. |
| R4 | `aiPaused` / `isSuspended` | `PortBridge.swift:261`, `:267-278` | **Dead machinery, false comment.** `:281` claims "Gating new calls (the `isSuspended` guard in the registry stream methods) stops the loop." No registry method reads `isSuspended`. The only readers outside the property are `PortPresentationTests.swift:409-444`. `aiPaused` is `@Published` and no view reads it. |
| R5 | `ai_error` / `ai_timeout` error codes | `BridgeErrorCode.swift:97-98`, mapped at `:190`, `:192`, `:273` | Unreachable in production. Used once, by a test stub (`BridgeStreamTests.swift:32`). `:273` still maps the `"ai"` namespace prefix to `.aiError`. |
| R6 | `port42-mcp.js` advertises `ai.complete` and two deleted methods to MCP clients | `Sources/Port42Lib/Resources/port42-mcp.js:82` | **Agent-facing and wrong.** The string names `messages.send`, `messages.recent`, `companions.invoke` and `ai.complete`, all four deleted. This one misleads a real caller. |
| R7 | Registry docs describe `ai.complete` as a present member | `BridgeRegistry.swift:174-178`, `:189-190`, `:212-214`; `BridgeMethods.swift:32-37`; `AppState.swift:329` | Comments only. `BridgeMethods.swift:33` points at `BridgeServiceAI.swift`, a deleted file. |
| R8 | `PermissionCoordinator` coalescing example is `ai.complete` | `PermissionCoordinator.swift:32` | Comment only. |
| R9 | `ToolExecutor` streaming rationale is written around `ai.complete` | `ToolExecutor.swift:192`, `:207` | Comment only, and the reasoning is still correct for any future finite stream method. |
| R10 | `GhosttyTerminalView` env comment still lists "CLI OAuth token" | `GhosttyTerminalView.swift:480` | Comment only, and contradicts `CLIHookProducerClaude.swift:56`. |
| R11 | Settings has a tab literally named "AI" | `SignOutSheet.swift:17` | Unverified what it renders now. Needs a look at the instance, not the tree. |

## 2 · What the CLIs support, measured

Both are installed: `claude` 2.1.283 at `~/.local/bin/claude`, `codex-cli` 0.156.1 at
`~/.nvm/versions/node/v22.18.0/bin/codex`.

| | Claude Code | Codex |
|---|---|---|
| Headless invocation | `claude -p <prompt>` (`--help:174`) | `codex exec <prompt>` |
| Machine-readable output | `--output-format json` or `stream-json` (`--help:149-153`) | `--json`, JSONL events |
| Token-level streaming | **Yes.** `stream-json` + `--include-partial-messages` (`--help:123-125`) emits `content_block_delta` with `delta.text` | **No.** Measured: `thread.started`, `turn.started`, `item.completed` (whole text at once), `turn.completed`. No delta event type exists in the `--json` stream |
| System prompt | `--system-prompt` (replace, `--help:235`) or `--append-system-prompt` | **No flag.** Instructions can only ride the prompt, `AGENTS.md` in the cwd, or `-c` config overrides |
| Tool suppression | `--tools ""` disables all tools (`--help:258-262`); `--restricted` drops the code-running tools and WebFetch (`--help:198-208`) | None. `--sandbox read-only` limits what tools may do, it does not remove them |
| Prompt via stdin | `--input-format stream-json` (`--help:126-129`) | Default. Reads stdin even when a prompt argument is given; measured, it printed "Reading additional input from stdin..." with `</dev/null` |
| Needs a trusted directory | No. The workspace-trust dialog is skipped under `-p` (`--help:175-180`) | **Yes.** Without `--skip-git-repo-check` it refused with `Not inside a trusted directory`, exit 1, **as plain text, not JSON** |

### Measured runs

Claude, lean: `claude -p "Reply with exactly: OK" --output-format json --model haiku --tools ""
--strict-mcp-config --setting-sources "" --system-prompt "..."`

```
wall 2.32s  ·  duration_ms 894  ·  ttft_ms 865
input_tokens 441  ·  cache_creation 0  ·  output_tokens 40  ·  total_cost_usd 0.000641
```

Claude, defaults (no `--tools`, no `--setting-sources`), same prompt and model:

```
wall 4.16s  ·  duration_ms 1634  ·  ttft_ms 1611
input_tokens 10  ·  cache_creation_input_tokens 22738  ·  output_tokens 76  ·  total_cost_usd 0.028813
```

**The default invocation costs 45 times the lean one for the same answer.** The 22,738 tokens are the
agent harness: the default system prompt, the tool schemas and the discovered settings. `--tools ""
--setting-sources "" --strict-mcp-config` removes them.

Codex: `codex exec --json --skip-git-repo-check --ephemeral --sandbox read-only "Reply with exactly:
OK"`

```
wall 7.67s  ·  input_tokens 15177  ·  cached_input_tokens 11008  ·  output_tokens 5
```

Codex's floor is not reducible by any flag measured. It is roughly 15k input tokens and about 7.7
seconds for a one-word answer.

Peak resident set of one lean `claude -p`: **264 MB** (`/usr/bin/time -l`: 276,889,600 bytes maximum
resident, 155,897,024 peak footprint). Three concurrent lean calls all returned correctly.

### Failure presentation

Claude exits 1 and still writes a complete result JSON to stdout, with `is_error: true` and a
human-readable `result` string. Measured:

| Condition | Exit | `result` |
|---|---|---|
| No auth available (`--bare`, no `ANTHROPIC_API_KEY`) | 1 | `Not logged in · Please run /login`, `terminal_reason: api_error` |
| Unknown model | 1 | `There's an issue with the selected model (no-such-model-xyz). It may not exist or you may not have access to it.`, `api_error_status: 404`; stderr also carries `[claude-code:unrecognized_model] {...}` |

Codex is less uniform. An unknown model produced JSONL `{"type":"error",...}` plus
`{"type":"turn.failed",...}` wrapping a nested JSON string, exit 1. The untrusted-directory refusal
produced plain text, exit 1. **A codex consumer must handle non-JSON output on the error path.**

### The credential finding

The probe above first ran with `ANTHROPIC_API_KEY` set in the environment, and `claude` said so:
"claude.ai connectors are disabled because ANTHROPIC_API_KEY or another auth source is set and takes
precedence over your claude.ai login." Auth follows the inherited environment.

This matters for D9. "The CLI authenticates under its own sign-in" holds only for the environment
Port42 hands the child. `AgentProcess.swift:54-60` and `CommandAgent.swift:117-123` both pass
`ProcessInfo.processInfo.environment` overlaid with config, so whatever Port42 inherited is inherited
again. The terminal path is worse on this axis, because it runs `/bin/zsh -lc`
(`CommandAgent.swift:100-108`) and therefore sources the user's profile. `shim/main.go:63-81`
(`sanitizeEnv`) already scrubs a related class of leaked variables, so the pattern for handling this
exists.

**Unknown:** whether a Finder-launched Port42 inherits `ANTHROPIC_API_KEY` at all. A launchd-context
app does not read a shell profile, so probably not, but this was measured in a shell-spawned context
only. Settled by reading `ProcessInfo.processInfo.environment` from a Finder-launched dev instance.

## 3 · Which machinery is reusable

### Reusable as-is

| Piece | Location |
|---|---|
| CLI binary discovery: hardcoded candidates, nvm scan, then `/usr/bin/which` | `ClaudeCodeSetup.swift:162-216` |
| Long prompt to a 0600 temp file | `CLIHookProducer.swift:161-169` (`writeBrief`) |
| One-shot `Process` with timeout and concurrent pipe drain | `ShellExec.swift:16-73`. The template. Both pipes drained on a concurrent queue with a `DispatchGroup` (`:44-49`) because a 64 KB pipe deadlocks (`:37-42`); `asyncAfter` deadline terminates (`:51-55`). Takes no env parameter, so it would need one |
| Request/response with a deadline and a single-resume guard | `AgentProcess.swift:90-146`. `DispatchWorkItem` timeout at `:120-124`, `NSLock` `resumeOnce` at `:109-117` |
| NDJSON line framing, including the `availableData` trap | `CommandAgent.swift:181-195` |
| Content-block text extraction (string or `[{type,text}]`) | `shim/main.go:438-460` (`extractText`) |
| Env scrub list for nested-child leakage | `shim/main.go:63-81` |
| Spawned-session identity and token file | `TerminalHooksService.swift:224-272`. Writes the token to a 0600 file and passes the path, never the token, because of `ps -E` (`:240-243`) |
| Codex trust and network config generation | `CLIHookProducerCodex.swift:186`, `:190-193`, `:226-232` |

### Terminal-port specific, does not apply

- The whole hook reply channel. `TerminalHooksService.swift:73-137` is an AF_UNIX socket the shim
  dials per event; the events are `Stop`, `SessionStart`, `Notification`, `SessionEnd`, which only
  exist for a long-lived session. `CLIHookProducerCodex.swift:144-146` states it outright: **"Codex
  hooks fire in the INTERACTIVE TUI and not under `codex exec`."** A headless run prints its answer on
  stdout and needs none of it.
- The PATH-shadowing shim. `CLIHookProducerClaude.swift:35-42` symlinks `claude` into a temp dir and
  prefixes PATH; `:48-53` defines a shell function. A direct exec calls the real binary and passes
  `--settings` and `--append-system-prompt` itself, which is exactly what `shim/main.go:150-198` does.
- `ZDOTDIR` and the written `.zshrc` / `.zshenv` / `.zprofile` / `.zlogin`
  (`TerminalHooksService.swift:297-301`, `:348-375`).
- `startupCommand` and `writeBrief`'s reason for existing: a 3,000-character command line typed into a
  PTY broke (`CLIHookProducer.swift:143-157`). A headless argv has no such limit.
- The Ghostty PTY spawn, `GhosttyTerminalView.swift:528-573`, and the fact that Ghostty's `command`
  cannot carry arguments (`:554-557`, `:679-692`), which is why the real command is typed into the
  shell.

### Must be written fresh

- `--output-format stream-json` argv construction and its event decoder. **Nothing in this tree runs
  `claude -p` or `codex exec` today.** `shim/main_test.go:430`, `:435` pass `-p` through as *user*
  args, which is the shim declining to pin a session, not Port42 invoking print mode.
- A concurrency limit. There is none anywhere: no semaphore, no worker pool.
  `AppState.activeCommandHandlers` (`AppState.swift:236`) is an unbounded dictionary, and
  `AppState.swift:1088-1093` staggers companion launches with an index delay plus jitter rather than
  bounding them.
- A timeout on the codex path, since `CommandAgent.swift` has none and blocks on `availableData` until
  the child closes stdout.

## 4 · How it is gated. The load-bearing part

`security-bridge-authorization.md:18` measured 41 of 69 registry methods ungated, and `:19-20` that
`BridgeDispatcher` hardcodes the object as `.machine` at `BridgeDispatcher.swift:112` and `:117`. An
ungated `ai.complete` would be defect number 42.

**The correct permission depends entirely on the argv, and that is the finding.**

`terminal.exec` is gated `.terminal` and capped at 120 seconds
(`BridgeMethods.swift:415`, `:424-431`). It runs one command the caller named, in `/bin/zsh`, and
returns its output. A `claude -p` invocation with default tools runs an **autonomous agent** that may
Bash, Edit, Write, WebFetch and spawn subagents, in a loop, choosing its own commands. That is
strictly more powerful than the thing `.terminal` gates, so `.terminal` is the floor and arguably
understates it.

The dormant `.ai` case would be dishonest for that. Its card reads "This port wants to use AI
capabilities. This will use your AI subscription tokens. Allow?" (`PortPermission.swift:46-50`). That
sentence describes token spend and says nothing about arbitrary code execution and network egress
under the user's own credentials.

Three defensible designs, in order of how much they ask for:

**(a) Text completion only. `--tools "" --setting-sources "" --strict-mcp-config` with Port42's own
`--system-prompt`.** Measured at 441 input tokens with no tool loop. Here `.ai` is the honest gate,
because that is all the call can do. The card becomes something like: *"<Port name> wants to ask
Claude Code a question. Claude Code will answer as text and will not run commands or read files. It
uses your Claude subscription."* This is the only variant where a new permission case is justified,
and it is also the variant a port most plausibly wants.

Codex has no equivalent. There is no way to disable its tools, so **option (a) is Claude-only**. That
asymmetry is a reason on its own not to promise one method across both CLIs.

**(b) Full agent. Default tools.** This must gate `.terminal`, and the card must say the model may run
commands and edit files. At that point a port should call `terminal.exec` and be visible about it, or
post in the chat and let the user watch a real companion do the work.

**(c) Do not add a permission. Route through the chat.** `chat.post` is ungated
(`PortChat.swift:264`), which is correct: it is posting a message, and the companion's own grants
govern whatever the companion then does. The consent boundary is already in the right place. This is
the plan's model.

Two further requirements whatever is chosen, both from the security note:

1. `writesTarget` and the object. A stream method already declares `writesTarget`
   (`BridgeRegistry.swift:201-207`) and the note's fix list item 2 is to turn the dispatcher's two
   hardcoded `.machine` arguments into a parameter. A new capability should not land before that, or it
   inherits port 0 grant semantics by construction.
2. The pregrant. `PortBridge.init` unions in the creating principal's machine grants
   (`PortBridge.swift:67-75`, passed as `pregrant` at `:414`), so a grant given once to an agent
   reaches every port that agent ever writes, including later ones
   (`security-bridge-authorization.md:48-53`). A `.terminal` grant given for a terminal would silently
   authorize an `ai.complete` in an unrelated port. **This alone is a reason to defer any new
   `.terminal`-class capability until fix 3 in that note lands.**

## 5 · The streaming contract

The old `ai.complete` was a `BridgeStreamMethod`. That contract is intact and one method still uses it
(`port.subscribe`, `BridgeMethods.swift:46`). A new finite stream method would fit without changing
anything: `endless: false` means an HTTP or gateway caller gets collect-into-final
(`BridgeRegistry.swift:210-215`, `ToolExecutor.swift:198-212`), port JS gets tokens via
`_tokenCallback` (`PortBridge.swift:433-457`), and a thrown `BridgeError` becomes a real JS reject
rather than a resolved `{error}` (`:446-447`).

**Claude can honor the contract. Codex cannot.** Claude's `stream-json` with
`--include-partial-messages` yields `content_block_delta` events carrying `delta.text`, measured, which
maps directly to `yield`. Codex's `--json` delivers the entire answer in one `item.completed`, so a
codex-backed `ai.complete` would stream one token, the whole reply. Honoring one contract with two
backends of different granularity means the port's author cannot tell from the API whether streaming
will happen. Better to declare it non-streaming than to stream on one machine and not another.

**`ai.cancel` already means the right thing.** `PortBridge.swift:464-474` cancels the tracked Task;
`runBridgeStream`'s cancel handler runs; `CancellationError` becomes a `"cancelled"` reject at
`PortBridge.swift:447-449`. For a subprocess the method body's cancel handler would `terminate()` the
child. Two gaps to close deliberately:

- `Process.terminate()` sends SIGTERM only. `AgentProcess.swift:85-88` does exactly that and does not
  escalate. `AutomationBridge.swift:89-96` is the pattern that does: terminate, then `interrupt()`
  after 2 seconds. A model mid-inference does not always die on SIGTERM.
- Cancellation stops the local read, not the billed inference. The tokens are already committed.

**A port closing mid-flight is already handled, and it is where R2 pays off.**
`PortBridge.releaseAcquisitions()` (`:292-302`) calls `suspendAI()`, which cancels every tracked
stream task, and `PortWindowManager.swift:540` and `:737` call it on park and background. A subprocess
launched from a stream method body inherits that teardown for free. Without a cancel handler that
kills the child, though, park would orphan a 264 MB process. `GatewayProcess.swift:104-110` shows the
orphan-prevention idea already in the tree: the child watches its parent's stdin for EOF.

## 6 · Cost and failure

**Latency.** 2.3 s lean, 4.2 s default, 5.4 s in the RSS run, for Claude. 7.7 s for Codex. Against the
API's own 0.9 s `duration_ms`, roughly 1.4 to 3.5 s of that is process start and teardown. A port
calling this in a render path or a loop will feel it.

**Memory.** 264 MB peak resident per call, measured. Ten concurrent ports asking at once is about
2.6 GB of Node processes on top of Port42 and its webviews. There is no limiter to prevent it. A
semaphore is not optional, it is the feature.

**Tokens.** The default invocation burns 22,738 input tokens per call against the user's subscription.
Ten ports polling once a minute is 13.6 million input tokens an hour. The lean invocation is 441. A
port author has no way to see either number, and the app no longer has a usage view (`UsageView` is
deleted), so the spend is invisible. **If this is built, the lean flags are not an optimization, they
are the only responsible default.**

**No CLI installed.** `ClaudeCodeSetup.findBinary` returns nil and the call must refuse before
spawning. The `/usr/bin/which` fallback at `ClaudeCodeSetup.swift:196-213` spawns a process with no
timeout, which is a small hazard on a hot path and argues for caching the resolved path.

**Not signed in.** Claude answers `Not logged in · Please run /login` with exit 1 and a complete result
JSON, which is a genuinely good error to forward. Codex's equivalent was not measured, and its
untrusted-directory refusal arrived as plain text, so its error path needs a raw-text fallback.

**Naming the real problem.** The failure taxonomy a caller needs is at least: no CLI installed; CLI
installed but not signed in; model unavailable; timed out; cancelled; the CLI refused (trust, sandbox,
permission mode); the CLI crashed. `BridgeErrorCode` has `ai_error` and `ai_timeout`
(`BridgeErrorCode.swift:97-98`), which is two of seven. The security note already flags that a denial
and a failure are indistinguishable today (`security-bridge-authorization.md:68-72`); adding a
capability with a five-way-collapsed error code repeats it. Claude's `--output-format json` result
carries `is_error`, `terminal_reason`, `api_error_status` and a human `result` string, all measured, so
the information is available. Forwarding it is a choice, not a limitation.

## 7 · What should not be built

- **`ai.complete` itself.** §"Recommendation".
- **A cross-CLI `ai.complete`.** Codex has no system prompt flag, no tool suppression, no token
  deltas, a non-reducible 15k token floor, a 7.7 s floor, and a non-JSON error path. One method over
  both backends would have to promise the intersection, which is "send text, wait 8 seconds, get text,
  and it may have edited your files." Claude-only, stated as Claude-only, is the honest version.
- **A `.ai` permission for anything that carries tools.** §4.
- **Resurrecting `PortPermission.ai`'s existing card text.** It describes token spend for something
  that would execute code.
- **Any new `.terminal`-class capability before the pregrant is cut.** `PortBridge.swift:67-75` means a
  grant for one thing authorizes it everywhere, including in ports created later.
- **A synchronous, blocking, per-call model API as a port primitive at all.** The design that fits the
  product is the one the plan already chose: a port asks a companion, in a chat the user can see, and
  gets an answer as an event. A port is a surface in a conversation, not a program with an LLM library
  linked in.

## 8 · Residue cleanup, proposed as its own small unit

Independent of any `ai.complete` decision, and safe to land alone. Two of these are user-facing.

| # | Change | Files |
|---|---|---|
| 1 | Fix the MCP capability string. Drop `messages.send`, `messages.recent`, `companions.invoke`, `ai.complete`. **Agent-facing and currently wrong.** | `port42-mcp.js:82` |
| 2 | Rename `ai.cancel` to `stream.cancel`, keeping `ai.cancel` as a surface alias so live ports do not break. The alias table already exists (`AppState.swift:334-338`) | `PortBridge.swift:461-474`, `:676-679`, `:704` |
| 3 | Rename `suspendAI()` to `cancelStreams()` and correct the comments that call it billing | `PortBridge.swift:281-290`, `:292-302`, `PortWindowManager.swift:540`, `:737` |
| 4 | Delete `aiPaused` and `isSuspended`, or wire `isSuspended` into the stream methods so its comment becomes true. Deleting also removes five tests | `PortBridge.swift:261`, `:267-278`, `PortPresentationTests.swift:385-444` |
| 5 | Delete `PortPermission.ai` and its icon and card arms. Nothing gates on it | `PortPermission.swift:7`, `:29`, `:46-50` |
| 6 | Delete `ai_error` and `ai_timeout` and the `"ai"` prefix mapping, or keep them and say in a comment that they are reserved | `BridgeErrorCode.swift:97-98`, `:190`, `:192`, `:273`; `BridgeStreamTests.swift:32` |
| 7 | Rewrite the streaming-registry comments to name `port.subscribe`, and remove the reference to the deleted `BridgeServiceAI.swift` | `BridgeRegistry.swift:174-178`, `:189-190`, `:212-214`; `BridgeMethods.swift:32-37`; `AppState.swift:329` |
| 8 | Fix the coalescing example and the tool-executor rationale | `PermissionCoordinator.swift:32`; `ToolExecutor.swift:192`, `:207` |
| 9 | Remove "CLI OAuth token" from the env comment. It contradicts `CLIHookProducerClaude.swift:56` | `GhosttyTerminalView.swift:480` |
| 10 | Check what the Settings tab named "AI" renders now, and rename or remove it. **User-facing** | `SignOutSheet.swift:17` |

Items 1 and 10 are the two a user or an agent can actually observe. The rest are comment and
dead-code hygiene and would be one commit.

## 9 · Unknowns, each with the test that settles it

| Claim | What would settle it |
|---|---|
| Whether `codex exec` can emit token deltas by any route | Read the `codex app-server` / `exec-server` protocol. `codex exec --help` lists neither an `--experimental-json` nor a delta option, so the answer for `exec` is no; the app-server was not examined |
| Whether a Finder-launched Port42 inherits `ANTHROPIC_API_KEY` | Log `ProcessInfo.processInfo.environment` from a Finder-launched dev instance |
| Whether Anthropic's and OpenAI's terms permit an app orchestrating subscription-authenticated CLI calls on a user's behalf | Read the current consumer terms. This is the same question D9 was written to avoid (`plan-shell-only.md:90-92`), and a headless `ai.complete` walks back toward it: Port42 would not hold the credential but it would be the thing deciding when to spend it |
| Whether `claude -p` under `--tools ""` still reads `CLAUDE.md` | Measured with `--setting-sources ""` only. Add `--add-dir` isolation and diff `input_tokens` |
| What a signed-out `codex exec` prints and exits | Log out of codex on a spare account and run it. Not attempted, because it would disturb the machine's sign-in |
| Whether `Process.terminate()` reliably kills a mid-inference `claude -p` | Start one, SIGTERM it, check for an orphan |
| What `SignOutSheet`'s "AI" tab renders | Open Settings on a dev instance |

## Sources

Every CLI figure is from `claude --help`, `codex --help`, `codex exec --help`, or a run on this
machine on 2026-09-26 with `claude` 2.1.283 and `codex-cli` 0.156.1. Code claims are file:line in this
worktree. `security-bridge-authorization.md` and `plan-shell-only.md` are cited by line.
