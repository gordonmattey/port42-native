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

## Done 2026-07-19: creases.read live-verified + the boot-wedge RCA that was blocking it

The "gateway up, no host" startup race is RESOLVED (full RCA in `summer2026-todo.md`). Primary
cause: the port-JS resolve path serialized bare-string results without `.fragmentsAllowed`;
Foundation raised an ObjC NSException `try?` cannot catch, which permanently corrupted the
main-queue drain (app alive, every queued action dead). The step-2 verification port `proxycheck`
persisted in the dev workspace and re-triggered `creases.read` on every boot, so the dev app had
been unbootable since step 2. Fixed in `PortBridge` + swept the sibling fragment-capable sites
(PortBridge push/pushEvent/storage-old-path, SyncService RPC response, ToolExecutor push +
jsonString). Secondary cause (identified, unfixed): `killProcessOnPort` uses `/usr/bin/lsof`, which
does not exist (macOS has `/usr/sbin/lsof`), so stale-gateway reclaim is dead code.

**`creases.read` is now live-verified on the port surface**: the restored port's DOM contains
"No creases yet. Creases form when a prediction breaks." — the alias fix works end to end. The
step-2 live checklist is complete.

## Done 2026-07-19 (second half): tail items 1, 2, 4, 5, 9 — the hybrid tool list is EMPTY

Commits ded1301..8519a3a, all pushed. Each item followed the matrix discipline: gate test written
and recorded failing, then implementation, then green (suite names below).

- **ded1301** the boot-wedge root fix + fragment-serialization sweep (7 sites; see the RCA above).
- **4904165** gateway lifecycle pair, both live-verified fail-then-pass: quit-time reap made
  synchronous (the Task hop never ran, orphaning the gateway on every Cmd+Q) and
  `killProcessOnPort` pointed at the real `/usr/sbin/lsof` (reclaim was dead code).
- **98bebd9** the five stale step-1 suites repointed at `generatedToolList()` (a new shared test
  helper); 80 tests green.
- **d9f606f** docs accuracy pass (README, CLAUDE.md, llms.txt contradiction fixes,
  ports-context.txt clean-break shapes, bridge-architecture status). llms.txt inventory left for
  the generated flip.
- **4eb0262 items 1+2**: `messages.sendAsCreator` (attributes to the calling principal's display
  identity; typing-indicator clear moved verbatim) and `space.switchTo` (not_found on unknown id).
  Both toolExposed false. `BridgeCommsTests`.
- **a21cd13 item 9**: `port.info`/`setTitle`/`setCapabilities`/`close`/`position` keyed on the
  caller's own principal (panel by udid-or-messageId; PortPanel carries its bridge so caches stay
  fresh). `port.close` is now a REAL self-close (old case was a no-op); `port.resize` needs no
  native case (pure JS carve-out). `BridgePortsTests`.
- **fb834d6 item 4**: `rest.call` (.rest permission, tool-exposed) with the per-companion secret
  grant and dict-body support unified; {status, headers?, body}. Local-HTTP round-trip gate in
  `BridgeRestTests` (python echo server, allow_reuse_address).
- **8519a3a item 5**: all 7 `browser.*` methods, ONE shared BrowserBridge session store across all
  surfaces (old: per-PortBridge + per-ToolExecutor instances); sessions remember their creating
  port (`owner` param) for event routing; errors throw; capture returns `.data` like
  screen.capture. `BridgeBrowserTests`.

**State**: `ToolDefinitions.hybridToolNames`/`.all` are EMPTY; all 57 golden schemas parity-checked
with no exclusions (`BridgeSchemaParityTests`); Spike B scans 58 methods. Old-switch cases for the
extracted families are deleted; what remains on the switches is exactly items 6+7 plus the
close-out.

## Done 2026-07-19 (evening): tail item 6 + the reclaim-safety incident (d73c4f4..f73ce36)

**Item 6 is DONE, headless + live.** `audio.capture`/`audio.stopCapture` + `camera.stream`/
`camera.stopStream` + `screen.stream`/`screen.stopStream` extracted (d73c4f4). ONE shared stateful
instance per family on AppState (`audioDevice`/`cameraDevice`/`screenDevice`); a session remembers
the PortBridge that started it (owner) for event routing; a dying owner's deinit stops any session
it still holds, keyed on identity (the mic-leak teardown). Tier-A gates in `BridgeAVStreamTests`
(recorded failing first): stop must RELEASE, asserted via weak refs — which surfaced and fixed a
real leak (camera stopStream kept the AVCaptureSession allocated). All six toolExposed false;
golden untouched; Spike B scans 64. Old PortBridge audio/screen/camera cases, per-port device
bridges, and postCapture deleted. **Live-verified in Port42Dev** via a rig port: mic (transcription
events + indicator off on stop), camera (frames + LED off), screen (frames after the TCC dance),
double-stop shows the real JS reject. **The deferred live checks are also done**: browser session
continuity through the gateway (open → text → close, one session) and a real `rest.call` GET (200).

**The reclaim-safety incident (f73ce36).** A `--filter "Port"` test run killed the RUNNING
production app: "Port" matches the module name `Port42Tests` (full-suite run), completeSetup walked
into `configureSyncIfNeeded`, and `killProcessOnPort(4242)` SIGTERMed the listener AND its clients
(`lsof -ti` has no state filter) — the app, companions, ngrok. Fixed at both roots, gated in
`GatewayReclaimSafetyTests`: `-sTCP:LISTEN` on the reclaim (fail-then-pass: client survives), and
`AppState.isTestProcess` guards `configureSyncIfNeeded` entirely (process-identity detection; the
SPM helper carries NO test env vars). Full RCA in `summer2026-todo.md`. **Rule: test filters use
exact suite names, never substrings** (bare "Port" = full suite = live Anthropic calls too).
Also repointed the stale ToolDefinitions coverage gate at the generated list (f189806).

**Found while live-testing (logged in `summer2026-todo.md`):** script tags in `port.create` HTML
never execute (innerHTML-style render; rig worked around via `port.exec`); dev Screen Recording
TCC clash (two dev bundles, one id — `tccutil reset ScreenCapture com.port42.dev` unblocks);
camera/screen streaming causes input lag (per-frame `CIContext` + main-thread base64 pushes).

## Done 2026-07-19 (late): tail item 7 — ALL TEN TAIL ITEMS ARE DONE (bc477fb)

`fs.pick` joined the registry (not an LLM tool); picked-path grants moved to an AppState store
KEYED BY PRINCIPAL id (`pickedFilePaths`/`grantPickedPath` — the Phase-3 seam), off the per-port
FileBridge. `fs.read`/`fs.write` accept an absolute path only when THIS principal picked it;
un-picked absolutes are `access_denied` on every surface. Sandbox (relative) semantics untouched.
Family flipped `wired: true`; old PortBridge `fs.*`/`files.*` cases + the per-port FileBridge
deleted (FileBridge itself slims at the close-out — ToolExecutor's dead cases still reference it).
Gates `BridgeFilesPickedTests` (recorded failing first): wiring, round-trip, denial, isolation.
Live: gateway denial verified; NSOpenPanel pick → read → write round-trip through a port in Dev.
Found: `fs.drop` only notifies JS — dropped paths were never actually readable (registerDroppedPath
has no callers); decide at the close-out whether drops should grant reads.

## Done 2026-07-19 (night): close-out steps 1–3 — BOTH OLD SWITCHES ARE GONE (f05e109)

The audit found every remaining case dead behind registry-first dispatch, with three handled
exceptions: `help` extracted to the registry ("-h" alias), `ai.cancel` kept as an explicit
machinery branch in PortBridge (transport shim, per-bridge Task state), the singular `engraving.*`
name variant dropped (no-compat). Gates in `BridgeCloseOutTests` (recorded failing with the full
92-label inventory): source-scan asserts no old-switch method cases in either file; help serves
from the registry; unknown methods fail cleanly. The deletions: PortBridge −700 lines,
ToolExecutor 1172 → ~180 (RemoteToolExecutor lost its internal old-path executor), FileBridge =
panels only. `fs.drop` now grants dropped paths to the dropping port's principal (the old path
never recorded the grant, so announced paths were unreadable). 192 bridge tests in 34 suites green;
live-smoked in Dev (gateway user.get/help/ports.list/unknown-error; a fresh port's JS round-trips
user.get + the creases.read alias). Net −1853/+117.

## Done 2026-07-19 (close): steps 4+5 — THE UNIFICATION ARC IS COMPLETE (d3ab402, 24b5c79)

**Step 4a**: the tool-name inventory derives from the registry (`AppState.toolNameMap`);
`ToolNaming.canonicalMethods` (90 hand-listed entries) deleted — ToolNaming owns only spelling
rules + the 7 rename overrides + aliases. Gate `BridgeNamingTests`, recorded failing both ways
(help missing from the list; port_resize/ai_cancel listed but not methods).
**Step 4b**: `ToolDefinitions` deleted entirely (the last permission table on the tool side).
**Step 4c**: llms.txt is dead. Conceptual prose → `llms-preamble.txt`; the inventory renders at
runtime from the registries (`BridgeReference.swift`) and serves through `help` AND
InstructionService's CLI docs. Gate `BridgeHelpTests`: every method documented + every method
self-describing, which forced backfilling descriptions for the 20 live-only methods that had none.
Rode along: the port-JS namespace proxy is now callable, so `port42.help()` works (silently broken
since the step-2 Proxy).
**Step 5**: 214 tests / 38 suites green including `BridgeCloseOutTests`; live matrix in Dev — the
same generated reference through gateway and port JS, user.get + creases.read alias on both.

**End state**: ONE registry declares, serves, documents, and permission-gates every method. No
switches, no hand-written tool schemas, no hand-listed name inventory, no hand-written API
reference, no parallel permission tables (the port-side `permissionForMethod` survives only for
the fs.drop gesture). The invariant the arc promised holds by construction.

## Done 2026-07-19 (later): PHASE 3 IS COMPLETE (uncommitted — awaiting the commit ask)

The status line "Phase 3 designed but UNSTARTED" was wrong: 157439c (Jul 17) had already shipped
the stable `local-http` gateway principal, the `senderId` keying, and grant persistence under
`portPerms.<principalId>`. The remainder shipped this session per `plan-phase3-gate-matrix.md`
(GM-signed decisions: no migration; a companion-created port acts as its creator, space-scoped):
- **A** negative gates pinned in `BridgePrincipalTests` (label-constructor scan + `remote-http`
  consumer allowlist), acid-tested.
- **B** `PermissionRequester` deleted; the coordinator, overlay, dispatcher, and fs.drop path take
  `Principal` directly; `PermissionRequest.principal` + `awaiterCount`. Found + fixed en route:
  `coalescesAndResumesAll` raced its own registration and hung the suite (see `summer2026-todo.md`).
- **C** `portPrincipal` is PortBridge's ONE identity: id = `createdBy ?? messageId` — a
  companion and its ports share one grant bucket and one storage namespace per space (todo #6's
  companion half). Deinit cancels pending asks by principal id.
- **D** live two-caller proof in Dev: local-http granted `clipboard.read`; `peer-test-B` (WS,
  own identity) still prompted, own bucket; grant survived relaunch without a prompt; gateway +
  port-JS reads unregressed. Gates recorded failing first throughout; 289 tests / 43 suites green.

## Done 2026-07-19/20: sweep, arc 2, knowledge distribution A-C, RELEASE v0.5.47

Continuing past Phase 3, all committed + pushed (shell-s1 AND main), HEAD d71d8d8:
- **Sweep** (d14be2a, 84274ee, d462672, 220b940): ports.list honors space_id + carries spaceId;
  port.move validates its target; the last parallel permission table (`permissionForMethod`)
  DELETED — the registry is the ONLY permission table; ONE port-document wrapper (CSP dedup);
  found+fixed a real drop-grant bug (dropped paths keyed on messageId, unreadable by a
  creator-resolved port). Shell plan audited to reality. Stray tree files adopted.
- **Arc 2** (a898317): the never-rejecting bridge fix (shipped in 1635d93) PINNED —
  `PortBridge.disposition(for:)` triage + `PortCallDispositionTests`; re-proven live. Phase 4 of
  `plan-api-unification.md` closed. The unification plan is DONE end to end (Phases 0-4).
- **Knowledge distribution A-C** (`plan-knowledge-distribution.md`): **A** (4496d40) llms.txt is a
  committed, generated, freshness-gated artifact at the repo root, served identically by live
  `help`; **B** (0baccad, 7e641ca) `help(topic:)` is an LLM tool — `help("ports")` serves the
  craft manual; the 1,100-line ports-context injection replaced by an 18-line resident core
  (`ports-core.txt`), manual lazy-loaded; cold-build eval passed live; **C** (c14c2ce, 792be7e)
  instruction blocks (CLAUDE.md/GEMINI.md/AGENTS.md) are slim pointers, rewritten at every boot
  (kills install-time drift), guarded so a TEST run never rewrites the user's real files.
  Remaining arc items: **D** (generated MCP server) and **E** (the port42-ports skill) — NOT started.
- **Release** (4b44de3, 7c8d6b0): v0.5.47 built, notarized, stapled, appcast pushed. This is what
  makes the instruction-block pointers TRUE in prod: `help`/`help("ports")` now answer on :4242.

## NEXT SESSION STARTS HERE: the command-companion cwd fix (`plan-companion-cwd.md`)

**The bug (root cause found + evidenced tonight, `summer2026-todo.md`):** `.command` companions
(a real `claude` CLI in a terminal — NOT `.llm` API companions, which are unaffected) all default
to cwd `/Users/gordon`. Claude 2.x keys its transcript on project=cwd, so every command companion
SHARES one stale transcript; the shim reads the wrong file and posts empty or stale text. Proven
with the shim instrument committed tonight (214cbd1): three turns all reported the same frozen
transcript with stale content; the real reply was in no file. Distinct dirs → distinct transcripts
(also proven).

**Decisions are LOCKED (GM) in `plan-companion-cwd.md`** — read it in full. Gate matrix opens with
**step 0, a BLOCKER SPIKE (no code):** verify that a pinned `--session-id` isolates two `claude`
terminals in the SAME cwd. Everything downstream (shared space-dir + per-port session id vs per-port
subdir) depends on that answer. Use the shim instrument (`[hooks] turnComplete: transcript=… sid=…`
in `~/port42-build/Port42Dev.log`) and `port.create` with a `cwd` override + `port.push` to drive.

## Other open tracks (`summer2026-todo.md`)
- Knowledge arc **D** (MCP server) + **E** (skill) — the cross-vendor adoption pieces.
- Auto-register an ad-hoc `claude` terminal port as a space companion (depends on the cwd fix).
- **Bugs**: the screen.stream pointer glitch (undiagnosed); script tags in port.create HTML never
  execute; the 6 pre-existing env test failures; the `remote-http-cal` fossil member row +
  qualified-name collisions.
- **Deferred cleanups**: streaming frame delivery cost (main-thread base64), llms-preamble prose
  accuracy pass.

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
