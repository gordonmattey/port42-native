# Implementation Plan: F-506 Remote Identity + F-509 Sender Attribution

## Problem

In shared channels, there's no way to tell who owns which AI. Two users with
an AI named "Echo" see identical names, colors, and avatars. The AI itself
doesn't know which human sent a message. The channel header only shows
historical senders with no ownership context.

## Design

Add `senderOwner` to the sync wire format. Every synced message carries the
display name of the human who owns the sender. For human messages,
`senderOwner` is empty (the sender IS the owner). For AI messages,
`senderOwner` is the human who runs that AI.

This single field unlocks both features:
- **F-506**: UI displays "Echo · gordon" with colors hashed on name+owner
- **F-509**: LLM context includes `[gordon]: message` for humans

## Implementation Steps

### Step 1: Wire format (SyncService + Gateway)

**SyncService.swift** — Add `senderOwner` to `SyncPayload`:
```swift
public struct SyncPayload: Codable {
    public let senderName: String
    public let senderType: String
    public let content: String
    public let replyToId: String?
    public var encrypted: Bool?
    public var senderOwner: String?  // NEW: owner's display name (nil for humans)
}
```

**gateway/gateway.go** — No changes needed. The gateway forwards encrypted
blobs and doesn't inspect payload fields. New fields pass through transparently.

**Backward compatible**: Old clients without `senderOwner` will decode it as
nil. Old gateways ignore unknown fields in encrypted payloads.

### Step 2: Populate senderOwner on send

**AppState.swift** — In `sendMessage` and `ChannelAgentHandler`, when building
the `SyncPayload` for an AI response, set `senderOwner` to the current user's
display name:

```swift
// For AI messages
payload.senderOwner = appState.currentUser?.displayName

// For human messages
payload.senderOwner = nil  // sender IS the owner
```

### Step 3: Store senderOwner in Message model

**Message.swift** — Add optional `senderOwner: String?` field.

**DatabaseService.swift** — Add migration `v7-sender-owner`:
```swift
migrator.registerMigration("v7-sender-owner") { db in
    try db.alter(table: "messages") { t in
        t.add(column: "senderOwner", .text)
    }
}
```

**SyncService.handleIncomingMessage** — Map `payload.senderOwner` to
`message.senderOwner` when creating the Message from a received envelope.

### Step 4: F-509 — Sender attribution in LLM context

**AppState.swift (ChannelAgentHandler)** — Update message formatting for the
LLM API call:

```swift
// Human messages: include sender name
} else {
    return ["role": "user", "content": "[\(msg.senderName)]: \(msg.content)"]
}

// Other companion messages: include owner
} else if msg.isAgent {
    let owner = msg.senderOwner.map { " (belonging to \($0))" } ?? ""
    return ["role": "user", "content": "(companion \(msg.senderName)\(owner) said): \(msg.content)"]
}
```

Update the system prompt to explain the format:
```
Messages from humans appear as [Name]: message.
Messages from other companions appear as (companion Name said): message.
```

**Test**: Send a message from a remote human, verify the AI addresses them by
name. Send from a remote AI, verify the local AI knows who owns it.

### Step 5: F-506 — Remote identity in UI

**ChatEntry / ConversationContent** — Pass `senderOwner` through to the
message rendering. When `senderOwner` is present, display as
"senderName · senderOwner":

```swift
// Display name logic
var displayName: String {
    if let owner = senderOwner {
        return "\(senderName) · \(owner)"
    }
    return senderName
}
```

**Port42Theme.agentColor** — Hash on `name + owner` instead of just `name`
so "Echo · gordon" and "Echo · alice" get different colors:

```swift
public static func agentColor(for name: String, owner: String? = nil) -> Color {
    let key = owner.map { "\(name)·\($0)" } ?? name
    let hash = key.utf8.reduce(0) { ($0 &+ Int($1)) &* 31 }
    return agentColors[abs(hash) % agentColors.count]
}
```

**ChannelHeader (memberNames)** — Update `getUniqueSenders` to return
`(name, owner, type)` tuples instead of bare strings. Show owner qualifier
for AI members. Distinguish humans from AIs visually.

### Step 6: F-507/F-508 bonus — Mention candidates from history

**ChatView.swift** — Build `mentionCandidates` from both local companions AND
unique senders from message history (already available via `getUniqueSenders`).
This lets users @mention remote humans and their AIs without needing new
gateway protocol.

## Testing with --peer

```bash
./build.sh --run --peer
```

1. Main app: create channel, copy invite link
2. Peer: Cmd+K, paste link, join
3. Main app: send message — peer should see "[gordon]: message"
4. Peer: send message — main should see "[peerName]: message"
5. Main app's Echo responds — peer sees "Echo · gordon" in distinct color
6. Peer's Echo responds — main sees "Echo · peerName" in different color
7. Both AIs address humans by name in their responses

## Migration Safety

- New `senderOwner` column is nullable, so existing messages work fine
- Old clients that don't send `senderOwner` will show names without qualifier
  (same as current behavior, graceful degradation)
- No gateway changes required (encrypted payload passthrough)
