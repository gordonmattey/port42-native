# Plan: Remote RPC API (Port42 API for CLIs)

**Last updated:** 2026-03-21
**Status:** Implementation in progress

---

## Vision
Allow external tools (CLIs like `yosuelf`, `claude-code`, or OpenClaw agents) to control Port42 Native via the Gateway. This exposes the rich `port42.*` bridge APIs (Terminal, Filesystem, Browser, Camera, AI) to remote peers.

## Architecture

### 1. Protocol Extensions (Wire Format)
We extend the `Envelope` structure to support Request/Response patterns:

```json
{
  "type": "call" | "response",
  "call_id": "uuid",
  "method": "terminal.exec",
  "args": ["ls -la", { "cwd": "/Users/gordon" }],
  "target_id": "peer-uuid", // Required for responses
  "is_host": true | false   // Sent during 'identify'
}
```

### 2. Gateway Routing (Go)
- **Host Identification:** The native macOS app identifies itself with `is_host: true`. The gateway tracks one `host` per channel.
- **Call Routing:** Messages of `type: "call"` are automatically routed to the `host` of the specified `channel_id`.
- **Response Routing:** Messages of `type: "response"` use `target_id` to route back to the original caller.

### 3. Native App Implementation (Swift)
- `SyncService` acts as the RPC dispatcher.
- `onCallReceived` callback maps remote methods to internal bridge logic.
- **Virtual Companion:** Remote CLIs should be treated as "Virtual Companions" so permissions (F-511) can be tracked and persisted.

---

## Implementation Progress

### Phase 1: Gateway & Protocol (COMPLETED)
- [x] Update `Envelope` struct in `gateway/gateway.go`.
- [x] Implement `routeCall` and `routeResponse` in Go.
- [x] Update `Peer` and `Gateway` structs to track hosts.
- [x] Update `SyncEnvelope` in `SyncService.swift`.
- [x] Native app now identifies as `isHost: true`.

### Phase 2: OpenClaw Plugin Upgrade (COMPLETED)
- [x] Update `port42-openclaw` protocol to support `call`/`response`.
- [x] Implement `conn.call()` method in TypeScript.
- [x] Register `port42_tools` plugin in OpenClaw.
- [x] Added tools: `terminal_exec`, `screenshot`, `clipboard_read`, `file_read`, `browser_open`.

### Phase 3: Bridge Wiring (IN PROGRESS)
- [ ] Connect `SyncService.onCallReceived` to `ToolExecutor` or a new `GlobalToolExecutor`.
- [ ] Implement permission prompts for remote calls.
- [ ] Integrate `UserDefaults` "Always Allow" checks into the RPC flow.

### Phase 4: CLI Client (TO DO)
- [ ] Create a standalone `port42-cli` (or update `yosuelf`) to use the new protocol.
- [ ] Support joining channels via invite link.

### Phase 5: Global Instructions & UX (COMPLETED)
- [x] Create `InstructionService.swift` to manage `~/.claude/CLAUDE.md` and `~/.gemini/GEMINI.md`.
- [x] Add "Upgrade Plugin" capability to `OpenClawService.swift`.
- [x] Add "Global CLI Instructions" section to `OpenClawSheet.swift`.
- [x] Add "Remote Access" permission toggles to `SignOutSheet.swift`.

---

## Security Considerations
- **Authentication:** Remote calls must only be accepted from authenticated peers (via Apple Enclave or shared token).
- **Permissions:** Every sensitive API must be gated by the same user-approval flow used for inline Ports.
- **Scoping:** Remote FS access should be restricted to the "picked" directory if applicable, or require explicit full-disk permission.
