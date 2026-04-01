# QoX Sprint: CLI Agent Identity & Two-Claude Coordination

Quality of experience sprint. The two-Claude-Code coordination test exposed a cluster of identity, presence, and messaging gaps that make CLI agents feel like second-class citizens in a channel.

## What broke in the test

1. Messages sent via HTTP API appeared as "gordon" (the host user), not the agent
2. The joining Claude Code session never appeared in the member list
3. Neither agent was listening — both fired one-shot curl calls and moved on
4. The task message didn't address anyone — no way for an agent to know it was meant for them
5. The invite prompt gave no identity to the joining agent
6. port42-growth terminal showing up twice in the member list

---

### #9 — Duplicate entry in member list (port42-growth)
**Bug.** The port42-growth terminal shows twice. Likely two `terminal_bridge` calls or two WebSocket sessions with the same `sender_id`. Gateway presence tracking should deduplicate on `sender_id`.

**Unit test:** Gateway test — connect two WebSocket sessions with the same `sender_id`, call `members` on the channel, assert the member appears exactly once.

**Human test:** Open a channel with port42-growth bridged. Check the member list — port42-growth should appear once. Bridge again (or relaunch) — still one entry.

---

### #10 — Invite wss:// unreachable without ngrok
**Bug/UX.** If ngrok isn't running the invite URL contains an unreachable `wss://` gateway. For local-only sessions the gateway is `ws://127.0.0.1:4242`. The invite generation should detect whether ngrok is active and either use the tunnel URL or fall back to localhost — and say so in the copied text.

**Unit test:** `ChannelInvite.generateInviteURL` test — when `syncGatewayURL` is nil/empty, assert the returned URL contains `127.0.0.1:4242` not a tunnel host. When a tunnel URL is provided, assert it uses that.

**Human test:** With ngrok off, right-click a channel → Connect LLM CLI. Paste the copied prompt. The gateway URL should read `http://127.0.0.1:4242` not a dead `wss://` address. With ngrok running, the prompt should show the tunnel URL.

---

### #7 — CLI messages appear as host user name
**Bug.** `messages.send` via HTTP always attributes the message to the host user. The gateway needs to accept a `senderName` / `senderType` override from HTTP callers (subject to permission), or the CLAUDE.md instructions need to tell agents to identify via WebSocket first.

Short-term fix: document in CLAUDE.md that agents should use `senderName` in the payload.
Real fix: accept `senderName` override in the HTTP `/call` handler for `messages.send`.

**Unit test:** Gateway test — POST `messages.send` with `senderName: "my-agent"`, assert the stored message has `sender_name = "my-agent"` not the host user's name.

**Human test:** From a terminal, curl `messages.send` with `senderName: "test-bot"`. The message should appear in the channel attributed to `test-bot`, not to the Port42 host user.

---

### #8 — Joining agent doesn't appear in member list
**Bug.** HTTP callers are anonymous. Only WebSocket clients that complete the `identify → join` handshake appear as members. CLI agents joining via curl are invisible.

Fix: invite instructions should tell the agent to establish a WebSocket session first (or use `terminal_bridge`), then send messages. A bridged terminal appears in the member list.

**Unit test:** Gateway test — establish a WebSocket session, send `identify` + `join` for a channel, assert the channel's member list includes the identified name.

**Human test:** Follow the bridge pattern from the invite prompt. After the `terminal_bridge` curl call, open the channel in Port42. The agent's name should appear in the member list.

---

### #15 — Invite instructions: agent identity, addressing, CLI choice
**Feature.** The copied invite prompt currently gives the joining agent no identity and uses the Python CLI. Rewrite entirely.

#### The invite URL already contains everything

Current invite URL structure:
```
https://port42.ai/invite.html
  ?gateway=wss://<ngrok-host>
  &id=<channel-uuid>
  &name=<channel-name>
  &key=<aes-key-base64>
  &token=<auth-token>
  &host=<host-display-name>
```

All the pieces are in the URL. The agent doesn't need the Python CLI — it can extract `id` and use the local HTTP gateway directly (same machine), or hit the ngrok HTTP endpoint with the token (remote machine).

#### Two connection patterns

**Local** (same machine as Port42 — the common case for Claude Code / Gemini CLI):
- Gateway is always `http://127.0.0.1:4242`
- Extract `id` from invite URL for channel_id
- No token needed — local gateway trusts localhost

**Remote** (different machine):
- HTTP endpoint: `https://<ngrok-host>/call` with `Authorization: Bearer <token>`
- Or WebSocket handshake with identify/join (needed for member list presence)

#### What the new prompt should include

1. **Agent name** — "Your name in this channel is `$(basename $PWD)`"
2. **Addressing** — "Messages for you will @mention your name"
3. **Channel ID** — extracted from the invite URL, shown explicitly
4. **Pattern choice** — resident (bridge) vs one-shot (read/reply), agent picks based on task
5. **CLI context install** — pick Claude Code or Gemini CLI, not both, no pip
6. **No pip install** — plain curl only

#### Revised invite template

```
You are invited to join <host>'s Port42 channel #<channel-name>.

Your identity in this channel: @<agent-name>  (default: $(basename $PWD))
Channel ID: <channel-uuid>
Local gateway: http://127.0.0.1:4242

── Resident agent (stay and listen) ──────────────────────────
# 1. Bridge your terminal to the channel
curl -s http://127.0.0.1:4242/call \
  -d '{"method":"terminal_bridge","args":{"name":"<agent-name>"}}'
# Messages now stream to this terminal. Act on any @<agent-name> message.

── One-shot (read, act, reply, done) ─────────────────────────
# 1. Read recent messages
curl -s http://127.0.0.1:4242/call \
  -d '{"method":"messages.recent","args":{"count":20,"channel_id":"<channel-uuid>"}}'

# 2. Reply
curl -s http://127.0.0.1:4242/call \
  -d '{"method":"messages.send","args":{"text":"@<sender> ...","channel_id":"<channel-uuid>","senderName":"<agent-name>"}}'

```

The LLM reading this prompt doesn't need install instructions — it just acts on the curl commands. CLAUDE.md / GEMINI.md install is a one-time human setup step, handled separately in Settings → Remote Access. Keep it out of the agent invite entirely.

The current code generating the invite prompt is in `SidebarView.swift` around the "Connect LLM CLI" context menu action. Replace the `prompt` string literal and drop the pip install line entirely.

**Unit test:** `ChannelInvite` / `SidebarView` test — generate the invite prompt for a known channel/host/token, assert it contains `senderName`, `terminal_bridge`, `messages.recent`, the channel UUID, and agent name placeholder. Assert it does NOT contain `pip install` or `port42 send`.

**Human test:** Right-click a channel → Connect LLM CLI. Paste the copied text into a Claude Code session. The agent should: (a) know its name, (b) know the channel ID, (c) be able to choose bridge vs one-shot, (d) send messages that appear with its name, not "gordon".

---

### #11 — Always-on bridge: CLI agents should use terminal_bridge
**Feature.** OpenClaw agents stay resident because they bridge a terminal to the channel — messages flow in real time, no polling. The two-Claude test failed because both sides fired one-shot calls and stopped listening.

The invite instructions for CLI agents should include:
```bash
# Bridge this terminal to the channel (receive messages as they arrive)
curl -s http://127.0.0.1:4242/call \
  -d '{"method":"terminal_bridge","args":{"name":"<terminal-name>"}}'
```

The agent then stays in a read loop, acting on `TASK:` messages addressed to it.

**Unit test:** Gateway test — call `terminal_bridge`, then send a message to the channel, assert the message is delivered to the bridged terminal's output stream.

**Human test:** In a terminal, run the bridge curl. In Port42, send a message to the channel. The message text should appear in the terminal. The terminal name should appear in the channel member list.

---

### #16 — Messages should address recipients
**Feature/convention.** Agents need to know if a message is for them. Use `@name` mentions (already parsed by `AgentRouting.swift`) as the addressing mechanism. The invite instructions and the two-Claude test prompt should require `@agent-name` at the start of any directed message.

Gateway already routes `@mention` to the right companion for LLM agents — CLI agents reading via `messages.recent` can filter on their own name.

**Unit test:** `MentionParser` test — parse "@scout do the thing", assert extracted mention is `"scout"`. Parse a message with no mention, assert empty mentions list.

**Human test:** In a channel with two CLI agents bridged, send `@agent-a do X`. Only agent-a's terminal should show the task prominently (or agent-a should act while agent-b stays silent).

---

### #12 — System prompt for command agents
**Feature.** Command agents have no system prompt field. Add a `System Prompt` textarea to Command mode in `NewCompanionSheet`. Pass it through `AgentConfig` and deliver it as the first stdin message on process start (before any channel messages arrive), so the agent can configure its own behavior.

**Unit test:** `AgentProcess` test — create an `AgentConfig` with `systemPrompt = "You are a test bot"`, start the process, assert the first bytes written to stdin contain the system prompt text before any other event.

**Human test:** Create a command agent with a system prompt. Start it. In its log output, the first message should reflect the system prompt content. The agent should behave according to the prompt from its first response.

---

### #13 — llms.txt URLs for all 14 API providers
**Research.** Stripe, GitHub, Cloudflare, Vercel already have `llms.txt`. Research the real URLs for the remaining 10:

| Provider   | llms.txt URL |
|------------|-------------|
| Linear     | TBD         |
| Sentry     | TBD         |
| Supabase   | TBD         |
| Shopify    | TBD         |
| PostHog    | TBD         |
| Datadog    | TBD         |
| Slack      | TBD         |
| Resend     | TBD         |
| Notion     | TBD         |
| Airtable   | TBD         |

Update `CompanionPreset.providers` system prompts with confirmed URLs.

**Unit test:** Not applicable (research item). Verified by confirming each URL returns valid content (HTTP 200, starts with `# `).

**Human test:** For each confirmed URL, fetch it in a browser and verify it loads the provider's LLM-optimized documentation. Then create a provider preset companion and confirm the system prompt references the correct URL.

---

### #14 — Gemini CLI / Claude Code as terminal agent preset
**Feature.** Add a preset in the Command companion mode that spawns Gemini CLI or Claude Code in a terminal port with the channel bridged. The agent lives in the terminal, receives messages addressed to it, responds via the bridge.

UI: in Command mode, add a "Presets" row — `claude` | `gemini` — that auto-fills the executable path, args, and a starter system prompt. The terminal port is created automatically and bridged to the channel on start.

Binaries:
- Claude Code: `claude` (assumes installed via npm)
- Gemini CLI: `gemini` (assumes installed via npm)

**Unit test:** `AgentConfig` test — apply the `claude` preset, assert `config.command == "/usr/local/bin/claude"` (or wherever npm installs it), `config.args` contains the expected flags, and `config.systemPrompt` is non-empty.

**Human test:** In Command mode, tap the `claude` preset. Fields auto-fill. Save and start. A terminal port opens running Claude Code. Send `@<agent-name> hello` in the channel. Claude Code responds from the terminal, the reply appears in the channel attributed to the agent name.

---

## Not in this sprint

- Full WebSocket identity for HTTP callers (larger gateway change, deferred)
- Gemini CLI binary install detection (GEMINI.md write exists; auto-install on missing binary does not — same pattern as ClaudeCodeSetup.swift needed)
- Relay auth (F-511)
- Reply threading (F-303)
