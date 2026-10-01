# CLAUDE.md

Instructions for Claude Code when working on port42-native.

## Project Overview

Port42 is a native macOS desktop for AI agents (1.0.0). Swift/SwiftUI and AppKit, with a bundled Go
gateway. Agents (Claude Code, Codex) run as companions in terminal ports (Ghostty); the ports they make
are live web surfaces beside them; every port and space has a chat. Sharing a port with another machine
goes through a relay (Noise, end to end); a browser joins through the guest page at tele.port42.ai.

## Project Layout

```
port42-native/
  Package.swift              # SPM manifest (GRDB, PLCrashReporter, PostHog, Sparkle, FluidAudio)
  build.sh                   # Unified build script (test gate, dev instances, release)
  Info.plist                 # Bundle config (com.port42.app)
  Port42.entitlements        # Debug entitlements (has get-task-allow)
  Port42.release.entitlements # Release entitlements (hardened runtime: network, microphone, camera)
  vendor/GhosttyKit.xcframework.tar.gz  # Terminal engine (Git LFS); build.sh unpacks it to GhosttyKit.xcframework
  gateway/                   # Go: the local door (main.go, gateway.go), relay client (outbound.go)
    relay/                   # The relay: Noise sessions, rate limits (served by cmd/port42-relay)
    tele/                    # The invite page server (cmd/port42-tele, tele.port42.ai)
    cmd/                     # port42-relay, port42-tele, p42peer
  guest/                     # The browser guest (JS): invite page, frame, bundle in dist/, npm test
  Sources/Port42/Port42App.swift   # @main entry
  Sources/Port42Lib/
    Models/                  # AppUser, AgentConfig, Space
    Views/
      ShellView.swift        # THE app surface: zoom spine (galaxy, space, focus), overlays, voice
      ShellDesktop.swift     # Tile chrome, port units, dock, port menu (pin, hide, share, move)
      PortChatPanel.swift    # A port's or space's chat panel; presence strip
      ChatTranscript.swift   # The transcript (AppKit NSTextView, TextKit 1)
      ImagineBox.swift       # ⌘I; QuickSwitcher.swift is ⌘K
      ShareBox.swift, SharePanel.swift, AcceptBox.swift   # Sharing
      GhosttyTerminalView.swift  # Terminal ports
      SignOutSheet.swift     # Settings (Access, Secrets, Remote, Display, Voice, Updates)
    Services/
      AppState.swift         # @MainActor ObservableObject, all app state
      DatabaseService.swift  # SQLite via GRDB (schema, append-only migrations, CRUD, observations)
      ShellState.swift       # Shell UI state (zoom, tiles, pins, boxes)
      BridgeRegistry.swift, BridgeMethods.swift, BridgeDispatcher.swift  # The API
      PermissionCoordinator.swift, ClientRegistry.swift, Principal.swift  # Who calls, what they may do
      RemoteAccess.swift, Invites.swift, RemoteTile.swift  # Sharing: the remote gate, invites, mirrors
      PortChat.swift, ChatPresence.swift, AgentRouting.swift  # Chats, presence, @mention routing
      GhosttyTerminalController.swift, TerminalHooksService.swift, CLIHookProducer*.swift  # Companions
      Imagine.swift, ImagineLink.swift  # /imagine and port42://imagine links
      Voice*.swift           # Hold-to-talk (Parakeet via FluidAudio, on device)
      GatewayProcess.swift   # Bundled gateway subprocess lifecycle, relays
      SkillCatalog.swift     # Which skill teaches each method
    Skills/port42-skills/    # The agent skills (generated references; tests enforce freshness)
    Resources/               # ports-context.txt, llms-preamble.txt, echo-prompt.txt, videos (not in git)
    Theme/Port42Theme.swift  # Colors, fonts (dark theme)
  Tests/Port42Tests/         # Swift Testing (@Test, #expect, @Suite)
  llms.txt                   # Generated API reference
  dist/
    Port42.app/              # Release app bundle
    Port42.dmg               # Notarized DMG (Git LFS tracked)
```

## App Bundle Structure

```
Port42.app/Contents/
  MacOS/
    Port42              # The app
    port42-gateway      # The Go gateway (local door; relay client when sharing)
    port42-cli          # The `port42` command
    port42-claude-shim  # Wraps the claude CLI for companions (hooks, instructions)
  Frameworks/Sparkle.framework   # Updates
  Resources/*.bundle    # Swift package resource bundles
  Info.plist
```

## Architecture

**State flows one way:** DatabaseService (SQLite) -> AppState (ObservableObject) -> Views (SwiftUI)

- `DatabaseService` owns the GRDB `DatabaseQueue`, handles all SQL
- `AppState` is the single `@MainActor ObservableObject` shared via `@EnvironmentObject`
- Views read from `AppState` and call methods on it to mutate
- GRDB `ValueObservation` keeps `AppState` in sync with the database reactively

**Data lives in:** `~/Library/Application Support/Port42/port42.sqlite`

**Gateway** runs as a subprocess inside the app bundle on 127.0.0.1:4242 (dev instances use their own
ports). It is the door for local callers (the `port42` command, companions, scripts; each with its own
token) and, when sharing, holds the relay connections through which other machines call.

**Unified API** The bridge API is registry-first. Every method is declared once in the `BridgeRegistry`
(`BridgeMethods.swift` and the per-area files) with a description, JSON input schema, permission and
body; every surface (a port's JS through the generic proxy in `PortBridge.swift`, the gateway's `/call`,
tool use) dispatches through `AppState.runBridgeMethod`. Tool schemas, `llms.txt`, the skills'
references and the guest's method table are generated from the registry, and tests fail when a
generated file is stale. A caller from another machine passes `RemoteAccess` first: denied unless an
invite granted it a right on the port it names.

## Build Commands

### Development

```bash
./build.sh              # Debug build into .build/Port42Dev.app (isolated dev instance)
./build.sh --run        # Debug build and launch
```

**Every build runs `swift test` first and aborts on a red suite** (~15s). A break surfaces on the
next build instead of at ship time. `SKIP_TESTS=1 ./build.sh --run` when you need the app now.

> **IMPORTANT: always rebuild the runnable bundle with `./build.sh`, never bare `swift build`.**
> `swift build` only updates the loose `.build/debug/Port42` binary; it does **not** assemble or
> re-sign `.build/Port42.app`. If you (or a test script) copy/launch `.build/Port42.app` after a
> bare `swift build`, you run a **stale bundle** and your changes silently won't be there, and you'll
> chase a "fix didn't work" ghost. `./build.sh` recompiles, assembles the bundle, and code-signs it.
> To confirm the bundle is current, the binary mtime should be newer than your last edit:
> `stat -f '%Sm %N' .build/Port42.app/Contents/MacOS/Port42`.

**Dev instances have owners** (`docs/dev-instances.md`): build and test only on yours, and never on
one someone holds. `scripts/dev-lock.sh` shows and takes locks; `build.sh` refuses a locked instance
unless `PORT42_DEV_OWNER` names its holder. Dev8 and Dev9 exist too (4250, 4251).

### Ship a release (sign + notarize + push)

```bash
./build.sh --release
```

This single command handles the full pipeline:
0. **Test gate** (every build, dev included): `swift test` must pass or the build aborts before
   anything is compiled, signed or launched. Override: `SKIP_TESTS=1 ./build.sh …`.
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

**Before cutting any release, run `scripts/unshipped.sh`** (1.0.5 left five built tickets behind: #128, #136,
#137, #221, #222). It lists every ticket built on a branch and not in `main`. Reconcile each line: in this
release, deferred (with the reason on its card), or dropped. A card moves to Resolved only when `main`
contains it, and its Resolved note names the release.

**Then tell growth, every release** (GM, 2026-09-28: 1.0.2 shipped and growth did not know). Post in the
operator space (`port42-app`) to the growth lead (`@lucky-ibis`): the version and build, the release
link, what changed in a line or two, and whether anything the site mirrors changed (`llms.txt`,
`ports-context`, the method index). Growth owns the site's Releases entry and its sync; the Download
buttons follow `releases/latest` on their own. Mark the release shipped on the operator dash
(`dash:item:dev-release-*`).

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
- **The Sparkle appcast is generated, never hand-set.** `./build.sh --release` runs
  `generate_appcast`, which copies the bundle's `LSMinimumSystemVersion` into `dist/appcast.xml` as
  `sparkle:minimumSystemVersion`. A floor in `Info.plist` above the real one therefore refuses
  updates to every Mac in between, and editing the feed by hand is undone at the next release.
  Change `Info.plist`.

## Conventions

- **macOS 14+** (Sonoma). Use modern APIs. `Package.swift` declares `.macOS(.v14)` and `Info.plist`
  declares `LSMinimumSystemVersion` 14.0; the two must always agree, and `README.md` says the same.
  A macOS 15 API is reached through a per-API `if #available` guard, never an app-wide deployment
  bump, so the 14 floor is what makes the compiler prove no unguarded 15-only call is reachable. The
  only macOS 15 API in the tree is ScreenCaptureKit microphone capture, gated in `ScreenRecorder.swift`.
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
- `makeParityWorld()` for an AppState with a user, a space and a companion; `AppUser.createLocal(displayName:)` for a user
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

- **1.0.0 (nautilus)**: the shell as the only UI; companions in terminal ports; a chat on every port and
  space, with presence; /imagine; sharing a port through a relay, from the app or a browser; voice input;
  the registry-first API with generated references. Release state and the final step:
  `docs/release-1.0.0.md`. What is next: the later list in `docs/plan-shell-only.md`.
