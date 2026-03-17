# Implementation Plan: Port Updates & UDIDs

**Features:** P-204 (Port Update), P-208 (Port UDIDs), P-211 (Inline Port Update)

**Last updated:** 2026-03-16

---

## Problem

Ports are write-once. When a companion wants to improve a port, it creates a new
message with a new port. The old one stays in the conversation, cluttering it.
There's no way to say "update the dashboard" and have the existing port change.

Ports also have no stable identity. A popped-out port loses connection to the
message it came from. There's no way to reference "this specific port" across
the system.

## Goal

Companions can update existing ports by reference using a tool call. The update
works whether the port is inline in chat, floating in a window, or minimized in
the background. Every port has a stable UDID that persists across its lifecycle.

---

## API Changes

### Creating a port — NO CHANGE

Companion emits a ` ```port ` fence in conversation as today. Port42 assigns
a UDID automatically on creation. The fence syntax does not change.

### Updating a port — NEW TOOL

```
port_update(id, html)
```

Companion calls `port_update` with the port's UDID and new HTML. Port42 finds
the port (inline, windowed, or minimized) and replaces its HTML.

Title-based fallback: if companion passes a title string instead of a UDID,
Port42 matches by title (same pattern as terminal_send).

### Discovering ports — NEW TOOL

```
ports_list() → [{id, title, status, createdBy}]
```

Returns all active ports so companions know what exists and can reference by UDID.

### JS bridge — ADDITION

`port42.port.info()` gains `id` field:
```javascript
{ id: "abc-123", messageId: "msg-456", createdBy: "sage", channelId: "ch-789" }
```

So a port can know its own UDID.

### What doesn't change

- Port fence syntax (no metadata in the fence)
- Creating ports via conversation
- Port permissions
- Port persistence/restart behavior

---

## User Flow

```
User: "update the dashboard to show weekly instead of daily"
                    │
Companion calls ports_list() to find the dashboard
                    │
    ┌───────────────┼───────────────┐
    │               │               │
 Found by         Multiple         Not found
 title/UDID       matches
    │               │               │
 Call             Ask which one    Create new
 port_update()                    port instead
    │
    ├── Inline: replace HTML in message, re-render webview
    ├── Windowed: reload webview with new HTML, keep position/size
    └── Minimized: update stored HTML, apply on next open
    │
    Analytics: port_updated event
```

---

## UDID Assignment

- Every port gets a UDID when first created (UUID string)
- Stored in: port_panels table, PortPanel struct, inline port state
- Accessible via: `port42.port.info().id` from JS inside the port
- Companions learn UDIDs from `ports_list` tool
- Title-based fallback when companion doesn't know the UDID

## Migration

Existing ports have no UDID. Handle gracefully:
- Ports without UDID in the database get one assigned on first load
- The UDID is written back to the port_panels row
- Inline ports (not yet popped out) get UDIDs assigned when first rendered
- Old ports work fine, they just can't be updated by reference until
  they get a UDID assigned

---

## What Changes

### 1. PortPanel gets a UDID

Add `udid: String` to PortPanel struct. Generated on creation. Persisted in
port_panels table.

**Files:** `PortWindowManager.swift`, `DatabaseService.swift` (migration)

### 2. Inline ports get UDIDs

When a port fence is first rendered inline, assign a UDID and track it in
a lookup table (messageId → UDID, title → UDID). This allows port_update
to find inline ports that haven't been popped out yet.

**File:** `ConversationContent.swift`

### 3. port_update tool

New tool definition and executor. Takes `id` (UDID or title) and `html`.
Finds the port across all states (inline, windowed, minimized) and replaces
its HTML.

- **Inline:** update the message content in the database, trigger re-render
- **Windowed:** call `webView.loadHTMLString()` with new HTML, keep window
- **Minimized:** update stored HTML in port_panels, apply on restore

**Files:** `ToolDefinitions.swift`, `ToolExecutor.swift`, `PortWindowManager.swift`

### 4. ports_list tool

New tool that returns all active ports with their UDIDs, titles, and status.

**Files:** `ToolDefinitions.swift`, `ToolExecutor.swift`

### 5. JS bridge update

`port42.port.info()` returns `id` field with the port's UDID.

**File:** `PortBridge.swift`

### 6. Companion context

Update system prompt to tell companions they can update ports:
- Use `ports_list` to discover existing ports
- Use `port_update(id, html)` to update one
- Don't create a new port when updating would be better

**Files:** `AppState.swift` (system prompt), `ports-context.txt`

### 7. Analytics

New event: `port_updated`
- Properties: portId (UDID), companion name, channel/swim, port state
  (inline/windowed/minimized)

Distinguish from existing `port_created` to track iteration patterns.

**File:** `Analytics.swift`

### 8. Database migration

Add `udid TEXT` column to `port_panels` table. Backfill existing rows with
generated UUIDs on migration.

**File:** `DatabaseService.swift`

---

## Build Order

```
Step 1: UDID on PortPanel + DB migration          → every port has an ID
Step 2: Inline port UDID tracking                  → inline ports are addressable
Step 3: ports_list tool                            → companions can discover ports
Step 4: port_update tool                           → companions can update ports
Step 5: JS bridge port42.port.info().id            → ports know themselves
Step 6: Companion context + system prompt          → companions know about updates
Step 7: Analytics port_updated event               → track iteration
```

## Verification

1. Companion creates a port (gets UDID assigned)
2. Call `ports_list` — port appears with UDID and title
3. User: "update that port to add a search bar"
4. Companion calls `port_update(id, newHtml)`
5. Inline port updates in place (no new message)
6. Pop out the port to a window
7. User: "now add dark mode"
8. Companion calls `port_update(id, newHtml)` again
9. Windowed port reloads with new HTML, same position/size
10. Check analytics: port_created (1) + port_updated (2)
11. Restart app, port still has its UDID
12. Old ports without UDIDs still work (graceful migration)
