# Bridge architecture, adapter honesty, and MCP mapping

Status: branch `shell-s1`. Item 8 (streaming) shipped; Spikes A (schema generation) and B (parameter
consistency) shipped. Sections 4 and 5 are the self-describing registry (partly built, generation
proven). Section 6 is the service / plug-in direction: the taxonomy and seam are the target, the `ai`
migration is the first concrete step.

## 0. Framing: API vs transport (and where presence lives)

Two nouns get conflated. Keep them apart and the rest of this document (and the MCP question) falls
out cleanly.

- **The API is the method namespace.** The ~54 named methods, their args, results, and permissions.
  That is the `BridgeRegistry`. It is transport-independent: it does not know how a call reached it.
- **A transport is how a call travels.** There are four: port JS (in-process), in-app tool use
  (in-process), HTTP `/call` (local curl / Claude Code), and the WS `call` envelope (remote peers).
  The last two are what people mean by "the port42 protocol."

So "the port42 protocol" is neither the API nor a synonym for it. It is one transport among four, and
it is also broader than the API: the same WS connection runs a messaging fabric (presence, sync,
channel join, E2E encryption, store-and-forward) of which the bridge `call` envelope is one type.

The convergence layer is the registry, `runBridgeMethod` / `runBridgeStream`, which lives in the host,
*below* every transport. All four transports funnel to it. In-process paths call it directly; the
gateway routes a remote call back into the host to reach it (the gateway routes and authenticates, it
does not execute). Unification happens there, at the API, not at any transport.

Presence is the clean proof that API and transport are different things. Presence is not a bridge
method, you cannot call it, it arrives as a push (`onPresenceChanged`) because it is about who is on
the wire right now. It belongs to the transport's messaging fabric, not the registry. If the API were
the protocol, you would be bolting presence onto the in-process transports that have no peers at all.
The API cannot be the protocol precisely because the protocol has to do presence and the API does not.

MCP (section 6) is a fifth transport for the `call` slice only. It never carries presence, because
presence was never part of the API.

## 1. The shape: one namespace, three surfaces, one core

Every device / space / port capability is a named method (`clipboard.read`, `port.create`,
`ai.complete`, `crease.write`). There is one registry of implementations and three thin adapters that
feed it.

```
  SURFACE (adapter)              builds a          CORE (unified)
  -----------------             Principal          -------------
  Port JS                        kind .port      +---------------------------+
  PortBridge.handleMethod  ----> id=messageId --> | runBridgeMethod(          |
    port42.foo(a,b)   positional                 |   canonical, principal,   |
                                                 |   args, pregrant)         |
  In-app tool use                kind .companion |                           |
  ToolExecutor.execute     ----> id=createdBy --> |  1 resolve alias          |
    (companion tool call)                        |  2 look up BridgeMethod   |
                                                 |  3 permission-gate on     |--> BridgeValue
  Gateway (external)             kind .peer      |    principal.id via       |
  RemoteToolExecutor.execute --> id=senderId --> |    PermissionCoordinator  |
    HTTP /call -> WS RPC                         |  4 run body               |
                                                 +---------------------------+
                                                   BridgeRegistry = [name: BridgeMethod]
                                                   built once: buildBridgeRegistry(appState)
```

An adapter's only job: build a `Principal`, pass `BridgeArgs`, render the returned `BridgeValue` for
its surface (`toJSONObject()` for JS / gateway, `toToolBlocks()` for tool use). A method's behavior and
its permission live in exactly one place.

### Contract types
- `BridgeArgs` / `BridgeValue` - surface-neutral value in / out.
- `Principal` - who is calling: `id`, `displayName`, `spaceId`, `kind`. Permissions key on `id`, not a
  label. `.port` id is the port's messageId; `.companion` id is the creating companion; `.peer` id is
  the authenticated gateway sender (local callers share `local-http`).
- `PermissionCoordinator` - coalesces concurrent asks, persists grants against `(id, spaceId)`; gateway
  "Always Allow" settings ride in as pregrants.

### Streaming (item 8)
Same shape with a token channel: `BridgeStreamRegistry` + `runBridgeStream(..., yield:)`. Same gating;
the body yields tokens then returns a final value. Each surface binds `yield` to its delivery (port JS
-> `pushToken`, gateway -> chunked / collect, tool use -> collect-into-final). This is what lets
`ai.complete` leave PortBridge's special case and join the registry.

## 2. The gateway is transport + auth, not semantics

`gateway/main.go` serves `/call`, `/health`, the WS hub, and the invite page. `HandleHTTPCall`
(`gateway.go:799`) turns `POST /call {method,args}` into a WS envelope `{type:"call", Method, Args,
CallID}`, sends it to the host over the hub, and routes the reply back by `CallID` (`httpCallbacks`).
Remote WS peers send the same `call` envelope directly, authenticated by peer.ID. On the Swift side,
`SyncService.onCallReceived(senderId, callId, method, input)` (`AppState.swift:1111`) dispatches to a
per-sender `RemoteToolExecutor`.

The gateway knows nothing about what a method does. It forwards `(senderId, callId, method, args)` and
awaits a reply. That is the seam a new wire protocol (for example MCP) slots into.

## 3. What is genuinely unified

Dispatch and permission. One `runBridgeMethod`, three adapters that only build a `Principal` and render
a `BridgeValue`. For a method that lives in the registry, behavior + permission are one place, and all
three surfaces reach it identically. That part is a true adapter architecture.

## 4. What is NOT unified (the "touch many places" cost)

Discovery and the JS binding are maintained in parallel to the registry rather than generated from it.
Adding one method touches one place for behavior and up to four more for metadata:

| Place | What | Unified? |
|---|---|---|
| `BridgeMethods.swift` | impl: permission, paramNames, body | yes, the one true place |
| `ToolDefinitions.swift` | Anthropic tool schema, hand-written | no, parallel list |
| `ToolNaming.canonicalMethods` | name inventory (+ overrides / aliases) | no, parallel list |
| `window.port42` in PortBridge | JS binding, a hand-written object literal, not a Proxy | no, parallel list |
| `llms.txt` | help / discovery doc | no, parallel list |

Migration artifact: the two old switches (`PortBridge.handleMethod`, `ToolExecutor.executeImpl`) still
hold not-yet-extracted methods, so those live in two places until the close-out deletion. Part of the
"many places" feeling is the half-done migration, not the end state.

Summary: dispatch + permission are unified; schema + JS binding + name inventory + docs are four
parallel lists. This is a metadata-generation gap, not an adapter-architecture failure.

## 5. The fix: a self-describing registry

Make the registry carry its own metadata, then generate the four lists from it.

- Add `description` + `inputSchema` to `BridgeMethod` (params with types / required / descriptions).
  `paramNames` becomes derivable from ordered params.
- `ToolDefinitions.all` -> generated by mapping the registry. Delete the hand-written schemas.
- `ToolNaming.canonicalMethods` -> generated from `registry.keys`. Delete the inventory.
- `window.port42` -> a generic JS `Proxy` that dispatches any `port42.a.b(...)` by name. Delete the
  object literal.
- `llms.txt` tool section -> generated from descriptions.

After that a new method is exactly one `BridgeMethod` with its schema inline, and every surface picks
it up for free because they all read the one registry.

## 6. Services and the plug-in seam

The registry has two kinds of tenant, and conflating them is what made `window.port42` read as one
undifferentiated coat over ~60 methods. (Visual map: the shell-s1 bridge-surface artifact.)

- **Built-ins.** The platform's own object model (ports, spaces, messaging, identity) and the stateless
  host calls (clipboard, screen, camera, audio, fs, notify, automation, browser, rest, terminal). These
  are port42. They are not pluggable and own no domain state.
- **Services.** A namespace that owns state and a domain contract and could just as well run outside the
  app. Three ship built in today, and together they are an *agent substrate* with three faculties:
  - **agent runtime** (`ai`, `companions.invoke`): run a model or an agent. `ai` already proxies to an
    external provider (Anthropic, Gemini), so "could be external" is not hypothetical, it is the current
    implementation.
  - **epistemic memory** (Keeper: `crease`, `fold`, `position`): how the companion's model of the
    relationship breaks and reforms.
  - **knowledge** (Keeper `engrave`, plus `storage`): facts about the user's world, and scoped key-value
    state.

A service integrates by registering a namespaced, self-describing set of methods into the one registry,
carrying its own names, schemas, permission, an optional declared DSL name-map, and a backend dependency.
It is then reachable from every surface (port JS, tool-use, gateway, MCP) with one gate and one schema,
no per-surface work. An external MCP server (`mcp.<server>.<tool>`) is the same shape as Keeper or `ai`.
We build the seam for a third party and run our own services through it. Treat ourselves as a third party.

**The DSL name-map is a first-class field, not a patch.** Keeper's JS surface is plural (`creases`,
`engravings`) while its methods are singular (`crease`, `engrave`). The current literal papers over the
gap inconsistently: `creases.read` dispatches `creases.read` (resolves nowhere), while `creases.write`
is hand-corrected to `crease.write`. As a service, Keeper *declares* its surface-to-method map once, and
every transport reads it. This subsumes the existing `files.* -> fs.*` alias table into the general
mechanism.

**`ai` is the reference migration.** It has every facet at once (a streaming method, plain reads, an
external backend, and a transport-coupled control it deliberately excludes), so migrating it to a single
service module is how we nail the pattern before generalizing. Concretely:

1. Move `ai.models` and `ai.status` off the old `PortBridge` switch (`:561`, `:587`) into the registry
   as self-describing methods (headless, ungated).
2. Group the whole namespace in one `registerAIService` module: `complete` (stream), `models`, `status`,
   co-locating methods, schemas, `.ai` gating, and the provider-backend wiring.
3. Keep `ai.cancel` a stream-control shim. It cancels by JS `callId` (`streamTasks`), which is
   transport-coupled, not a service method. A documented carve-out, same class as `port.resize`.
4. The provider abstraction (`resolveStreamBackend` / `makeLLMBackend`) is the service's backend seam,
   the part Keeper and `storage` each supply their own version of.

No `BridgeService` protocol yet. The pattern emerges as a convention (one register-module per service)
and is formalized only after a second service (Keeper) confirms it earns the abstraction.

### 6a. MCP mapped onto the seam

MCP is JSON-RPC over stdio or HTTP / SSE: a server advertises tools (name + JSON-Schema input +
handler), clients call `tools/call`, results return as content with optional progress / partial for
streaming. The bridge is already MCP-shaped:

| MCP concept | Bridge equivalent |
|---|---|
| `tools/list` | `BridgeRegistry` keys + schemas |
| `tools/call` | `runBridgeMethod` |
| call input / result content | `BridgeArgs` / `BridgeValue` |
| streaming / progress | `runBridgeStream` yield |
| host-side authz (MCP leaves this open) | `Principal` + `PermissionCoordinator` |

Two directions, each wired once at the core, not per surface:

**(A) Port42 as an MCP server.** A fifth reader of the registry: an `McpServerAdapter` speaks MCP
JSON-RPC, lists the registry as MCP tools, dispatches `tools/call` -> `runBridgeMethod` with a
`Principal(kind: .peer)` per client. Cheapest build: teach the Go gateway (or a sidecar) to translate
MCP `tools/call` into the existing `call` envelope, reusing `onCallReceived` -> `RemoteToolExecutor`.
MCP progress / SSE binds to `runBridgeStream` yield the same way port JS binds it to `pushToken`.

**(B) Port42 as an MCP client.** Register each external MCP server's tools INTO the registry as
`BridgeMethod`s (namespaced `mcp.<server>.<tool>`) whose body proxies to the MCP server. Because the
registry is the single injection point, those tools become available on all three surfaces at once with
the same gating and schema surface, zero per-surface work.

The self-describing registry (section 5) is the same lever for both problems: it removes the parallel
lists AND makes `tools/list` a generated `registry.map { $0.mcpSchema }`.

## 7. Sequencing decision

Item 8 (streaming `ai.complete` into the registry) is done first, in the self-describing shape, as the
architectural spike. The stream method carries its own `description` + `inputSchema` inline; a generator
turns that into the Anthropic tool schema, guarded by a parity test that asserts the generated
`ai.complete` schema equals the current hand-written one. That proves inline-metadata -> generated
schema + parity + streaming dispatch across all three surfaces on one hard method (streaming +
callback) before the pattern is trusted on the other 53.

De-risk boundary: the spike does NOT prove the generic JS Proxy, because `ai.complete` is a callback
method that keeps an explicit shim. The Proxy is proven in the big-bang on a plain method.

Then the big-bang (section 5) rolls the proven shape across all 54 methods in one pass: extend
`BridgeMethod` with the same metadata fields, backfill 54, flip `ToolDefinitions` /
`ToolNaming.canonicalMethods` / `llms.txt` to generated, replace the `window.port42` literal with a
Proxy plus a shim carve-out for callback methods, delete the two old switches and the parallel lists.
Guarded by the same parity + coverage tests.

## 8. Considered and rejected: forcing a single transport

A tempting simplification: force every call through the gateway / WS protocol so there is literally
one transport, including a loopback for the two in-process paths. It is possible. It is the wrong
convergence layer, and it is recorded here as considered, not overlooked.

The gateway routes and authenticates; it does not execute. A remote call is forwarded back into the
Swift host to run (`onCallReceived -> RemoteToolExecutor -> runBridgeMethod`). So routing an in-process
call "through the gateway" would be:

```
port JS (in host) -> serialize -> WS/loopback -> gateway subprocess -> route ->
back to the SAME host -> runBridgeMethod -> execute
```

Two process hops and a serialization boundary to reach a function already in the calling process. It
buys no additional unification, because the convergence already exists at the registry (section 0),
below the transport. What it costs:

- **Latency**, worst for streaming (every `ai.complete` token round-tripping a subprocess).
- **A process dependency**: the app's own ports and companions would break whenever the gateway
  subprocess is down. Today the in-process paths work regardless.
- **A serialization wall some methods cannot cross**: `port.exec` runs JS on a live `WKWebView`, the
  suspend guard reads a live `PortBridge`, `findInlineBridge` returns an in-process object. These act
  on live handles that do not survive JSON, which is exactly why the gateway forwards them back to the
  host instead of executing them.

Decision: converge at the API layer (the registry, done) and keep the transport layer plural. The
in-process path is faster and more robust, and some methods only make sense in-process. Uniform
transport is a different, more expensive design with no offsetting unification gain.
