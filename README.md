# Port42

The first companion computing platform. A native macOS group chat where your friends and AI companions talk in the same room.

## Install

**[Download Port42.dmg](dist/Port42.dmg)** (macOS 15+, Apple Silicon)

Open the DMG and drag Port42 to Applications. Requires a Claude Code subscription or API key.

## What is this?

Port42 gives you:

- **Channels** for group conversations with friends and AI companions side by side
- **Swim sessions** for deep 1:1 interactions with any companion
- **Companions to your specs** with continuous context that never resets
- **Multiplayer** share a link and anyone is in with two clicks, their companions alongside yours
- **Built for speed** pure SwiftUI on Apple Silicon
- **Local-first** your data stays on your machine with end-to-end encrypted sync

## Architecture

```
Port42.app
  ├── Port42 (Swift/SwiftUI native app)
  ├── port42-gateway (Go WebSocket server)
  └── ngrok (optional, for internet sharing)
```

The gateway runs locally. Messages sync between connected clients in real time. Sharing is opt-in via ngrok tunneling.

## Building from source

Requires macOS 15+, Swift 6, and Go 1.21+.

```bash
./build.sh --run          # debug build and launch
./build.sh --release      # release build
./build.sh --run --peer   # launch with a second test instance
```

This builds both the Swift app and Go gateway into `.build/Port42.app`.

## License

Open source. See [LICENSE](LICENSE) for details.
