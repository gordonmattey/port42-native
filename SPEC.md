# Port42 Native Spec

**Last updated:** 2026-03-07

**Status:** Working draft

---

## What Port42 Native Is

A native macOS chat application where humans and AI agents coexist as
first-class participants. Real-time syncing, end-to-end encrypted group
chat with a "bring your own agent" plugin system and voice rooms.

Discord for the agentic era. No walled gardens, no subscriptions to
someone else's AI. You bring your own intelligence. Point at any command,
script, or executable on your machine and it becomes a participant in
the conversation.

The app is native SwiftUI on Apple Silicon. Not Electron, not a web view.
Sync is Signal-style: a lightweight Go relay forwards encrypted blobs it
cannot read. Messages live on your machine. Voice goes peer-to-peer.

---

## Users

### Gordon and Friends (Launch)

A small group of builders, hackers, and thinkers who want one place to
talk, think, and build together with their AI companions alongside them.
They already use Port42's CLI tools and want the shared social layer.

### Developer / Power User (Growth)

Drowning in fragmented tools (Slack + Discord + ChatGPT + Claude +
Cursor). Wants a single space where humans and agents collaborate
naturally. Trades via API keys and local scripts, not managed services.
Non-custodial by instinct.

### Builder (Future)

Creates custom agents, shares them, builds on the Port42 agent protocol.
Not a launch priority.

---

## User Flows

### Flow 1: First Launch

```
F-100: App opens, generates identity key pair (stored in Keychain) -->
F-101: Set display name and optional avatar -->
F-102: Default #general channel created locally -->
F-200: Sidebar renders with #general -->
F-300: Chat view shows welcome message -->
F-301: Type and send first message (local only)
```

Target: Under 30 seconds from open to first message.

### Flow 2: Add an LLM Agent

```
F-400: Settings > Agents > Add New -->
F-401: Set name and system prompt -->
F-406: Auth auto-detected from Claude Code OAuth (or enter API key) -->
F-402: Agent appears in sidebar COMPANIONS section -->
F-301: Type "@agent-name hello" in chat -->
F-403: Port42 builds API call with channel context + system prompt -->
F-404: Agent response appears in chat with bot badge
```

Target: Under 30 seconds from "Add Agent" to agent responding in chat.

### Flow 2b: Add a Command Agent (power user)

```
F-400: Settings > Agents > Add New > Command tab -->
F-401: Configure command path, args, env vars -->
F-402: Agent process spawns, appears in sidebar -->
F-301: Type "@agent-name hello" in chat -->
F-403: Message routed to agent via stdin JSON -->
F-404: Agent response appears in chat with bot badge
```

### Flow 2c: Invite an Agent (share with a friend)

```
F-407: User configures agent, clicks "Share Agent" -->
F-407: Port42 generates invite link (name + system prompt + provider + model) -->
Friend clicks link, Port42 opens -->
F-406: Friend provides their own auth (Claude Code OAuth or API key) -->
F-402: Agent appears in friend's sidebar, same personality, their own billing
```

Target: Under 1 minute from link shared to agent responding in friend's chat.

### Flow 2d: Swim into a Companion

```
F-408: Click companion in sidebar (or type /swim @companion) -->
F-408: Dedicated 1:1 view opens, full screen conversation -->
F-401: Every message goes directly to companion, no @mention needed -->
F-401: Companion streams response with full conversation context -->
User types "exit" or presses Escape to return to channels
```

Target: Instant. Click and you're in.

### Flow 3: Invite a Friend

```
F-500: Create invite (generates link with relay address + encrypted channel key) -->
Friend opens link in their Port42 app -->
F-501: Key exchange happens automatically -->
F-502: Both users see shared channel, syncing in real time -->
F-301: Messages sync instantly between both instances
```

Target: Under 1 minute from link shared to first synced message.

### Flow 4: Join Audio Room

```
F-200: See speaker icon on channel with active audio room -->
F-600: Click to join audio room -->
F-601: WebRTC peer connection established -->
F-602: Audio bar appears at bottom of chat -->
F-603: Talk with friends, see voice activity indicators -->
F-604: Mute/deafen/leave controls
```

Target: Under 3 seconds from click to hearing audio.

### Flow 5: Agent Cross-Talk

```
User A has @ai-engineer in #builders -->
User B has @ai-muse in #builders -->
User A: "@ai-engineer review this architecture" -->
F-403: @ai-engineer responds with technical analysis -->
User B: "@ai-muse what's your take on the naming?" -->
F-403: @ai-muse responds with creative perspective -->
Both agents visible to both users as channel participants
```

### Flow 6: Bridge to Discord

```
F-602: Settings > Bridges > Add Discord -->
F-601: Enter Discord bot token, select channels to bridge -->
F-603: Bridge connects, status shows green in sidebar -->
Someone @mentions your agent in Discord -->
F-600: Bridge adapter routes message through AgentRouter -->
F-401: Agent processes message, generates response -->
F-601: Response posted back to Discord channel -->
F-604: Full conversation visible in Port42 chat view too
```

Target: Under 2 minutes from adding bridge to agent responding in Discord.

---

## Feature Registry

### Identity & Onboarding

| ID | Feature | Description | Done When | Milestone |
|----|---------|-------------|-----------|-----------|
| F-100 | Identity Generation | Generate Ed25519 key pair on first launch, store in macOS Keychain. Identity is the key pair, no accounts. | Key pair generated, stored, and retrievable across app restarts | M1 |
| F-101 | Profile Setup | Set display name and optional avatar image. Stored locally. | Name and avatar display in sidebar and on sent messages | M1 |
| F-102 | Default Channel | Create a local #general channel on first launch with a welcome message. | App opens to a usable chat on first run | M1 |

### Sidebar & Navigation

| ID | Feature | Description | Done When | Milestone |
|----|---------|-------------|-----------|-----------|
| F-200 | Sidebar | Left panel with sections: CHANNELS, DMs, SPACES (future), COMPANIONS. Channel list sorted by recent activity. | Sidebar renders all sections, channels clickable | M1 |
| F-201 | Channel Switching | Click channel in sidebar to switch chat view. Preserve draft input per channel. | Switching channels updates chat view, draft text preserved | M1 |
| F-202 | Activity Indicators | Unread bold text, unread count badge, green dot for active audio room, pulse for live activity. | Indicators update in real time as messages arrive | M1 (basic) / M3 (full) |
| F-203 | Quick Switcher | Cmd+K overlay with fuzzy search across channels, DMs, agents. | Overlay opens, filters results as you type, Enter navigates | M2 |

### Chat

| ID | Feature | Description | Done When | Milestone |
|----|---------|-------------|-----------|-----------|
| F-300 | Message Display | Scrollable message list. Sender name (bold), timestamp (right-aligned), content. Agent messages show teal left border and "(via OwnerName)". | Messages render with correct attribution and styling | M1 |
| F-301 | Message Input | Single-line input, Enter to send, Shift+Enter for newline. Clear on send. | User can type and send messages that appear in the chat | M1 |
| F-302 | @Mention Autocomplete | Typing @ triggers dropdown above input showing matching agents and humans. Arrow keys navigate, Tab/Enter select, Escape dismiss. Max 8 visible. | Autocomplete appears, filters, and inserts selected name | M2 |
| F-303 | Reply Threading | Reply to a specific message. Shows quoted original above reply. | Reply links to original message, both display correctly | M3 |
| F-304 | Message Status | Sent, delivered, read indicators (checkmarks or similar). | Status updates as relay confirms delivery and recipient reads | M3 |
| F-305 | Typing Indicators | Show "Name is typing..." when another user is composing. | Typing state broadcasts and displays within 500ms | M3 |
| F-306 | /Commands | Support /swarm and extensible command registry. | Commands parse and route to appropriate handlers | M6 |

### BYOA (Bring Your Own Agent)

| ID | Feature | Description | Done When | Milestone |
|----|---------|-------------|-----------|-----------|
| F-400 | Agent Config UI | Settings > Agents > Add. Two modes: LLM (name + system prompt + provider + model) and Command (name + command path + args + env). Channels and trigger mode for both. | User can configure and save an agent | M2 |
| F-401 | LLM Agent Engine | Port42 calls LLM API directly with channel context as conversation history and agent's system prompt. Supports Anthropic (Claude). Streams tokens to chat as they arrive. No subprocess needed. | @mention triggers streaming API call, tokens appear live in chat | M2 |
| F-402 | Agent Sidebar Presence | Agents appear in COMPANIONS sidebar section with status indicator. Bot badge on messages. | Agents visible in sidebar with correct status | M2 |
| F-403 | Agent Message Routing | Detect @mentions in messages. Route to correct agent based on name. Build context from recent channel history (configurable window, default 50 messages). Respect trigger mode (mention-only vs all-messages). | Agent receives mention, responds, response appears in chat | M2 |
| F-404 | Agent Response Display | Agent messages appear in chat with bot badge, teal styling, "(via OwnerName)" attribution. | Agent messages visually distinct from human messages | M2 |
| F-405 | Command Agent (power user) | Spawn agent as child process. stdin/stdout NDJSON protocol. Events: mention, message, shutdown. Response: streaming content lines, optional reply_to. Logs captured from stderr. | Command agent receives events and streams responses via stdio | M2 |
| F-406 | Agent Auth | Auto-detect Claude Code OAuth token from macOS Keychain ("Claude Code-credentials"). Watches for token refresh. Fallback: user provides API key manually. Per-agent auth config. | Agent calls succeed with Claude Code OAuth from Keychain or manual API key | M2 |
| F-407 | Agent Invite Link | Share agent config as a link (port42://agent?...). Contains name, system prompt, provider, model. Recipient adds their own auth. | Friend can add shared agent from a link | M2 |
| F-408 | Swim | Jump into a companion for direct 1:1 conversation. Opens a dedicated DM-style view. No @mention needed, companion always responds. Streaming conversation with full context. Native version of the CLI `swim` command. `/swim @companion` or click companion in sidebar. | User swims into a companion, has direct streaming conversation, exits back to channels | M2 |

### Sync & Encryption

| ID | Feature | Description | Done When | Milestone |
|----|---------|-------------|-----------|-----------|
| F-500 | Invite System | Generate invite link containing relay address and encrypted channel key. Recipient opens in Port42, key exchange completes automatically. | Two users connected and see shared channel after invite flow | M3 |
| F-501 | E2E Encryption | Per-channel symmetric keys. Messages encrypted before leaving the app. Relay sees only encrypted blobs. CryptoKit (AES-GCM). | Messages unreadable without channel key, verified by inspection | M3 |
| F-502 | Real-Time Sync | WebSocket connection to Go relay. Messages forwarded to all channel members instantly. | Message sent on Device A appears on Device B within 500ms | M3 |
| F-503 | Store and Forward | Relay holds encrypted messages for offline recipients. Delivers on reconnect. Deletes after ACK. | Messages sent while recipient offline arrive when they reconnect | M3 |
| F-504 | Offline Queue | Messages created while offline queue locally. Sync automatically when connection restored. | No messages lost during network interruption | M3 |
| F-505 | Presence | Online/offline status for all channel members. Broadcast via relay. | User can see who is online in a channel | M3 |
| F-506 | Remote Identity | Qualify synced AI names with owner (e.g. "Echo · gordon") so AIs with the same name are visually distinct across peers. Colors and avatars differ per owner. | Two users with identically named AIs can tell them apart in chat | M3 |
| F-507 | Cross-Peer Mentions | @ mention autocomplete includes remote humans and their AIs, built from message history and presence data. | User can @mention a remote human or their AI in a shared channel | M3 |
| F-508 | Full Member List | Channel header shows all connected members and companions (from presence), not just historical senders. Humans and AIs visually distinguished. | Header shows remote companions and humans with type indicators | M3 |
| F-509 | Sender Attribution | Human messages sent to AI include sender name in context. AI knows who is speaking and can address them by name. | AI responds using the correct human's name | M3 |

### Go Relay Server

| ID | Feature | Description | Done When | Milestone |
|----|---------|-------------|-----------|-----------|
| F-510 | Relay Core | Go binary that accepts WebSocket connections, routes encrypted blobs by channel membership, stores until ACK. | Relay forwards messages between two connected clients | M3 |
| F-511 | Relay Auth | Secure Enclave P256 identity. Client connects, gateway sends a nonce challenge, client signs with `SecureEnclave.P256.Signing.PrivateKey` (hardware-backed, non-extractable). Gateway verifies signature against the client's public key. No passwords, no accounts, no Apple ID. Identity is device-bound and hardware-secured. | Only the key holder can connect as that identity. Private key cannot be exported or cloned. | M3 |
| F-512 | Relay Self-Host | Single binary, no external dependencies, configurable via env vars or flags. README with deploy instructions. | Anyone can run their own relay with `./port42-relay` | M3 |
| F-514 | Channel Join Tokens | Invite links include a one-time join token signed by the inviter. Gateway only allows channel joins with a valid token from an existing member. Prevents unauthorized channel access even if the channel ID is known. | Connecting to the gateway and sending a join without a valid token is rejected | M3 |
| F-515 | Join/Leave Announcements | System messages when a peer joins or leaves a shared channel. Triggered by presence events from the gateway. Shows "Name joined the channel" or "Name left the channel." | Peers see system messages when others join or leave | M3 |
| F-513 | Signaling | SDP/ICE exchange for WebRTC audio room setup routed through relay. | Audio room connections negotiate through relay | M5 |

### Platform Bridges

| ID | Feature | Description | Done When | Milestone |
|----|---------|-------------|-----------|-----------|
| F-600 | Bridge Architecture | Adapter pattern: bridge process connects to external platform API, routes messages through AgentRouter. Agents work identically across platforms. | Bridge adapter interface defined, one platform working | M4 |
| F-601 | Discord Bridge | Connect to Discord server via bot token. Messages in bridged channels route to your local agents. Agent responses posted back to Discord. | Agent responds to @mention in Discord channel | M4 |
| F-602 | Bridge Config UI | Settings > Bridges > Add. Configure platform, auth token, channel mapping (which Discord channels map to which agents). | User can set up and manage bridge connections | M4 |
| F-603 | Bridge Status | Show bridge connection status in sidebar. Online/offline indicator. Reconnect on disconnect. | Bridge status visible, auto-reconnects | M4 |
| F-604 | Bridge Message Sync | Messages from bridged platforms appear in Port42 chat view alongside local messages. Unified conversation history. | Discord messages visible in Port42 with platform badge | M4 |

### Audio Rooms

| ID | Feature | Description | Done When | Milestone |
|----|---------|-------------|-----------|-----------|
| F-700 | Join/Leave Audio | Click speaker icon on channel to join audio room. Room created on first join, destroyed when empty. | User can join and leave, other participants hear them | M5 |
| F-701 | WebRTC P2P Audio | Peer-to-peer audio via WebRTC. Signaling through relay (F-513). TURN fallback for strict NATs. | Audio streams between two peers on different networks | M5 |
| F-702 | Audio Bar | Persistent bar at bottom of chat when in a room. Shows room name, participant avatars, controls. | Bar visible, shows correct participants, persists across channel switches | M5 |
| F-703 | Voice Activity | Green ring pulse around speaking participant's avatar. | Visual indicator activates when participant is speaking | M5 |
| F-704 | Mute/Deafen/Leave | Microphone toggle, speaker toggle, leave button. Keyboard shortcuts: Cmd+M, Cmd+Shift+D. | All controls functional, state reflected to other participants | M5 |
| F-705 | Audio Settings | Input/output device selection. Voice activity detection sensitivity. Push-to-talk option. | User can select devices and configure voice activation | M5 |

### Local Storage

| ID | Feature | Description | Done When | Milestone |
|----|---------|-------------|-----------|-----------|
| F-800 | SQLite Database | GRDB.swift for local persistence. Messages, channels, users, agents, audio rooms. | Data persists across app restarts | M1 |
| F-801 | Channel CRUD | Create, rename, delete channels. Stored in SQLite. | Channels persist and can be managed | M1 |
| F-802 | Message Persistence | All messages stored locally in SQLite, indexed by channel and timestamp. | Messages survive app restart, load on channel switch | M1 |

### Theme & Polish

| ID | Feature | Description | Done When | Milestone |
|----|---------|-------------|-----------|-----------|
| F-900 | Dark Theme | Black background (#000/#111), neon green accent (#00ff41), teal for agent text (#00d4aa), SF Mono font, no light mode. | App matches Portal42 web aesthetic | M1 |
| F-901 | Notifications | macOS native notifications for mentions and DMs. Badge count on dock icon. Respect Do Not Disturb. | Notifications fire for mentions, badge updates | M6 |
| F-902 | Keyboard Shortcuts | Full shortcut set: Cmd+K, Cmd+N, Cmd+1-9, Cmd+M, Cmd+/, Enter, Shift+Enter, Escape, Up arrow edit. | All shortcuts functional | M1 (basic) / M6 (full) |
| F-903 | App Packaging | App icon, DMG for distribution, code signing. | App installable via DMG on any Apple Silicon Mac | M6 |

---

## Milestones

### M1: Local Chat Shell

*A working native chat app on your Mac. No networking, no agents. Just the shell.*

Covers identity generation (F-100), profile setup (F-101), default channel (F-102),
sidebar with channel list (F-200, F-201), basic activity indicators (F-202),
message display (F-300), message input (F-301), SQLite persistence (F-800, F-801,
F-802), dark theme (F-900), and basic keyboard shortcuts (F-902).

Enables Flow 1. App launches, looks right, feels native. You can create channels,
send messages, switch between them, and everything persists.

**M1 is done when:** App launches on Apple Silicon, user sets a name, creates channels,
sends messages, switches channels with draft preserved, restarts app and all data is there.
Matches Portal42 dark/green aesthetic.

### M2: Bring Your Own Agent

*Give your agent a name and a brain. It joins the chat as a participant.*

Covers companion config UI (F-400), LLM engine (F-401), sidebar presence (F-402),
message routing (F-403), response display (F-404), command agent protocol (F-405),
auth with Claude Code OAuth (F-406), invite links (F-407), swim (F-408),
@mention autocomplete (F-302), and quick switcher (F-203).

Enables Flow 2 (LLM companion), Flow 2b (command agent), Flow 2c (invite),
and Flow 2d (swim). The simple path: name your companion, write a system prompt,
auth auto-detected from Claude Code. @mention it in any channel or swim into it for
a direct 1:1 session. The power path: point at any local command that speaks NDJSON.

**M2 is done when:** User creates a companion (name + system prompt), @mentions it
in chat and gets a streaming response. User can swim into a companion for direct 1:1
conversation. Command agents work via stdin/stdout. Invite links let friends add the
same companion with their own auth. Autocomplete works for companion names.

**Build sequence:**

1. LLM Engine + Swim view (F-401, F-408) — Call Anthropic API with streaming, wired into a 1:1 companion conversation view. First end-to-end demo: click companion, type, tokens stream back live.
2. AppState wiring + Response display (F-404) — message → detect mentions → route → engine → insert response with bot badge, teal styling, streaming tokens in channel chat.
3. Companion Config UI (F-400) — "Add Companion" sheet, LLM and Command tabs.
4. Sidebar presence (F-402) — Companions in COMPANIONS section, clickable to swim.
5. @Mention autocomplete (F-302) — Dropdown above input when typing @.
6. Quick switcher (F-203) — Cmd+K overlay with fuzzy search.

### M3: Sync & Friends

*Real-time encrypted chat between multiple people.*

Covers invite system (F-500), E2E encryption (F-501), real-time sync (F-502),
store-and-forward (F-503), offline queue (F-504), presence (F-505), remote identity
(F-506), cross-peer mentions (F-507), full member list (F-508), sender attribution
(F-509), relay core (F-510), relay auth (F-511), relay self-host (F-512), channel
join tokens (F-514), reply
threading (F-303), message status (F-304), typing indicators (F-305), and full
activity indicators (F-202).

Enables Flow 3 and Flow 5. Two people on different machines share a channel.
Messages sync instantly. Each person's agents are visible and distinguishable.
Messages queue when offline and deliver on reconnect.

**M3 is done when:** Two users on separate Macs, connected via relay, can chat in
real time with E2E encryption. Messages arrive within 500ms. Offline messages
deliver on reconnect. Each user's agents are visible, distinguishable by owner,
and mentionable by the other user.

### M4: Platform Bridges

*Your agents follow you into Discord and beyond.*

Covers bridge architecture (F-600), Discord bridge (F-601), bridge config UI (F-602),
bridge status (F-603), and bridge message sync (F-604).

Enables Flow 6 (new). Connect Port42 to a Discord server. Your local agents respond
to @mentions in Discord channels. Messages flow both ways: Discord messages appear
in Port42, agent responses post back to Discord. Your agents aren't locked in.

**M4 is done when:** User connects to a Discord server, @mentions their agent in a
Discord channel, agent responds in Discord. Bridge shows connected status in Port42
sidebar. Discord messages visible in Port42 chat view.

### M5: Audio Rooms

*Voice chat in any channel.*

Covers join/leave (F-700), WebRTC audio (F-701), audio bar (F-702), voice activity
(F-703), mute/deafen/leave controls (F-704), audio settings (F-705), and relay
signaling (F-513).

Enables Flow 4. Click to join a voice room in any channel. Audio is peer-to-peer.
Persistent bar at bottom shows who's talking.

**M5 is done when:** Two users can join an audio room, hear each other, see voice
activity indicators, mute/unmute, and leave. Works across different networks.

### M6: Transport Layer Evaluation

*Evaluate replacing the custom Go gateway with a production-grade P2P/messaging library.*

The M3 gateway is a hand-rolled WebSocket relay that handles presence, store-and-forward,
and channel routing. It works well as a learning scaffold with zero dependencies, but
production use will surface scaling, reliability, and NAT traversal gaps that mature
libraries have already solved.

Candidates to evaluate:
- **LiveKit** (rooms, presence, media, signaling out of the box, also covers M5 audio)
- **Matrix / matrix-rust-sdk** (decentralized, E2E encryption baked in, room management)
- **libp2p** (fully decentralized, NAT traversal, pub/sub channels)
- **CRDTs + custom transport** (Automerge/Yjs for conflict-free sync)

The SyncService abstraction means the transport can be swapped without touching the rest
of the app. Key criteria: self-hostable, no vendor lock-in, Swift client maturity, and
alignment with Port42's escape-the-walled-garden philosophy.

**M6 is done when:** A decision document compares the custom gateway against at least two
library options on latency, reliability, NAT traversal, encryption, and maintenance burden.
If a library wins, a migration plan exists.

### M7: Ship

*Package it up and get it into people's hands.*

Covers /commands (F-306), notifications (F-901), full keyboard shortcuts (F-902),
and app packaging (F-903).

**M6 is done when:** DMG installs cleanly on a fresh Apple Silicon Mac. Notifications
work. All keyboard shortcuts documented and functional.

---

## Dependencies

| Dependency | Features | Status | Action Required |
|------------|----------|--------|-----------------|
| GRDB.swift (SQLite) | F-800, F-801, F-802 | Mature, stable | Add as SPM dependency |
| Apple CryptoKit | F-501 | Ships with macOS | None |
| macOS Keychain / Security.framework | F-100, F-406 | Ships with macOS | None |
| Discord API (discord.js or raw HTTP) | F-601 | Stable | Evaluate: Swift Discord library vs raw WebSocket gateway. Needed for M4. |
| Google WebRTC (Swift) | F-701, F-513 | Available, active | Evaluate Swift package maturity for macOS. Alternatives: LiveKit SDK. Needed for M5. |
| Go standard library | F-510, F-511, F-512 | Ships with Go | None |
| TURN server | F-701 | Need to self-host or use a service | Decide: self-host coturn, use Cloudflare TURN, or Twilio TURN. Needed for M5. |

---

## Out of Scope

- Mobile apps (iOS, Android)
- Video chat (audio only)
- File attachments and media sharing
- Message editing after send
- Message deletion
- Reactions / emoji responses
- Search across messages
- User profiles beyond name and avatar
- Admin / moderation tools
- Public channel discovery
- Light mode
- Built-in AI agents (you bring your own)
- Agent marketplace (sharing is via invite links, not a store)
- Message history sync (you have what your device has)
- Threads beyond simple reply-to
- Read receipts with user-level granularity

---

## Open Questions

### Blocks M1

| ID | Question |
|----|----------|
| F-900 | SF Mono ships with Xcode but not all Macs. Fallback to Menlo, or bundle SF Mono? |
| F-800 | GRDB.swift vs SwiftData vs raw SQLite? GRDB is most proven but SwiftData is Apple-native. |
| F-100 | Ed25519 vs Curve25519 for identity keys? Ed25519 for signing, Curve25519 for key exchange, or use both? |

### Blocks M2

| ID | Question | Status |
|----|----------|--------|
| F-401 | ~~Stream or wait?~~ **Decided: Stream.** Tokens stream to chat as they arrive. | Resolved |
| F-403 | History window: default 50 messages, configurable per agent. Needs experimentation to tune. Token-budget mode is future work. | Partially resolved |
| F-405 | ~~Streaming for command agents?~~ **Decided: Yes.** Command agents can stream partial content lines. | Resolved |
| F-406 | ~~OAuth token location?~~ **Decided: macOS Keychain.** Service name "Claude Code-credentials". Watch for token refresh via Keychain notification. | Resolved |
| F-407 | Invite link needs reverse proxy for HTTPS fallback. `port42://agent?...` requires URL scheme registration in Info.plist. HTTPS link needs a web service to redirect. How minimal can the web component be? | Open |

### Blocks M3

| ID | Question |
|----|----------|
| F-501 | Full Signal Protocol (double ratchet, forward secrecy) or simplified AES-GCM with static channel keys? Signal Protocol is stronger but significantly more complex. |
| F-510 | Where to host the default relay? VPS provider choice, region, cost. |
| F-500 | Invite link format: deep link (port42://invite/...) or HTTPS with universal link? Need to register URL scheme. |
| F-502 | Conflict resolution for concurrent messages: timestamp ordering sufficient, or need vector clocks / CRDTs? |

### Blocks M4 (Platform Bridges)

| ID | Question |
|----|----------|
| F-601 | Discord bot token requires a Discord Application. Should Port42 provide a shared app (easier setup) or require users to create their own (more control, no central dependency)? |
| F-601 | Rate limiting: Discord has strict rate limits. How to queue agent responses to avoid hitting limits? |
| F-604 | Message format translation: Discord markdown vs Port42 message format. How much formatting fidelity to preserve? |
| F-600 | Beyond Discord: Slack, Matrix, Telegram? Define the bridge adapter interface generically enough for future platforms. |

### Blocks M6 (Transport Layer)

| ID | Question |
|----|----------|
| F-510 | Custom gateway vs LiveKit vs Matrix vs libp2p? LiveKit covers audio too (M5) but adds a server dependency. Matrix is decentralized and has E2E baked in but the Swift SDK is less mature. libp2p is fully P2P but complex. Custom gateway gives full control but means maintaining presence, NAT traversal, and reliability ourselves. |

### Blocks M5 (Audio Rooms)

| ID | Question |
|----|----------|
| F-701 | Google WebRTC Swift package vs LiveKit vs building on AVFoundation directly? WebRTC is complex, LiveKit abstracts it but adds a dependency. |
| F-701 | TURN server: self-host coturn, or use managed service (Cloudflare, Twilio)? Cost vs reliability. |
| F-703 | Voice activity detection: WebRTC's built-in VAD sufficient, or need custom threshold? |
