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

## Done this arc (committed + pushed, 7573fab..b2d76fd)

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

**Service architecture defined; `ai` migrated as the reference (committed + pushed).** The bridge surface
resolves into platform / device / **service** tenants; the service region is an agent substrate with
three faculties (agent runtime, epistemic memory, knowledge). See `bridge-architecture-and-mcp.md` §6
and the bridge-surface artifact.
- **ae74b27** docs: the service / plug-in seam (§6), taxonomy + triad, MCP as one instance, `ai` named
  the reference migration.
- **6536c3b** `ai` migrated to its own module (`BridgeServiceAI.swift`): `ai.complete` (stream) +
  `ai.models`/`ai.status` (moved off the old `PortBridge` switch into the registry), `ai.cancel` left a
  documented transport shim. 58 methods B1/B2-green; `BridgeAIServiceTests` green; live in Port42Dev
  (`ai.models`/`ai.status` served via the gateway, dotted + snake). No `BridgeService` protocol yet.
- **e2cdd27** todo: AppleScript / Automation test-env enablement (the 7th env-only test failure).

**The manifest / plug-in architecture, proven across three services (committed + pushed).** A service is
declared as DATA (`ServiceManifest`: methods with canonical + surface names, schema, permission,
paramNames) plus a body; the name-map derives from per-method surface/canonical (never hand-written).
Same manifest for external plugins (ship data + an endpoint) and in-process services (bind closures by
canonical). The `BridgeService` question is answered: `ServiceManifest` **is** the descriptor.
- **bc81ab4** **Spike D** — manifest-driven service, proven external-first with a hypothetical `weather`
  plugin (`ServiceManifest.swift` + `registerManifest`): pure data + one generic backend → dispatchable,
  gated, schema-generating methods, name-map derived, zero method-specific code.
- **cbd0ba4** **Keeper** migrated (`BridgeServiceKeeper.swift`): the in-process case holds the same
  shape. Declares plural surfaces (`creases.*`/`engravings.*`); the 8-entry name-map derives and wires
  via `AppState.bridgeAliases` + `resolveBridgeAlias` (every adapter). Fixed a live bug (the literal
  dispatched `creases.read`/`engravings.*` to names that resolved nowhere) — verified live: full
  write/read/forget round-trip through the DSL surface.
- **0a98974** **storage** migrated (`BridgeServiceStorage.swift`): the simplest tenant, empty name-map.
- Spike B generalized: manifest services leave the source-scan (now 42 methods) and are checked by a
  runtime probe (`appManifestServices()`). Spike A parity + memory/D4/storage suites green (168 tests).

**Spikes C + D done, big-bang steps 1 + 2 done (committed + pushed, ..b2d76fd).**
- **8d1e001 Spike C** — JavaScriptCore harness proves the generic Proxy dispatches identically to the
  literal for platform+device, routes service surfaces via the name-map, carves out machinery/events/
  `port.resize`/streaming. (`ProxyDispatchSpikeTests`.)
- **bc81ab4 Spike D** — manifest-driven service proven external-first (`ServiceManifest` + `registerManifest`).
- **49e3160 + da033e0 Step 1** — the LLM tool list is GENERATED from the registry
  (`AppState.generatedToolDefinitions`); the 52 hand-written schemas deleted (700→108 lines), frozen as
  `Tests/Fixtures/tool-definitions-golden.json` which guards generation. `toolExposed` flag marks the 6
  non-tool registry methods. Hybrid: browser.\*/rest.call stay hand-written until extracted.
- **b2d76fd Step 2** — the ~240-line `window.port42` literal replaced by a generic Proxy + explicit
  carve-outs (machinery, event listeners, `ai.complete`/`companions.invoke` streaming shims,
  `port.resize`). **Clean break** (GM): per-method result unwrapping is gone; all surfaces return the
  structured `BridgeValue` (ports read `.value`/`.html`/`.ok`/`.result`/`.output`). Also fixed
  `handleMethod` to resolve aliases via `state.resolveBridgeAlias` (was static `ToolNaming.resolveAlias`,
  files-only), so service name-maps (`creases.* -> crease.*`) now resolve on the port-JS surface too.

## Next

**FIRST: confirm `creases.read` live on a stable app.** Step 2's core is live-proven (a port's own
script round-trips `storage` with clean-break returns `{ok}`/`{value}`, `user.get`, `ai.complete`
carve-out). The one thing NOT re-verified live is the port-JS `creases.read` fix (returns `[]` before,
should return the "No creases yet" string now) — blocked only by the recurring "gateway up, no host"
startup race (`summer2026-todo.md`), which needs a clean boot. One command: create a web port whose
onload script does `port42.creases.read()` and read its DOM (NOT `port.exec` with nested bridge calls —
that reentrancy-deadlocks the main actor). Unit-covered green regardless; this is belt-and-suspenders.

**The tail** (`plan-api-unification.md` Phase 2b) — extract the still-live-only families still on the two
old switches: browser.\*, `rest.call`, audio/screen/camera streams + `audio.capture`, the self-referential
port methods (`info`/`close`/`setTitle`/`setCapabilities`/`resize`), `messages.sendAsCreator`,
`space.switchTo`. Each into the registry (or a service module). THEN the close-out: delete the two old
switches (`PortBridge.handleMethod` tail, `ToolExecutor.executeImpl`), and flip
`ToolNaming.canonicalMethods` + `llms.txt` to generated (both need the full name inventory, so they ride
with the tail). Then the four parallel lists and both switches are gone: unification complete.

## Uncommitted, not mine (left in the tree)
`docs/membrane/membrane-architecture.md` edit + `docs/membrane/plays-with-others.md` (a packs/plugs/
canvas edit from an earlier session), plus `VERSION`, `.factory/`, `docs/handoff-2026-07-17.md` (the
older, superseded handoff), `test-engravings-preamble.sh`. Review + commit or drop.
