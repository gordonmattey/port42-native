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

## Why not keep SwimSession as a thin wrapper?

SwimSession's responsibilities map cleanly onto existing channel infrastructure:

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

Keeping a wrapper means maintaining two code paths forever for no benefit.

---

## DB Schema

### New columns on `channels`

```sql
syncEnabled INTEGER NOT NULL DEFAULT 1   -- 0 for swim channels, 1 for regular
isSwim      INTEGER NOT NULL DEFAULT 0   -- 1 for swim channels
```

### Swim channel ID convention

`"swim-{companionId}"` — stable, deterministic, no collision with regular UUIDs.

### swimMessages → messages field mapping

| swimMessages | messages |
|---|---|
| `id` | `id` |
| `companionId` | `channelId` = `"swim-{companionId}"` |
| `role` = "user" | `senderType` = "human", `senderId` = local user id |
| `role` = "assistant" | `senderType` = "agent", `senderId` = companionId |
| `content` | `content` |
| `timestamp` | `timestamp` + `createdAt` |
| — | `senderName` = looked up from users/agents |
| — | `replyToId` = NULL |
| — | `syncStatus` = "local" |

---

## Steps (each independently testable)

### Step 1 — v17 Migration

**Files:** `DatabaseService.swift` only

**What changes:**
- Register `"v17-swim-unification"` migration:
  1. Create backup tables: `channels_backup_v17`, `messages_backup_v17`, `swimMessages_backup_v17`
  2. Add `syncEnabled` (default 1) and `isSwim` (default 0) columns to `channels`
  3. Insert swim channel records into `channels` for each companionId in `swimMessages` (INSERT OR IGNORE, type = "direct", syncEnabled = 0, isSwim = 1)
  4. Copy all `swimMessages` rows into `messages` (role → senderType/senderId mapping above)
- `swimMessages` table left intact (not dropped until Step 6)

**Nothing else changes.** App behaviour is identical to before — `SwimSession` still reads from `swimMessages`, channels still use `messages`. The migration just prepares the data.

**How to test:**
- Run app, open any DB browser (e.g. DB Browser for SQLite at `~/Library/Application Support/Port42/port42.sqlite`)
- Verify `channels_backup_v17`, `messages_backup_v17`, `swimMessages_backup_v17` exist with correct row counts
- Verify swim channel rows exist in `channels` (id = `"swim-{companionId}"`, isSwim = 1, syncEnabled = 0)
- Verify swim messages copied into `messages` with correct channelId, senderType, content
- Verify existing channels and messages unaffected
- Verify swim still works end-to-end (still reading from old `swimMessages` path — no regression)

---

### Step 2 — Channel model + SyncService filter

**Files:** `Models/Channel.swift`, `Services/SyncService.swift`

**What changes:**

`Channel` gains two new fields:
```swift
var syncEnabled: Bool = true
var isSwim: Bool = false
```
GRDB coding keys updated. `Channel.swim(companion:)` factory added:
```swift
static func swim(companion: AgentConfig) -> Channel {
    Channel(id: "swim-\(companion.id)", name: companion.displayName,
            type: "direct", syncEnabled: false, isSwim: true)
}
```

`SyncService` filters by `syncEnabled` when joining channels on connect and when routing outbound messages:
```swift
let syncableChannels = channels.filter { $0.syncEnabled }
```

**How to test:**
- Run app — all existing channels still sync normally
- Swim channels (now in `channels` table from Step 1) do not appear in WebSocket sync traffic (check gateway logs)
- New swim channel records load correctly via `DatabaseService.getChannels()`
- Swim still works end-to-end (still on old `SwimSession` path — no regression)

---

### Step 3 — AppState additions (additive only, nothing removed)

**Files:** `Services/AppState.swift`

**What changes:**

Add alongside existing state — nothing removed yet:
```swift
@Published public var channelErrors: [String: String] = [:]

public func cancelStreaming(channelId: String) {
    // cancel the active LLMEngine for companions in this channel
}

public func retryLastMessage(channelId: String) {
    // re-send the last user message in the channel
}
```

Also add `upsertChannel` to `DatabaseService` if not already present (needed for Step 4's `openSwim` replacement).

**How to test:**
- Build succeeds, no existing behaviour changes
- `channelErrors`, `cancelStreaming`, `retryLastMessage` exist and are callable
- Swim and channels both work as before

---

### Step 4 — Rewire SwimView + remove SwimSession (atomic)

**Files:** `Views/SwimView.swift`, `Services/AppState.swift`

This is the only step that must be done atomically — `SwimSession` is deleted and `SwimView` rewired in the same commit since they're inseparable.

**What changes:**

`AppState`:
- Remove `private var swimSessions: [String: SwimSession]`
- Remove `@Published public var activeSwimSession: SwimSession?`
- Replace `openSwim(companion:)`:
  ```swift
  public func openSwim(companion: AgentConfig) {
      let swimChannel = Channel.swim(companion: companion)
      try? db.upsertChannel(swimChannel)
      try? db.assignAgentToChannel(agentId: companion.id, channelId: swimChannel.id)
      selectChannel(swimChannel.id)
  }
  ```
- Replace `closeSwim()` with `deselectSwim()` (just deselects the swim channel, same as navigating away)

`SwimView`:
- Remove `@ObservedObject var session: SwimSession`
- Wire to AppState channel state:
  - `session.chatEntries(userName:)` → `appState.channelEntries(channelId: swimChannelId)`
  - `session.isStreaming` → `appState.streamingAgentNames.contains(companion.displayName)`
  - `session.isTooling` → `appState.toolingAgentNames.contains(companion.displayName)`
  - `session.error` → `appState.channelErrors[swimChannelId]`
  - `session.send()` → `appState.sendMessage(content:)`
  - `session.stop()` → `appState.cancelStreaming(channelId: swimChannelId)`
  - `session.retry()` → `appState.retryLastMessage(channelId: swimChannelId)`
  - `session.dismiss error` → `appState.channelErrors[swimChannelId] = nil`

`SwimSession` class and `SwimMessage` struct deleted.

**How to test:**
- Open swim with a companion — header appears, history loads from DB
- Send a message — companion responds, streaming indicator shows
- Stop mid-stream — stops cleanly
- Trigger error (e.g. bad model) — error bar appears with retry button
- Restart app — open swim again, old messages still there
- Regular channels unaffected
- Swim messages no longer written to `swimMessages` table (now writes to `messages`)

---

### Step 5 — Unified error display in ChatView

**Files:** `Views/ChatView.swift`

**What changes:**

Pass the new AppState error state into `ConversationContent` for regular channels too:
```swift
ConversationContent(
    // existing params...
    error: appState.channelErrors[channel.id],
    onStop: { appState.cancelStreaming(channelId: channel.id) },
    onRetry: { appState.retryLastMessage(channelId: channel.id) },
    onDismissError: { appState.channelErrors[channel.id] = nil }
)
```

`ConversationContent` already supports all these — no changes needed there.

**How to test:**
- Trigger an error in a regular channel (e.g. remove API key mid-conversation)
- Verify same error bar + retry/dismiss UI appears as in swim
- Dismiss error — clears correctly
- Retry — re-sends last message

---

### Step 6 — v18 Migration (drop swimMessages)

**Files:** `DatabaseService.swift` only

**What changes:**

Register `"v18-drop-swim-messages"` migration:
```sql
DROP INDEX IF EXISTS idx_swim_messages_companion;
DROP TABLE swimMessages;
```

Ship this as a separate release after Step 4 has been in production for at least one release cycle and confirmed stable.

**How to test:**
- Run app — `swimMessages` table no longer exists
- Swim works correctly (reads from `messages` since Step 4)
- No crash on fresh install (migration skipped cleanly if `swimMessages` never existed)
- Backup tables `_backup_v17` still present (drop manually when fully confident)

---

## Rollback

If v17 produces bad state, backup tables allow recovery before v18 ships:

```sql
DELETE FROM channels WHERE isSwim = 1;  -- remove newly inserted swim channels
DELETE FROM messages WHERE channelId LIKE 'swim-%';  -- remove migrated swim messages
-- swimMessages untouched until v18, so old path still works
```

Full restore if needed:
```sql
DELETE FROM channels; INSERT INTO channels SELECT id, name, type, createdAt FROM channels_backup_v17;
DELETE FROM messages; INSERT INTO messages SELECT * FROM messages_backup_v17;
```

---

## Files Touched Summary

| File | Step | Change |
|---|---|---|
| `DatabaseService.swift` | 1, 3, 6 | v17 migration, upsertChannel, v18 migration |
| `Models/Channel.swift` | 2 | `syncEnabled`, `isSwim`, `swim(companion:)` factory |
| `Services/SyncService.swift` | 2 | Filter by `syncEnabled` |
| `Services/AppState.swift` | 3, 4 | Add channelErrors/cancel/retry, replace openSwim, remove SwimSession refs |
| `Views/SwimView.swift` | 4 | Rewire to AppState, delete SwimSession + SwimMessage |
| `Views/ChatView.swift` | 5 | Pass error/stop/retry to ConversationContent |
| `Views/ConversationContent.swift` | — | No changes needed |
