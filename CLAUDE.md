# CLAUDE.md

Instructions for Claude Code when working on port42-native.

## Project Overview

Port42 is a native macOS companion app for consciousness computing. Swift/SwiftUI frontend with a bundled Go WebSocket gateway on port 4242. Sharing over the internet uses ngrok tunneling.

## Architecture

```
Port42.app/Contents/
  MacOS/
    Port42           # Swift/SwiftUI app (main binary)
    port42-gateway   # Go WebSocket server
  Resources/
    *.bundle          # Swift package resource bundles
  Info.plist
```

- **Swift app** (Sources/Port42Lib/, Sources/Port42/) manages UI, local SQLite DB (via GRDB), Keychain identity, and companion AI agents
- **Go gateway** (gateway/) is a WebSocket hub for real-time message routing, presence, and store-and-forward
- **ngrok** creates a secure tunnel from the gateway to the internet for sharing

## Build Commands

### Debug (quick iteration)
```bash
swift build                    # build debug Swift binary
./build-and-run.sh             # build, package into .app, ad-hoc sign, and launch
```

### Go gateway
```bash
cd gateway && go build -o ../port42-gateway
```

### Release build + sign + notarize
```bash
# 1. Build release binaries
swift build -c release
cd gateway && go build -o ../port42-gateway && cd ..

# 2. Copy into app bundle
cp .build/release/Port42 dist/Port42.app/Contents/MacOS/Port42
cp port42-gateway dist/Port42.app/Contents/MacOS/port42-gateway

# 3. Sign with hardened runtime (release entitlements, no get-task-allow)
IDENTITY="Developer ID Application: Gordon Mattey (5R5X43WDXE)"
ENT="Port42.release.entitlements"
codesign --force --options runtime --sign "$IDENTITY" --entitlements "$ENT" dist/Port42.app/Contents/MacOS/port42-gateway
codesign --force --options runtime --sign "$IDENTITY" --entitlements "$ENT" dist/Port42.app/Contents/MacOS/Port42
codesign --force --options runtime --sign "$IDENTITY" --entitlements "$ENT" dist/Port42.app

# 4. Verify
codesign --verify --deep --strict dist/Port42.app

# 5. Create DMG
hdiutil create -volname "Port42" -srcfolder dist/Port42.app -ov -format UDZO dist/Port42.dmg
codesign --force --sign "$IDENTITY" dist/Port42.dmg

# 6. Notarize (credentials stored as keychain profile "port42-notary")
xcrun notarytool submit dist/Port42.dmg --keychain-profile "port42-notary" --wait

# 7. Staple
xcrun stapler staple dist/Port42.dmg
```

## Signing Details

- **Identity**: `Developer ID Application: Gordon Mattey (5R5X43WDXE)`
- **Team ID**: `5R5X43WDXE`
- **Apple ID**: `gordon.mattey@gmail.com`
- **Notary profile**: `port42-notary` (stored in macOS Keychain)
- **Debug entitlements**: `Port42.entitlements` (has `get-task-allow` for debugging)
- **Release entitlements**: `Port42.release.entitlements` (empty dict, required for notarization)
- **IMPORTANT**: Never use `Port42.entitlements` for release builds. The `get-task-allow` entitlement will cause notarization to fail.

## Distribution

- `dist/Port42.dmg` and `dist/Port42.zip` are tracked via Git LFS (see `.gitattributes`)
- `dist/Port42.app/` is gitignored (rebuild from source)
- DMG download link: `https://github.com/gordonmattey/port42-native/raw/refs/heads/main/dist/Port42.dmg`

## Key Files

| Path | Purpose |
|------|---------|
| `Sources/Port42Lib/Services/AppState.swift` | Central app state, channel/companion management |
| `Sources/Port42Lib/Services/TunnelService.swift` | ngrok tunnel management |
| `Sources/Port42Lib/Services/ChannelInvite.swift` | Invite link generation and parsing |
| `Sources/Port42Lib/Services/SyncService.swift` | WebSocket sync with gateway |
| `Sources/Port42Lib/Views/` | All SwiftUI views |
| `gateway/gateway.go` | Go WebSocket gateway (routing, presence, store-and-forward) |
| `gateway/main.go` | Gateway HTTP server (ws, health, invite landing page) |

## Development Rules

- DO NOT COMMIT unless asked
- DO NOT REFACTOR unless asked
- FIX ROOT CAUSES not symptoms
- Test changes by building and running before committing
- When modifying the gateway, rebuild with `cd gateway && go build -o ../port42-gateway`
