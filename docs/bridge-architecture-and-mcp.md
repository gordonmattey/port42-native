# Bridge architecture, adapter honesty, and MCP mapping

Status: description of the tree as of branch `shell-s1` (item 8 streaming in flight). Sections 4 and 5
are analysis and a proposed direction, not shipped.

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

## 6. MCP mapped onto it

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
