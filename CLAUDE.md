# CLAUDE.md

Instructions for Claude Code when working on port42-native.

## Project Overview

Port42 is a native macOS companion app for consciousness computing. Swift/SwiftUI frontend with a bundled Go WebSocket gateway. Sharing over the internet uses ngrok tunneling. E2E encrypted channels via AES-256-GCM.

## Project Layout

```
port42-native/
  Package.swift              # SPM manifest (GRDB, PLCrashReporter, PostHog)
  build.sh                   # Unified build script (debug/release)
  Info.plist                 # Bundle config (com.port42.app)
  Port42.entitlements        # Debug entitlements (has get-task-allow)
  Port42.release.entitlements # Release entitlements (empty, for notarization)
  gateway/
    main.go                  # HTTP server (ws, health, invite landing page)
    gateway.go               # WebSocket hub (routing, presence, store-and-forward)
    go.mod / go.sum
  Sources/Port42/
    Port42App.swift          # @main entry, creates AppState, window config
  Sources/Port42B/
    Port42B.swift            # Second app instance for local testing (separate DB)
  Sources/Port42Lib/
    Models/
      AppUser.swift          # User identity with P256 signing keys (Keychain)
      Channel.swift          # Chat channel with optional encryptionKey
      Message.swift          # Chat message with syncStatus tracking
      AgentConfig.swift      # Companion config: LLM/Command modes, triggers, provider
    Views/
      SetupView.swift        # First-launch: set display name
      ContentView.swift      # NavigationSplitView (sidebar + chat)
      SidebarView.swift      # Channel list, companions, user info, lock icons
      ChatView.swift         # Channel header + message list + input
      MessageView.swift      # Individual message (human/agent/system)
      InputView.swift        # Text input with send
      QuickSwitcher.swift    # Cmd+K overlay with fuzzy search, invite link pasting
      NewChannelSheet.swift  # Create channel modal
      NgrokSetupSheet.swift  # Ngrok auth token setup
      SignOutSheet.swift     # Settings panel (gateway URL, sign out)
    Services/
      AppState.swift         # @MainActor ObservableObject, all app state
      DatabaseService.swift  # SQLite via GRDB (schema, migrations, CRUD, observations)
      SyncService.swift      # WebSocket sync with gateway
      GatewayProcess.swift   # Bundled gateway subprocess lifecycle
      TunnelService.swift    # Ngrok tunnel management
      ChannelInvite.swift    # Invite link generation and parsing (port42:// and HTTPS)
      ChannelCrypto.swift    # AES-256-GCM per-channel encryption
      LLMEngine.swift        # Claude API streaming for companions
      AgentRouting.swift     # MentionParser + AgentRouter
      AgentAuth.swift        # Claude Code OAuth (Keychain) + API key resolver
      AgentInvite.swift      # port42://agent? invite link generate/parse
      AgentProtocol.swift    # NDJSON encode/decode for command agent stdio
      AgentProcess.swift     # Command agent subprocess lifecycle
    Theme/
      Port42Theme.swift      # Colors, fonts (dark theme, #00d4aa accent)
  Tests/Port42Tests/         # Swift Testing (@Test, #expect, @Suite)
  dist/
    Port42.app/              # Release app bundle (gitignored, rebuild from source)
    Port42.dmg               # Notarized DMG (Git LFS tracked)
```

## App Bundle Structure

```
Port42.app/Contents/
  MacOS/
    Port42             # Swift/SwiftUI app (main binary)
    port42-gateway     # Go WebSocket server
  Resources/
    *.bundle           # Swift package resource bundles
  Info.plist
```

## Architecture

**State flows one way:** DatabaseService (SQLite) -> AppState (ObservableObject) -> Views (SwiftUI)

- `DatabaseService` owns the GRDB `DatabaseQueue`, handles all SQL
- `AppState` is the single `@MainActor ObservableObject` shared via `@EnvironmentObject`
- Views read from `AppState` and call methods on it to mutate
- GRDB `ValueObservation` keeps `AppState` in sync with the database reactively

**Data lives in:** `~/Library/Application Support/Port42/port42.sqlite`

**Gateway** runs as a subprocess inside the app bundle on port 4242. Self-hosted by default, remote gateway supported via UserDefaults "gatewayURL".

**Sync** uses WebSocket protocol: identify -> welcome -> join channels -> message routing. Messages are encrypted with per-channel AES-256-GCM keys before transmission.

## Build Commands

### Development

```bash
./build.sh              # Debug build into .build/Port42.app
./build.sh --run        # Debug build and launch
./build.sh --peer       # Build and launch a second instance for local testing
./build.sh --run --peer # Build and launch both instances
```

### Ship a release (sign + notarize + push)

```bash
./build.sh --release
```

This single command handles the full pipeline:
1. Swift release build with `-DRELEASE` flag
2. Go gateway build
3. Developer ID signing with hardened runtime + timestamp
4. DMG creation with Applications symlink (drag-and-drop install)
5. DMG signing
6. Notarization (via `notarytool` Keychain profile)
7. Stapling
8. Copy to `dist/`

**After a release build, always commit and push** so the DMG is available on GitHub:
```bash
git add -f dist/Port42.app dist/Port42.dmg && git commit -m "Release: <description>" && git push
```

build.sh auto-detects signing identity from Keychain:
- **Release**: Developer ID Application cert, hardened runtime, `Port42.release.entitlements`
- **Debug + dev profile**: Apple Development cert, `Port42.dev.entitlements` (has applesignin)
- **Debug fallback**: Developer ID or ad-hoc, `Port42.entitlements`

## Signing Details

- **Identity**: `Developer ID Application: Gordon Mattey (5R5X43WDXE)`
- **Team ID**: `5R5X43WDXE`
- **Apple ID**: `gordon.mattey@gmail.com`
- **Notary profile**: `notarytool` (stored in macOS Keychain via `xcrun notarytool store-credentials`)
- **Debug entitlements**: `Port42.entitlements` (has `get-task-allow` for debugging)
- **Release entitlements**: `Port42.release.entitlements` (network client/server, no get-task-allow)
- **IMPORTANT**: Never use `Port42.entitlements` for release builds. The `get-task-allow` entitlement causes notarization to fail.

## Distribution

- `dist/Port42.dmg` is tracked via Git LFS (see `.gitattributes`)
- DMG download link: `https://github.com/gordonmattey/port42-native/raw/refs/heads/main/dist/Port42.dmg`

## Conventions

- **macOS 14+** (Sonoma). Use modern APIs.
- **No light mode.** Everything uses `Port42Theme` colors.
- **Font:** Always `Port42Theme.mono()` or `Port42Theme.monoBold()`. No system fonts.
- **State:** All mutable state lives in `AppState`. Views are pure renderers.
- **Database:** All persistence goes through `DatabaseService`. No direct SQLite calls elsewhere.
- **Observation:** Use GRDB `ValueObservation` for reactive data, not polling or manual refresh.
- **No Combine in views.** Use `@Published` on `AppState`, `onChange` in views.
- **Naming:** Models are plain structs. Services are classes. Views are structs.
- **Migrations:** Never modify an existing migration. Always append a new `registerMigration`.

## Testing

Tests use **Swift Testing** (not XCTest). Key conventions:
- `import Testing` (never `import XCTest`)
- `@Suite("Name")` for test suites, `@Test("description")` for individual tests
- `#expect(condition)` for assertions (not `XCTAssert`)
- `throws` on test functions for error handling (no `XCTAssertNoThrow`)
- Factory methods like `AppUser.createLocal(displayName:)`, `Channel.create(name:)`, `Message.create(...)` for test data
- `DatabaseService(inMemory: true)` for isolated DB tests
- Run tests with `swift test` or filter with `swift test --filter SuiteName`

## Development Rules

- DO NOT COMMIT unless asked
- DO NOT REFACTOR unless asked
- FIX ROOT CAUSES not symptoms
- Test changes by building and running before committing
- Write tests for new features using Swift Testing
- When modifying the gateway, `./build.sh` handles it automatically

## Milestones

- **M1 (Local Chat Shell)**: Done
- **M2 (Companions)**: Done (LLM agents, command agents, channel membership, invite links, Quick Switcher)
- **M3 (Sync)**: In progress. Done: gateway, WebSocket sync, E2E encryption, typing indicators, remote identity, sender attribution, member list, cross-peer mentions, invite system, channel join tokens. Remaining: presence dots (F-505), relay auth (F-511), join/leave announcements bugfix (F-515), reply threading (F-303), message status (F-304), offline queue (F-504 partial)
