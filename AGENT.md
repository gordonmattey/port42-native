# Port42 Native: Agent Guide

## Quick Start

```bash
cd /Users/gordon/Dropbox/Work/Hacking/workspace/portal-42/port42-native

# Build and launch
./build-and-run.sh

# Build only (no launch)
swift build

# Reset app data (fresh start)
rm -rf ~/Library/Application\ Support/Port42/port42.sqlite
```

## Project Layout

```
port42-native/
  Package.swift              # SPM manifest (GRDB dependency)
  build-and-run.sh           # Build + package into .app + launch
  Port42.app/                # macOS app bundle
    Contents/
      Info.plist             # Bundle config (ai.snowos.port42)
      MacOS/                 # Binary copied here by build script
  Sources/Port42/
    Port42App.swift            # @main entry, creates AppState, window config
  Sources/Port42Lib/
    Models/
      AppUser.swift            # User identity (GRDB model)
      Channel.swift            # Chat channel (GRDB model)
      Message.swift            # Chat message (GRDB model)
      AgentConfig.swift        # Companion config: LLM/Command modes, triggers, provider
    Views/
      SetupView.swift          # First-launch: set display name
      ContentView.swift        # NavigationSplitView (sidebar + chat)
      SidebarView.swift        # Channel list, companions section, user info
      ChatView.swift           # Channel header + message list + input
      MessageView.swift        # Individual message (human/agent/system)
      InputView.swift          # Text input with send
      NewChannelSheet.swift    # Create channel modal
    Services/
      DatabaseService.swift    # SQLite via GRDB (schema, CRUD, observations)
      AppState.swift           # @MainActor ObservableObject, all app state
      AgentProtocol.swift      # NDJSON encode/decode for command agent stdio
      AgentProcess.swift       # Command agent subprocess lifecycle
      AgentRouting.swift       # MentionParser + AgentRouter
      AgentAuth.swift          # Claude Code OAuth (Keychain) + API key resolver
      AgentInvite.swift        # port42://agent? invite link generate/parse
    Theme/
      Port42Theme.swift        # Colors, fonts (dark theme, #00ff41 green)
  Tests/Port42Tests/           # Swift Testing (@Test, #expect, @Suite)
```

## Architecture

**State flows one way:** DatabaseService (SQLite) -> AppState (ObservableObject) -> Views (SwiftUI)

- `DatabaseService` owns the GRDB `DatabaseQueue`, handles all SQL
- `AppState` is the single `@MainActor ObservableObject` shared via `@EnvironmentObject`
- Views read from `AppState` and call methods on it to mutate
- GRDB `ValueObservation` keeps `AppState` in sync with the database reactively

**Data lives in:** `~/Library/Application Support/Port42/port42.sqlite`

## How to Work on This

### Adding a new feature

1. Read the spec: `SPEC.md` has Feature IDs (F-XXX) with Done When criteria
2. Read the architecture: `ARCHITECTURE.md` has the system design
3. Find the relevant files using the project layout above
4. Read the existing code before modifying

### Adding a new model

1. Create the struct in `Models/` conforming to `Codable, FetchableRecord, PersistableRecord`
2. Add a migration in `DatabaseService.migrate()` (append a new `registerMigration`)
3. Add CRUD methods to `DatabaseService`
4. Add state and observation to `AppState`

### Adding a new view

1. Create the view in `Views/`
2. Use `@EnvironmentObject var appState: AppState` to access state
3. Use `Port42Theme` for all colors and fonts
4. Wire it into the navigation in `ContentView.swift` or `SidebarView.swift`

### Modifying the database schema

Never modify an existing migration. Always add a new one:

```swift
migrator.registerMigration("v2") { db in
    try db.alter(table: "messages") { t in
        t.add(column: "newColumn", .text)
    }
}
```

## Conventions

- **SwiftUI target:** macOS 14+ (Sonoma). Use modern APIs.
- **No light mode.** Everything uses `Port42Theme` colors.
- **Font:** Always `Port42Theme.mono()` or `Port42Theme.monoBold()`. No system fonts.
- **State:** All mutable state lives in `AppState`. Views are pure renderers.
- **Database:** All persistence goes through `DatabaseService`. No direct SQLite calls elsewhere.
- **Observation:** Use GRDB `ValueObservation` for reactive data, not polling or manual refresh.
- **No Combine in views.** Use `@Published` on `AppState`, `onChange` in views.
- **Naming:** Models are plain structs. Services are classes. Views are structs.

## Current Status

M1 (Local Chat Shell) is done. M2 (Bring Your Own Agent) is in progress.
See `SPEC.md` for the full milestone plan and build sequence.

## Spec Reference

Feature IDs trace through the full spec:

- `SPEC.md` — What to build (features, flows, done-when criteria)
- `ARCHITECTURE.md` — How to build it (system design, data model, protocols)
