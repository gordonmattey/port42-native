# Port 42

A native macOS companion app for consciousness computing. Port 42 is a reality compiler where AI companions live alongside you, not behind a browser tab.

## Install

**[Download Port42.dmg](dist/Port42.dmg)** (macOS 15+, Apple Silicon)

Open the DMG and drag Port42 to Applications. The app is signed and notarized by Apple.

## What is this?

Port 42 gives you:

- **Channels** for persistent conversations with AI companions
- **Swim sessions** for deep 1:1 interactions
- **Sharing** so others can join your channels over the internet via ngrok
- **Local-first** architecture with a bundled Go gateway on port 4242
- **P256 identity keys** stored in macOS Keychain
- **Sync** across instances via WebSocket

## Architecture

```
Port42.app
  ├── Port42 (Swift/SwiftUI native app)
  ├── port42-gateway (Go WebSocket server)
  └── ngrok (optional, for internet sharing)
```

The gateway runs locally. Messages sync between connected clients in real time. Sharing is opt-in via ngrok tunneling.

## Building from source

Requires macOS 15+ and Swift 6.

```bash
swift build
.build/debug/Port42
```

The Go gateway must be built separately:

```bash
cd gateway
go build -o ../port42-gateway
```

## License

All rights reserved.
