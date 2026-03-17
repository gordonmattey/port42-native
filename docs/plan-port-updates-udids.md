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

Companions can update existing ports by reference. The update works whether the
port is inline in chat, floating in a window, or minimized in the background.
Every port has a stable UDID that persists across its lifecycle.

---

## User Flow

```
User: "update the dashboard to show weekly instead of daily"
                    │
Companion checks recent ports (last 5 messages)
                    │
    ┌───────────────┼───────────────┐
    │               │               │
 One recent      Multiple recent   No recent
 port            ports              ports
    │               │               │
 Update it       Match by title    Create new
                 or context        port
                    │
                 Still ambiguous?
                    │
                 Ask which one
                    │
Companion emits ```port id="<UDID>"
<updated HTML>
```
                    │
    ┌───────────────┼───────────────┐
    │               │               │
 Inline          Windowed        Minimized
    │               │               │
 Replace HTML    Replace HTML    Update saved
 in same msg     preserve pos    HTML
 no new message  and size
                    │
    Analytics: port_updated event
```

## Port Fence Syntax

Current:
```
```port
<title>dashboard</title>
<div>...</div>
```

Updated (backward compatible):
```
```port id="abc-123"
<title>dashboard</title>
<div>...</div>
```

The `id="<UDID>"` after `port` is optional metadata. If present, Port42 looks
for an existing port with that UDID and updates it. If absent, a new UDID is
assigned (new port).

## UDID Assignment

- Every port gets a UDID when first created (UUID string)
- Stored in: message content (in the fence metadata), port_panels table, PortPanel struct
- Accessible via: `port42.port.info().id` from JS inside the port
- Companions learn the UDID from tool use: `port42.ports.list()` returns UDIDs
- Title-based fallback: if companion doesn't know the UDID, title matching works
  (same as terminal_send today)

## Migration

Existing ports have no UDID. Handle gracefully:
- Ports without UDID in the database get one assigned on first load
- The UDID is written back to the port_panels row
- Message content is NOT retroactively modified (too risky)
- Old ports work fine, they just can't be updated by reference until
  they're popped out (which creates a panel with a UDID)

## What Changes

### 1. Port fence parser

Modify the regex/parser that detects ` ```port ` fences to also extract
optional `id="..."` metadata.

**File:** `ConversationContent.swift` (or wherever port fences are parsed)

### 2. PortPanel gets a UDID

Add `udid: String` to PortPanel struct. Generated on creation. Persisted in
port_panels table.

**Files:** `PortWindowManager.swift`, `DatabaseService.swift` (migration)

### 3. Port update logic

When a new port fence has an `id="..."` that matches an existing port:
- **Inline:** replace the HTML in the message, re-render the webview
- **Windowed:** reload the webview with new HTML, keep position/size
- **Minimized:** update stored HTML, apply on next open

If no match found, create new port as usual.

**Files:** `PortWindowManager.swift`, `ConversationContent.swift`

### 4. Companion context

Companions need to know port UDIDs to reference them. Two ways:
- Tool use: `terminal_list` already returns port names. Add a `ports_list`
  tool that returns `[{udid, title, status, createdBy}]`
- System prompt: mention that ports can be updated by including the id

**Files:** `ToolDefinitions.swift`, `ToolExecutor.swift`, `AppState.swift` (system prompt)

### 5. JS bridge

`port42.port.info()` returns `{id: "<UDID>", title: "..."}` so ports know
their own identity.

**File:** `PortBridge.swift`

### 6. Analytics

New event: `port_updated`
- Properties: portId (UDID), companion name, channel/swim, update method
  (inline/windowed/minimized)

Distinguish from `port_created` so we can track iteration patterns.

**File:** `Analytics.swift`

### 7. Database migration

Add `udid TEXT` column to `port_panels` table. Backfill existing rows with
generated UUIDs on migration.

**File:** `DatabaseService.swift`

## Build Order

```
Step 1: UDID on PortPanel + DB migration          → every port has an ID
Step 2: Port fence parser extracts id="..."        → companions can reference ports
Step 3: Port update logic (inline + windowed)      → updates work
Step 4: ports_list tool + companion context         → companions know UDIDs
Step 5: JS bridge port42.port.info().id             → ports know themselves
Step 6: Analytics port_updated event                → track iteration
```

## Verification

1. Companion creates a port (gets UDID assigned)
2. User: "update that port to add a search bar"
3. Companion emits ```port id="<same-udid>" with updated HTML
4. Inline port updates in place (no new message)
5. Pop out the port to a window
6. User: "now add dark mode"
7. Companion emits another update
8. Windowed port reloads with new HTML, same position/size
9. Check analytics: port_created (1) + port_updated (2)
10. Restart app, check port still has its UDID
11. Old ports without UDIDs still work (graceful migration)
