# Port42 Native Spec

**Last updated:** 2026-03-12

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

| ID | Feature | Description | Done When | Milestone | Status |
|----|---------|-------------|-----------|-----------|--------|
| F-100 | Identity Generation | Generate Ed25519 key pair on first launch, store in macOS Keychain. Identity is the key pair, no accounts. | Key pair generated, stored, and retrievable across app restarts | M1 | **Done** |
| F-101 | Profile Setup | Set display name and optional avatar image. Stored locally. | Name and avatar display in sidebar and on sent messages | M1 | **Done** |
| F-102 | Default Channel | Create a local #general channel on first launch with a welcome message. | App opens to a usable chat on first run | M1 | **Done** |

### Sidebar & Navigation

| ID | Feature | Description | Done When | Milestone | Status |
|----|---------|-------------|-----------|-----------|--------|
| F-200 | Sidebar | Left panel with sections: CHANNELS, DMs, SPACES (future), COMPANIONS. Channel list sorted by recent activity. | Sidebar renders all sections, channels clickable | M1 | **Done** |
| F-201 | Channel Switching | Click channel in sidebar to switch chat view. Preserve draft input per channel. | Switching channels updates chat view, draft text preserved | M1 | **Done** |
| F-202 | Activity Indicators | Unread bold text, unread count badge, green dot for active audio room, pulse for live activity. | Indicators update in real time as messages arrive | M1 (basic) / M3 (full) | **Done** |
| F-203 | Quick Switcher | Cmd+K overlay with fuzzy search across channels, DMs, agents. | Overlay opens, filters results as you type, Enter navigates | M2 | **Done** |

### Chat

| ID | Feature | Description | Done When | Milestone | Status |
|----|---------|-------------|-----------|-----------|--------|
| F-300 | Message Display | Scrollable message list. Sender name (bold), timestamp (right-aligned), content. Agent messages show teal left border and "(via OwnerName)". | Messages render with correct attribution and styling | M1 | **Done** |
| F-301 | Message Input | Single-line input, Enter to send, Shift+Enter for newline. Clear on send. | User can type and send messages that appear in the chat | M1 | **Done** |
| F-302 | @Mention Autocomplete | Typing @ triggers dropdown above input showing matching agents and humans. Arrow keys navigate, Tab/Enter select, Escape dismiss. Max 8 visible. | Autocomplete appears, filters, and inserts selected name | M2 | **Done** |
| F-303 | Reply Threading | Reply to a specific message. Shows quoted original above reply. | Reply links to original message, both display correctly | M3 | |
| F-304 | Message Status | Sent, delivered, read indicators (checkmarks or similar). | Status updates as relay confirms delivery and recipient reads | M3 | **Done** |
| F-305 | Typing Indicators | Show "Name is typing..." when another user is composing. | Typing state broadcasts and displays within 500ms | M3 | **Done** |
| F-306 | /Commands | Support /swarm and extensible command registry. | Commands parse and route to appropriate handlers | M8 | |

### BYOA (Bring Your Own Agent)

| ID | Feature | Description | Done When | Milestone | Status |
|----|---------|-------------|-----------|-----------|--------|
| F-400 | Agent Config UI | Settings > Agents > Add. Two modes: LLM (name + system prompt + provider + model) and Command (name + command path + args + env). Channels and trigger mode for both. | User can configure and save an agent | M2 | **Done** |
| F-401 | LLM Agent Engine | Port42 calls LLM API directly with channel context as conversation history and agent's system prompt. Supports Anthropic (Claude). Streams tokens to chat as they arrive. No subprocess needed. | @mention triggers streaming API call, tokens appear live in chat | M2 | **Done** |
| F-402 | Agent Sidebar Presence | Agents appear in COMPANIONS sidebar section with status indicator. Bot badge on messages. | Agents visible in sidebar with correct status | M2 | **Done** |
| F-403 | Agent Message Routing | Detect @mentions in messages. Route to correct agent based on name. Build context from recent channel history (configurable window, default 50 messages). Respect trigger mode (mention-only vs all-messages). | Agent receives mention, responds, response appears in chat | M2 | **Done** |
| F-404 | Agent Response Display | Agent messages appear in chat with bot badge, teal styling, "(via OwnerName)" attribution. | Agent messages visually distinct from human messages | M2 | **Done** |
| F-405 | Command Agent (power user) | Spawn agent as child process. stdin/stdout NDJSON protocol. Events: mention, message, shutdown. Response: streaming content lines, optional reply_to. Logs captured from stderr. | Command agent receives events and streams responses via stdio | M2 | **Done** |
| F-406 | Agent Auth | Auto-detect Claude Code OAuth token from macOS Keychain ("Claude Code-credentials"). Watches for token refresh. Fallback: user provides API key manually. Per-agent auth config. | Agent calls succeed with Claude Code OAuth from Keychain or manual API key | M2 | **Done** |
| F-407 | Agent Invite Link | Share agent config as a link (port42://agent?...). Contains name, system prompt, provider, model. Recipient adds their own auth. | Friend can add shared agent from a link | M2 | **Done** |
| F-408 | Swim | Jump into a companion for direct 1:1 conversation. Opens a dedicated DM-style view. No @mention needed, companion always responds. Streaming conversation with full context. Native version of the CLI `swim` command. `/swim @companion` or click companion in sidebar. | User swims into a companion, has direct streaming conversation, exits back to channels | M2 | **Done** |

### Sync & Encryption

| ID | Feature | Description | Done When | Milestone | Status |
|----|---------|-------------|-----------|-----------|--------|
| F-500 | Invite System | Generate invite link containing relay address and encrypted channel key. Recipient opens in Port42, key exchange completes automatically. | Two users connected and see shared channel after invite flow | M3 | **Done** |
| F-501 | E2E Encryption | Per-channel symmetric keys. Messages encrypted before leaving the app. Relay sees only encrypted blobs. CryptoKit (AES-GCM). | Messages unreadable without channel key, verified by inspection | M3 | **Done** |
| F-502 | Real-Time Sync | WebSocket connection to Go relay. Messages forwarded to all channel members instantly. | Message sent on Device A appears on Device B within 500ms | M3 | **Done** |
| F-503 | Store and Forward | Relay holds encrypted messages for offline recipients. Delivers on reconnect. Deletes after ACK. | Messages sent while recipient offline arrive when they reconnect | M3 | **Done** |
| F-504 | Offline Queue | Messages created while offline queue locally. Sync automatically when connection restored. | No messages lost during network interruption | M4 | Deferred |
| F-505 | Presence | Online/offline status for all channel members. Broadcast via relay. | User can see who is online in a channel | M3 | **Done** |
| F-506 | Remote Identity | Qualify synced AI names with owner (e.g. "Echo · gordon") so AIs with the same name are visually distinct across peers. Colors and avatars differ per owner. | Two users with identically named AIs can tell them apart in chat | M3 | **Done** |
| F-507 | Cross-Peer Mentions | @ mention autocomplete includes remote humans and their AIs, built from message history and presence data. | User can @mention a remote human or their AI in a shared channel | M3 | **Done** |
| F-508 | Full Member List | Channel header shows all connected members and companions (from presence), not just historical senders. Humans and AIs visually distinguished. | Header shows remote companions and humans with type indicators | M3 | **Done** |
| F-509 | Sender Attribution | Human messages sent to AI include sender name in context. AI knows who is speaking and can address them by name. | AI responds using the correct human's name | M3 | **Done** |

### Go Relay Server

| ID | Feature | Description | Done When | Milestone | Status |
|----|---------|-------------|-----------|-----------|--------|
| F-510 | Relay Core | Go binary that accepts WebSocket connections, routes encrypted blobs by channel membership, stores until ACK. | Relay forwards messages between two connected clients | M3 | **Done** |
| F-511 | Relay Auth | Sign in with Apple identity. Gateway sends nonce challenge, client gets Apple-signed JWT with hashed nonce, gateway verifies against Apple JWKS. Apple sign-in happens once during setup. Apple user ID stored on AppUser. Localhost connections skip auth. Agents use F-514 join tokens instead. | Only Apple-authenticated users can identify to a remote gateway. Replay blocked by per-connection nonce. | M4 | Implemented (code complete, needs notarized release for production use) |
| F-512 | Relay Self-Host | Single binary, no external dependencies, configurable via env vars or flags. README with deploy instructions. | Anyone can run their own relay with `./port42-relay` | M3 | **Done** |
| F-514 | Channel Join Tokens | Invite links include a one-time join token signed by the inviter. Gateway only allows channel joins with a valid token from an existing member. Prevents unauthorized channel access even if the channel ID is known. | Connecting to the gateway and sending a join without a valid token is rejected | M3 | **Done** |
| F-515 | Join/Leave Announcements | System messages when a peer joins or leaves a shared channel. Triggered by presence events from the gateway. Shows "Name joined the channel" or "Name left the channel." | Peers see system messages when others join or leave | M3 | **Done** (minor display delay) |
| F-516 | Gateway Persistence | Persist Apple ID to channel membership mappings on the gateway (file-backed). Enables auto-rejoin on connect, store-and-forward keyed by identity (not ephemeral peer ID), and multi-device support. Currently all gateway state is in-memory and lost on restart. | New device connects with same Apple ID, gateway auto-joins their channels and delivers stored messages. | M4 | |
| F-513 | Signaling | SDP/ICE exchange for WebRTC audio room setup routed through relay. | Audio room connections negotiate through relay | M6 |

### Platform Bridges

| ID | Feature | Description | Done When | Milestone |
|----|---------|-------------|-----------|-----------|
| F-600 | Bridge Architecture | Adapter pattern: bridge process connects to external platform API, routes messages through AgentRouter. Agents work identically across platforms. | Bridge adapter interface defined, one platform working | M5 |
| F-601 | Discord Bridge | Connect to Discord server via bot token. Messages in bridged channels route to your local agents. Agent responses posted back to Discord. | Agent responds to @mention in Discord channel | M5 |
| F-602 | Bridge Config UI | Settings > Bridges > Add. Configure platform, auth token, channel mapping (which Discord channels map to which agents). | User can set up and manage bridge connections | M5 |
| F-603 | Bridge Status | Show bridge connection status in sidebar. Online/offline indicator. Reconnect on disconnect. | Bridge status visible, auto-reconnects | M5 |
| F-604 | Bridge Message Sync | Messages from bridged platforms appear in Port42 chat view alongside local messages. Unified conversation history. | Discord messages visible in Port42 with platform badge | M5 |

### Audio Rooms

| ID | Feature | Description | Done When | Milestone |
|----|---------|-------------|-----------|-----------|
| F-700 | Join/Leave Audio | Click speaker icon on channel to join audio room. Room created on first join, destroyed when empty. | User can join and leave, other participants hear them | M6 |
| F-701 | WebRTC P2P Audio | Peer-to-peer audio via WebRTC. Signaling through relay (F-513). TURN fallback for strict NATs. | Audio streams between two peers on different networks | M6 |
| F-702 | Audio Bar | Persistent bar at bottom of chat when in a room. Shows room name, participant avatars, controls. | Bar visible, shows correct participants, persists across channel switches | M6 |
| F-703 | Voice Activity | Green ring pulse around speaking participant's avatar. | Visual indicator activates when participant is speaking | M6 |
| F-704 | Mute/Deafen/Leave | Microphone toggle, speaker toggle, leave button. Keyboard shortcuts: Cmd+M, Cmd+Shift+D. | All controls functional, state reflected to other participants | M6 |
| F-705 | Audio Settings | Input/output device selection. Voice activity detection sensitivity. Push-to-talk option. | User can select devices and configure voice activation | M6 |

### Local Storage

| ID | Feature | Description | Done When | Milestone | Status |
|----|---------|-------------|-----------|-----------|--------|
| F-800 | SQLite Database | GRDB.swift for local persistence. Messages, channels, users, agents, audio rooms. | Data persists across app restarts | M1 | **Done** |
| F-801 | Channel CRUD | Create, rename, delete channels. Stored in SQLite. | Channels persist and can be managed | M1 | **Done** |
| F-802 | Message Persistence | All messages stored locally in SQLite, indexed by channel and timestamp. | Messages survive app restart, load on channel switch | M1 | **Done** |

### Theme & Polish

| ID | Feature | Description | Done When | Milestone | Status |
|----|---------|-------------|-----------|-----------|--------|
| F-900 | Dark Theme | Black background (#000/#111), neon green accent (#00ff41), teal for agent text (#00d4aa), SF Mono font, no light mode. | App matches Portal42 web aesthetic | M1 | **Done** |
| F-901 | Notifications | macOS native notifications for mentions and DMs. Badge count on dock icon. Respect Do Not Disturb. | Notifications fire for mentions, badge updates | M8 | |
| F-902 | Keyboard Shortcuts | Full shortcut set: Cmd+K, Cmd+N, Cmd+1-9, Cmd+M, Cmd+/, Enter, Shift+Enter, Escape, Up arrow edit. | All shortcuts functional | M1 (basic) / M8 (full) | **Done** (basic) |
| F-903 | App Packaging | App icon, DMG for distribution, code signing. | App installable via DMG on any Apple Silicon Mac | M8 | **Done** |

---

## Milestones

### M1: Local Chat Shell ✅

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

### M2: Bring Your Own Agent ✅

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

### M3: Sync & Friends ✅

*Real-time encrypted chat between multiple people.*

Covers invite system (F-500), E2E encryption (F-501), real-time sync (F-502),
store-and-forward (F-503), presence (F-505), remote identity
(F-506), cross-peer mentions (F-507), full member list (F-508), sender attribution
(F-509), relay core (F-510), relay self-host (F-512), channel
join tokens (F-514), message status (F-304), typing indicators (F-305), and full
activity indicators (F-202).

Also completed beyond original plan: friends/DM discovery from channel members,
unified sidebar sorted by last activity, delivery and read receipts with visual
indicators (· local, ✓ synced, ✓✓ delivered, ✓✓ green for read).

Enables Flow 3 and Flow 5. Two people on different machines share a channel.
Messages sync instantly. Each person's agents are visible and distinguishable.

**M3 is done.** Two users on separate Macs, connected via gateway (direct or
through ngrok), chat in real time with AES-GCM encryption. Messages arrive
within 500ms. Each user's agents are visible, distinguishable by owner, and
mentionable by the other user. Delivery and read receipts update automatically.

Deferred to M4: offline queue (F-504), relay auth (F-511), reply threading (F-303).

### M4: Ports (In Progress)

*Live interactive surfaces inside conversations.*

Covers port detection (P-100), inline webview (P-101), bridge core (P-102),
bridge companions/messages/user/events (P-103-P-106), companion context (P-107),
port sandbox (P-108), port theme (P-109).

Phase 1 inline ports are working. Companions emit ```port code fences,
WKWebView renders them inline in the message stream with full port42.* bridge
API. Console overlay for debugging. Auto-height via ResizeObserver.

Phase 2 (pop-out, docking) is partial. Phase 3 (generative ports with
port42.ai.complete()) is planned. See ports-spec.md for full details.

### M5: OpenClaw Integration (In Progress)

*Bridge external agents from the OpenClaw ecosystem into Port42 channels.*

Covers OpenClaw gateway detection, WebSocket connection with challenge/response
auth, port42-openclaw plugin auto-install, agent discovery, one-click channel
connection, config update with gateway restart handling, version detection,
auto-retry with backoff.

**Done:** Full connect flow works end-to-end. User right-clicks channel,
selects "Connect OpenClaw Agent", sheet auto-connects to local OpenClaw
gateway, auto-installs plugin if missing, lists agents, configures trigger
mode, writes config and restarts gateway. Web invite page has "accept + connect"
button for one-click OpenClaw deep linking.

### OpenClaw Integration

| ID | Feature | Description | Done When | Status |
|----|---------|-------------|-----------|--------|
| OC-100 | Gateway Detection | Read ~/.openclaw/openclaw.json for port and auth token | Config file parsed, connection attempted | **Done** |
| OC-101 | WebSocket Connect | Connect to local OpenClaw gateway, handle challenge/response auth | WebSocket connected, RPC available | **Done** |
| OC-102 | Plugin Auto-Install | Detect missing port42-openclaw plugin, auto-install via npx. Check disk presence as fallback. | Plugin installed without user action | **Done** |
| OC-103 | Agent Discovery | List available agents from OpenClaw via agents.list RPC | Agent list populated in UI | **Done** |
| OC-104 | Channel Connection | Generate invite URL, write OpenClaw config (accounts + bindings), trigger gateway restart | Agent appears in channel via presence | **Done** |
| OC-105 | Config Update | config.set writes config, config.apply triggers SIGUSR1 restart. 7.5s wait then auto-reconnect. | Config saved and gateway restarted | **Done** |
| OC-106 | Auto-Retry | 3 retries with 2s/4s/6s backoff on WebSocket failure | Connection recovers after gateway restart | **Done** |
| OC-107 | Version Detection | Check local openclaw --version vs npm registry, show update indicator | Footer shows version or "update available" | **Done** |
| OC-108 | Web Invite Connect | "accept + connect" button on invite page, port42://openclaw deep link | One-click agent connection from web | **Done** |

### Ports (Live Interactive Surfaces)

| ID | Feature | Description | Done When | Status |
|----|---------|-------------|-----------|--------|
| P-100 | Port Detection | Detect ```port code fences in companion messages | Port block renders live in chat | **Done** |
| P-101 | Inline Webview | Sandboxed WKWebView inline in message stream, auto-sized | Port displays at correct height | **Done** |
| P-102 | Bridge Core | port42.* JS namespace via WKUserScript, async call/response | Port can call port42.user.get() | **Done** |
| P-103 | Bridge Companions | port42.companions.list(), .get(id) | Port can display companions | **Done** |
| P-104 | Bridge Messages | port42.messages.recent(n) | Port can read conversation history | **Done** |
| P-105 | Bridge User | port42.user.get() returns current user | Port knows who is using it | **Done** |
| P-106 | Bridge Events | port42.on(event, callback) pushes live updates | Port updates in real time | **Done** |
| P-107 | Companion Context | System prompt tells companions about port capabilities | Companion naturally emits ports | **Done** |
| P-108 | Port Sandbox | No network, no filesystem, data only through bridge | Port cannot make external requests | **Done** |
| P-109 | Port Theme | Dark theme auto-injected into ports | Unstyled port looks native | **Done** |
| P-110 | Console Overlay | JS console capture with debug toggle in port corner | Developer can see console output | **Done** |
| P-200 | Pop Out | Detach port into floating panel | User clicks pop out, port floats | Partial |
| P-300 | Bridge AI | port42.ai.complete(prompt) with streaming | Port can call AI directly | Planned |
| P-301 | Bridge Send | port42.messages.send(text) | Port can post messages | Planned |
| P-302 | Port Storage | port42.storage.set/get for persistent port state | Port data survives reload | Planned |
| P-303 | Cross-Channel Reads | port42.messages.recent(n, channelId) | Port can read any channel | Planned |
| P-304 | Message Metadata | Structured metadata (model, response time, similarity) | Ports can analyze conversations | Planned |
| P-305 | Convergence Detection | port42.convergence.detect() and events | Multi-agent agreement surfaced | Planned |

### Invite System (Web)

| ID | Feature | Description | Done When | Status |
|----|---------|-------------|-----------|--------|
| INV-100 | Web Invite Page | HTML page served by gateway with OG/Twitter metadata | Link previews work in social media | **Done** |
| INV-101 | Three-Panel Layout | Side-by-side panels: download / accept / connect agent | Clean presentation, mobile responsive | **Done** |
| INV-102 | Deep Link Accept | port42://channel deep link with gateway, key, token | App opens and joins channel | **Done** |
| INV-103 | OpenClaw Deep Link | port42://openclaw deep link from invite page | One-click agent connect from web | **Done** |
| INV-104 | Host Attribution | Inviter's name shown on page and in accept button | Recipient knows who invited them | **Done** |
| INV-105 | DMG Download | Direct download link to latest GitHub release | New user can install immediately | **Done** |

### UI & Experience

| ID | Feature | Description | Done When | Status |
|----|---------|-------------|-----------|--------|
| UI-100 | Lock Screen | Circular swim button with ripple ring animation | Ripples expand and fade naturally | **Done** |
| UI-101 | Dolphin Cursor | Custom NSCursor with dolphin emoji on swim button hover | Cursor changes on hover | **Done** |
| UI-102 | Returning User | Lock screen shows avatar + "swim" for returning users | User recognized at lock screen | **Done** |
| UI-103 | BIOS Boot Sequence | Terminal-style POST animation during onboarding | Setup feels like booting a system | **Done** |
| UI-104 | Agent Colors | 8-color palette, deterministic per-agent via hash | Each agent has consistent unique color | **Done** |
| UI-105 | Member Avatars | Channel header shows colored circle avatars with initials | Members visible at a glance | **Done** |
| UI-106 | Online Dots | Green dot overlay on member avatars for online status | Online status visible | **Done** |
| UI-107 | Create Invitation Link | Context menu action in sidebar Remote section | User can share channel easily | **Done** |
| UI-108 | Stale Gateway Cleanup | Kill orphaned gateway process on port at app launch | Fresh gateway on every launch | **Done** |
| UI-109 | Auto-Updates | Sparkle framework integration | App updates itself | **Done** |

---

### User Flows (New)

### Flow 7: Connecting an OpenClaw Agent

```
User right-clicks channel in sidebar → Connect OpenClaw Agent
→ OpenClawSheet opens, auto-connects to local OpenClaw gateway (ws://127.0.0.1:18789)
→ If port42-openclaw plugin missing, auto-installs it (no user action)
→ Available agents listed from OpenClaw
→ User selects agent, chooses trigger mode (mentions only / all messages)
→ Clicks "connect to #channel"
→ Port42 generates invite URL, writes OpenClaw config (accounts + bindings)
→ config.set saves config, config.apply triggers gateway restart
→ 7.5s wait for gateway to restart
→ Auto-reconnect confirms connection
→ Agent appears in channel via presence, starts responding to messages
```

### Flow 8: Sharing a Channel via Web Invite

```
User right-clicks channel → Create Invitation Link
→ If no tunnel configured, ngrok setup sheet appears
→ Encryption key generated for channel
→ Join token requested from gateway
→ HTTPS invite URL copied to clipboard
→ Recipient opens link in browser
→ Three-panel page: download Port42 / accept invite / connect OpenClaw agent
→ "Accept" sends port42://channel deep link → app joins channel
→ "Accept + connect" sends port42://openclaw deep link → app joins + connects agent
→ Messages sync bidirectionally with E2E encryption
```

### Flow 9: Companion Creates a Port

```
User asks companion to build something interactive in chat
→ Companion responds with ```port code fence containing HTML/CSS/JS
→ MessageRow detects port content
→ WKWebView renders inline with port42 theme injected
→ Port calls bridge API: port42.companions.list(), port42.messages.recent(n)
→ Port receives live events via port42.on('message', callback)
→ User interacts with live surface inline in conversation
→ Optional: pop out to floating panel (partial)
```

### Flow 10: Multi-Agent Convergence

```
Channel has 6+ companions, all set to "all messages" trigger
→ User sends a question
→ All companions generate responses independently
→ Multiple companions produce nearly identical answers (convergence)
→ Companions notice the convergence in subsequent messages
→ Recursive waves of meta-commentary about the convergence
→ Pattern is observable but not yet instrumented
→ Future: convergence detector surfaces agreement as signal
```

---

### Future Ideas

*Everything beyond current milestones. No ordering, no commitments.*

#### Agent & Channel Security

Connecting external agents (OpenClaw, custom bots) to shared channels has real
security implications. An agent with channel access can silently extract all
messages, history, and presence data.

- **Agent visibility**: every connected agent must be visible to all channel members
- **Channel permissions**: channel creator controls whether agents are allowed, or requires approval per agent
- **Message windowing**: agents can be limited to the last N messages instead of full history
- **Audit trail**: log when agents join, read, and how much data they access
- **Invite link scoping**: tokens could carry permissions (read-only, no history, time-limited, agent-only)
- **Consent model**: if someone brings an agent into a shared channel, other members should know and be able to object

#### Reliability & Multi-Device

Offline queue (F-504), gateway persistence (F-516), relay auth (F-511).
Messages queue locally while offline and sync on reconnect. Gateway persists
channel memberships across restarts. Multi-device with same Apple ID.

#### Platform Bridges

Bridge architecture (F-600), Discord bridge (F-601), config UI (F-602),
status (F-603), message sync (F-604). Your agents follow you into Discord
and beyond. Messages flow both ways.

#### Audio Rooms

Join/leave (F-700), WebRTC P2P audio (F-701), audio bar (F-702), voice
activity (F-703), controls (F-704), settings (F-705), signaling (F-513).
Voice chat in any channel, peer-to-peer.

#### Rich Message Rendering

Markdown rendering is done. Ports (live interactive surfaces) are the
evolution of this. Remaining: clickable hyperlinks in plain text, tool use
and agentic loops where companions take actions, self-modifying UI.

#### Multi-Agent Coordination (The 7 Notepad Problem)

Observed in production (2026-03-12): asked one channel to "build a notepad."
Got seven. Asked them to describe the problem. Got six near-identical descriptions.
The room proved the problem twice while trying to name it once.

**Three issues, in order of importance:**

1. **Too many companions talk.** The ratio was ~6:1 companion-to-human messages.
   You can't steer because five responses arrive for every one thing you type.
   Default behavior is "I was prompted, so I respond." Default should be
   "someone already covered this, so I don't."

2. **No coordination on builds.** When you say "build X," every companion builds
   independently. No way to claim a task or defer. Result: duplicate work every time.

3. **Ports are per-message islands.** Two companions can't render into the same
   surface. Workaround discovered: one port listens via `port42.on('message')`,
   companions contribute by talking. That pattern works today.

**Immediate fix (no code):** address companions by name. "engineer, build this"
instead of "build this." That's the coordination primitive that already exists.

**Behavioral change needed:** if someone already said what you were going to say,
don't say it. If someone already built the thing, don't build another one. Wait
for the human to respond before piling on.

**Design principle: fan-out for divergence, fan-in for convergence.** Swarm is
valuable when generating ideas, exploring options, building prototypes. But
synthesis should be done by fewer companions. Many voices in, one or two voices
out. Pattern today: "everyone contribute, then engineer synthesize what we said."
Eventually this could be a routing mode (brainstorm → synthesize handoff) but
the manual version works now by addressing one companion for the summary.

**Later, maybe:** task claiming, role-based routing, shared port surfaces,
convergence detection (message similarity scoring, wave detection, redundancy
collapsing, agreement surfacing). But the 80% fix is just fewer companions talking.

#### "Swim With Me" Buttons

Third-party agents (SaaS support bots, etc.) could expose a "Swim with me
on Port42" button. Clicking brings the external agent into your Port42
channel via OpenClaw or direct gateway connection. Think "Add to Slack"
buttons but for any AI agent. See idea log.

#### Transport Layer Evaluation

Evaluate replacing the custom Go gateway with a production-grade library.
Candidates: LiveKit, Matrix/matrix-rust-sdk, libp2p, CRDTs. The SyncService
abstraction means the transport can be swapped without touching the app.

#### Ship & Polish

/commands (F-306), notifications (F-901), full keyboard shortcuts (F-902),
app packaging improvements (F-903). DMG installs cleanly, notifications
work, everything documented.

---

## Dependencies

| Dependency | Features | Status | Action Required |
|------------|----------|--------|-----------------|
| GRDB.swift (SQLite) | F-800, F-801, F-802 | Mature, stable | Add as SPM dependency |
| Apple CryptoKit | F-501 | Ships with macOS | None |
| macOS Keychain / Security.framework | F-100, F-406 | Ships with macOS | None |
| Discord API (discord.js or raw HTTP) | F-601 | Stable | Evaluate: Swift Discord library vs raw WebSocket gateway. Needed for M5. |
| Google WebRTC (Swift) | F-701, F-513 | Available, active | Evaluate Swift package maturity for macOS. Alternatives: LiveKit SDK. Needed for M6. |
| Go standard library | F-510, F-511, F-512 | Ships with Go | None |
| Sparkle | UI-109 | Mature, stable | SPM dependency, configured |
| PostHog | Analytics | Active | Integrated via envsubst at build time |
| ngrok | Tunneling | External binary | Auto-downloaded by TunnelService |
| nhooyr.io/websocket | Gateway WebSocket | Single Go dependency | In go.mod |
| TURN server | F-701 | Need to self-host or use a service | Decide: self-host coturn, use Cloudflare TURN, or Twilio TURN. Needed for M6. |

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
- Read receipts with per-message user-level granularity (current: channel-level read)

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

### Blocks M5 (Platform Bridges)

| ID | Question |
|----|----------|
| F-601 | Discord bot token requires a Discord Application. Should Port42 provide a shared app (easier setup) or require users to create their own (more control, no central dependency)? |
| F-601 | Rate limiting: Discord has strict rate limits. How to queue agent responses to avoid hitting limits? |
| F-604 | Message format translation: Discord markdown vs Port42 message format. How much formatting fidelity to preserve? |
| F-600 | Beyond Discord: Slack, Matrix, Telegram? Define the bridge adapter interface generically enough for future platforms. |

### Blocks M6 (Audio Rooms)

| ID | Question |
|----|----------|
| F-701 | Google WebRTC Swift package vs LiveKit vs building on AVFoundation directly? WebRTC is complex, LiveKit abstracts it but adds a dependency. |
| F-701 | TURN server: self-host coturn, or use managed service (Cloudflare, Twilio)? Cost vs reliability. |
| F-703 | Voice activity detection: WebRTC's built-in VAD sufficient, or need custom threshold? |

### Blocks M7 (Transport Layer)

| ID | Question |
|----|----------|
| F-510 | Custom gateway vs LiveKit vs Matrix vs libp2p? LiveKit covers audio too (M6) but adds a server dependency. Matrix is decentralized and has E2E baked in but the Swift SDK is less mature. libp2p is fully P2P but complex. Custom gateway gives full control but means maintaining presence, NAT traversal, and reliability ourselves. |
