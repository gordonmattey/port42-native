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

## Components Changed

| Component | File(s) | What changes |
|---|---|---|
| **PortPanel struct** | `PortWindowManager.swift` | Add `udid: String` field |
| **Database** | `DatabaseService.swift` | New migration: `udid` column on `port_panels`, backfill existing rows |
| **Inline port tracking** | `ConversationContent.swift` | Assign UDIDs to inline ports on render, maintain lookup table |
| **Port update tool** | `ToolDefinitions.swift`, `ToolExecutor.swift` | New `port_update(id, html)` tool definition + executor |
| **Ports list tool** | `ToolDefinitions.swift`, `ToolExecutor.swift` | New `ports_list()` tool definition + executor |
| **Port update logic** | `PortWindowManager.swift` | New `updatePort(udid:, html:)` method handling inline/windowed/minimized |
| **JS bridge** | `PortBridge.swift` | `port42.port.info()` returns `id` field |
| **API docs** | `ports-context.txt` | Document `ports_list` and `port_update` |
| **System prompt** | `AppState.swift`, `SwimView.swift` | Tell companions about port updates |
| **Analytics** | `Analytics.swift` | New `port_updated` event |

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

---

## Verification

| Test | Steps | Expected |
|---|---|---|
| **UDID assigned on create** | Ask companion to create a port. Call `ports_list`. | Port appears with a UDID and title |
| **ports_list discovery** | Create 3 ports with different titles. Call `ports_list`. | All 3 listed with UDIDs, titles, createdBy |
| **Update inline port** | Create a port. Say "update that port to add a button". Companion calls `port_update`. | Same message re-renders with new HTML. No new message created. |
| **Update windowed port** | Pop out a port. Ask to update it. | Window reloads with new HTML. Position and size preserved. |
| **Update minimized port** | Minimize a port. Ask to update it. Restore it. | Shows updated HTML on restore. |
| **Title fallback** | Ask "update the dashboard" without knowing UDID. | Companion matches by title, updates correct port. |
| **Ambiguous title** | Create two ports named "dashboard". Ask to update "the dashboard". | Companion asks which one or picks most recent. |
| **No match** | Ask to update a port that doesn't exist. | Companion creates a new port instead or says not found. |
| **UDID persists restart** | Create a port, pop out, restart app. Call `ports_list`. | Same UDID as before restart. |
| **Migration** | Run on DB with existing ports (no udid column). | Migration adds column, backfills UUIDs. App works. |
| **JS bridge** | Inside a port, call `port42.port.info()`. | Returns `{id: "...", messageId: "...", ...}` |
| **Analytics** | Create a port, then update it twice. Check PostHog. | 1 `port_created` + 2 `port_updated` events |
| **Old ports** | Existing ports from before the update. | Render fine, get UDID on first interaction |
