# Contributing to Port42

Port42 is open source under the MIT license. This guide covers building it, running a development
instance, testing, the project's conventions, and how to propose larger changes. For how the code
fits together, read [ARCHITECTURE.md](ARCHITECTURE.md) first.

## Prerequisites

- A Mac with Apple silicon, running macOS 14 or later.
- Xcode 16 or later (the Swift toolchain, and Swift Testing for the test suite).
- Go 1.24 or later, for the gateway, the `port42` command and the hook shim.
- Node.js with npm, for the browser guest in `guest/` and for the gateway's guest test.
- Git LFS. The GhosttyKit terminal engine is vendored as an LFS file
  (`vendor/GhosttyKit.xcframework.tar.gz`). Without it, `build.sh` downloads the same archive from a
  pinned URL and verifies its checksum.
- `envsubst` (`brew install gettext`), which `build.sh` uses to write `Info.plist`.
- `rsvg-convert` (`brew install librsvg`), needed only when the app icon is regenerated from its SVG.
- To run companions, Claude Code or Codex on your `PATH`.

## Build and run

```bash
git lfs install
git clone https://github.com/gordonmattey/port42-native.git
cd port42-native
./build.sh --run
```

A debug build is an isolated development instance, **Port42 Dev**. It never touches an installed
Port42:

| | Installed app | Dev instance |
|---|---|---|
| Bundle id | `com.port42.app` | `com.port42.dev` |
| Data | `~/Library/Application Support/Port42` | `~/Library/Application Support/Port42Dev` |
| Gateway | `127.0.0.1:4242` | `127.0.0.1:4243` |
| Command | `port42` | `port42-dev` |

The bundle is written to `.build/Port42Dev.app`, and its output is logged to
`~/port42-build/Port42Dev.log`. More instances sit beside it, each with its own bundle id, data
directory and gateway port: `--dev2` (4244), `--dev3` (4245), `--dev4` (4246), `--dev5` (4247),
`--dev6` (4248) and `--dev7` (4249). Two instances on one Mac can share ports with each other through
the relay.

**Every build runs `swift test` first** and stops if a test fails, before anything is compiled,
signed or launched. `SKIP_TESTS=1 ./build.sh --run` skips the gate when you need the app now.

**Rebuild with `./build.sh`, never a bare `swift build`.** `swift build` updates only the loose
binary; it does not assemble or sign the `.app`, so launching the bundle afterwards runs the old code.
`build.sh` also builds the Go gateway, CLI and shim, and bundles them.

`build.sh` stops only an instance launched from its own build directory before replacing it, never
the installed app.

**Releases** are for maintainers. `./build.sh --release` builds with a Developer ID, notarizes, and
then publishes, pushing the Sparkle appcast and creating the GitHub release. `NO_PUBLISH=1
./build.sh --release` stops after a signed, notarized DMG and publishes nothing.

## Test

| Suite | Command |
|---|---|
| Swift (the app) | `swift test`, or `swift test --filter SuiteName` |
| Gateway, relay, tele | `cd gateway && go test ./...` |
| `port42` command | `cd cli && go test ./...` (`build.sh` runs this too) |
| Hook shim | `cd shim && go test ./...` |
| Browser guest | `cd guest && npm install && npm test` |

The gateway's browser-guest test runs the guest code in Node, so run `npm install` in `guest/` first.
It is skipped when Node is not installed.

After changing anything in `guest/src`, run `npm run build` in `guest/` and commit
`dist/port42-guest.js` and `invite.html` together; `invite.html` names the bundle's hash, and
`npm test` fails if either is stale.

### Swift Testing conventions

- `import Testing`, never `import XCTest`.
- `@Suite("Name")` for a suite and `@Test("description")` for a test.
- `#expect(condition)` for assertions, not `XCTAssert`.
- Test functions `throw` rather than wrapping calls in no-throw assertions.
- `DatabaseService(inMemory: true)` for an isolated database, and factories such as
  `AppUser.createLocal(displayName:)` and `Space.create(name:)` for test data. Bridge suites build
  an app over an in-memory database with `makeParityWorld()`.

### Calibrate every new test

A test that has never failed has not shown that it can. For each new test or gate:

1. Break the code it guards (delete the check, flip the condition, drop the entry).
2. Run the test and watch it fail, for the reason you expect.
3. Restore the code and watch it pass.

## Conventions

- **macOS 14 is the floor.** `Package.swift` (`.macOS(.v14)`), `Info.plist`
  (`LSMinimumSystemVersion` 14.0) and the README must agree. A macOS 15 API is reached through a
  per-API `if #available` guard, never by raising the deployment target.
- **No light mode.** Every color comes from `Port42Theme`.
- **Fonts.** Always `Port42Theme.mono()` or `Port42Theme.monoBold()`. No system fonts.
- **State.** All mutable state lives in `AppState`. Views render it and call methods on it.
- **Persistence.** Everything goes through `DatabaseService`. No direct SQLite calls elsewhere.
- **Observation.** Use GRDB `ValueObservation` for reactive data, not polling or manual refresh.
- **No Combine in views.** Use `@Published` on `AppState` and `onChange` in views.
- **Naming.** Models are plain structs, services are classes, views are structs.
- **Migrations are append-only.** Never edit an existing migration; add a new `registerMigration`.
- **Fix root causes, not symptoms,** and keep a fix to the change it needs.
- **Injected bridge JS** (`PortBridge.swift`) is plain JavaScript with no frameworks.

## Add a bridge method

Every bridge method is declared once, and every surface (port JS, the gateway, tool use) picks it up
from the registry. There is no second place to wire it.

1. **Declare it** in the register function for its family: `buildBridgeRegistry` in
   `BridgeMethods.swift`, or the feature file that registers its namespace (for example
   `registerChatMethods` in `PortChat.swift`). Give the `BridgeMethod` its `permission` (or nil),
   `paramNames` in positional order, a `description`, an `inputSchema`, and the `run` body. A method
   that streams goes in `buildBridgeStreamRegistry` as a `BridgeStreamMethod`.
2. **If it writes a port,** set `writesTarget` to the argument that names the port. The registry
   then adds the write token for you. Set `replacesState` if the write replaces what the port shows,
   and `needsLiveSurface` if it delivers to a live surface. `BridgeParamConsistencyTests` catches a
   write verb that does not declare its target.
3. **Throw coded errors,** `BridgeError(code:)` with a `BridgeErrorCode`. A new code is a new case
   there.
4. **Decide whether another machine may call it.** Add it to `RemoteAccess.table` in
   `RemoteAccess.swift`: on a named port with a given right, as a filtered listing, or `.never`.
   `RemoteAccessTests` fails until it is classified.
5. **Give it a skill** in `SkillCatalog.skill(for:)`. `SkillCatalogTests` fails for a method with no
   skill.
6. **Test it,** and calibrate the tests.
7. **Regenerate the committed artifacts,** read each diff, and commit them with the change:

   ```bash
   PORT42_REGEN_GOLDEN=1 swift test --filter BridgeSchemaParityTests   # Tests/Fixtures/tool-definitions-golden.json
   PORT42_REGEN_DOCS=1   swift test --filter BridgeDocsExportTests     # llms.txt
   PORT42_REGEN_SKILLS=1 swift test --filter SkillCatalogTests         # skills/*/reference.md
   PORT42_REGEN_GUEST=1  swift test --filter GuestMethodsTests         # guest/src/methods.json, port-page.json
   ```

   Without the variable each suite only verifies, and it fails while its artifact is stale.

## Bug fixes and small changes

Fix it and open a pull request. Explain what broke and why in the commit message, and include steps
to reproduce if the fix is not obvious. Typos, docs, performance and test coverage follow the same
path.

## Major changes: Port42 Proposals

A major change needs a **Port42 Proposal (P42P)** before code is written, because companions, ports
and other instances depend on the API and the wire formats staying stable. Major means:

- a new user-facing feature;
- a change to a wire format (the gateway envelope, the relay or Noise session, invite coupons);
- a change to the bridge API (`port42.*` and its methods);
- an architectural change (new modules, restructured data flow);
- removing or changing existing behavior.

The process:

1. Open an issue titled `[P42P] Your feature name`.
2. Write the proposal in the issue (below).
3. Discuss it there until a maintainer approves it, asks for changes, or closes it with a reason.
4. Build it, and open a pull request that references the issue.

A proposal has two parts.

**The spec** covers the summary and status; each user flow (what the person does, what the system
does, what they see); where it fits in the architecture, as a diagram; a feature table with an ID,
priority and a "done when" condition for each feature; exact protocol or API changes with
compatibility notes; the effect on the port sandbox, CSP, permissions and remote access; and open
questions.

**The implementation plan** covers what must not break; the build steps, each with its goal, the
files it creates and modifies, the unit tests (and how each is calibrated) and a manual check; and
the order of the steps.

`docs/ports-spec.md` with `docs/ports-implementation-plan.md`, and `docs/design-phase4-relay.md` with
`docs/plan-nautilus-phase4.md`, are spec and plan pairs from shipped work.

## Secrets

A PostHog personal key once reached two releases. Turn on the pre-commit secret check once per clone:

```bash
git config core.hooksPath scripts/git-hooks
```

It runs gitleaks with `.gitleaks.toml` when gitleaks is installed (`brew install gitleaks`), and a
pattern check otherwise. CI scans every push the same way (`.github/workflows/secrets.yml`). Only the
public `phc_` PostHog key may ship; the build refuses any other.

## Signing commits

Not required, but appreciated.

## Questions

Open an issue.
