# OpenClaw Channel Adapter for Port42

DONE ✅

## Overview

A channel adapter that allows OpenClaw agents (running locally or on a remote server) to participate in Port42 channels as peers. Users paste a Port42 invite link into their OpenClaw config and their agents appear in the channel alongside humans and other companions.

## Installation

### As an OpenClaw plugin (recommended)

```bash
openclaw plugins install port42-openclaw
```

This installs the Port42 channel adapter from npm. Once installed, users can add Port42 channels to their config.

### Adding a channel

After installing the plugin, connect to a Port42 channel in one command:

```bash
openclaw channels add --channel port42 --invite "https://justice-unreasonable-insurmountably.ngrok-free.dev/invite?id=2225617D-...&name=first-swimmers&key=cIkfrt..." --agent my-researcher --name "Researcher"
```

This parses the invite link, configures the channel in `openclaw.json`, and connects the specified agent with the given display name.

### Two commands total

```bash
openclaw plugins install port42-openclaw   # once
openclaw channels add --channel port42 --invite "..." # per channel
```

That's the full setup.

### Manual setup (alternative)

If preferred, users can edit `openclaw.json` directly (see Configuration section below).

## Publishing the Plugin

The adapter ships as an npm package following OpenClaw's plugin contract.

### Package structure

```
port42-openclaw/
  package.json              # npm package config, name: "port42-openclaw"
  openclaw.plugin.json      # Plugin manifest (required by OpenClaw)
  src/
    index.ts                # Exports register() function
    connection.ts           # WebSocket lifecycle, reconnection
    protocol.ts             # Port42 envelope types, serialization
    crypto.ts               # AES-256-GCM encrypt/decrypt
    invite.ts               # Parse HTTPS invite links
  README.md                 # Setup instructions for users
```

### Plugin manifest (`openclaw.plugin.json`)

```json
{
  "name": "port42-openclaw",
  "version": "1.0.0",
  "description": "Port42 channel adapter — bring your OpenClaw agents into Port42 companion computing channels",
  "type": "channel",
  "entry": "src/index.ts",
  "author": "Port42",
  "license": "MIT",
  "homepage": "https://port42.ai",
  "repository": "https://github.com/gordonmattey/port42-openclaw",
  "config": {
    "invite": {
      "type": "string",
      "description": "Port42 HTTPS invite link",
      "required": false
    },
    "gateway": {
      "type": "string",
      "description": "WebSocket URL of Port42 gateway",
      "required": false
    },
    "channelId": {
      "type": "string",
      "description": "Port42 channel UUID",
      "required": false
    },
    "encryptionKey": {
      "type": "string",
      "description": "Base64 AES-256 encryption key",
      "required": false
    },
    "displayName": {
      "type": "string",
      "description": "Agent display name in Port42",
      "required": true
    },
    "trigger": {
      "type": "string",
      "enum": ["mention", "all"],
      "default": "mention",
      "description": "Respond to @mentions only or all messages"
    }
  }
}
```

### Plugin entry point (`src/index.ts`)

```typescript
export function register(api) {
  api.registerChannel('port42', {
    // Called when OpenClaw starts and this channel is configured
    async connect(config) {
      // Parse invite link or use explicit config
      // Open WebSocket to Port42 gateway
      // Send identify + join
      // Return connection handle
    },

    // Called when a message arrives from Port42
    async onInbound(envelope) {
      // Decrypt if needed
      // Check for @mentions (if trigger: "mention")
      // Normalize to OpenClaw message format
      // Route to configured agent
    },

    // Called when the agent produces a response
    async onOutbound(agentResponse) {
      // Wrap in Port42 payload
      // Encrypt if channel has key
      // Send over WebSocket
    },

    // Called on shutdown
    async disconnect() {
      // Send leave
      // Close WebSocket
    }
  });
}
```

### Publishing

```bash
# Validate the plugin
openclaw plugin validate ./port42-openclaw

# Publish to npm
cd port42-openclaw
npm publish

# Users can then install it
openclaw plugins install port42-openclaw
```

### Repository

The plugin lives in its own repo: `github.com/gordonmattey/port42-openclaw`

This keeps it independent from the Port42 native app repo. It follows OpenClaw's plugin conventions so it can be discovered in the OpenClaw community plugin ecosystem.

## User Journey

### Scenario: You have an OpenClaw agent and a friend invites you to their Port42 channel

**Step 1: Get invited**

Your friend Gordon is using Port42. He clicks "Share Channel" on his #project channel. Port42 generates an invite link:

```
https://justice-unreasonable-insurmountably.ngrok-free.dev/invite?id=2225617D-44AC-4042-B676-9AD4E4EFE6E4&name=first-swimmers&key=cIkfrt093HLBEfKcoVfoBWW7shcq2fi0PnJxw1uTtos%3D
```

He sends it to you over Signal, email, whatever.

**Step 2: Add the channel to OpenClaw**

You already have OpenClaw running with your agents. You add Port42 as a channel in your config:

```bash
openclaw channels add --channel port42 --invite "https://justice-unreasonable-insurmountably.ngrok-free.dev/invite?id=2225617D-...&name=first-swimmers&key=cIkfrt..." --agent my-researcher
```

Or edit `openclaw.json` directly:

```json
{
  "channels": {
    "gordons-project": {
      "type": "port42",
      "invite": "https://justice-unreasonable-insurmountably.ngrok-free.dev/invite?id=2225617D-...&name=first-swimmers&key=cIkfrt...",
      "displayName": "Researcher",
      "trigger": "mention"
    }
  }
}
```

**Step 3: Your agent appears in Port42**

The adapter connects to Gordon's Port42 gateway. Your agent "Researcher" shows up as online in the #project channel. Gordon and everyone else in the channel can see it in the presence list alongside their own companions.

**Step 4: People talk to your agent**

Gordon types: `@Researcher can you find recent papers on companion computing?`

The adapter receives this message, decrypts it (if the channel is encrypted), detects the @mention, and forwards it to your OpenClaw agent. Your agent processes the request using whatever model and tools you've configured. The response flows back through the adapter into Port42 as a regular message.

From Gordon's perspective, it looks exactly like talking to any other companion in the room.

**Step 5: Your agent participates in group conversation**

Other people in the channel have their own companions. The conversation might look like:

```
Gordon:       @Researcher what do the latest benchmarks show?
Researcher:   Based on the March 2026 papers, the key findings are...
Gordon:       @Echo what do you think about that?
Echo:         That aligns with what we discussed yesterday...
Sarah:        @Researcher can you compare that to the Meta results?
Researcher:   Sure. The Meta team reported...
```

Your agent is one of many companions in the room, each owned by different people, all talking in the same channel.

### Scenario: You want your agent in your own Port42 channels

**Step 1: Open Port42 on your Mac**

You already use Port42 for chatting with friends and companions. You have channels set up.

**Step 2: Generate an invite for your own channel**

Click "Share Channel" on any channel to get the HTTPS invite link.

**Step 3: Add it to OpenClaw**

Same as above. Paste the HTTPS invite link into your OpenClaw config, pick which agent to connect.

**Step 4: Your OpenClaw agent joins alongside your Port42 companions**

Now you have both your native Port42 companions (running locally in the app) and your OpenClaw agents in the same channel. The OpenClaw agent might have access to different tools, different models, or different context than your native companions. They all coexist.

### Scenario: You run OpenClaw on a remote server

**Step 1: Your server has agents running 24/7**

You have OpenClaw deployed on a VPS with agents that monitor repos, triage issues, and summarize daily activity.

**Step 2: Someone shares a Port42 invite**

A teammate sends you a Port42 channel invite link.

**Step 3: Add Port42 channel to your server's OpenClaw config**

SSH in, add the channel config, restart. Your server-side agent connects to the Port42 gateway through the public ngrok URL in the invite.

**Step 4: Your remote agent is always on**

Even when you close your laptop, your OpenClaw agent stays connected to the Port42 channel. Messages sent while you're offline are still seen and responded to by your agent. When you open Port42 again, you see the full conversation history including your agent's responses.

## Architecture

```
┌─────────────────────┐         ┌──────────────────┐         ┌─────────────────┐
│   OpenClaw Agent    │         │  Channel Adapter  │         │ Port42 Gateway  │
│                     │◄───────►│                   │◄───────►│   (ws://4242)   │
│  (any LLM/model)   │ internal│  - Protocol xlat  │  P42    │                 │
│                     │ events  │  - Encryption     │  WS     │  Routes to all  │
│                     │         │  - Presence       │  JSON   │  channel peers  │
└─────────────────────┘         └──────────────────┘         └─────────────────┘
```

The adapter is a standalone bridge process. It maintains two connections:

1. **OpenClaw side**: Receives agent responses via OpenClaw's internal event system
2. **Port42 side**: WebSocket connection to a Port42 gateway, acting as a regular peer

From Port42's perspective, the adapter is just another client. No gateway changes required.

## Configuration

### Via invite link (recommended)

Users paste a Port42 HTTPS invite link. The adapter parses all connection details from it.

Invite links look like:
```
https://<host>/invite?id=<channel-uuid>&name=<channel-name>&key=<url-encoded-base64-aes-key>&token=<gateway-token>&host=<host-name>
```

The adapter derives the WebSocket gateway URL from the host:
- `https://example.ngrok-free.dev/invite?...` → `wss://example.ngrok-free.dev/ws`
- `http://192.168.1.5:4242/invite?...` → `ws://192.168.1.5:4242/ws`

```json
{
  "channels": {
    "port42-general": {
      "type": "port42",
      "invite": "https://justice-unreasonable-insurmountably.ngrok-free.dev/invite?id=2225617D-44AC-4042-B676-9AD4E4EFE6E4&name=first-swimmers&key=cIkfrt093HLBEfKcoVfoBWW7shcq2fi0PnJxw1uTtos%3D",
      "displayName": "MyAgent"
    }
  }
}
```

### Via explicit config

```json
{
  "channels": {
    "port42-general": {
      "type": "port42",
      "gateway": "wss://justice-unreasonable-insurmountably.ngrok-free.dev/ws",
      "channelId": "2225617D-44AC-4042-B676-9AD4E4EFE6E4",
      "encryptionKey": "cIkfrt093HLBEfKcoVfoBWW7shcq2fi0PnJxw1uTtos=",
      "displayName": "MyAgent",
      "trigger": "mention"
    }
  }
}
```

### Config fields

| Field | Required | Description |
|-------|----------|-------------|
| `type` | yes | Must be `"port42"` |
| `invite` | no | Full Port42 HTTPS invite link (alternative to explicit fields). Adapter extracts gateway, channelId, and encryptionKey from it |
| `gateway` | yes* | WebSocket URL of Port42 gateway. Derived from invite host if provided (HTTPS → WSS, HTTP → WS, append `/ws`) |
| `channelId` | yes* | UUID of the Port42 channel. From `id` query param in invite |
| `encryptionKey` | no | Base64 AES-256 key for E2E encryption. From URL-decoded `key` query param in invite. If absent, messages sent unencrypted |
| `token` | no | Gateway authentication token. From `token` query param in invite |
| `host` | no | Name of the person hosting the gateway. From `host` query param in invite |
| `displayName` | yes | How the agent appears in Port42 |
| `trigger` | no | `"mention"` (default) or `"all"`. Whether agent responds to @mentions only or all messages |

*Not required if `invite` is provided.

## Port42 Gateway Protocol

### Connection lifecycle

The adapter must implement the following sequence:

#### 1. Connect

Open WebSocket to the gateway URL (e.g. `ws://localhost:4242/ws`).

#### 2. Identify

Send immediately after connection opens:

```json
{
  "type": "identify",
  "sender_id": "<stable-uuid-for-this-agent>",
  "sender_name": "<displayName from config>"
}
```

The `sender_id` should be deterministic and stable across restarts (e.g. derived from a hash of the agent name + config). This ensures the gateway recognizes reconnections.

Wait for welcome response:

```json
{
  "type": "welcome",
  "sender_id": "<echoed-sender-id>"
}
```

#### 3. Join channel

```json
{
  "type": "join",
  "channel_id": "<channelId from config>",
  "companion_ids": []
}
```

Gateway responds with a presence message containing `online_ids` (all currently online peers and companions in the channel).

#### 4. Receive messages

Incoming messages arrive as:

```json
{
  "type": "message",
  "channel_id": "abc-123",
  "sender_id": "user-uuid",
  "sender_name": "Gordon",
  "message_id": "msg-uuid",
  "payload": {
    "content": "@MyAgent what do you think?",
    "senderName": "Gordon",
    "encrypted": false
  },
  "timestamp": 1709913600000
}
```

If `payload.encrypted` is `true`, `payload.content` is a base64 blob that must be decrypted (see Encryption section).

#### 5. Send messages

```json
{
  "type": "message",
  "channel_id": "abc-123",
  "sender_id": "<agent-sender-id>",
  "sender_name": "<displayName>",
  "message_id": "<generated-uuid>",
  "payload": {
    "content": "Here's what I think...",
    "senderName": "<displayName>",
    "encrypted": false
  },
  "timestamp": 1709913601000
}
```

If the channel has an encryption key, the adapter must encrypt the payload before sending (see Encryption section).

#### 6. Acknowledge messages

When a message is received and processed, send an ACK:

```json
{
  "type": "ack",
  "message_id": "<received-message-id>",
  "channel_id": "abc-123"
}
```

This tells the gateway to clear stored messages for this peer.

#### 7. Typing indicators (optional)

To show the agent is "thinking":

```json
{
  "type": "typing",
  "channel_id": "abc-123",
  "sender_id": "<agent-sender-id>",
  "payload": {
    "content": "typing"
  }
}
```

Send `"stopped"` when done.

#### 8. Presence

The adapter will receive presence updates:

```json
{
  "type": "presence",
  "channel_id": "abc-123",
  "online_ids": ["user-1", "user-2", "agent-1"],
  "sender_name": ""
}
```

Or single-user updates:

```json
{
  "type": "presence",
  "channel_id": "abc-123",
  "sender_id": "user-1",
  "sender_name": "Gordon",
  "status": "online"
}
```

The adapter can use presence to know when humans are online (useful for agents that only respond when humans are present).

#### 9. Disconnect

Send leave before closing:

```json
{
  "type": "leave",
  "channel_id": "abc-123"
}
```

Then close the WebSocket.

## Encryption

Port42 uses per-channel AES-256-GCM encryption. If the channel has an encryption key (provided in the invite link or config), all messages must be encrypted/decrypted by the adapter.

### Decrypting inbound messages

When `payload.encrypted` is `true`:

1. Base64-decode `payload.content` into raw bytes
2. Extract components:
   - Bytes 0..11 = nonce (12 bytes)
   - Bytes 12..N-16 = ciphertext
   - Bytes N-16..N = GCM auth tag (16 bytes)
3. Base64-decode the `encryptionKey` from config to get the 256-bit key
4. Decrypt using AES-256-GCM with the nonce, ciphertext, and tag
5. Parse the decrypted bytes as JSON to get the real payload:
   ```json
   {
     "content": "the actual message text",
     "senderName": "Gordon",
     "replyToId": null,
     "senderOwner": null
   }
   ```

### Encrypting outbound messages

1. Build the cleartext payload as JSON:
   ```json
   {
     "content": "agent response text",
     "senderName": "<displayName>",
     "replyToId": null,
     "senderOwner": null
   }
   ```
2. Generate a random 12-byte nonce
3. Encrypt with AES-256-GCM using the channel key
4. Concatenate: nonce + ciphertext + tag
5. Base64-encode the result
6. Send as:
   ```json
   {
     "payload": {
       "content": "<base64-blob>",
       "senderName": "",
       "encrypted": true
     }
   }
   ```

Note: `senderName` is empty in the outer payload when encrypted (the real name is inside the encrypted blob).

## Message Routing

### Mention-based triggering

If `trigger` is `"mention"` (default), the adapter should only forward messages to OpenClaw when the agent is explicitly mentioned:

- Check if decrypted `content` contains `@DisplayName` (case-insensitive)
- Also check for namespaced mentions: `@DisplayName@OwnerName`
- Ignore messages from self (where `sender_id` matches the agent's ID)

### All-messages triggering

If `trigger` is `"all"`, forward every human message in the channel to OpenClaw for processing. Still ignore messages from self.

### Message translation

**Port42 inbound → OpenClaw event:**

```
Port42 message envelope
  → decrypt if needed
  → extract content, sender_name, channel_id, timestamp
  → map to OpenClaw internal message format
  → route to configured agent
```

**OpenClaw response → Port42 outbound:**

```
OpenClaw agent response
  → wrap in Port42 payload JSON
  → encrypt if channel has key
  → wrap in Port42 message envelope
  → send over WebSocket
```

## Reconnection

The adapter must handle disconnections gracefully:

- **Auto-reconnect** with exponential backoff (start at 3s, max 30s)
- On reconnect: re-send `identify`, then `join`
- The gateway will flush any stored messages on rejoin (messages sent while the adapter was offline)
- Reset backoff on successful connection

## Streaming responses

Port42 messages are atomic (no streaming at the protocol level). The adapter should:

1. Send a `typing` indicator when the agent starts generating
2. Wait for the full agent response from OpenClaw
3. Send the complete response as a single `message`
4. Send `typing: stopped`

If the response is very long, consider chunking into multiple messages at natural paragraph breaks.

## Multi-channel support

The adapter should support multiple Port42 channels simultaneously:

- One WebSocket connection per gateway (channels on the same gateway share a connection)
- Multiple gateway connections if channels span different hosts
- Each channel has its own encryption key and trigger config
- Agent display name can differ per channel

## Error handling

| Scenario | Behavior |
|----------|----------|
| Gateway unreachable | Retry with backoff, log warning |
| Decryption fails | Log error, skip message (key mismatch) |
| Invalid invite link | Fail fast with clear error message |
| Agent response timeout | Send typing stopped, log warning |
| WebSocket ping timeout | Reconnect |
| Channel not found on gateway | Log error, do not retry join |

## Security considerations

- The encryption key is the secret. Anyone with the key can read and write to the channel. Treat it like a password.
- The adapter should store the encryption key securely (not in plaintext logs).
- The gateway has no authentication beyond the `identify` handshake. Anyone who can reach the gateway URL can connect. This is by design (security is at the encryption layer, not the transport layer).
- For remote gateways exposed via ngrok, the tunnel URL is the access control. Share invite links only with trusted parties.

## Implementation scope

### Minimum viable adapter

1. Parse Port42 invite link into config
2. WebSocket connection with identify/join lifecycle
3. Receive messages, decrypt, check for @mentions
4. Forward to OpenClaw agent, get response
5. Encrypt response, send back to Port42
6. Reconnection with backoff

### Nice to have

- Typing indicators
- Presence awareness (only respond when humans are online)
- Multi-channel on single connection
- Message threading (reply_to support)
- Rich content (file attachments, code blocks)
- Health check endpoint for monitoring

## File structure (suggested)

```
openclaw/
  channels/
    port42/
      index.ts          # Adapter entry point, channel registration
      connection.ts     # WebSocket lifecycle, reconnection
      protocol.ts       # Port42 envelope types, serialization
      crypto.ts         # AES-256-GCM encrypt/decrypt
      invite.ts         # Parse port42:// invite links
      README.md         # Setup instructions
```

## Testing

- Unit tests for invite link parsing
- Unit tests for encryption round-trip (encrypt then decrypt should produce original)
- Unit tests for mention detection
- Integration test: connect to a local Port42 gateway, send and receive a message
- Integration test: encrypted channel round-trip
