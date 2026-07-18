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

## Done this arc (committed + pushed, 7573fab..05477cc)

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

## Next

**Spike A — schema-generation parity (do this first).** Build the generator + a test asserting
`generated schema == hand-written ToolDefinitions` for all 54 registered methods. Additive, zero
behavior change. Green = generation proven, safe to flip `ToolDefinitions` to hybrid-generated. Any
mismatch = we learn exactly which methods before touching production. This de-risks the big-bang and
decides the sequence question. See `bridge-architecture-and-mcp.md` §5 and `plan-api-unification.md`.

Then, order TBD by Spike A's result:
- **The tail** — `plan-api-unification.md` Phase 2b matrix, items 1-7/9/10, each proven by
  `BridgeParityHarness` (registry body == old path), then **delete the two old switches** (close-out).
- **The big-bang** — self-describing registry deletes the four parallel lists (`ToolDefinitions`,
  `ToolNaming.canonicalMethods`, `llms.txt`, the `window.port42` literal → generic Proxy). Full
  deletion needs every method in the registry, so pulling it forward means **hybrid mode** first.
  Spikes B (paramNames↔schema consistency) and C (Proxy-vs-literal dispatch) de-risk the Proxy.

## Uncommitted, not mine (left in the tree)
`docs/membrane/membrane-architecture.md` edit + `docs/membrane/plays-with-others.md` (a packs/plugs/
canvas edit from an earlier session), plus `VERSION`, `.factory/`, `docs/handoff-2026-07-17.md` (the
older, superseded handoff), `test-engravings-preamble.sh`. Review + commit or drop.
