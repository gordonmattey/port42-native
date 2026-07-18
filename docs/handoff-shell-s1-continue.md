# Shell-s1 — status & how to keep track

Branch **shell-s1**, in `/Users/gordon/Dropbox/Work/Hacking/workspace/portal-42/port42-native`.
This is the living status doc for the API/tool-use unification arc. Start here, then follow the links.
Everything below is committed + pushed unless noted.

## How to keep track (which doc owns what)

Four active docs, one job each. Update the one whose concern changed; keep this file as the index.

| Doc | Owns | Update when |
|---|---|---|
| **this file** | current status + next step | end of each work session / milestone |
| **`plan-api-unification.md`** | the build plan: invariant, tail matrix (items 1-7/9/10), no-compat policy, sequencing | a tail item lands, or the sequence changes |
| **`bridge-architecture-and-mcp.md`** | architecture reference: API-vs-transport, adapter-honesty gap, big-bang self-describing (§5), MCP (§6), sequencing (§7) | an architecture decision changes |
| **`summer2026-todo.md`** | backlog + bugs (ports.list, the 6 pre-existing test fails, the cancel-residual hardening) | a bug is found or fixed |

Reference-only (done, do not update): `rca-aicomplete-cancel-hang.md`, `plan-phase3-principal.md`.
Separate track (not this arc): `docs/membrane/*` — WIRE / port42:// / libp2p / cross-instance.

## Rules (hard)
- **Test in Port42Dev ONLY** (`com.port42.dev`, gateway **:4243**). Never prod (`:4242`) without an
  explicit say-so. Live-check via `curl -s http://127.0.0.1:4243/call -d '{"method":...,"args":...}'`.
- **We do NOT protect backward compatibility** (pre-WIRE). Compat shims are a bad smell — remove them,
  do not add them. Policy is in `plan-api-unification.md` § "Policy".
- **Don't commit unless asked**; when asked, commit + push to `shell-s1`, incrementally, every green
  step. **Commit messages: heredoc, no backticks.** **No em dashes** in prose. Fix root causes; RCA
  before fixing anything non-trivial.
- Build with `./build.sh` (dev). Relaunch = `open .build/Port42Dev.app`. The **Keychain prompt** and a
  per-caller **`.ai` permission prompt** at first model call are human-only — ask GM.

## Done this arc (committed + pushed, 7573fab..e1d655d)

**Item 8 (streaming) is complete end to end.** `ai.complete` and `companions.invoke` both flow through
one `AppState.runLLMStream`, reachable identically from all three surfaces (port JS, gateway, in-app
tool-use) via `runBridgeStream`. Self-describing (inline `description`+`inputSchema`, schema generator).
Verified unit + live in Port42Dev.

- **68ae1f5** AI backend/model/token resolution moved off PortBridge onto AppState.
- **bb2b915** registered `ai.complete` in the streaming registry (self-describing spike + generator).
- **1f696c6** port-JS adapter streams via `runBridgeStream`.
- **9727978** **RCA cancel fix** (`rca-aicomplete-cancel-hang.md`): settlement is core-owned, not
  delegated to the engine (which swallows `NSURLErrorCancelled`). Exposed `.callId`/`.cancel()`.
- **1635d93** **killed the compat shims**: real JS reject (no `resolve({error})` / `if(r.error) throw`),
  structured `{text}` return (no bare-string unwrap). No-compat policy written into the plan.
- **1a4e20d** C4: gateway + tool-use adapters stream (collect-into-final).
- **05477cc** folded `companions.invoke` into the registry; deleted `PortAIHandler`/`activeStreams`;
  fixed a `suspendAI` regression (park now cancels `streamTasks`, not the dead `activeStreams`).

**Spikes A + B done (self-describing registry de-risked; sequence decided: pull the big-bang forward).**
- **e824029** **Spike A — schema-generation parity.** `BridgeMethod` now carries inline
  `description`+`inputSchema`; `anthropicToolSchema` generates the Anthropic tool schema from either
  method type. All 52 tool-exposed methods' schemas relocated onto the registry;
  `BridgeSchemaParityTests` asserts generated == `ToolDefinitions` byte-for-byte (sorted-keys) for all
  52, plus a coverage gate (every tool checked or on the documented hybrid-only list: browser.\*,
  rest.call) and a rot guard. **Green on first run** = generation faithful, `ToolNaming` override table
  proven complete, so the big-bang is now a mechanical flip-and-delete, not a risky backfill.
- **dbe2a37** **clipboard.write drift fixed** (found while doing A). Tool schema said `text`; the
  method's param is `data` everywhere else (JS binding, `paramNames`, impl, docs). Under the
  registry-first adapter a companion emitted `{text}`, the impl read `data`, and the call threw
  `missingArg("data")` — companion clipboard writes were broken. Aligned the schema on `data`.
- **e1d655d** **Spike B — parameter consistency sweep.** Source-scan of `BridgeMethods.swift`
  (segmented by register function so bags + shared-helper reads are scoped) proving, for all 56
  registry methods, that every required schema prop (B1) and every non-bag `paramName` (B2) is a key
  the body reads. Green, zero bag-exemptions. Acid-tested: reintroducing the clipboard drift makes B1
  report exactly that method. This is the class clipboard belonged to; no others exist.

## Next

**Spike C — Proxy-vs-literal dispatch (the last de-risk before the big-bang).** Prove a generic
`window.port42` Proxy dispatches `port42.a.b(...args)` → `call('a.b', args)` identically to the current
hand-written object literal (`PortBridge.swift:1521`), and enumerate the carve-outs the Proxy cannot be
generic over. From reading the literal, the non-generic behaviors are: result unwrapping
(`.then(r => r.ok)` / `r.value` / `r.html` / `r.output` / `r.result`) — **deliberately dropped** under
the no-compat policy (the Proxy returns the structured `BridgeValue`); arg defaulting (`opts || {}`,
`n || 20`) — moves into the body, which already defaults; and the streaming/callback methods
(`ai.complete`, `ai.cancel`) — the **one genuine carve-out** the plain `call()` Proxy can't cover.
Approach: a JavaScriptCore (`JSContext`) harness that stubs `call`, evaluates the extracted literal and
a candidate Proxy, invokes each method with sample args, and asserts the recorded `(method, argsArray)`
match for every non-streaming method. Green + the carve-out list = safe to replace the literal.

**Then the big-bang** (`bridge-architecture-and-mcp.md` §5), now a mechanical flip-and-delete guarded by
the three spikes: flip `ToolDefinitions` / `ToolNaming.canonicalMethods` / `llms.txt` to generated
(hybrid: keep hand-written only for browser.\*/rest.call until extracted), replace the `window.port42`
literal with the Proxy + the streaming carve-out, delete the parallel lists.

**The tail** (`plan-api-unification.md` Phase 2b, items 1-7/9/10) — the still-live-only methods, each
proven by `BridgeParityHarness`, then **delete the two old switches** (close-out).

## Uncommitted, not mine (left in the tree)
`docs/membrane/membrane-architecture.md` edit + `docs/membrane/plays-with-others.md` (a packs/plugs/
canvas edit from an earlier session), plus `VERSION`, `.factory/`, `docs/handoff-2026-07-17.md` (the
older, superseded handoff), `test-engravings-preamble.sh`. Review + commit or drop.
