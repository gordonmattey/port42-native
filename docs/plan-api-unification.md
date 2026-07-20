# Plan: API / tool-use unification (the keystone, summer-todo #2)

*2026-07-17, branch shell-s1. Status: **PLANNED**, no code. The forcing functions and evidence are in
`summer2026-todo.md` (the "#2" section, the `ports.list` consistency item, the Unknown-tool item, and
the MCP/principal item). This doc is the build plan: one base implementation per method, three thin
calling paths over it, and one authenticated principal carried end to end. Test only in Port42Dev
(:4243). Full plan per phase; nothing built until reviewed.*

---

## 1. Scope

**In scope.** Collapse the two parallel method implementations into one base registry; give every
calling path (port JS, companion tool-use, gateway RPC) a thin adapter over that registry; replace the
label-shaped caller identity with a real `Principal` backed by the gateway's authenticated peer id.

**The invariant we are enforcing** (already asserted in `CLAUDE.md`, not yet true in code): *one bridge
method, one implementation, one permission rule, one return shape, reached by every caller the same
way, differing only in how identity is established and how the result is rendered.*

**Out of scope (rides on this, sequenced after).** MCP-as-a-port-capability, chrome-as-ports beyond the
background, publish-a-port-as-a-website interactivity, cross-instance addressing. Each needs the
principal; none should be built beside the current three inconsistent paths. The base registry is also
the natural home for the "make failure visible" fixes (never-rejecting bridge, silent CSP blocks) but
those land as small follow-ups, not as part of the refactor's core.

### Policy: we do NOT protect backward compatibility

This platform is pre-WIRE (port42:// · libp2p · cross-instance). Breaking existing ports, callers, and
return shapes is acceptable and expected. **Backward-compatibility shims are a bad smell: do not add
them, and remove the ones already present.** A shim that preserves an old shape at the cost of a clean
design is a defect, not a courtesy. Prefer the correct forward design and let consumers update.

Concretely, when a root cause touches an old convention, fix the convention, do not wrap it. Resolve
(not preserve) these:

- **The never-reject convention.** JS `_reject` used to `resolve({error})` and each shim did
  `if (r.error) throw`. Resolved: `call()`'s promise rejects; any `{error}` result rejects (routed once
  in `userContentController`); the `if (r.error) throw` shims are deleted. A failed call is a real
  rejection, not a value to inspect. (The HTTP/gateway path keeps `{error}` in the JSON body — correct
  for a request/response transport, not a shim.)
- **The bare-string unwrap.** `ai.complete` resolved with a bare string to match old ports
  (`streamText`). Resolved: it resolves with the structured `{text: ...}` value; `streamText` deleted.
- **Cancel settlement delegated to the engine.** See `docs/rca-aicomplete-cancel-hang.md`. Resolved:
  settlement is core-owned.

Still to resolve under this policy (tracked, not yet done):
- `companions.invoke` still resolves a bare string and runs on the legacy `PortAIHandler` path — fold
  into the streaming registry with the structured shape.
- The big-bang self-describing registry (§ below / bridge-architecture doc §5) deletes the four parallel
  metadata lists and the `window.port42` object literal (generic Proxy) — all compat-shaped duplication.

---

## 2. The current architecture (what we are collapsing)

Three calling paths reach the bridge today:

| Path | Entry | Method names | Returns | Identity |
|---|---|---|---|---|
| Port JS | `PortBridge.handleMethod` (`PortBridge.swift:303`) | dotted camelCase: `port.getHtml`, `ports.list`, `audio.stopCapture` | native JS value, resolved into the page | `PermissionRequester(id: portId, spaceId, createdBy)` |
| Companion tool-use | `ToolExecutor.executeImpl` (`ToolExecutor.swift:147`) | snake: `port_get_html`, `ports_list` | `[["type":"text","text":…]]` content blocks | `PermissionRequester(id: createdBy, spaceId)` |
| Gateway RPC | `RemoteToolExecutor.execute` (`ToolExecutor.swift:1184`) wraps `ToolExecutor` | dotted, then `.`→`_` munge (`:1186`) | first block's text, or JSON | flattened: `"remote-<peerId.prefix(8)>"` (`AppState.swift:1102`) |

`PortBridge.handleMethod` has **85 cases**. `ToolExecutor.executeImpl` has **68**. The overlap is large
and the two drift on four axes:

1. **Naming.** JS uses dotted camelCase; tool-use uses snake. The gateway munges only `.`→`_`, never
   camel→snake, so `port.getHtml` becomes `port_getHtml`, which is not `port_get_html`, so the gateway
   answers **Unknown tool**. The 85-vs-68 gap means ~17 methods are reachable from a port but from
   nowhere else.
2. **Permission table.** Two maps: `PortPermission.permissionForMethod` (`PortPermission.swift:20`, JS
   path) and `ToolDefinitions.permission(for:)` (`ToolDefinitions.swift:685`, tool-use path). Primed to
   disagree.
3. **Return shape.** JS gets native values; tool-use wraps text blocks. This is literally why
   `ports.list` returns an array to a port and a text blob to an agent.
4. **Identity is a label, not a principal.** The gateway runs a real handshake and sets an authenticated
   `PeerID` (`gateway/gateway.go:34-36`). `AppState.onCallReceived` throws it away, minting
   `"remote-<prefix>"` as the display name (`AppState.swift:1102`), and that string becomes the
   permission key.

**What is already unified (the head start).** The permission *ask* was consolidated this session:
`PermissionCoordinator` + `PermissionRequester` (`PermissionCoordinator.swift`) is one queue every path
routes through. `PermissionRequester` (id / displayName / spaceId / createdBy) is an accidental first
draft of the `Principal`. We are promoting it, not inventing it.

**One more current fact the plan must preserve or deliberately change:** the JS bridge **never rejects**.
`handleMethod` returns an `["error": …]` dict and the shim resolves the promise with it
(`PortBridge.swift:296`); `_reject` exists (`:231`) but only `ai.complete` uses it. So every port's
`try/catch` is decoration today. Changing this is a behavior change (§7).

---

## 3. Target architecture (high level)

```
   port JS ──▶ PortBridgeAdapter ─┐
   tool-use ─▶ ToolUseAdapter ────┤──▶  BridgeRegistry[canonical]  ──▶ BridgeValue
   gateway ──▶ GatewayAdapter ────┘        (one impl per method,          │
                  │                          one permission rule)          │
                  └── each builds a Principal ────────────────────────────┘
                      (authenticated identity + grants)     each adapter renders
                                                            BridgeValue for its surface
```

- **`BridgeRegistry`** — one entry per canonical method: permission requirement + a body
  `(Principal, Args) async throws -> BridgeValue`. The single source of truth.
- **`BridgeValue`** — a JSON-shaped result type. JS renders it native; tool-use wraps it in a content
  block (JSON when structured, text when a string); the gateway returns it as JSON.
- **`Principal`** — who is calling: a stable authenticated id, a display name, a space context, a kind
  (port / companion / peer), and the resolved grants. Built by each adapter, carried into the body and
  into the permission check.
- **Adapters** — each path shrinks to: parse args → build `Principal` → look up canonical name → check
  permission (one map) → call the body → render `BridgeValue`. No method logic lives in an adapter.

---

## 4. The plan, part by part

### Phase 0 — the contract (design + types, zero behavior change) — **DONE 2026-07-17**

**Goal.** Land the four types and the naming decision with no dispatch rewired yet, so Phase 1 has a
target to move bodies into.

**Shipped:** `BridgeValue.swift` (+ `BridgeError`), `BridgeArgs.swift`, `Principal.swift`,
`ToolNaming.swift`, `BridgeRegistry.swift` (skeleton), and `Tests/Port42Tests/BridgeContractTests.swift`
(20 tests, green). Nothing wired to the live paths yet.

**What the build surfaced (fed back into later phases):**
- **More renames than three.** The tool surface and the JS surface disagree on file ops too:
  `file_read`/`file_write`/`file_list`/`file_mkdir` (tools) vs `fs.read`/`fs.write` (JS). Canonical is
  `fs.*`; the four `file_*` names are overrides in `ToolNaming`, alongside `run_applescript`,
  `run_jxa`, `screen_info`. The `files.*` names are aliases to `fs.*` (a separate table).
- **`screen_info` and `screen.displays` are the same method, different shape** (text blob vs structured
  array over the same `NSScreen.screens`). Canonical `screen.displays`; the tool adapter will render the
  structured `BridgeValue`, so the agent stops getting a hand-built text blob. Concrete Phase-1 merge.
- **Two arg conventions, not one.** Port JS calls **positionally** (`port.getHtml(id)` → `["…"]`);
  tool-use/gateway pass a **named dict**. So `BridgeMethod` carries `paramNames`, and the port-JS
  adapter is the one place that zips positional → named (`BridgeArgs(positional:names:)`). This was not
  in the original plan and is now Phase-2 adapter work.
- **JS and gateway share one encoder.** Both want JSON; only tool-use differs (text/JSON/image blocks).
  So it is two encoders (`toJSONObject`, `toToolBlocks`), not three. `.data` renders as a base64 string
  for JS/JSON but as a real Anthropic image block for tool-use, so a screenshot method returns pixels
  the model can see.

**Work.**
- **Canonical name = the dotted name the docs already publish** (`port.getHtml`, `ports.list`). See §5
  for why. Underscore/tool-name is a *wire encoding*, mapped explicitly, never munged.
- Define `enum BridgeValue { case null, bool(Bool), int(Int), double(Double), string(String),
  array([BridgeValue]), object([String: BridgeValue]), data(Data, mime: String) }` with encoders:
  `toJSONObject()` (gateway), `toToolBlocks()` (tool-use), `toJSValue()` (JS). `data` carries the
  base64 image cases (`screen_capture`, `camera.capture`).
- Define `struct Principal { let id: String; let displayName: String; let spaceId: String?; let kind:
  PrincipalKind; var grants: Set<PortPermission> }` where `kind = .port | .companion | .peer`. Give it
  the `scopeDescription` / requester bridge so it can produce a `PermissionRequester` (or replace it,
  §Phase 3).
- Define `struct BridgeMethod { let permission: PortPermission?; let run: (Principal, BridgeArgs) async
  throws -> BridgeValue }` and `typealias BridgeRegistry = [String: BridgeMethod]` (keyed by canonical
  name). `BridgeArgs` is a thin typed accessor over `[String: Any]` (`.string("id")`,
  `.int("version")`, required-vs-optional helpers) so bodies stop hand-parsing.
- Define `BridgeError: Error` with a machine code + message, so a failure can be rendered as `{error}`
  for JS, an error block for tool-use, and `{error}` JSON for the gateway from one throw.
- **Name map:** `ToolNaming.canonical(fromTool:)` / `.tool(fromCanonical:)` (snake ⇄ dotted), the
  single place `ports_list` ⇄ `ports.list` is known. `ToolDefinitions` schema names stay snake (the LLM
  contract), and this map is how they reach canonical.

**Files.** New: `BridgeRegistry.swift`, `BridgeValue.swift`, `Principal.swift`, `BridgeArgs.swift`,
`ToolNaming.swift`. No existing dispatch touched yet.

**Risk.** Low (additive). The only judgement is the type surface; keep `BridgeValue` minimal.

**Test plan (unit only; nothing wired, so nothing live to regress).**
- `BridgeValueTests` (`@Suite`): one `@Test` per encoder path.
  - `toJSONObject()`, `toToolBlocks()`, `toJSValue()` for each case: null, bool, int, double, string,
    nested `array`, nested `object`, and `data(_, mime:)` (the base64 image case for `screen.capture` /
    `camera.capture`). Assert exact encoded shape (a string stays a string in JS but becomes a text
    block in tool-use; an object becomes a JSON object in all three).
  - Error rendering: a `BridgeError(code:message:)` renders to `{error}` for JS, an error content block
    for tool-use, and `{error}` JSON for the gateway, from one value.
- `ToolNamingTests`: the coverage + round-trip gate.
  - For **every** name in `ToolDefinitions` (iterate the schema list, not a hand-copied list):
    `canonical(fromTool: n)` is non-nil and `tool(fromCanonical: canonical(fromTool: n)) == n`.
  - No collisions: the map is a bijection (two tool names never map to one canonical; assert set sizes
    match both directions).
- `PrincipalTests`: `scopeDescription` and the `PermissionRequester` bridge for each `kind`
  (`.port` / `.companion` / `.peer`), including `spaceId == nil` (global-to-caller wording).
- **Command:** `swift test --filter BridgeValue`, `--filter ToolNaming`, `--filter Principal`.
- **Done:** all green; the name map covers 100% of `ToolDefinitions` names with zero collisions.

### Phase 1 — the base registry (one implementation per method) — **HEADLESS EXTRACTION DONE; live-only families extracted in Phase 2**

**Goal.** Every method body lives once, in `BridgeRegistry`, keyed by canonical name.

**Batches landed:**
- **Relationship memory** (crease / engrave / fold / position — 12 methods), 2026-07-17. Bodies in
  `BridgeMethods.swift`; `BridgeParityHarness.swift` + `BridgeParityMemoryTests.swift` (12 tests,
  green) prove each matches `ToolExecutor` on read shape, write side effect, and error text. These are
  tool-only methods, so the extraction is behavior-preserving; the read-JSON cases (`fold.read`,
  `position.read`) moved to structured `BridgeValue` and compare equal via the harness's semantic
  (sorted-keys) canonicalization.

- **Storage** (get / set / delete / list — 4 methods), 2026-07-17. The two old paths disagreed on
  scope, return shape, and value handling. **GM: no backward compatibility needed**, so this is the one
  clean contract, not a merge: scope derives from the **principal** (space or `__global__`, creator =
  principal id or `__shared__`), `get → {value}` (JSON round-tripped), `set/delete → {ok}`, `list →
  {keys}`. Because the shape is deliberately new, it is tested **directly** (`BridgeStorageTests`, 9
  green) rather than by parity: round-trip, scope isolation by principal, global-vs-space, no-space
  error, and the positional (JS) arg mapping. Added `BridgeValue.fromJSONObject` (handles the NSNumber
  bool/int trap) for reads.

  Note on method: where the old paths **agree**, parity (old == new) is the gate; where GM has chosen a
  new shape, a **direct behavioral test** of the intended contract is the gate instead.

- **Ports, read/write core** (`ports.list`, `getHtml`, `history`, `update`, `patch`, `restore`,
  `rename`, `move` — 8 methods), 2026-07-17. DB/panel-backed, so headless-testable. Clean contract:
  `ports.list` is one `.array` of port objects on every surface (capabilities from the one source, so
  the `[]` vs `["terminal"]` split is gone); `history` is a `.array`; the mutators return `{ok}` or
  throw `not_found`/`bad_arg`. `BridgePortsTests`, 9 green (incl. the positional→named mapping on a real
  port method). **Deferred to a follow-up sub-batch (webview/terminal-touching, so Phase-2 live-only):**
  `port.create`, `port.push`, `port.exec`, `port.manage`, `port.info/resize/setTitle/setCapabilities`.

- **Identity / spaces / companions / messages / bus** (user.get, space.current, space.list,
  companions.list, companions.get, messages.recent, bus.read, bus.publish, messages.send — 9 methods),
  2026-07-17. Read-mostly, DB-backed. Reads are structured arrays/objects; the two sends return `{ok}`
  and are checked by side effect. Space + sender resolution derive from the principal (explicit
  `space_id` still targets another space). `BridgeCommsTests`, 9 green. (The world builder now mirrors
  the DB into `state.spaces`/`state.companions`, as the real app does via observations.) Deferred:
  `messages.sendAsCreator` and `space.switchTo` (JS-only / UI action) → Phase-2 live-only.

- **Files** (fs.read/write/list/mkdir — 4), 2026-07-17. Data-dir sandbox model (relative only,
  traversal blocked, absolute → picker/live-only), `.filesystem`-gated, `BridgeFilePaths.dataDir` a
  testable hook. `BridgeFilesTests`, 7 green.
- **Devices, headless-safe** (clipboard.read/write, screen.displays — 3), 2026-07-17. Clipboard
  round-trips via NSPasteboard; `screen.displays` is the canonical structured array that replaces the
  `screen_info` text blob. `BridgeDeviceTests`, 4 green.

**Phase 1 headless extraction: COMPLETE.** ~40 methods live once in the registry, 70 bridge tests green
(no regressions in the existing `*BridgeTests`). **What is intentionally NOT extracted yet** — these
touch real hardware, the network, or a live surface, so they cannot be verified without the running
app and are extracted **during Phase 2 wiring**, where each is exercised live as its adapter switches
in: `port.create/push/exec/manage/info/resize/setTitle/setCapabilities`, `messages.sendAsCreator`,
`space.switchTo`, `screen.capture/windows/stream`, `camera.*`, `audio.*`, `notify.send`, `browser.*`,
`automation.*`, `rest.call`, `ai.complete/cancel` (streaming, a documented exception), `fs.pick`.

**Work.**
- Move the body of each `case` from the two switches into a registry entry. Most already delegate to
  `AppState` / the `*Bridge` singletons, so this is consolidation. Do it in method-family batches
  (crease/fold/position, storage, port.*, screen/camera/clipboard, file, audio, browser, automation,
  messages/space/companions) so each batch is separately reviewable and testable.
- **Dedup the genuine forks.** `port.manage` has two implementations today (PortBridge + ToolExecutor);
  adding "background" this session required editing both. One entry now. Same for any method whose two
  copies had drifted (audit each family for behavior diffs while merging; a diff is a bug to resolve,
  not to preserve).
- **Resolve the return-shape per method deliberately.** For each method decide the one `BridgeValue`
  (e.g. `ports.list` → `.array` of objects, everywhere). Where tool-use currently returned a
  hand-built text blob, the tool adapter (Phase 2) will JSON-encode the structured value; if a method's
  text was genuinely prose for the model, keep it a `.string`.
- Registry is built once (on `AppState`), closures capture `appState` weakly as the two executors do.

**Files.** `BridgeRegistry.swift` grows the entries; `ToolExecutor.swift` / `PortBridge.swift` unchanged
this phase (still the live paths). This lets Phase 1 land and be tested against the old paths as an
oracle before any switchover.

**Risk.** Medium. The trap is a silent behavior diff between two merged copies. Mitigate with the oracle
test below.

**Test plan (the differential oracle is the core of the whole refactor).**
- **The harness** (`BridgeParityHarness`): a table of cases `(canonical, tool, input, setup)`. For each,
  build one in-memory world (`DatabaseService(inMemory:true)` + a test `AppState`), run **the old path**
  and **the registry body** against it, normalize both results to a JSON value, and `#expect` they are
  equal. This is the safety net for Phases 1 and 2, so it lives in the test target from the first batch.
- **Per method family a `@Suite`** (`crease`, `fold`, `position`, `storage`, `port`, `messages`,
  `space`, `companions`, `file`) with, per method:
  - a **happy-path** case, and
  - at least one **error-path** case (missing required arg, not-found id, unserializable value), asserting
    both paths produce the same `BridgeError` code.
- **Mutating methods assert the side effect, not just the return.** For `port.patch`, `port.update`,
  `port.manage`, `storage.set`/`delete`, `port.rename`/`move`: run old vs registry from an identical
  starting state in two isolated worlds and `#expect` the resulting DB/panel state is equal (diff the
  row / panel, not only the response).
- **`port.manage` gets explicit per-action parity** (`focus`/`close`/`dock`/`undock`/`background`/
  `unbackground`), because it is the known two-implementation fork being merged.
- **Methods that can't run headless** (`screen.capture`, `camera.capture`, `clipboard.*`, `audio.*`,
  `notify.send`, `browser.*`, `automation.*`, `terminal.exec`): stub the underlying `*Bridge` behind a
  protocol so the *dispatch + arg-parse + permission + BridgeValue shaping* is still differential-tested;
  the real hardware call is verified live in Phase 2. List these explicitly as "live-only body" so the
  Phase 2 live matrix knows to cover them.
- **Golden capture (load-bearing for Phase 2).** The harness also **writes each old-path result to a
  fixture file** (`Tests/Fixtures/bridge-golden/*.json`) on this run. Once Phase 2 deletes the old
  switches the oracle is gone, so these frozen goldens become the Phase-2 regression baseline. Capture
  them here, while both paths still exist.
- **Coverage assertion:** a test iterates every `ToolDefinitions` name and every `PortBridge` case name
  and fails if any lacks a registry entry or a parity case. No method merges silently untested.
- **Command:** `swift test --filter BridgeParity` (plus per-suite filters).
- **Done:** every method family has a registry entry, a passing parity case (happy + error), a captured
  golden, and the coverage assertion is green. Old paths still live and untouched.

### Phase 2 — thin adapters (switch the live paths onto the registry) — **IN PROGRESS**

**Approach (safe, incremental — chosen over a big-bang delete):** each adapter goes **registry-first
with old-path fallback**. It resolves the incoming name to canonical, and if the registry handles it,
runs the one dispatch path; otherwise it falls through to its existing switch, which still serves the
live-only families until they are extracted. So the old switches are deleted *last*, once every method
is extracted and verified, not up front.

**Landed:**
- **The shared dispatcher** (`BridgeDispatcher.swift`): `AppState.runBridgeMethod(canonical, principal,
  args, pregrant)` — resolve alias, look up the one impl, permission-gate via the coordinator (keyed by
  principal, honoring pregrants), run. Plus `bridgeHandles(_)`. `AppState.bridgeRegistry` is built once
  and stored. This is the single choke point every adapter shares.
- **Gateway wired** (`RemoteToolExecutor.execute`): registry-first. A dotted name is canonical; a snake
  tool name maps through `ToolNaming` — so **both spellings now reach the same method**, and
  `port.getHtml` over the gateway returns HTML instead of Unknown tool. "Always Allow" settings become
  pregrants. `BridgeDispatchTests`, 6 green (incl. the getHtml-no-longer-404 case).

- **In-app companion wired** (`ToolExecutor.execute`): registry-first, renders `BridgeValue` as
  tool-use blocks. A companion's `ports_list` now returns a JSON array; `crease_read` keeps its prose.
- **Port JS wired** (`PortBridge.handleMethod`): registry-first, positional args mapped to named via
  `paramNames`, native JSON returned. `fs.*` is held back (see below).
- **The `wired` flag** (`BridgeMethod.wired`, default true): a method extracted + unit-tested but not
  yet adapter-routed. `fs.*` is `wired:false` — its registry impl is a data-dir sandbox, but port JS
  still relies on the picked-path model (`fs.pick` → `fs.read` an absolute path), so routing it now
  would break that flow. `bridgeHandles` excludes unwired methods, so `fs.*` keeps running on the old
  path until Phase 3 gives the picked-path grant a home on the principal. The registry `fs.*` bodies
  and their tests stay green via direct dispatch.

**All three adapters now route registry-first with old-path fallback** (77 bridge tests green). The old
switches still serve the live-only + unwired families and are deleted last.

**Live-verified in Port42Dev (:4243), 2026-07-17:** gateway `ports.list` → JSON array (capabilities
correct), `port.getHtml` (dotted) → HTML not Unknown-tool, `port_get_html` (snake) → same,
`space.list`/`space_list` → same method, `screen.displays`/`screen_info` → structured array,
`user.get` → structured, unknown → clean error. Port JS: `port42.ports.list()` from inside a port →
native array, same shape. In-app companion: "list ports" → works. All three paths confirmed on one impl.

**Live-only device families extracted** (thin wrappers, 2026-07-17): `screen.capture` (top-level
`.data` → image block for the model, base64 for JS), `screen.windows`, `camera.capture`, `notify.send`,
`automation.runAppleScript`/`runJXA`, `audio.speak`/`play`/`stop`. One shared bridge instance each.
**Still on the old path** (stateful/streaming or complex): `audio.capture`, camera/screen stream,
browser sessions, live port `push`/`exec`/`manage`/`create`, `rest.call` (URLRequest + secret injection).

**Next:** extract the remaining live-only/stateful methods, reconcile `fs.*` + do the principal
(Phase 3), then delete the old switches.

**Original goal.** Delete the two big switches; the three paths become adapters.

**Work.**
- **`ToolUseAdapter`** (replaces `ToolExecutor.executeImpl`): `canonical(fromTool: name)` → registry
  lookup → build `Principal(kind:.companion, id: createdBy, spaceId)` → permission via the one map →
  run → `BridgeValue.toToolBlocks()`. The existing pregrant / persist logic (`ToolExecutor.execute`
  `:77-101`) moves into the adapter's permission step unchanged.
- **`PortBridgeAdapter`** (replaces `PortBridge.handleMethod`): method name is already canonical (dotted)
  → registry lookup → `Principal(kind:.port, id: portId, spaceId, createdBy)` → permission → run →
  `BridgeValue.toJSValue()` resolved into the page. Keep `ai.complete` / `ai.cancel` streaming on their
  current bespoke path (they are token-callback shaped, not request/response); the registry covers the
  request/response surface, and streaming is a documented exception, not a fork.
- **`GatewayAdapter`** (replaces `RemoteToolExecutor.execute`): accept the dotted name (or snake, via the
  map) → registry lookup → build `Principal(kind:.peer, …)` (Phase 3 gives it the real id; here it can
  still carry the flattened label so this phase is identity-neutral) → run → `.toJSONObject()`.
- One permission map: `BridgeRegistry` entries carry the requirement, so `PortPermission.permissionForMethod`
  and `ToolDefinitions.permission(for:)` both retire in favor of `registry[canonical]?.permission`.
  Keep `ToolDefinitions` for the *schemas* the LLM sees (that is a separate concern); only its
  permission-lookup function goes.

**Files.** `PortBridge.swift`, `ToolExecutor.swift` (both shrink hard; `RemoteToolExecutor` becomes a
~20-line adapter), `PortPermission.swift` / `ToolDefinitions.swift` (drop the duplicate permission maps).

**Risk.** Medium-high, because this is the switchover. The differential tests from Phase 1 are the safety
net; run them against the *adapters* now, not just the registry.

**Test plan (switchover: goldens replace the now-deleted oracle, then a live cross-path matrix).**
- **Golden regression (unit).** Re-run `BridgeParityHarness` in *replay* mode: each case runs the new
  adapter path and `#expect`s equality against the Phase-1 golden fixture (the old path is gone, so the
  frozen JSON is the baseline). Green means the adapters reproduce the old behavior byte-for-byte where
  it should be unchanged, and the deliberate return-shape changes (e.g. `ports.list` text to JSON) are
  updated goldens with a comment saying why.
- **Adapter-shaping unit tests.** For one representative method, assert the *same* `BridgeValue` renders
  correctly per surface: JS gets the native value, tool-use gets the JSON/text block, gateway gets the
  JSON object. Confirms the three adapters differ only in rendering.
- **Permission-path unchanged (unit).** A gated method through each adapter still asks the coordinator
  once and caches the grant (reuse the existing pattern; assert the coordinator saw exactly one request).
- **Live cross-path matrix in Port42Dev (:4243)** — the acceptance gate. For each row, the three paths
  return the same result:

  | Probe | Port JS | Companion tool-use | Gateway curl |
  |---|---|---|---|
  | `ports.list` | `port42.ports.list()` | `ports_list` | `-d '{"method":"ports.list"}'` → identical JSON array |
  | `port.getHtml` | `port42.port.getHtml(id)` | `port_get_html` | `port.getHtml` → **HTML, not Unknown tool** |
  | `port.manage background` | from a port | via tool-use | via curl → one code path, port goes to Layer 0 |
  | a JS-only method (e.g. `port.position`, `screen.displays`) | works | now reachable | now reachable (was Unknown) |
  | a hardware method (`screen.capture`, `clipboard.read`) | prompts + works | prompts + works | prompts + works |

- **Regression sweep of the shipped ports:** open the session's real ports in Port42Dev (SHADER, a chat
  port, a voice port) and confirm each still functions on the adapter path (no blank tile, calls resolve).
- **Command:** `swift test --filter BridgeParity` (replay) + the manual matrix above; `sample Port42Dev`
  if any path hangs.
- **Done:** both switches deleted; replay goldens green; the live matrix passes on all three paths;
  shipped ports still work.

### Phase 2b — the unification tail (finish extraction, then delete the switches)

**Goal.** Extract every remaining method so the two old switches can be deleted (single source of truth).
GM's calls (2026-07-17): **`ai.complete`/`ai.cancel` are IN scope** (not a "documented exception" — the
streaming case is the hard one and must be dealt with), and **every item needs a defined test before it
is touched.**

**Streaming contract extension (item 7).** `BridgeValue` is one-value-out; streaming needs a
`BridgeStreamMethod` variant: `(Principal, BridgeArgs, yield: (String) -> Void) async throws ->
BridgeValue`. Dispatch/principal/permission stay unified; each adapter wires `yield` to its surface
(port JS → `_tokenCallback`, gateway → chunked, tool-use → collect). This also forces the
never-rejecting-bridge fix — `ai.complete` is exactly where reject matters.

**Batch 1 — DONE 2026-07-17 (verified live):** `port.create`, `port.push`, `port.exec` (via
`PortExecJS`), `port.manage`, `terminal.exec`. The by-id/opts port methods that were duplicated across
both switches, plus the one gated terminal method.

**All 10 remaining items — each with its defined test/case (a method is not touched until its test exists):**

| # | Item | Test unit / case (the gate for that item) |
|---|---|---|
| 1 | `messages.sendAsCreator` | Unit (`BridgeCommsTests`): call it → a message persists with the creator's senderName and the target space id. |
| 2 | `space.switchTo` | Unit: call with a space id → `appState.currentSpace` flips to it; unknown id → `BridgeError.notFound`. |
| 3 | `companions.invoke` | Unit: invoke an LLM companion with a stubbed engine → returns the stub text; a non-LLM (command) companion → `BridgeError`. Live: `companions.invoke(echo,"ping")` → non-empty text. |
| 4 | `rest.call` | Unit: hit a local test HTTP server → `{status,headers,body}`; with a stored secret named in opts, assert the resolved header was injected. Live: one real GET returns 200 + body. |
| 5 | `browser.*` (open/navigate/capture/text/html/execute/close) | Live (session continuity): `browser.open(url)` → id; `browser.text(id)` returns page text; `browser.close(id)` → ok. Proves the ONE shared `BrowserBridge` instance in the registry holds session state across separate calls. |
| 6 | `audio.capture` + camera/screen streams (`stopCapture`/`stopStream`) | **Teardown test** (the mic-leak item, Tier-A): start capture → `stopCapture` → assert the `SFSpeechRecognizer`/`AVAudioEngine` is DOWN (AudioBridge state assert or thread sample). Camera/screen: start → stop → assert the session is torn down. Must *release*, not merely "work". |
| 7 | `fs.*` picked-path (wire the currently `wired:false` family) | Live: `fs.pick` → an absolute path; `fs.read(that path)` succeeds; `fs.read(an un-picked absolute path)` → `access_denied`. Unit: a picked path is readable only under the granting port's principal, not another's (Phase-3 keying). The existing sandbox tests (`BridgeFilesTests`) stay green. |
| 8 | `ai.complete` / `ai.cancel` (streaming) | Unit: a stub `BridgeStreamMethod` yields N tokens + a final value → assert the adapter delivered exactly N token callbacks then the final. Live: a port `ai.complete` streams tokens in and resolves; `ai.cancel` mid-stream stops further tokens. |
| 9 | Self-referential port methods (`setTitle`/`setCapabilities`/`close`/`resize`/`info`/`position`) | Unit: extract keyed on the port's own principal (`principal.id` = port id resolves the panel) → a `setTitle` updates that panel's title; `setCapabilities` updates its capabilities; `info` returns the port's own id/space. (Required or the port-JS switch can't be deleted.) |
| 10 | `ai.models` / `ai.status` + the never-rejecting-bridge fix | Unit (models/status): returns the configured provider's model list / current status. Unit+Live (reject): a failing bridge call now `_reject`s the port promise → a test port that `await`s a known-failing call asserts its `catch` runs (today the catch is dead). |
| — | **Delete the old switches** (the close-out gate, not a method) | Gate: the full bridge suite + the live cross-path matrix green *after* the two switch bodies are removed, plus a grep asserting the old `case "…"` labels are gone. Nothing may fall through to a deleted switch. Can only run once items 1–10 are extracted. |

**Sequencing:** item 8 (the streaming contract) first — it reshapes the contract, so prove it early
rather than bolt it on last. Then 1–7 and 9–10, then the switch-deletion gate last.

**Status (2026-07-19): ALL TEN ITEMS DONE.** Item 6: `BridgeAVStreamTests` Tier-A release gates +
owner-death teardown, live-verified mic/camera/screen in Port42Dev; browser session-continuity and
rest.call live gates verified through the gateway. Item 7: `BridgeFilesPickedTests` — fs.pick in
the registry, picked-path grants keyed by principal id on AppState (the Phase-3 seam), un-picked
absolutes access_denied, per-principal isolation; live NSOpenPanel pick → read → write round-trip
in Port42Dev. Remaining: the close-out only.

### Phase 3 — the real principal (stop flattening the authenticated identity)

**Goal.** Permissions and grants key on *who is calling*, not on a display label.

**Work.**
- Thread the gateway's authenticated `PeerID` from `sync.onCallReceived` (`AppState.swift:1100`) into
  the `Principal` instead of `"remote-<prefix>"`. `onCallReceived` already receives `senderId`; stop
  collapsing it. The `RemoteToolExecutor` cache keyed by `senderId` stays, but the identity it carries
  becomes the principal, not the label.
- `Principal.id` becomes the permission key. A grant is now a statement about a principal
  (`grants keyed by (principal.id, permission)`), so two different gateway callers no longer share the
  `remote-http-cal` bucket. Migrate the persisted `portPerms.<label>` store to `<principalId>` (or
  keep the label as a display field and re-key storage on id).
- `PermissionRequester` is either replaced by `Principal` or reduced to a view of it. The
  `PermissionCoordinator` API takes a `Principal` (it already takes a requester; this is a type swap).
- Space context: a peer principal still has `spaceId == nil` when acting headless, which now correctly
  means "global to this authenticated peer," not "unpersistable."

**Files.** `AppState.swift` (`onCallReceived`, the `remoteExecutors` map, the perm persistence helpers),
`Principal.swift`, `PermissionCoordinator.swift` (type swap), the perm-storage read/write.

**Risk.** Medium. Behavioral: existing "Always Allow" grants stored under the old label keys need a
migration or they silently stop applying. Write the migration; verify a previously-granted gateway
caller is still granted after upgrade.

**Test plan (identity: unit for the keying + migration, live for the two-caller proof).**
- **Principal construction (unit).** `onCallReceived` builds a `Principal` whose `id` is the passed
  `senderId` (authenticated `peer.ID`), not a `remote-<prefix>` string. Assert directly on the
  constructed principal for a sample `senderId`.
- **Permission keys on principal id (unit).** Grant permission to principal A; assert principal B with a
  different id is **not** granted (separate buckets). Assert principal A is still granted on a second
  call (cache/persist under `id`). This is the core behavior change, tested without hardware.
- **Grant migration (unit) — the silent-drop guard.** Seed the persisted store in the old
  `portPerms.<label>` shape for a caller, run the migration, and assert the grant now resolves under the
  caller's principal id (a previously "Always Allow"ed gateway caller stays allowed after upgrade). Also
  assert an unseeded caller is not accidentally granted.
- **Negative / grep gate.** A test (or a CI grep) asserts no authorization path constructs
  `"remote-\(…prefix…)"`; the label may survive only as a `displayName`, never as the permission key.
- **Live in Port42Dev (:4243) — the two-caller proof.** Drive the gateway as **two distinct authenticated
  identities** (two `sender_id`s over the WS handshake). Grant a gated method for caller A; confirm caller
  B calling the same method **still prompts** (no shared `remote-http-cal` bucket). Then relaunch
  Port42Dev and confirm A's grant persisted under its principal id.
- **Command:** `swift test --filter Principal --filter PermissionMigration` + the two-identity live check.
- **Done:** distinct callers get distinct decisions; grants persist under principal id across relaunch;
  the migration keeps old grants working; no authz path builds a label identity.

### Phase 4 — the consistency wins that now fall out (small, opt-in)

These are cheap once §1-3 exist and close several open todo items; do them as small follow-ups, each
its own commit and its own test so a regression is bisectable:
- **`ports.list` JSON + capabilities** (todo #9): satisfied by the single `BridgeValue` for the method;
  ensure `capabilities` is computed in the one body so terminal ports report `["terminal"]` everywhere.
  *Test:* unit parity case already covers the JSON shape; add a case asserting a terminal port yields
  `capabilities: ["terminal"]`, and a live check that the same port reports `["terminal"]` from all
  three paths (closes the `ports.list` vs `terminal.list` mismatch).
- **Missing gateway APIs** (`port.position`, `screen.displays`, `port.move`): add registry entries; they
  become reachable from all paths at once. Corrects the "Unknown tool" todo. *Test:* a live curl to each
  returns the documented shape (`{x,y,width,height}`, the displays array) instead of Unknown tool; a unit
  case pins the `BridgeValue` shape.
- **Make the bridge reject** (todo "never-rejecting bridge"): the JS adapter maps a thrown `BridgeError`
  to `_reject` instead of resolving `{error}`. **Behavior change** (§7); its own commit, announced in the
  ports skill. *Test:* a tiny test port that `await`s a call it knows will fail and asserts its `catch`
  runs (today the `catch` is dead and the promise resolves with `{error}`); confirm a *successful* call
  still resolves. Verify live because this changes every port's error handling.
- **One port-document wrapper** (todo "CSP duplicated in `PortView.swift:245` and
  `PortWindowManager.swift:947`"): unrelated to dispatch but in the same blast radius; fold in if cheap.
  *Test:* snapshot the wrapper HTML produced for a fixed port and assert both former call sites now emit
  the identical document (byte-equal), so the CSP can never again drift between them.

---

## 5. The naming decision (the one real fork)

**Canonical = dotted name (`port.getHtml`), tool/wire names map to it explicitly.**

- It matches the published API (`CLAUDE.md`, `llms.txt`) and every port's existing `port42.foo.bar()`
  call site, so no port source changes.
- The camelCase Unknown-tool bug is a *string-munging* bug (`.`→`_` cannot recover `get_html` from
  `getHtml`). An explicit `ToolNaming` map deletes the whole class instead of patching cases.
- The LLM tool schemas stay snake (`ToolDefinitions`), because Anthropic tool names disallow dots; the
  map is the seam between the model's snake and the canonical dotted name.

Rejected: canonical = snake. It would force rewriting every JS call site and the public docs, for no
gain, since a map is needed regardless (the LLM cannot emit dots).

---

## 6. Risks and test strategy

- **Silent behavior diffs when merging two copies** — the top risk. Mitigation: the Phase-1 differential
  oracle (old path vs registry) per method, kept green through the Phase-2 switchover.
- **Return-shape change breaks a consumer** that parsed the old text blob (e.g. an in-the-wild port or a
  script parsing `ports.list` text). Mitigation: grep the resource ports and known callers; the change
  is toward JSON, which is the documented contract, but announce it.
- **Reject-instead-of-resolve** changes error handling for every port. Mitigation: its own phase, its own
  commit, gated, documented in the ports skill.
- **Grant migration** (Phase 3) can silently drop "Always Allow." Mitigation: explicit migration + a
  live upgrade test.
- **Streaming stays a documented exception** (`ai.complete`), not forced into the request/response
  registry. State it so a future reader does not "fix" it into the registry.
- **All verification in Port42Dev (:4243).** Never the prod daily driver. Live checks per phase above,
  plus `swift test` (Swift Testing) for the registry, encoders, name map, and permission lookups.

**Test infrastructure (built once in Phase 1, reused through Phase 4).**
- **`BridgeParityHarness`** (`Tests/Port42Tests/`) is the spine: a case table `(canonical, tool, input,
  setup)` with two modes. *Oracle mode* (Phase 1) runs old-path vs registry in the same in-memory world
  and asserts equality. *Replay mode* (Phase 2+) runs the adapter against the frozen golden. Same cases,
  two references, so a case is written once.
- **Golden fixtures** live in `Tests/Fixtures/bridge-golden/*.json`, captured during the Phase-1 oracle
  run while both paths still exist. **Ordering constraint: capture goldens before Phase 2 deletes the old
  switches.** After deletion the only baseline is the fixture, so a missing golden is an untestable
  method. The coverage assertion (every method has a golden) enforces this at the phase boundary.
- **Hardware stubs:** the non-headless `*Bridge` types (`Screen`, `Camera`, `Clipboard`, `Audio`,
  `Notification`, `Browser`, `Automation`) sit behind protocols with test doubles, so dispatch, arg
  parsing, permission, and `BridgeValue` shaping are unit-tested for every method; only the real device
  call is live-only, and those are enumerated in the Phase-2 live matrix.
- **Conventions:** Swift Testing (`@Suite`/`@Test`/`#expect`, `throws`), `DatabaseService(inMemory:true)`,
  the `AppUser.createLocal` / `Space.create` / `Message.create` factories. No `XCTest`.
- **What "live" means each phase:** `./build.sh --run` into Port42Dev, drive the three paths (a port's JS,
  an in-app companion, `curl :4243/call` and the tunnel), and `sample Port42Dev <pid>` before killing if
  anything hangs (per the parked demo-freeze note).

---

## 7. Sequencing and what it unlocks

```
   Phase 0 contract ─▶ Phase 1 registry ─▶ Phase 2 adapters ─▶ Phase 3 principal ─▶ Phase 4 wins
        (types)          (one impl)          (delete switches)     (real identity)     (todo closeouts)
```

Phases 1-2 pay off on their own: `ports.list` consistency, the camelCase Unknown-tool, `port.manage`
double-impl, and the 17 unreachable methods all resolve, and there is finally one place to fix the
never-rejecting bridge. Phase 3 is the deeper half and is the shared prerequisite for the items stacked
behind it today, each of which reduces to "one answer to who is calling":

- **MCP as a port capability** (per-(principal, server) grants; a shared port calls as the viewer).
- **Chrome-as-ports** beyond the background (a dock port is a different principal from a shader; a
  background port must never hold the dock's authority).
- **Publish a port as a website** (a published port runs with zero authority, or as the viewer's
  principal, never the author's).
- **Cross-instance addressing** in `membrane/bus-architecture.md` (the peer's principal is the address).

Recommendation: build 1-2 as one reviewable arc (immediate consistency wins, low identity risk), then 3
as a deliberate second arc (identity, with its migration), then pick up Phase-4 closeouts opportunistically.

## 8. Related

- `summer2026-todo.md` — "#2 API/tool-use unification", "`ports.list` API consistency", "documented
  gateway APIs that return Unknown tool", "MCP as a port capability / the principal", "publish a port as
  a website".
- `membrane/bus-architecture.md` — a port is an addressable actor; the principal is the "who may write"
  facet (right-of-way) and the cross-instance address.
- `plan-port42-ports-skill.md` — depends on this landing first, so the skill documents one coherent
  surface once.
