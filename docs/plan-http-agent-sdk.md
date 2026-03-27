# HTTP Agent SDK — Full Implementation Plan

**Features:** F-670 through F-675
**Branch:** `http-agent-sdk`
**Depends on:** Gateway (gateway.go), AppState companion routing, bridge API

---

## Design Principle: Zero Rewrite

The SDK must not require changing existing code. A LangChain chain, a plain function, a CLI script — whatever the developer already has — stays exactly as-is. The wrapper is 3 lines:

```python
agent = Agent("my-thing", channels=["#work"])

@agent.on_mention
def handle(msg):
    return my_existing_function(msg.text)  # unchanged

agent.run()
```

**No orchestration.** No planner, no graph, no agent-to-agent protocol. Coordination is emergent:
- Ports are the shared surface (not shared memory)
- @mentions are the routing (not a framework)
- Silence is the default (not "everyone gets a turn")
- Secrets are the domain boundary (each companion owns its API)

This is bottom-up coordination. The GitHub + PostHog demo proved it — two companions, two SaaS APIs, one port, zero glue code. The infrastructure does the work. The SDK stays thin on purpose.

If you want to talk to another companion: @mention them in your response.
If you want to share data: push to a port.
If you want feedback: decorate another function.

Nothing else. No `Agent.register_tool()`, no `Agent.plan()`, no `Agent.coordinate_with()`.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│  Python Process (e.g. intent-engine)                         │
│                                                              │
│  from port42 import Agent                                    │
│  agent = Agent("synthesizer", channels=["#intel"])           │
│                                                              │
│  @agent.on_mention                                           │
│  def handle(msg):                                            │
│      result = synthesizer_chain.invoke(msg.text)             │
│      return result.summary                                   │
│                                                              │
│  agent.run()                                                 │
└─────────────┬────────────────────────────────────────────────┘
              │ WebSocket (ws://127.0.0.1:4242/ws) ← same endpoint!
              │
┌─────────────▼────────────────────────────────────────────────┐
│  Gateway (Go)                                port :4242      │
│                                                              │
│  /ws — same endpoint, same protocol                          │
│  ├─ identify handshake (existing)                            │
│  ├─ join channels with tokens (existing)                     │
│  ├─ message routing (existing Envelope system)               │
│  ├─ call/response RPC (bridge APIs via host, existing)       │
│  ├─ presence tracking (existing)                             │
│  ├─ store-and-forward (existing)                             │
│  └─ feedback relay (new: reactions/replies → agent)          │
│                                                              │
│  The agent IS a peer. No special type needed.                │
└─────────────┬────────────────────────────────────────────────┘
              │ WebSocket (same /ws)
              │
┌─────────────▼────────────────────────────────────────────────┐
│  Port42 macOS App (Swift)                                    │
│                                                              │
│  AppState sees agent as companion:                           │
│  ├─ presence online/offline via gateway (existing)           │
│  ├─ messages route through normal channel flow (existing)    │
│  ├─ bridge API calls routed via host peer (existing)         │
│  └─ reactions/replies forwarded back via gateway (new)       │
└──────────────────────────────────────────────────────────────┘
```

The key insight: **HTTP agents are just peers.** No new endpoint. No new handshake. No new gateway type. The existing `/ws` protocol already does everything — identify, join channels with tokens, message routing, call/response RPC, presence, store-and-forward. A Python process connecting to `/ws` is indistinguishable from another Port42 app instance.

The only new gateway work is the `feedback` message type (Phase 4). Everything else exists.

---

## Phase 1: Agent Connection via Existing Protocol (F-670)

### No new endpoint needed

The existing `/ws` flow works as-is for HTTP agents:

```
1. Agent connects to ws://127.0.0.1:4242/ws
2. Gateway sends: {"type": "no_auth"}           ← localhost, no auth
3. Agent sends:   {"type": "identify", "sender_id": "agent-synth-abc123", "sender_name": "synth"}
4. Gateway sends: {"type": "welcome", "sender_id": "agent-synth-abc123"}
5. Agent sends:   {"type": "join", "channel_id": "<uuid>", "token": "<if remote>"}
6. Gateway sends: {"type": "presence", "channel_id": "...", "online_ids": [...]}
7. Gateway sends: {"type": "history", ...}  ← channel history replay
8. Message loop — same as any peer
```

This is identical to how a second Port42 app instance connects. The Python SDK just speaks the same protocol.

### Connection: just show the code

**Localhost (most common case):**

After creating the remote companion, the UI shows a copyable code snippet:

```python
from port42 import Agent

agent = Agent("synth")
agent.run()
```

That's it. Localhost = `ws://127.0.0.1:4242`, no auth, no tokens. The agent identifies, joins channels by name, done.

**Remote (ngrok):**

Two ways to get connected:

1. **Invite page** — The existing `/invite` page gains a "connect python agent" panel (see below). User shares the invite link, developer opens it in browser, copies the snippet with gateway URL + channel ID + token pre-filled.

2. **New Companion sheet** — After creating the remote companion and assigning to a channel, the UI generates the snippet with the tunnel URL:

```python
from port42 import Agent

agent = Agent("synth",
    gateway="wss://abc123.ngrok.io",
    channels=["<channel-uuid>"],
    tokens=["<join-token>"])
agent.run()
```

Tokens come from `SyncService.requestToken()` — same invite token infrastructure used for channel invites and OpenClaw.

### Channel joining

Two flows depending on when channels are assigned:

**Flow A: Channels in connect string** (remote use case)
- Connect string includes channel UUIDs + tokens
- SDK auto-joins on connect
- Used when the user assigns the companion to channels before generating the connect string

**Flow B: Channels assigned later** (localhost use case)
- User creates remote companion, no channels yet
- Agent connects to gateway, identifies, waits
- User adds companion to channel in Port42 UI
- Port42 sends the channel ID to the agent via a new `assign` envelope (or the agent polls `channel.list` via bridge API)

For v1, go with **Flow A** — the user adds the companion to a channel first, then the connect string includes that channel. Simpler, no new envelope types.

**Channel name resolution**: The SDK calls `POST /call {"method":"channel.list"}` before connecting, matches names to UUIDs. This keeps the gateway stateless. Works because `/call` is HTTP — no WebSocket needed yet.

```python
# SDK resolves channel names before connecting
def _resolve_channels(self, names: list[str]) -> list[str]:
    resp = httpx.post(f"{self.http_url}/call", json={
        "method": "channel.list"
    })
    channels = resp.json()  # [{"id": "...", "name": "..."}]
    return [ch["id"] for ch in channels if ch["name"] in names]
```

### Auth

Auth is `no_auth` in production releases — `authVerifier` is nil, gateway sends `{"type": "no_auth"}` and the agent proceeds with identify. No tokens needed for the WebSocket handshake.

Channel access is gated by **join tokens** — same as any peer. On localhost, joins are permissive (no token required). On remote (ngrok + auth enabled in future), the agent needs a per-channel token which is included in the connect string or invite page.

No new auth mechanism needed. The existing token infrastructure handles everything.

### Code snippet generation

The invite page is hosted on the website (not the gateway). The gateway `/invite` HTML is legacy. For the Python snippet, the source is the **Port42 app UI itself** — the "Add Remote" tab in New Companion sheet.

After creating the remote companion and assigning it to a channel, the sheet generates a copyable snippet. The snippet uses `ChannelInvite.generateInviteURL()` params (gateway URL, channel ID, token) formatted as Python:

```swift
// In NewCompanionSheet, after createRemote():
let gateway = appState.sync.gatewayURL ?? "ws://127.0.0.1:4242"
let snippet = """
from port42 import Agent

agent = Agent("\(name)",
    gateway="\(gateway)",
    channels=["\(channelId)"],
    tokens=["\(token)"])
agent.run()
"""
```

For localhost, simplify to just:
```python
from port42 import Agent
agent = Agent("synth")
agent.run()
```

The website invite page could also gain a "connect python agent" panel in the future — same params are in the URL query string — but that's a separate repo/deploy.

### Presence

Already handled. `joinChannel` broadcasts presence, `removePeer` broadcasts offline. The Swift app's presence tracking picks up the agent's sender_id.

### Disconnect/reconnect

When the agent disconnects:
- `removePeer` fires, broadcasts offline
- Messages are stored via store-and-forward (`storeForPeer`)
- Agent reconnects, re-identifies with same `sender_id`, gets stored messages flushed

The SDK persists its `sender_id` locally (`.port42/agent.json`) so reconnection preserves identity:

```python
def _load_state(self):
    try:
        with open(self._state_file) as f:
            state = json.load(f)
            self.sender_id = state.get("sender_id")
    except FileNotFoundError:
        self.sender_id = f"agent-{self.name}-{uuid.uuid4().hex[:12]}"
```

### Wire protocol summary (agent ↔ gateway)

**All existing Envelope types — no new types except `feedback`:**

| Direction | Type | Fields | Notes |
|-----------|------|--------|-------|
| GW → Agent | `no_auth` | | Localhost: proceed with identify |
| GW → Agent | `challenge` | nonce | Remote: auth required |
| Agent → GW | `identify` | sender_id, sender_name, auth_type?, token? | Same as any peer |
| GW → Agent | `welcome` | sender_id | Same as any peer |
| Agent → GW | `join` | channel_id, token? | Join a channel (with invite token if remote) |
| GW → Agent | `presence` | channel_id, sender_id, status, online_ids[] | Member status |
| GW → Agent | `history` | Same as message | Replayed on join |
| GW → Agent | `message` | channel_id, sender_id, sender_name, payload, message_id, timestamp | Chat message |
| Agent → GW | `message` | channel_id, sender_id, sender_name, payload, message_id | Send chat message |
| Agent → GW | `call` | method, args, call_id, sender_id | Bridge API call (routed to host) |
| GW → Agent | `response` | call_id, payload, error? | Bridge API response |
| Agent → GW | `typing` | channel_id, sender_id | Typing indicator |
| GW → Agent | `feedback` | message_id, target_id, payload | **NEW** — reaction/reply on agent's message |

---

## Phase 2: "Add Remote Companion" UI + Swift-Side Recognition (F-670 continued)

### UI: New "Remote" tab in NewCompanionSheet

Add a fourth tab alongside Port42 / SaaS / Custom API:

```
[Port42] [SaaS] [Custom API] [Remote]
```

**TemplateCategory update:**
```swift
enum TemplateCategory { case port42, saas, custom, remote }
```

**Remote tab contents — minimal form:**

```swift
if templateCategory == .remote {
    VStack(alignment: .leading, spacing: 12) {
        Text("Connect an external process as a companion.")
            .font(Port42Theme.mono(11))
            .foregroundStyle(Port42Theme.textSecondary)

        // Name
        TextField("companion name", text: $name)
            // same styling as existing name field

        // Gateway URL (pre-filled, usually no change needed)
        TextField("ws://127.0.0.1:4242", text: $remoteGatewayURL)
            .font(Port42Theme.mono(12))
            .foregroundStyle(Port42Theme.textSecondary)

        // Trigger picker
        Picker("Trigger", selection: $remoteTrigger) {
            Text("@mentions only").tag(AgentTrigger.mentionOnly)
            Text("all messages").tag(AgentTrigger.allMessages)
        }

        // Info block
        Text("Run your agent: python agent.py\nIt connects via WebSocket and appears here.")
            .font(Port42Theme.mono(10))
            .foregroundStyle(Port42Theme.textSecondary)
    }
}
```

**New state vars:**
```swift
@State private var remoteGatewayURL = "ws://127.0.0.1:4242"
@State private var remoteTrigger: AgentTrigger = .mentionOnly
```

**Create action for remote:**

When the user clicks Create with the Remote tab active, it creates an `AgentConfig` with `mode: .httpAgent`. This is a **placeholder** — it tells the app "a companion with this name will connect externally." When the Python-side agent connects via `/agent/ws` and registers with the same name, the gateway matches them and the companion goes online.

```swift
private func createRemote() {
    guard let user = appState.currentUser else { return }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return }

    let companion = AgentConfig.createHTTPAgent(
        ownerId: user.id,
        displayName: trimmedName,
        trigger: remoteTrigger,
        gatewayURL: remoteGatewayURL
    )
    appState.addCompanion(companion)
    isPresented = false
}
```

**Similar to OpenClaw, but simpler:** OpenClaw needs plugin install + config RPC + gateway restart. Remote companions are just a config record — the agent connects itself.

### How agents appear in the Port42 app

Two paths to recognition:

1. **User creates via UI first** (the "Add Remote Companion" flow above) — AgentConfig already exists with `mode: .httpAgent`. When the agent connects and the gateway broadcasts its presence, AppState matches by `displayName` and marks it online.

2. **Agent connects without prior UI setup** — The gateway broadcasts presence for an unknown `agent-` prefixed sender_id. AppState auto-creates an `AgentConfig` with `mode: .httpAgent` from the gateway's agent info. The companion appears in the sidebar immediately.

Both paths converge: the companion exists as an `AgentConfig` in the DB, participates in routing/mentions/cooldowns like any other companion.

### AgentConfig changes

```swift
// Add to AgentConfig.AgentMode
public enum AgentMode: String, Codable {
    case llm
    case command
    case httpAgent  // new: external process via gateway WebSocket
}
```

New fields on `AgentConfig`:
```swift
public var gatewayURL: String?  // for httpAgent mode — where to connect (nil = local :4242)
```

New factory method:
```swift
public static func createHTTPAgent(
    ownerId: String,
    displayName: String,
    trigger: AgentTrigger,
    gatewayURL: String? = nil
) -> AgentConfig {
    AgentConfig(
        id: UUID().uuidString,
        ownerId: ownerId,
        displayName: displayName,
        mode: .httpAgent,
        trigger: trigger,
        systemPrompt: nil,
        provider: nil,
        model: nil,
        command: nil,
        args: nil,
        workingDir: nil,
        envVars: nil,
        createdAt: Date()
    )
}
```

### Ports context: not injected

LLM companions get port context injected into their system prompt (active ports, content summaries). HTTP agents **don't** — they're not LLM-managed. They interact with ports via bridge API calls:
- `port_create` to build a port
- `port_push` to push data into a live port
- `port_exec` to run JS on a port
- `port_patch` to make targeted edits

They deliver data (JSON, structured output, text) and build their own visual surfaces. The host app doesn't inject port state — the agent pulls what it needs.

### AgentRouter changes

`AgentRouter.findTargetAgents()` already works with `AgentConfig` — HTTP agents are just configs with `mode: .httpAgent`. Routing checks trigger mode (mentionOnly vs allMessages), same logic.

The difference: for LLM/command agents, AppState launches `LLMEngine` or `AgentProcess`. For HTTP agents, the message is already routed through the gateway — no launch needed. The HTTP agent sees it arrive via its WebSocket.

But wait — the current flow is:
1. User sends message → AppState saves to DB → SyncService sends to gateway
2. AppState also calls `triggerAgents()` → finds matching companions → launches LLMEngine

For HTTP agents, step 2 is unnecessary — the gateway already delivers the message. But the agent's response comes back as a `message` from the gateway, not from a local LLMEngine.

**Key realization:** HTTP agents don't need local triggering at all. They self-trigger on the remote side. The gateway delivers messages, the Python process handles them, sends a response, and the response arrives via gateway as a regular message.

So: `triggerAgents()` should skip HTTP agents entirely. They participate in presence and display, but not in local triggering.

### SyncService: detecting HTTP agent presence

When a `presence` event arrives with an `agent-` prefix sender_id:
1. Check if we have a local AgentConfig for this agent_id
2. If not, request agent info from gateway (new RPC: `agent.info`)
3. Create/update local AgentConfig with `mode: .httpAgent`
4. Update channel membership

### New gateway RPC: `agent.info`

When a peer sends `{"type": "call", "method": "agent.info", "args": {"agent_id": "..."}}`:
- Gateway looks up the agent in `g.agents`
- Returns: `{"name": "synthesizer", "trigger": "mention", "channels": [...]}`

This lets the Swift app populate the companion list without the agent needing to announce itself via messages.

---

## Phase 3: Python SDK (F-671)

### Package: `port42`

```
port42/
├── pyproject.toml
├── port42/
│   ├── __init__.py          # exports Agent
│   ├── agent.py             # Agent class
│   ├── connection.py        # WebSocket client
│   ├── types.py             # Message, Feedback, Port, etc.
│   ├── bridge.py            # Bridge API wrappers
│   └── langchain/           # F-673, F-674
│       ├── __init__.py
│       ├── callback.py      # Port42CallbackHandler
│       └── tools.py         # Port42Tool
```

### Dependencies

```toml
[project]
name = "port42"
requires-python = ">=3.10"
dependencies = [
    "websockets>=12.0",
]

[project.optional-dependencies]
langchain = [
    "langchain-core>=0.3",
]
```

Minimal: just `websockets`. LangChain support is optional.

### Agent class

```python
import asyncio
import json
import uuid
import threading
from websockets.sync.client import connect as ws_connect
from websockets.client import connect as ws_connect_async

class Agent:
    def __init__(
        self,
        name: str,
        channels: list[str] | None = None,
        trigger: str = "mention",       # "mention" | "all_messages"
        gateway: str = "ws://127.0.0.1:4242",
        tokens: list[str] | None = None,  # per-channel join tokens (remote)
    ):
        self.name = name
        self.channels = channels or []
        self.trigger = trigger
        self.gateway_url = gateway + "/ws"
        self.sender_id: str | None = None
        self._channel_tokens = dict(zip(self.channels, tokens or []))
        self._ws = None
        self._handlers: dict[str, list[callable]] = {
            "mention": [],
            "message": [],
            "feedback": [],
        }
        self._state_file = f".port42/{name}.json"
        self._load_state()
        if not self.sender_id:
            self.sender_id = f"agent-{name}-{uuid.uuid4().hex[:12]}"

    def _load_state(self):
        """Load sender_id from previous session for reconnect."""
        try:
            with open(self._state_file) as f:
                state = json.load(f)
                self.sender_id = state.get("sender_id")
        except FileNotFoundError:
            pass

    def _save_state(self):
        """Persist sender_id for reconnect."""
        import os
        os.makedirs(os.path.dirname(self._state_file), exist_ok=True)
        with open(self._state_file, "w") as f:
            json.dump({"sender_id": self.sender_id}, f)

    # --- Decorators ---

    def on_mention(self, fn):
        self._handlers["mention"].append(fn)
        return fn

    def on_message(self, fn):
        self._handlers["message"].append(fn)
        return fn

    def on_feedback(self, fn):
        self._handlers["feedback"].append(fn)
        return fn

    # --- Connection ---

    def run(self):
        """Block and listen for messages (sync API)."""
        self._connect()
        try:
            self._loop()
        except KeyboardInterrupt:
            self._disconnect()

    async def run_async(self):
        """Async version of run()."""
        await self._connect_async()
        try:
            await self._loop_async()
        except asyncio.CancelledError:
            await self._disconnect_async()

    @classmethod
    def from_connect(cls, connect_string: str) -> "Agent":
        """Create agent from a port42://connect? string."""
        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(connect_string)
        params = parse_qs(parsed.query)
        name = params.get("name", ["agent"])[0]
        gateway = params.get("gateway", ["ws://127.0.0.1:4242"])[0]
        channels = params.get("channels", [""])[0].split(",") if "channels" in params else []
        tokens = params.get("tokens", [""])[0].split(",") if "tokens" in params else []
        agent = cls(name=name, gateway=gateway)
        agent._channel_ids = channels
        agent._channel_tokens = dict(zip(channels, tokens))
        return agent

    def _connect(self):
        self._ws = ws_connect(self.gateway_url)
        # Step 1: Read auth prompt (no_auth or challenge)
        auth_msg = json.loads(self._ws.recv())
        if auth_msg["type"] == "no_auth":
            pass  # localhost, proceed
        elif auth_msg["type"] == "challenge":
            # Remote auth — bearer token from connect string
            pass  # TODO: bearer token auth for remote gateways

        # Step 2: Identify — same as any Port42 peer
        self._ws.send(json.dumps({
            "type": "identify",
            "sender_id": self.sender_id,
            "sender_name": self.name,
        }))
        welcome = json.loads(self._ws.recv())
        if welcome.get("type") != "welcome":
            raise ConnectionError(f"Expected welcome, got: {welcome}")
        self._save_state()

        # Step 3: Resolve channel names → UUIDs (if needed)
        if self.channels and not hasattr(self, "_channel_ids"):
            self._channel_ids = self._resolve_channels(self.channels)
            self._channel_tokens = {}

        # Step 4: Join channels — same as any peer
        for ch_id in getattr(self, "_channel_ids", []):
            join = {"type": "join", "channel_id": ch_id}
            token = getattr(self, "_channel_tokens", {}).get(ch_id)
            if token:
                join["token"] = token
            self._ws.send(json.dumps(join))
            # Read presence + history responses
            while True:
                resp = json.loads(self._ws.recv())
                if resp["type"] == "presence":
                    break  # joined successfully
                elif resp["type"] == "error":
                    print(f"Failed to join {ch_id}: {resp.get('error')}")
                    break

    def _resolve_channels(self, names: list[str]) -> list[str]:
        """Resolve channel names to UUIDs via HTTP /call API."""
        import httpx
        http_url = self.gateway_url.replace("ws://", "http://").replace("wss://", "https://")
        http_url = http_url.replace("/ws", "/call")
        resp = httpx.post(http_url, json={"method": "channel.list"})
        channels = resp.json()
        # channels is [{"id": "...", "name": "...", ...}]
        name_set = {n.lstrip("#").lower() for n in names}
        return [ch["id"] for ch in channels if ch.get("name", "").lower() in name_set]

    def _loop(self):
        while True:
            raw = self._ws.recv()
            env = json.loads(raw)
            self._dispatch(env)

    def _dispatch(self, env: dict):
        msg_type = env.get("type")

        if msg_type == "message":
            msg = Message.from_envelope(env)
            # Check if this is a mention
            if f"@{self.name}" in (msg.text or "").lower():
                for handler in self._handlers["mention"]:
                    result = handler(msg)
                    if result is not None:
                        self.send(str(result), channel_id=msg.channel_id)
            else:
                for handler in self._handlers["message"]:
                    result = handler(msg)
                    if result is not None:
                        self.send(str(result), channel_id=msg.channel_id)

        elif msg_type == "feedback":
            fb = Feedback.from_envelope(env)
            for handler in self._handlers["feedback"]:
                handler(fb)

        elif msg_type == "presence":
            pass  # could expose via on_presence

        elif msg_type == "history":
            pass  # could buffer for msg.history access

    # --- Bridge API wrappers ---

    def _call(self, method: str, args: dict = None) -> dict:
        """Make an RPC call to the Port42 host via gateway."""
        call_id = f"sdk-{uuid.uuid4().hex[:12]}"
        env = {
            "type": "call",
            "method": method,
            "args": args or {},
            "call_id": call_id,
            "sender_id": self.sender_id,
        }
        self._ws.send(json.dumps(env))
        # Wait for response with matching call_id
        # (need a pending calls map + threading for concurrent calls)
        while True:
            raw = self._ws.recv()
            resp = json.loads(raw)
            if resp.get("call_id") == call_id:
                if resp.get("error"):
                    raise RuntimeError(resp["error"])
                return resp.get("payload", {})
            else:
                # Not our response — dispatch normally
                self._dispatch(resp)

    def send(self, text: str, channel_id: str = None):
        """Send a message to a channel."""
        env = {
            "type": "message",
            "channel_id": channel_id or self._resolved_channels[0]["id"],
            "sender_id": self.sender_id,
            "sender_name": self.name,
            "message_id": f"agent-{uuid.uuid4().hex[:16]}",
            "payload": json.dumps({"text": text}).encode(),
        }
        self._ws.send(json.dumps(env))

    # Port operations
    def port_push(self, port_id: str, data: dict):
        return self._call("port.push", {"id": port_id, "data": data})

    def port_exec(self, port_id: str, js: str):
        return self._call("port.exec", {"id": port_id, "js": js})

    def port_patch(self, port_id: str, search: str, replace: str):
        return self._call("port.patch", {"id": port_id, "search": search, "replace": replace})

    def port_create(self, html: str, title: str = None):
        return self._call("port.update", {"html": html})  # creates inline port

    # Rest/HTTP
    def rest_call(self, url: str, method: str = "GET", secret: str = None, **kwargs):
        args = {"url": url, "method": method}
        if secret:
            args["secret"] = secret
        args.update(kwargs)
        return self._call("rest.call", args)

    # Clipboard
    def clipboard_read(self):
        return self._call("clipboard.read")

    def clipboard_write(self, data: str):
        return self._call("clipboard.write", {"data": data})

    # Notifications
    def notify(self, title: str, body: str = None):
        args = {"title": title}
        if body:
            args["body"] = body
        return self._call("notify.send", args)

    # Screen
    def screen_capture(self, scale: float = 0.5):
        return self._call("screen_capture", {"scale": scale})

    # Terminal
    def terminal_exec(self, command: str):
        return self._call("terminal.exec", {"command": command})

    # Files
    def files_read(self, path: str):
        return self._call("files.read", {"path": path})

    def files_write(self, path: str, data: str):
        return self._call("files.write", {"path": path, "data": data})

    # Typing indicator
    def typing(self, channel_id: str = None):
        env = {
            "type": "typing",
            "channel_id": channel_id or self._resolved_channels[0]["id"],
            "sender_id": self.sender_id,
        }
        self._ws.send(json.dumps(env))
```

### Threading model

The sync `run()` blocks on `ws.recv()` in a loop. For the `_call()` RPC pattern (send call, wait for response), there's a conflict: we need to dispatch incoming messages while waiting for a specific call response.

Solution: **Dual-thread model.**

```
Thread 1 (recv loop):   reads all WS messages, dispatches to handlers,
                         routes call responses to pending futures
Thread 2 (user thread):  handler code runs here (on_mention callbacks),
                         can call bridge APIs which block on response
```

```python
class Agent:
    def __init__(self, ...):
        self._pending_calls: dict[str, threading.Event] = {}
        self._call_results: dict[str, dict] = {}
        self._recv_thread: threading.Thread = None

    def run(self):
        self._connect()
        self._recv_thread = threading.Thread(target=self._recv_loop, daemon=True)
        self._recv_thread.start()
        self._recv_thread.join()  # block until disconnect

    def _recv_loop(self):
        while True:
            raw = self._ws.recv()
            env = json.loads(raw)
            # Check if it's a call response
            call_id = env.get("call_id")
            if call_id and call_id in self._pending_calls:
                self._call_results[call_id] = env
                self._pending_calls[call_id].set()
            else:
                # Dispatch in thread pool to avoid blocking recv
                threading.Thread(target=self._dispatch, args=(env,), daemon=True).start()

    def _call(self, method, args=None):
        call_id = f"sdk-{uuid.uuid4().hex[:12]}"
        event = threading.Event()
        self._pending_calls[call_id] = event
        self._ws.send(json.dumps({
            "type": "call", "method": method,
            "args": args or {}, "call_id": call_id,
            "sender_id": self.sender_id,
        }))
        if not event.wait(timeout=30):
            del self._pending_calls[call_id]
            raise TimeoutError(f"Call {method} timed out")
        result = self._call_results.pop(call_id)
        del self._pending_calls[call_id]
        if result.get("error"):
            raise RuntimeError(result["error"])
        return json.loads(result.get("payload", "{}"))
```

### Async API

For users who want async (LangChain is typically sync, but some users prefer async):

```python
async def run_async(self):
    async with websockets.connect(self.gateway_url) as ws:
        self._ws_async = ws
        await self._register_async()
        async for raw in ws:
            env = json.loads(raw)
            await self._dispatch_async(env)
```

The async `_call_async` uses `asyncio.Future` instead of `threading.Event`.

### Message and Feedback types

```python
@dataclass
class Message:
    text: str
    sender: str
    sender_id: str
    channel_id: str
    message_id: str
    timestamp: int
    history: list[dict]  # recent channel messages

    @classmethod
    def from_envelope(cls, env: dict) -> "Message":
        payload = json.loads(env.get("payload", "{}"))
        return cls(
            text=payload.get("text", ""),
            sender=env.get("sender_name", ""),
            sender_id=env.get("sender_id", ""),
            channel_id=env.get("channel_id", ""),
            message_id=env.get("message_id", ""),
            timestamp=env.get("timestamp", 0),
            history=payload.get("history", []),
        )

@dataclass
class Feedback:
    message_id: str     # which agent message was reacted to
    type: str           # "reaction" | "reply"
    content: str        # emoji or reply text
    sender: str
    sender_id: str

    @classmethod
    def from_envelope(cls, env: dict) -> "Feedback":
        payload = json.loads(env.get("payload", "{}"))
        return cls(
            message_id=env.get("message_id", ""),
            type=payload.get("feedback_type", ""),
            content=payload.get("content", ""),
            sender=env.get("sender_name", ""),
            sender_id=env.get("sender_id", ""),
        )
```

---

## Phase 4: Feedback Relay (F-672)

### What triggers feedback

1. **Reactions**: User clicks an emoji reaction on an agent's message
2. **Replies**: User replies in-thread to an agent's message

Both need the Swift app to detect that the target message was from an HTTP agent and relay back through the gateway.

### Swift-side: detecting agent messages

When a user reacts to or replies to a message:
1. Look up the message's `senderID`
2. If it matches an HTTP agent (prefix `agent-` or `mode: .httpAgent` in AgentConfig)
3. Send a `feedback` envelope through SyncService:

```swift
let feedback = SyncEnvelope(
    type: "feedback",
    channelID: message.channelID,
    senderID: currentUser.id,
    senderName: currentUser.displayName,
    messageID: message.id,  // the agent's message being reacted to
    payload: encodeFeedbackPayload(type: "reaction", content: "👍")
)
syncService.send(feedback)
```

### Gateway-side: routing feedback

The gateway receives the `feedback` message. It needs to find the agent that authored `message_id` and deliver the feedback to that agent's peer.

**Problem:** The gateway doesn't track message authorship — it just routes.

**Solution:** The feedback envelope includes a `target_id` field (the agent's sender_id from the original message). The Swift app knows who sent the message (it's in the local DB). So:

```swift
// Swift side fills in the target
feedback.targetID = originalMessage.senderID  // "agent-abc123"
```

Gateway routing for `feedback` type:

```go
case "feedback":
    g.routeFeedback(ctx, peer, env)

func (g *Gateway) routeFeedback(ctx context.Context, sender *Peer, env Envelope) {
    if env.TargetID == "" {
        return
    }
    g.mu.RLock()
    targetPeer, online := g.peers[env.TargetID]
    g.mu.RUnlock()
    if online {
        targetPeer.Send(ctx, env)
    } else {
        // Store for delivery when agent reconnects
        g.storeForPeer(env.TargetID, env)
    }
}
```

### Feedback webhook (optional, stateless agents)

Some agents might not keep a WebSocket open. For these, the gateway can POST feedback to a webhook URL registered during `register`:

```json
{
    "type": "register",
    "name": "batch-pipeline",
    "channels": ["#intel"],
    "trigger": "mention",
    "feedback_webhook": "http://localhost:8080/feedback"
}
```

If the agent is offline and `feedback_webhook` is set, POST instead of storing:

```go
if !online && agent.FeedbackWebhook != "" {
    go postFeedbackWebhook(agent.FeedbackWebhook, env)
}
```

This is v2. Ship without it first.

---

## Phase 5: LangChain Integration (F-673, F-674)

### Port42CallbackHandler (F-673)

Streams LangChain execution progress into Port42 channels.

```python
from langchain_core.callbacks import BaseCallbackHandler
from port42 import Agent

class Port42CallbackHandler(BaseCallbackHandler):
    def __init__(self, agent: Agent, channel_id: str = None):
        self.agent = agent
        self.channel_id = channel_id

    def on_chain_start(self, serialized, inputs, **kwargs):
        chain_name = serialized.get("name", "chain")
        self.agent.typing(self.channel_id)

    def on_chain_end(self, outputs, **kwargs):
        # If output is a Pydantic model, render as structured port
        if hasattr(outputs, "model_dump"):
            self._render_as_port(outputs)
        # Otherwise just post the string
        elif isinstance(outputs, str):
            self.agent.send(outputs, channel_id=self.channel_id)

    def on_chain_error(self, error, **kwargs):
        self.agent.send(f"⚠ Chain error: {error}", channel_id=self.channel_id)

    def on_tool_start(self, serialized, input_str, **kwargs):
        tool_name = serialized.get("name", "tool")
        self.agent.typing(self.channel_id)

    def on_tool_end(self, output, **kwargs):
        pass  # tool results flow into chain

    def _render_as_port(self, model):
        """Convert Pydantic model to an HTML port."""
        html = render_model_to_html(model)
        self.agent.port_create(html=html)
```

### Usage with intent-engine chains

```python
from port42 import Agent
from port42.langchain import Port42CallbackHandler

agent = Agent("synthesizer", channels=["#intel"])
handler = Port42CallbackHandler(agent)

@agent.on_mention
def handle(msg):
    # Run the LangChain chain with Port42 callback
    result = synthesizer_chain.invoke(
        {"transcript": msg.text},
        config={"callbacks": [handler]}
    )
    return result.summary
```

### Port42Tool (F-674)

Wraps Port42 bridge APIs as LangChain tools:

```python
from langchain_core.tools import BaseTool
from port42 import Agent

class Port42Tool(BaseTool):
    """Base class for Port42 bridge tools in LangChain."""
    agent: Agent

class RestCallTool(Port42Tool):
    name = "rest_call"
    description = "Make an HTTP request using Port42's secret store"

    def _run(self, url: str, method: str = "GET", secret: str = None, **kwargs):
        return self.agent.rest_call(url, method=method, secret=secret, **kwargs)

class ScreenCaptureTool(Port42Tool):
    name = "screen_capture"
    description = "Take a screenshot of the user's screen"

    def _run(self, scale: float = 0.5):
        return self.agent.screen_capture(scale=scale)

class ClipboardTool(Port42Tool):
    name = "clipboard"
    description = "Read or write the user's clipboard"

    def _run(self, action: str = "read", data: str = None):
        if action == "write" and data:
            return self.agent.clipboard_write(data)
        return self.agent.clipboard_read()

class TerminalTool(Port42Tool):
    name = "terminal_exec"
    description = "Run a shell command on the user's machine"

    def _run(self, command: str):
        return self.agent.terminal_exec(command)

# Convenience: get all tools
def port42_tools(agent: Agent) -> list[BaseTool]:
    return [
        RestCallTool(agent=agent),
        ScreenCaptureTool(agent=agent),
        ClipboardTool(agent=agent),
        TerminalTool(agent=agent),
    ]
```

Usage:
```python
from langchain_anthropic import ChatAnthropic
from port42.langchain import port42_tools

agent = Agent("research-bot", channels=["#research"])
tools = port42_tools(agent)
llm = ChatAnthropic(model="claude-sonnet-4-20250514").bind_tools(tools)
```

---

## Phase 6: Agent Templates (F-675)

### CLI: `port42 init`

Part of the `port42` Python package. A `[project.scripts]` entry:

```toml
[project.scripts]
port42 = "port42.cli:main"
```

```python
# port42/cli.py
import click
import os

@click.group()
def main():
    pass

@main.command()
@click.argument("name")
@click.option("--template", default="basic", help="Template: basic, langchain, pipeline")
def init(name: str, template: str):
    """Create a new Port42 agent project."""
    os.makedirs(name, exist_ok=True)

    if template == "basic":
        write_basic_template(name)
    elif template == "langchain":
        write_langchain_template(name)
    elif template == "pipeline":
        write_pipeline_template(name)

    click.echo(f"Created {name}/ — run with: cd {name} && python agent.py")
```

### Templates

**basic** — minimal agent:
```python
# agent.py
from port42 import Agent

agent = Agent("{{name}}", channels=["#general"])

@agent.on_mention
def handle(msg):
    return f"Hello {msg.sender}! You said: {msg.text}"

agent.run()
```

**langchain** — chain + callback:
```python
# agent.py
from port42 import Agent
from port42.langchain import Port42CallbackHandler
from langchain_anthropic import ChatAnthropic
from langchain_core.prompts import ChatPromptTemplate

agent = Agent("{{name}}", channels=["#general"])
handler = Port42CallbackHandler(agent)

prompt = ChatPromptTemplate.from_messages([
    ("system", "You are a helpful assistant."),
    ("human", "{input}"),
])
chain = prompt | ChatAnthropic(model="claude-sonnet-4-20250514")

@agent.on_mention
def handle(msg):
    result = chain.invoke(
        {"input": msg.text},
        config={"callbacks": [handler]}
    )
    return result.content

agent.run()
```

**pipeline** — multi-step with ports:
```python
# agent.py
from port42 import Agent

agent = Agent("{{name}}", channels=["#ops"])

@agent.on_mention
def handle(msg):
    agent.typing()

    # Step 1: Analyze
    analysis = run_analysis(msg.text)

    # Step 2: Create dashboard port
    html = render_dashboard(analysis)
    port = agent.port_create(html=html, title="Analysis")

    # Step 3: Return summary
    return f"Analysis complete. {len(analysis.items)} items flagged."

agent.run()
```

---

## Intent-Engine Mapping

How Gordon's 5 LangChain chains become Port42 companions:

### Chain → Companion mapping

| Chain | Companion name | Trigger | Channels | Behavior |
|-------|---------------|---------|----------|----------|
| synthesizer | `synth` | mention | #intel | @synth with transcript → Synthesis model → port |
| anomaly | `anomaly` | mention | #intel | @anomaly with context → AnomalyReport → port |
| gap | `gap` | mention | #intel | @gap with context → GapReport → port |
| report_writer | `writer` | mention | #reports | @writer with synthesis → RenderedReport → port |
| strategy + deal_eval | `strategy` | mention | #strategy | @strategy with context → StrategyReport → port |

### Example: synthesizer as companion

```python
# synth/agent.py
from port42 import Agent
from port42.langchain import Port42CallbackHandler
from intent_engine.chains.synthesizer import synthesizer_chain, Synthesis

agent = Agent("synth", channels=["#intel"], trigger="mention")
handler = Port42CallbackHandler(agent)

@agent.on_mention
def handle(msg):
    agent.typing()
    result: Synthesis = synthesizer_chain.invoke(
        {"transcript": msg.text},
        config={"callbacks": [handler]}
    )
    # Build a port for the synthesis
    html = render_synthesis_port(result)
    agent.port_create(html=html, title=f"Synthesis: {result.themes[0]}")
    return result.summary

@agent.on_feedback
def handle_feedback(fb):
    """User corrections flow into the feedback store."""
    from intent_engine.feedback import FeedbackStore
    store = FeedbackStore()
    store.add(fb.message_id, fb.type, fb.content, fb.sender)

agent.run()
```

### Feedback loop

The intent-engine already has a FeedbackStore (Slack reactions → corrections → next run). Port42 replaces the Slack surface:

1. synth posts a Synthesis → port in #intel
2. User reacts 👎 to a flagged theme → feedback relay (F-672) → `on_feedback` handler
3. Handler stores correction in FeedbackStore
4. Next synthesis run injects corrections into prompt
5. Better synthesis → better port

Same loop, no Slack dependency. Port42 is the feedback surface.

### Pipeline orchestrator

The existing `run_pipeline()` function (context assembly → chain execution → enrichment → delivery) could be a single companion that orchestrates the others:

```python
agent = Agent("pipeline", channels=["#intel"], trigger="mention")

@agent.on_mention
def handle(msg):
    agent.typing()
    # Run all chains in sequence
    agent.send("@synth " + msg.text)     # triggers synthesizer
    agent.send("@anomaly " + msg.text)   # triggers anomaly detector
    agent.send("@gap " + msg.text)       # triggers gap analyzer
    # Each posts their own port
    return "Pipeline dispatched. Results incoming."
```

Or keep the orchestrator as a single process running all chains internally (simpler, no coordination overhead):

```python
agent = Agent("intel", channels=["#intel"])

@agent.on_mention
def handle(msg):
    agent.typing()

    synthesis = synthesizer_chain.invoke({"transcript": msg.text})
    anomalies = anomaly_chain.invoke({"context": synthesis.dict()})
    gaps = gap_chain.invoke({"context": synthesis.dict()})

    # Build combined dashboard port
    html = render_intel_dashboard(synthesis, anomalies, gaps)
    agent.port_create(html=html, title="Intel Brief")

    return f"Intel brief ready. {len(anomalies.flags)} flags, {len(gaps.items)} gaps."

@agent.on_feedback
def handle_feedback(fb):
    feedback_store.add(fb.message_id, fb.type, fb.content, fb.sender)
```

---

## Implementation Order

### Sprint 1: Python SDK + zero gateway changes

**Goal:** Python process connects to existing gateway, sends/receives messages. No gateway changes needed.

1. **Python**: `port42/connection.py` — WebSocket client speaking existing identify/join/message protocol
2. **Python**: `port42/agent.py` — Agent class with `on_mention`, `on_message`, `run()`
3. **Python**: `port42/types.py` — Message dataclass
4. **Python**: Channel name resolution via `POST /call {"method":"channel.list"}`
5. **No gateway changes** — the agent is just a peer on `/ws`
6. **Test**: Python agent connects to running Port42 gateway, receives a message, sends a response back, message appears in channel

### Sprint 2: Bridge API access

**Goal:** Python agent can call Port42 bridge APIs (port_push, rest_call, etc.)

1. **Python**: `_call()` RPC method with threading model
2. **Python**: `port42/bridge.py` — all bridge API wrappers
3. **Python**: Dual-thread recv + dispatch
4. **Test**: Agent creates a port via bridge API, pushes data into it, port updates live

### Sprint 3: Swift-side recognition + "Add Remote" UI

**Goal:** HTTP agents appear in Port42 companion list. Users can add them from New Companion sheet.

1. **AgentConfig.swift**: Add `.httpAgent` mode, `gatewayURL` field, `createHTTPAgent()` factory
2. **NewCompanionSheet.swift**: Add "Remote" tab with name/trigger, shows code snippet after create
3. **AppState.swift**: Detect `agent-` prefix senders, auto-create AgentConfig if not pre-created via UI
4. **AppState.swift**: Skip HTTP agents in `triggerAgents()` (they self-trigger)
5. **SidebarView.swift**: Show HTTP agents with network icon (e.g., `network` SF Symbol)
6. **DatabaseService.swift**: Migration to add `gatewayURL` column to agents table
7. **Test**: Create remote companion via UI, copy snippet, run Python agent, companion appears online in sidebar with correct presence

### Sprint 4: Feedback relay

**Goal:** Reactions and replies on agent messages flow back to the agent.

1. **gateway.go**: Add `feedback` message type, `routeFeedback()`
2. **AppState.swift**: Detect reaction/reply on HTTP agent message, send feedback envelope
3. **Python**: `on_feedback` handler, Feedback dataclass
4. **Test**: Send message as agent, user reacts with emoji, agent's `on_feedback` handler fires with correct reaction data

### Sprint 5: LangChain integration

**Goal:** LangChain chains stream to Port42 via callbacks, bridge tools available.

1. **Python**: `port42/langchain/callback.py` — Port42CallbackHandler
2. **Python**: `port42/langchain/tools.py` — Port42Tool wrappers
3. **Test**: LangChain chain with Port42CallbackHandler shows typing indicator during execution, posts structured result to channel on completion

### Sprint 6: Invite page + templates

**Goal:** Invite page shows Python snippet. `port42 init` scaffolds a working project.

1. **main.go**: Add "connect python agent" panel to invite page with pre-filled snippet
2. **Python**: `port42/cli.py` — click CLI with init command
3. **Python**: Template files (basic, langchain, pipeline)
4. **pyproject.toml**: Package metadata, scripts entry
5. **Test**: Open invite page in browser, copy Python snippet, run it, agent connects and joins channel. Separately: `port42 init test-agent && cd test-agent && python agent.py` connects to running gateway

### Sprint 7: Intent-engine integration

**Goal:** Gordon's day-job pipelines running as Port42 companions.

1. Wire up synthesizer chain as a companion
2. Add port rendering for Pydantic output models
3. Connect feedback store to `on_feedback`
4. Add remaining chains (anomaly, gap, report_writer, strategy)
5. Build combined intel dashboard port
6. **Test**: @mention synth companion in channel with transcript text, synthesizer chain runs, Synthesis output renders as a port, react with correction emoji, feedback store receives it, next run reflects the correction

---

## Resolved Decisions

1. **Agent-to-agent**: Companion chaining. No difference. Agents are peers, @mentions trigger `on_mention`, same routing.

2. **Rate limiting**: Global level, same as now. `rateLimitPerSec = 30` per peer. Agents are peers.

3. **Port ownership**: Tag `sender_id` as port creator when agent creates via bridge API.

4. **Secrets**: Yes, Python agents can access secrets. `agent.rest_call(url, secret="stripe")` → bridge API call → gateway routes to host → host resolves from Keychain, makes HTTP request, returns result. Secret value never leaves the machine. Agent references by name, host injects. Same mechanism as LLM companions. `secretNames` on AgentConfig scopes which secrets a companion can use.
