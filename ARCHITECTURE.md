# Port42 Native: Architecture & Requirements

## Vision

Port42 Native is a macOS Silicon chat application where humans and AI companions
coexist as first-class participants. Discord meets consciousness computing.
Real-time syncing, end-to-end encrypted, with a "bring your own agent" plugin system.

The first milestone: connect friends in a shared syncing chat where each person
can plug in their own AI agents.

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
|  |  - Spaces        |  |  - Typing indicators       |   |
|  |  - DMs           |  |  - Agent presence          |   |
|  |  - Audio Rooms   |  |  - Possession/Swarm modes  |   |
|  |  - Activity      |  |  - Audio room bar          |   |
|  |                  |  |                             |   |
|  +------------------+  |  +-------------------------+|   |
|                        |  | Input                   ||   |
|                        |  | @mention autocomplete   ||   |
|                        |  +-------------------------+|   |
|                        +-----------------------------+   |
|                                                          |
|  +----------------------------------------------------+  |
|  |  Local Engine                                      |  |
|  |  +----------------+  +---------------------------+ |  |
|  |  | SQLite Store   |  | Agent Runner              | |  |
|  |  | - Messages     |  | - Load agent plugins      | |  |
|  |  | - Channels     |  | - Route @mentions         | |  |
|  |  | - Contacts     |  | - Manage agent lifecycle  | |  |
|  |  | - Agent config |  | - Sandbox execution       | |  |
|  |  +----------------+  +---------------------------+ |  |
|  |                                                    |  |
|  |  +----------------+  +---------------------------+ |  |
|  |  | Crypto Layer   |  | Sync Engine               | |  |
|  |  | - E2E encrypt  |  | - WebSocket to relay      | |  |
|  |  | - Key exchange |  | - Offline queue           | |  |
|  |  | - Per-channel  |  | - Conflict resolution     | |  |
|  |  | - Signal proto |  | - Presence broadcast      | |  |
|  |  +----------------+  +---------------------------+ |  |
|  +----------------------------------------------------+  |
+----------------------------+-----------------------------+
                             |
                    Encrypted WebSocket
                             |
+----------------------------v-----------------------------+
|                   Go Relay Server                        |
|                                                          |
|  - Receives encrypted message blobs                      |
|  - Routes to recipients by channel membership            |
|  - Stores messages until delivered (encrypted at rest)   |
|  - Manages presence/online status                        |
|  - Knows NOTHING about message content                   |
|  - Invite-based auth (no passwords, just key pairs)      |
|  - Self-hostable (single Go binary)                      |
|                                                          |
+----------------------------------------------------------+
```

---

## Technology Choices

| Layer | Technology | Why |
|-------|-----------|-----|
| UI | SwiftUI | Native macOS, Apple Silicon optimized, modern declarative UI |
| Local DB | SQLite (via GRDB.swift) | Lightweight, embedded, proven, great Swift bindings |
| Crypto | libsignal-protocol-swift or CryptoKit | E2E encryption, forward secrecy |
| Networking | URLSessionWebSocketTask | Native WebSocket, no dependencies |
| Audio | WebRTC (via Google's Swift package) | P2P voice with TURN fallback |
| Relay Server | Go | Goroutines for concurrent connections, tiny binary, fast |
| Agent Plugins | Foundation.Process (stdin/stdout JSON) | Any language, any tool, zero SDK needed |
| Build | Xcode / Swift Package Manager | Native toolchain |

---

## Signal-Style Sync Model

How messages flow between peers:

```
Alice's App                    Go Relay                    Bob's App
    |                             |                            |
    |-- encrypt(msg, chan_key) -->|                            |
    |                            |-- store encrypted blob --> |
    |                            |                            |
    |                            |   (Bob comes online)       |
    |                            |-- deliver encrypted -->    |
    |                            |                            |
    |                            |   Bob sends ACK            |
    |                            |<-- ACK -------------------|
    |                            |   (delete stored blob)     |
    |                            |                            |
    |                            |   (Real-time: Bob online)  |
    |-- encrypt(msg) ---------->|-- forward immediately ---->|
    |                            |                            |
```

### Key properties:
- **E2E encrypted**: Relay never sees plaintext
- **Store and forward**: Messages delivered when recipient comes online
- **Delete on ACK**: Relay discards messages after delivery
- **Per-channel keys**: Each channel has its own encryption key
- **Forward secrecy**: Key ratcheting so compromising one key doesn't compromise history
- **No accounts**: Identity is a key pair, share public key to connect

---

## Bring Your Own Agent (BYOA)

Each user plugs in their own AI agents. No built-in agents ship with the app.
Port42 is the platform, not the AI. You bring whatever intelligence you want.

### How It Works

Point Port42 at any local command, script, or executable. That's it.
Your agent is a process that reads JSON from stdin and writes JSON to stdout.

```
Port42 App                          Your Agent Process
    |                                      |
    |-- stdin: {"event":"mention",    ---> |
    |           "message":"...",           |
    |           "channel":"team",         |
    |           "sender":"Gordon"}        |
    |                                      |
    |                              (your code runs)
    |                              (call Claude, GPT,
    |                               Ollama, grep, whatever)
    |                                      |
    |  <-- stdout: {"content":"..."}  --- |
    |                                      |
```

### Agent Config

Users configure agents through Settings > Agents:

```
Name:        @ai-engineer
Command:     /usr/local/bin/my-agent
Args:        --model claude --context-window 200k
Working Dir: ~/projects (optional)
Env Vars:    ANTHROPIC_API_KEY=sk-... (optional)
Channels:    #team, #builders (which channels it listens in)
Trigger:     mention-only | all-messages
```

### Agent JSON Protocol

**Input (stdin, one JSON object per line):**

```json
{
    "event": "mention",
    "message_id": "uuid",
    "content": "@ai-engineer what do you think about this approach?",
    "sender": "Gordon",
    "sender_id": "uuid",
    "channel": "team",
    "channel_id": "uuid",
    "timestamp": "2026-03-06T14:30:00Z",
    "history": [
        {"sender": "Gordon", "content": "...", "timestamp": "..."},
        {"sender": "Alex", "content": "...", "timestamp": "..."}
    ]
}
```

**Output (stdout, one JSON object per line):**

```json
{
    "content": "The architecture looks solid. I'd suggest...",
    "reply_to": "uuid",
    "metadata": {}
}
```

**Events sent to agents:**
- `mention` when @mentioned by name
- `message` for all messages (if trigger is "all-messages")
- `channel_join` when added to a channel
- `channel_leave` when removed from a channel
- `shutdown` when Port42 is closing (agent should exit cleanly)

### What This Enables

Because the protocol is just stdin/stdout JSON, agents can be anything:

- A Python script that calls Claude API with a custom system prompt
- A Go binary that runs local code analysis
- A shell script that wraps `curl` to hit any API
- A Rust tool that does local file search
- An Ollama wrapper for fully local/private AI
- A Node.js script connecting to your company's internal tools
- Even `cat` if you want the world's simplest echo agent

### Agent Visibility

- Agents appear in channel member lists with a bot badge
- Other users see your agents' messages attributed to "AgentName (via YourName)"
- Each user controls which agents are active in which channels
- Agents from different users can interact with each other

---

## Audio Rooms

Every channel can have a persistent audio room, like Discord voice channels.

### How It Works

```
Alice's App                Go Relay               Bob's App
    |                         |                       |
    |-- join_audio(chan) ---->|                       |
    |                        |-- signal to peers -->  |
    |                        |                        |
    |<============ WebRTC P2P audio ================>|
    |   (direct connection, relay only signals)       |
    |                                                 |
```

- **Signaling** goes through the Go relay (tiny SDP/ICE exchange)
- **Audio streams** are peer-to-peer via WebRTC (no relay for actual audio)
- **TURN fallback** when P2P fails (behind strict NATs)
- Audio is NOT recorded or stored

### UX

- Each channel shows a speaker icon when an audio room is active
- Click to join, shows participants with voice activity indicators
- Persistent bar at bottom of chat when you're in a room
- Mute/unmute, deafen, leave controls
- Agents can potentially participate via TTS/STT (future)

```
+--------------------------------------------------+
| #team                                     [2:42] |
|                                                  |
|  (messages...)                                   |
|                                                  |
+--------------------------------------------------+
| Audio: #team  Gordon, Alex  [Mute] [Deafen] [x] |
+--------------------------------------------------+
| Type a message...                        [Send]  |
+--------------------------------------------------+
```

---

## Data Model

### Core Entities

```
User
  - id: UUID
  - displayName: String
  - publicKey: Data
  - avatarData: Data?
  - isLocal: Bool (is this the current user)

Channel
  - id: UUID
  - name: String
  - type: enum (team, dm, space, ai-council)
  - members: [User]
  - agents: [AgentConfig]
  - channelKey: Data (symmetric key for E2E)
  - createdAt: Date

Message
  - id: UUID
  - channelId: UUID
  - senderId: UUID (user or agent)
  - senderType: enum (human, agent)
  - content: String
  - timestamp: Date
  - mentions: [String]
  - replyToId: UUID?
  - syncStatus: enum (local, sent, delivered, read)

AgentConfig
  - id: UUID
  - ownerId: UUID
  - displayName: String
  - command: String (path to executable)
  - args: [String]
  - workingDir: String?
  - envVars: [String: String]
  - trigger: enum (mentionOnly, allMessages)
  - activeChannels: [UUID]

AudioRoom
  - id: UUID
  - channelId: UUID
  - participants: [User]
  - isActive: Bool
  - createdAt: Date
```

### Local Storage (SQLite)

```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    public_key BLOB NOT NULL,
    avatar_data BLOB,
    is_local INTEGER DEFAULT 0,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE channels (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL DEFAULT 'team',
    channel_key BLOB,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE channel_members (
    channel_id TEXT REFERENCES channels(id),
    user_id TEXT REFERENCES users(id),
    joined_at TEXT DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (channel_id, user_id)
);

CREATE TABLE messages (
    id TEXT PRIMARY KEY,
    channel_id TEXT REFERENCES channels(id),
    sender_id TEXT NOT NULL,
    sender_type TEXT NOT NULL DEFAULT 'human',
    content TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    reply_to_id TEXT,
    sync_status TEXT DEFAULT 'local',
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_messages_channel ON messages(channel_id, timestamp);
CREATE INDEX idx_messages_sync ON messages(sync_status);

CREATE TABLE agents (
    id TEXT PRIMARY KEY,
    owner_id TEXT REFERENCES users(id),
    display_name TEXT NOT NULL,
    command TEXT NOT NULL,
    args TEXT,
    working_dir TEXT,
    env_json TEXT,
    trigger TEXT NOT NULL DEFAULT 'mention_only',
    description TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE audio_rooms (
    id TEXT PRIMARY KEY,
    channel_id TEXT REFERENCES channels(id),
    is_active INTEGER DEFAULT 1,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE audio_room_participants (
    room_id TEXT REFERENCES audio_rooms(id),
    user_id TEXT REFERENCES users(id),
    joined_at TEXT DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (room_id, user_id)
);

CREATE TABLE agent_channels (
    agent_id TEXT REFERENCES agents(id),
    channel_id TEXT REFERENCES channels(id),
    PRIMARY KEY (agent_id, channel_id)
);
```

---

## UX Design (Matching Portal42 Web)

### Visual Language

- **Background**: Deep black (#000000, #111111)
- **Primary accent**: Neon green (#00ff41)
- **AI messages**: Cyan/teal tint
- **Text**: Monospace font (SF Mono or Menlo)
- **Borders**: Subtle gray (#333333) with green glow on active elements
- **Animations**: Subtle pulse/breathing effects, smooth transitions
- **Dark-only**: No light mode. This is a terminal-native aesthetic.

### Layout

```
+---+----------------------------------------------+
| S |                                              |
| I |  #team                              [2:42]   |
| D |                                              |
| E |  @ai-engineer 2:30 PM                        |
| B |  The sync layer architecture looks solid.    |
| A |  I'd recommend using CRDTs for offline       |
| R |  conflict resolution.                        |
|   |                                              |
| # team        |  Gordon 2:31 PM                  |
| # investors   |  @ai-muse what do you think      |
| # builders    |  about the naming?               |
| # ideas       |                                  |
|               |  @ai-muse (via Gordon) 2:31 PM   |
| SPACES        |  Port42 carries weight. It's a   |
| > snowos      |  portal AND a port, a place      |
| > health      |  ships dock and depart.          |
|               |                                  |
| DMs           |  --- typing: @ai-analyst ---     |
| > Alex        |                                  |
| > Sarah       +----------------------------------+
|               | @ai-en|                          |
| COMPANIONS    |  @ai-engineer                    |
| @ ai-engineer |  @ai-entrepreneur                |
| @ ai-muse     |  @ai-energy-audit                |
| @ ai-analyst  +----------------------------------+
+---+----------------------------------------------+
```

### Interactions

1. **Send message**: Type + Enter (same as web version)
2. **@mention agent**: Type @ to trigger autocomplete dropdown
3. **Channel switch**: Click sidebar channel
4. **Invite friend**: Share invite link (contains relay address + channel key)
5. **Add agent**: Settings > Agents > Add (configure type, API key, etc.)
6. **Possession mode**: `/possess @agent-name` to enter agent's perspective
7. **Swarm mode**: `/swarm <problem>` to activate collective intelligence

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+K | Quick channel switcher |
| Cmd+N | New channel |
| Cmd+Shift+A | Add agent |
| Cmd+1-9 | Switch to channel N |
| Cmd+Enter | Send message |
| Escape | Close autocomplete / exit mode |
| Cmd+/ | Show all shortcuts |

---

## MVP Milestones

### M1: Local Chat Shell
- SwiftUI app with sidebar + chat view + input
- SQLite message storage (GRDB.swift)
- Send and display messages locally
- Channel creation and switching
- Match the Portal42 dark/green aesthetic

### M2: BYOA (Bring Your Own Agent)
- Agent config UI (point at any local command/script/binary)
- Process lifecycle management (spawn, monitor, kill)
- stdin/stdout JSON protocol
- @mention routing to agents
- Agent responses displayed in chat with bot badge
- Autocomplete for @mentions

### M3: Sync & Friends
- Go relay server (encrypted message forwarding)
- E2E encryption (CryptoKit)
- Invite system (share link to connect)
- Real-time message sync between two instances
- Presence indicators (online/offline)

### M4: Audio Rooms
- WebRTC peer-to-peer voice
- Signaling through Go relay
- Join/leave/mute/deafen controls
- Voice activity indicators
- Persistent audio bar in chat UI

### M5: Ship
- Offline message queue
- Message delivery status (sent/delivered/read)
- Notification support
- Hour meter integration
- App icon, DMG packaging
- Self-hostable relay binary

---

## Project Structure

```
port42-native/
  ARCHITECTURE.md          <- this file
  relay/                   <- Go relay server
    main.go
    relay.go
    auth.go
    go.mod
  app/                     <- SwiftUI macOS app
    Port42.xcodeproj
    Port42/
      App.swift            <- entry point
      Models/
        Message.swift
        Channel.swift
        User.swift
        Agent.swift
      Views/
        Sidebar/
          SidebarView.swift
          ChannelListView.swift
        Chat/
          ChatView.swift
          MessageBubbleView.swift
          InputView.swift
          AutocompleteView.swift
        Agents/
          AgentConfigView.swift
          AgentListView.swift
        Settings/
          SettingsView.swift
      Services/
        DatabaseService.swift    <- SQLite via GRDB
        SyncService.swift        <- WebSocket to relay
        CryptoService.swift      <- E2E encryption
        AgentService.swift       <- Agent lifecycle
        MessagePipeline.swift    <- Validate/filter/route
      Theme/
        Port42Theme.swift        <- Colors, fonts, styling
      Agents/
        AgentProtocol.swift      <- stdin/stdout JSON protocol
        AgentProcess.swift       <- Process lifecycle management
        AgentRouter.swift        <- Route @mentions to agents
      Audio/
        AudioRoomService.swift   <- WebRTC session management
        AudioRoomView.swift      <- Join/leave/mute UI
        SignalingClient.swift    <- SDP/ICE exchange via relay
```

---

## Non-Goals (for MVP)

- Mobile apps (iOS/Android)
- Video chat (audio only for now)
- File sharing (beyond text)
- User accounts / cloud auth
- Public channels / discovery
- Message search
- Light mode
- Built-in AI agents (you bring your own)
