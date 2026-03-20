# Plan: Swim → Channel Unification

**Status:** Planning
**Goal:** Make swim a special channel type. Single `messages` table, single message flow, unified error display. `SwimSession` and `swimMessages` eliminated.

---

## Background

Currently swim and channels are parallel architectures:

| | Channels | Swim |
|---|---|---|
| Messages | `messages` table | `swimMessages` table |
| Model | `Message` struct | `SwimMessage` struct |
| Session | `AppState` + `AgentRouter` | `SwimSession` (owns `LLMEngine`) |
| Streaming state | `streamingAgentNames` on AppState | `isStreaming` on SwimSession |
| Error state | none | `@Published error` on SwimSession |
| Stop/retry | none | `stop()` / `retry()` on SwimSession |
| Sync | yes (via SyncService) | never |
| View | `ChatView` + `ChannelHeader` | `SwimView` (custom header) |

A swim is a 1:1 channel between the user and one companion, with sync disabled. The duplication is unnecessary.

---

## Question: Why not keep SwimSession as a thin wrapper?

We shouldn't. SwimSession's responsibilities map cleanly onto existing channel infrastructure:

| SwimSession does | Channel equivalent |
|---|---|
| Owns `LLMEngine` + streams tokens | `AgentRouter` → `LLMEngine` (already does this) |
| `@Published isStreaming` | `AppState.streamingAgentNames` (already keyed by companion) |
| `@Published isTooling` | `AppState.toolingAgentNames` (already exists) |
| `@Published error: String?` | Add `@Published channelErrors: [String: String]` to AppState |
| `send()` | `AppState.sendMessage(content:)` (already exists) |
| `stop()` | Add `AppState.cancelStreaming(channelId:)` |
| `retry()` | Add `AppState.retryLastMessage(channelId:)` |
| `chatEntries(userName:)` | `AppState.channelEntries` (already converts `Message` → `ChatEntry`) |

Keeping a wrapper means maintaining two code paths forever. Full elimination is cleaner.

---

## DB Schema Changes

### swimMessages vs messages field mapping

| swimMessages | messages equivalent |
|---|---|
| `id` | `id` |
| `companionId` | `channelId` = `"swim-{companionId}"` |
| `role` = "user" | `senderType` = "human", `senderId` = user.id |
| `role` = "assistant" | `senderType` = "agent", `senderId` = companionId |
| `content` | `content` |
| `timestamp` | `timestamp`, `createdAt` = same value |
| — | `senderName` = displayName (looked up from users/agents) |
| — | `replyToId` = NULL |
| — | `syncStatus` = "local" |

### New columns on `channels`

```sql
syncEnabled INTEGER NOT NULL DEFAULT 1   -- 0 for swim channels, 1 for regular
isSwim      INTEGER NOT NULL DEFAULT 0   -- 1 for swim channels
```

### Swim channel ID convention

`"swim-{companionId}"` — stable, deterministic, no collision with regular UUIDs.

---

## Migration Strategy

Two separate migrations for safety:

### v17-swim-unification

```sql
-- 1. Backup current tables (for rollback / testing)
CREATE TABLE channels_backup_v17 AS SELECT * FROM channels;
CREATE TABLE messages_backup_v17 AS SELECT * FROM messages;
CREATE TABLE swimMessages_backup_v17 AS SELECT * FROM swimMessages;

-- 2. Add new columns to channels
ALTER TABLE channels ADD COLUMN syncEnabled INTEGER NOT NULL DEFAULT 1;
ALTER TABLE channels ADD COLUMN isSwim INTEGER NOT NULL DEFAULT 0;

-- 3. Create swim channel records for each companion that has swim messages
--    (INSERT OR IGNORE so re-running is safe)
INSERT OR IGNORE INTO channels (id, name, type, createdAt, syncEnabled, isSwim)
SELECT
    'swim-' || companionId,
    (SELECT displayName FROM agents WHERE agents.id = swimMessages.companionId),
    'direct',
    MIN(timestamp),
    0,
    1
FROM swimMessages
GROUP BY companionId;

-- 4. Copy swim messages into messages table
INSERT OR IGNORE INTO messages
    (id, channelId, senderId, senderName, senderType, content,
     timestamp, replyToId, syncStatus, createdAt)
SELECT
    sm.id,
    'swim-' || sm.companionId,
    CASE sm.role
        WHEN 'user'      THEN (SELECT id FROM users WHERE isLocal = 1 LIMIT 1)
        WHEN 'assistant' THEN sm.companionId
    END,
    CASE sm.role
        WHEN 'user'      THEN (SELECT displayName FROM users WHERE isLocal = 1 LIMIT 1)
        WHEN 'assistant' THEN (SELECT displayName FROM agents WHERE agents.id = sm.companionId)
    END,
    CASE sm.role
        WHEN 'user'      THEN 'human'
        WHEN 'assistant' THEN 'agent'
    END,
    sm.content,
    sm.timestamp,
    NULL,
    'local',
    sm.timestamp
FROM swimMessages sm;
```

### v18-drop-swim-messages

```sql
-- Only runs after v17 confirmed stable in production
DROP INDEX IF EXISTS idx_swim_messages_companion;
DROP TABLE swimMessages;
```

Keep v17 and v18 as separate registered migrations. Ship v17 first, validate in production, add v18 in a follow-up release. The backup tables (`_backup_v17`) stay in the DB and can be dropped manually once confident.

---

## Model Changes

### Channel

Add two fields:
```swift
var syncEnabled: Bool = true
var isSwim: Bool = false
```

GRDB coding keys updated to include both. `Channel.create(name:)` factory unchanged (defaults to syncEnabled=true, isSwim=false).

Factory for swim channels:
```swift
static func swim(companion: AgentConfig) -> Channel {
    Channel(id: "swim-\(companion.id)", name: companion.displayName,
            type: "direct", syncEnabled: false, isSwim: true)
}
```

### Message

No changes needed — `messages` table already has all required fields.

### Remove SwimMessage

`SwimMessage` struct deleted. All references replaced with `Message`.

---

## AppState Changes

### Remove

- `private var swimSessions: [String: SwimSession]`
- `@Published public var activeSwimSession: SwimSession?`
- `openSwim(companion:)` → replaced
- `closeSwim()` → replaced
- All `swimSessions[...]` access

### Add

```swift
// Per-channel error state (used by swim and eventually regular channels too)
@Published public var channelErrors: [String: String] = [:]

// Cancel in-flight LLM stream for a channel
public func cancelStreaming(channelId: String)

// Retry last user message in a channel
public func retryLastMessage(channelId: String)
```

### openSwim replacement

```swift
public func openSwim(companion: AgentConfig) {
    // Ensure swim channel exists in DB
    let swimChannel = Channel.swim(companion: companion)
    try? db.upsertChannel(swimChannel)

    // Select the swim channel (same path as selecting any channel)
    selectChannel(swimChannel.id)

    // Ensure companion is assigned to the swim channel
    try? db.assignAgentToChannel(agentId: companion.id, channelId: swimChannel.id)
}
```

### Streaming/error routing

LLM responses for swim go through `AgentRouter` (same as companions in channels). The existing `streamingAgentNames` / `toolingAgentNames` already handles display. `channelErrors` is set when `AgentRouter` gets an error, cleared on next send.

---

## SyncService Changes

Exclude swim channels from sync:

```swift
// When joining channels on connect:
let syncableChannels = channels.filter { $0.syncEnabled }

// When sending messages:
guard channel.syncEnabled else { return }
```

This is the only SyncService change needed — swim channels simply never participate in WebSocket sync.

---

## View Changes

### SwimView

- Header stays exactly as-is (teal dot, companion name, back button — intentionally simpler than ChannelHeader)
- Body: replace `session.chatEntries(userName:)` with `appState.channelEntries(channelId:)`
- Replace `session.isStreaming` with `appState.streamingAgentNames.contains(companionName)`
- Replace `session.error` with `appState.channelErrors[channelId]`
- Replace `session.send()` with `appState.sendMessage(content:)`
- Replace `session.stop()` with `appState.cancelStreaming(channelId:)`
- Replace `session.retry()` with `appState.retryLastMessage(channelId:)`
- Remove `@ObservedObject var session`

### ChatView

- Pass `appState.channelErrors[channelId]` as `error` to `ConversationContent`
- Pass `onStop` / `onRetry` / `onDismissError` handlers so channel chat gets the same error UI as swim
- This is the error display unification

### ConversationContent

No changes needed — it already supports all these optional callbacks.

---

## Files Touched

| File | Change |
|---|---|
| `DatabaseService.swift` | Add v17, v18 migrations. Add `upsertChannel`. Remove swim-specific methods. |
| `Models/Channel.swift` | Add `syncEnabled`, `isSwim` fields + `swim(companion:)` factory |
| `Models/Message.swift` | No change |
| `Services/AppState.swift` | Remove SwimSession references. Add `channelErrors`, `cancelStreaming`, `retryLastMessage`, new `openSwim` |
| `Services/SyncService.swift` | Filter by `syncEnabled` |
| `Services/AgentRouting.swift` | Ensure swim channel route works (likely no change needed) |
| `Views/SwimView.swift` | Remove SwimSession dependency, wire to channel state |
| `Views/ChatView.swift` | Pass error/stop/retry to ConversationContent |
| `Views/ConversationContent.swift` | No change |
| ~~`SwimSession` (in SwimView.swift)~~ | Deleted |

---

## Rollback

If v17 produces bad state, the backup tables allow recovery:

```sql
-- Restore channels
DELETE FROM channels;
INSERT INTO channels SELECT id, name, type, createdAt FROM channels_backup_v17;

-- Restore messages
DELETE FROM messages;
INSERT INTO messages SELECT * FROM messages_backup_v17;

-- SwimMessages never dropped until v18
-- So swimMessages is still intact for app rollback
```

---

## Ship Order

1. Land v17 migration + model changes + AppState refactor + view changes in one PR
2. Test: open swim, send messages, restart app, verify history loads
3. Test: regular channels unaffected, sync still works
4. Test: swim channels don't appear in sync traffic
5. If stable after one release cycle, add v18 (drop swimMessages) in follow-up PR
6. Backup tables can be dropped manually post-v18 validation
