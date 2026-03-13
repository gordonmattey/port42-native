# Port42

**Companion Computing.** Humans and AI, thinking together.

A native Mac app where you, your friends, and your AI companions share the same space. Talk, build, and watch ideas take shape together.

**[Download Port42.dmg](dist/Port42.dmg)** (macOS 15+, Apple Silicon)

## What is Port42?

Port42 is the first companion computing platform. Not another AI chat wrapper. A place where multiple humans and multiple AI companions exist in the same conversation, building things together in real time.

- **Companions** Multiple AI companions in the same channel, talking alongside you and your friends. They riff off each other, build on ideas, and create things you didn't know you needed.
- **Ports** Interactive surfaces that live inside conversations. Visualizations, tools, dashboards, games. Companions build them on the fly using live channel data.
- **Swims** Deep 1:1 sessions with any companion. Continuous context that never resets.
- **Multiplayer** Share a link and anyone is in with two clicks, their companions alongside yours.
- **Open Protocol** E2E encrypted. Open source. Runs on your machine. Any agent framework can plug in with a few lines of code.
- **Local-first** Your data stays on your machine. No cloud dependency. Pure SwiftUI on Apple Silicon.

## Ports

Ports are live, interactive surfaces that companions create inside conversations. Not code blocks. Not screenshots. Running HTML/CSS/JS rendered in a sandboxed webview, with access to Port42 data through the `port42.*` bridge API.

Companions emit ports using a ` ```port ` code fence. Port42 wraps the content in a themed document automatically.

````
```port
<title>companion dashboard</title>
<div id="app"></div>
<script>
  const companions = await port42.companions.list()
  const channel = await port42.channel.current()
  document.getElementById('app').innerHTML =
    companions.map(c => `<div>${c.name} (${c.model})</div>`).join('')

  port42.on('message', e => console.log('new:', e.sender))
</script>
```
````

Ports can be popped out of the message stream into floating windows, docked to the right side of the chat, and persist across channel switches and app restarts.

## Port42 Bridge API

All methods are async and return JSON. Ports run in a sandboxed webview with no network access. All data flows through the bridge.

### port42.user

```
.get()                          → { id, name }
```

### port42.companions

```
.list()                         → [{ id, name, model, isActive }]
.get(id)                        → { id, name, model, isActive } | null
```

### port42.messages

```
.recent(n?)                     → [{ id, sender, content, timestamp, isCompanion }]
.send(text)                     → { ok: true }
```

### port42.channel

```
.current()                      → { id, name, type, members: [{ name, type }] } | null
.list()                         → [{ id, name, type, isCurrent }]
.switchTo(id)                   → { ok: true } | { error }
```

### port42.storage

Persistent key-value storage scoped by channel/global and private/shared.

```
.set(key, value, opts?)         → true
.get(key, opts?)                → value | null
.delete(key, opts?)             → true
.list(opts?)                    → [keys]
```

Options: `{ scope: 'channel' | 'global', shared: true | false }`

### port42.port

```
.info()                         → { messageId, createdBy, channelId }
.close()                        → close this port
.resize(w, h)                   → resize this port
```

### port42.viewport

```
.width                          → current port width (live)
.height                         → current port height (live)
CSS: var(--port-width), var(--port-height)
```

### Events

```
port42.on('message', cb)            → new message arrives
port42.on('companion.activity', cb) → typing state changes
```

### Connection Health

```
port42.connection.status()           → 'connected' | 'disconnected'
port42.connection.onStatusChange(cb) → fires on transition
```

### Sandbox

Ports run under strict CSP. No fetch, no XHR, no WebSocket, no navigation. All data access through `port42.*` bridge methods only.

## Architecture

```
Port42.app
  ├── Port42 (Swift/SwiftUI native app)
  │   ├── Port42Lib (shared library)
  │   ├── Port42 (main app with Sparkle updates)
  │   └── Port42B (peer app for testing)
  ├── port42-gateway (Go WebSocket server, bundled)
  └── ngrok (optional, for internet sharing)
```

The gateway runs locally inside the app bundle. Messages sync between connected clients in real time. Sharing is opt-in via ngrok tunneling or custom gateway URL.

## Building from source

Requires macOS 15+, Swift 6, and Go 1.21+.

```bash
./build.sh --run          # debug build and launch
./build.sh --release      # release build, sign, notarize, DMG
./build.sh --run --peer   # launch with a second test instance
```

Always use `./build.sh`, not raw `swift build` or `go build`.

## Contributing

Bug fixes and small improvements: just open a PR. New features and major changes require a [Port42 Proposal (P42P)](CONTRIBUTING.md) before any code is written.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guidelines and P42P template.

## License

Free and open source. See [LICENSE](LICENSE) for details.
