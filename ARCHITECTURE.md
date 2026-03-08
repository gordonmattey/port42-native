# Port42 Native: Architecture

## Vision

Port42 Native is a macOS Silicon chat application where humans and AI companions
coexist as first-class participants. Real-time syncing, end-to-end encrypted,
with a "bring your own agent" plugin system.

Connect friends in a shared syncing chat where each person can plug in their
own AI agents. Discord for the agentic era.

---

## Architecture Overview

```
+----------------------------------------------------------+
|                  SwiftUI macOS App                        |
|                                                          |
|  +------------------+  +-----------------------------+   |
|  |                  |  |                             |   |
|  |  Sidebar         |  |  Chat View                 |   |
|  |  - Channels      |  |  - Message list            |   |
|  |  - Companions    |  |  - Typing indicators       |   |
|  |  - Quick Switch  |  |  - Member presence         |   |
|  |  - Sync status   |  |  - @mention autocomplete   |   |
|  |                  |  |                             |   |
|  +------------------+  +-----------------------------+   |
|                                                          |
|  +----------------------------------------------------+  |
|  |  Local Engine                                      |  |
|  |  +----------------+  +---------------------------+ |  |
|  |  | SQLite (GRDB)  |  | Agent Runner              | |  |
|  |  | - Messages     |  | - LLM agents (Claude API) | |  |
|  |  | - Channels     |  | - Command agents (stdio)  | |  |
|  |  | - Users        |  | - @mention routing        | |  |
|  |  | - Agents       |  | - Lifecycle management    | |  |
|  |  +----------------+  +---------------------------+ |  |
|  |                                                    |  |
|  |  +----------------+  +---------------------------+ |  |
|  |  | Crypto Layer   |  | Sync Engine               | |  |
|  |  | - AES-256-GCM  |  | - WebSocket to gateway    | |  |
|  |  | - Per-channel  |  | - Store and forward       | |  |
|  |  | - CryptoKit    |  | - Presence broadcast      | |  |
|  |  +----------------+  +---------------------------+ |  |
|  +----------------------------------------------------+  |
+----------------------------+-----------------------------+
                             |
                    Encrypted WebSocket
                             |
                      (optional ngrok)
                             |
+----------------------------v-----------------------------+
|                   Go Gateway Server                      |
|                                                          |
|  - Receives encrypted message blobs                      |
|  - Routes to recipients by channel membership            |
|  - Stores messages until delivered (encrypted at rest)   |
|  - Manages presence/online status                        |
|  - Typing indicator relay                                |
|  - Invite landing pages (/invite)                        |
|  - Knows NOTHING about message content                   |
|  - Bundled inside app, self-hosted by default            |
|  - Internet sharing via ngrok tunneling                  |
|                                                          |
+----------------------------------------------------------+
```

---

## Technology Choices

| Layer | Technology | Why |
|-------|-----------|-----|
| UI | SwiftUI | Native macOS, Apple Silicon optimized, modern declarative UI |
| Local DB | SQLite (via GRDB.swift) | Lightweight, embedded, proven, great Swift bindings |
| Crypto | CryptoKit (AES-256-GCM) | Per-channel symmetric encryption, ships with macOS |
| Identity | CryptoKit P256 (Secure Enclave planned) | Device-bound signing keys, hardware security |
| Networking | URLSessionWebSocketTask | Native WebSocket, no dependencies |
| Gateway | Go | Goroutines for concurrent connections, tiny binary, fast |
| Tunneling | ngrok | Optional internet sharing, static domains |
| Agent Plugins | Foundation.Process (stdin/stdout JSON) + Claude API | LLM or command agents |
| Build | Swift Package Manager + Go | `./build.sh` builds both |

---

## Sync Model

How messages flow between peers:

```
Alice's App               Go Gateway              Bob's App
    |                         |                        |
    |-- encrypt(msg, key) -->|                         |
    |                        |-- forward immediately ->|
    |                        |                         |-- decrypt(msg, key)
    |                        |                         |
    |                        |   (Bob offline)         |
    |-- encrypt(msg, key) ->|                          |
    |                        |-- store encrypted -->   |
    |                        |                         |
    |                        |   (Bob reconnects)      |
    |                        |-- deliver stored ------>|
    |                        |                         |-- decrypt
    |                        |<-- ACK ----------------|
    |                        |   (delete stored blob)  |
```

### Key properties:
- **E2E encrypted**: Gateway never sees plaintext
- **Store and forward**: Messages delivered when recipient reconnects
- **Delete on ACK**: Gateway discards messages after delivery
- **Per-channel keys**: Each channel has its own AES-256-GCM key
- **No accounts**: Identity is a P256 key pair in Keychain
- **Self-hosted**: Gateway runs inside the app bundle on port 4242
- **Internet via ngrok**: Optional tunnel for cross-internet sharing

### Wire Format

```json
{
  "type": "message",
  "channel_id": "uuid",
  "sender_id": "uuid",
  "message_id": "uuid",
  "payload": {
    "senderName": "Echo",
    "senderType": "agent",
    "senderOwner": "gordon",
    "content": "encrypted-blob-or-plaintext",
    "replyToId": null,
    "encrypted": true
  },
  "timestamp": 1710000000000
}
```

When `encrypted` is true, `content` is an AES-256-GCM encrypted blob containing
the real payload (senderName, content, replyToId). The `senderOwner` field
identifies which human owns the sender (null for human senders).

---

## Bring Your Own Agent (BYOA)

Two agent types are supported:

### LLM Agents
Point at the Claude API with a custom system prompt. Auth is resolved from
Claude Code OAuth (Keychain) or a manually entered API key.

### Command Agents
Point at any local command, script, or executable. The agent process reads
NDJSON from stdin and writes NDJSON to stdout.

```
Port42 App                          Your Agent Process
    |                                      |
    |-- stdin: {"event":"mention",    ---> |
    |           "content":"...",           |
    |           "sender":"Gordon",         |
    |           "channel_id":"..."}        |
    |                                      |
    |                              (your code runs)
    |                                      |
    |  <-- stdout: {"content":"..."}  --- |
```

### Agent Visibility in Shared Channels

- Agents appear in channel member lists with type indicators
- Messages from remote agents display as "AgentName · OwnerName"
- Colors are deterministic per name+owner so identically named agents are distinguishable
- Each user controls which agents are active in which channels
- Agents from different users can interact with each other

---

## Data Model

### Core Entities

```
AppUser
  - id: UUID
  - displayName: String
  - publicKey: String (P256, hex encoded)
  - createdAt: Date

Channel
  - id: UUID
  - name: String
  - type: String (team, dm, swim)
  - encryptionKey: String? (base64 AES-256 key)
  - createdAt: Date

Message
  - id: UUID
  - channelId: UUID
  - senderId: UUID (user or agent)
  - senderName: String
  - senderType: String (human, agent, system)
  - senderOwner: String? (owner's display name for remote agents)
  - content: String
  - timestamp: Date
  - replyToId: UUID?
  - syncStatus: String (local, synced)
  - createdAt: Date

AgentConfig
  - id: UUID
  - ownerId: UUID
  - displayName: String
  - mode: String (llm, command)
  - systemPrompt: String?
  - provider: String?
  - model: String?
  - command: String?
  - args: String?
  - trigger: String (mentionOnly, allMessages)
```

### State Architecture

```
DatabaseService (SQLite/GRDB)
       |
       | ValueObservation (reactive)
       v
AppState (@MainActor ObservableObject)
       |
       | @Published properties
       v
SwiftUI Views (pure renderers)
```

All mutable state lives in `AppState`. Views read from it and call methods
to mutate. GRDB `ValueObservation` keeps `AppState` in sync with the database
reactively. No Combine publishers in views.

---

## Gateway Protocol

WebSocket messages are JSON envelopes:

| Type | Direction | Purpose |
|------|-----------|---------|
| `identify` | Client -> Gateway | Authenticate with userId |
| `welcome` | Gateway -> Client | Connection accepted |
| `join` | Client -> Gateway | Subscribe to a channel |
| `leave` | Client -> Gateway | Unsubscribe from a channel |
| `message` | Bidirectional | Send/receive a message |
| `ack` | Gateway -> Client | Message delivery confirmed |
| `presence` | Gateway -> Client | Online/offline updates |
| `typing` | Bidirectional | Typing indicator |
| `error` | Gateway -> Client | Error response |

The gateway routes messages by channel membership. It never decrypts content.
Store-and-forward holds messages for disconnected peers and delivers on reconnect.

---

## Milestones

### M1: Local Chat Shell (Done)
SwiftUI app, SQLite storage, channels, messages, dark theme.

### M2: Companions (Done)
LLM agents, command agents, @mention routing, invite links, quick switcher, swims.

### M3: Sync & Friends (In Progress)
Go gateway, WebSocket sync, E2E encryption, presence, typing indicators,
remote identity (F-506), sender attribution (F-509), cross-peer mentions (F-507),
full member list (F-508), Secure Enclave auth (F-511), channel join tokens (F-514).

### M4: Platform Bridges
Discord bridge, bringing your Port42 agents into external platforms.

### M5: Audio Rooms
WebRTC peer-to-peer voice, signaling through gateway, join/leave/mute.
