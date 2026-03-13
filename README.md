# Port42

**Companion Computing.** Humans and AI, thinking together.

A native Mac app where you, your friends, and your AI companions share the same space. Talk, build, and watch ideas take shape together.

**[Download Port42.dmg](dist/Port42.dmg)** (macOS 15+, Apple Silicon)

![Port42 — companions building a live visualization during conversation](docs/screenshot.png)

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
.invoke(id, prompt, opts?)      → response text (string)
```

`invoke` calls a companion's AI from within a port. The companion sees recent channel context. Response is port-private (does not appear in chat). Supports streaming via `opts.onToken` and `opts.onDone`. Requires AI permission.

### port42.ai

```
.models()                       → [{ id, name, tier }]
.complete(prompt, opts?)        → response text (string)
.cancel(callId)                 → { ok: true }
```

Raw LLM access with no personality. Options: `{ model, systemPrompt, maxTokens, images, onToken, onDone }`. Pass `images: [base64String]` for vision (screenshot analysis, image understanding). Requires AI permission (shared with `companions.invoke`).

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

`type` is `'channel'` or `'swim'`. Members include `{ name, type: 'human' | 'companion' }`.

### port42.storage

Persistent key-value storage. Survives app restarts.

```
.set(key, value, opts?)         → true
.get(key, opts?)                → value | null
.delete(key, opts?)             → true
.list(opts?)                    → [keys]
```

Options: `{ scope: 'channel' | 'global', shared: true | false }`

Four combinations: per-companion per-channel (default), per-companion global, shared per-channel, shared global.

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

### port42.terminal

Full shell sessions inside ports. Requires terminal permission.

```
.spawn(opts?)                   → { sessionId }
.send(sessionId, data)          → { ok: true }
.resize(sessionId, cols, rows)  → { ok: true }
.kill(sessionId)                → { ok: true }
.on('output', cb)               → { sessionId, data } (ANSI escape sequences)
.on('exit', cb)                 → { sessionId, code }
.loadXterm()                    → Terminal class (bundled xterm.js)
```

Spawn options: `{ shell, cwd, cols, rows, env }`. Defaults: `/bin/zsh`, 80x24.

### port42.clipboard

System clipboard access. Requires clipboard permission.

```
.read()                         → { type: 'text'|'image'|'empty', data?, format? }
.write(data)                    → { ok: true }
```

Text: pass a string. Image: pass `{ type: 'image', data: '<base64 png>' }`.

### port42.fs

File access through native pickers. Requires filesystem permission.

```
.pick(opts?)                    → { path } | { paths: [...] } | { cancelled: true }
.read(path, opts?)              → { data, encoding, size }
.write(path, data, opts?)       → { ok: true, size }
```

Pick options: `{ mode: 'open'|'save', types, multiple, directory, suggestedName }`. Read/write options: `{ encoding: 'utf8'|'base64' }`. Only paths chosen via `pick()` are accessible.

### port42.notify

System notifications. Requires notification permission.

```
.send(title, body?, opts?)      → { ok: true, id }
```

Options: `{ sound: true, subtitle: 'text' }`.

### port42.audio

Microphone capture with live transcription and audio output. Capture requires microphone permission.

```
.capture(opts?)                 → { ok: true, sampleRate }
.stopCapture()                  → { ok: true }
.speak(text, opts?)             → { ok: true } (resolves when speech finishes)
.play(data, opts?)              → { ok: true, duration }
.stop()                         → { ok: true }
.on('transcription', cb)        → { text, isFinal }
.on('data', cb)                 → { samples, sampleRate, frameCount, format }
```

Capture options: `{ transcribe: true, language: 'en-US', rawAudio: false }`. Speak options: `{ voice, rate, pitch, volume }`. Play takes base64-encoded audio (WAV, MP3, AAC). Play options: `{ volume }`.

### port42.screen

Screenshot capture via ScreenCaptureKit. Requires screen permission.

```
.windows()                      → { windows: [{ id, title, app, bundleId, bounds }] }
.capture(opts?)                 → { image, width, height }
```

`windows()` lists visible windows. Use `id` with `capture({ windowId })` to screenshot a specific window. Capture options: `{ scale, windowId, region, displayId, includeSelf }`. `image` is base64 PNG. `scale` controls resolution (0.1 to 2.0, default 1.0). By default Port42's own windows are excluded; pass `includeSelf: true` to include them.

### port42.browser

Headless web browsing. Requires browser permission. Max 5 concurrent sessions.

```
.open(url, opts?)                   → { sessionId, url, title }
.navigate(sessionId, url)           → { url, title }
.capture(sessionId, opts?)          → { image, width, height }
.text(sessionId, opts?)             → { text, title, url }
.html(sessionId, opts?)             → { html, title, url }
.execute(sessionId, js)             → { result }
.close(sessionId)                   → { ok: true }
.on('load', cb)                     → { sessionId, url, title }
.on('error', cb)                    → { sessionId, url, error }
.on('redirect', cb)                 → { sessionId, url }
```

Open options: `{ width, height, userAgent }`. Text/HTML options: `{ selector }` for CSS-scoped extraction. Sessions use non-persistent data stores. Only http/https/data URIs allowed.

### Events

```
port42.on('message', cb)            → new message arrives { id, sender, content, timestamp, isCompanion }
port42.on('companion.activity', cb) → typing state changes { activeNames: [...] }
```

### Connection Health

```
port42.connection.status()           → 'connected' | 'disconnected'
port42.connection.onStatusChange(cb) → fires on transition
```

### Permissions

Sensitive APIs require user permission on first use per port session. Permission groups:

| Permission | Methods |
|-----------|---------|
| AI | `ai.complete`, `companions.invoke` |
| Terminal | `terminal.spawn` |
| Microphone | `audio.capture`, `audio.stopCapture` |
| Screen | `screen.windows`, `screen.capture` |
| Browser | `browser.open`, `browser.navigate`, `browser.capture`, `browser.text`, `browser.html`, `browser.execute`, `browser.close` |
| Clipboard | `clipboard.read`, `clipboard.write` |
| Filesystem | `fs.pick`, `fs.read`, `fs.write` |
| Notification | `notify.send` |

No permission required: `audio.speak`, `audio.play`, `audio.stop`, all read-only APIs.

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
