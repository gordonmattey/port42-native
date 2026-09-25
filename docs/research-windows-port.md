# What a Windows version of Port42 would take

Written 2026-09-24 against `nautilus` at `6d37d0d` (Phase 0 step 2, the call door, landed). Every
number below is measured from that tree, not estimated. No effort or schedule figures appear here;
scope and timing are GM's.

## The question under the question

"A Windows version" is three different products, and they cost nothing alike.

| | Goal | What it needs |
|---|---|---|
| A | **Someone on Windows can see and drive a port I share.** | Nothing new. This is scenario 4, Phase 4, through the browser guest page. |
| B | **Port42 runs on Windows as a shell.** | A second client, and a kernel that is not Swift-and-AppKit. |
| C | **A headless Port42 on Windows**: ports, registry, agents, no shell. | The kernel only, plus a terminal that is not Ghostty. |

A is already on the roadmap and rides along free. Most of what follows is about B, because that is
the expensive one, and because B's real content is not Windows at all.

## The measured shape of the tree

```
Swift        Views      25 files   14,930 lines     SwiftUI + AppKit, none of it portable
             Services   96 files   28,935 lines     of which 15,490 platform-neutral, 13,445 coupled
             Models      5 files       836 lines     plain structs
             Theme       2 files       111 lines
Go           gateway    13 files    3,691 lines     already cross-platform
             cli         9 files    1,360 lines     already cross-platform
             shim        2 files      792 lines     already cross-platform
```

Framework imports across all Swift (95 files import Foundation): SwiftUI 35, AppKit 30, WebKit 12, GRDB 8, GhosttyKit 6,
AVFoundation 4, ScreenCaptureKit 3, AVKit 3, Security 2, UserNotifications 1, Speech 1, Sparkle 1,
AuthenticationServices 1.

The registry is 72 methods. Roughly 26 are device-backed (screen 9, browser 7, audio 5, camera 3,
clipboard 2, automation 2, notify 1); the rest (port 20, space 4, fs 5, bus 2, ports, terminal, rest,
user, companions) are logic.

`Package.swift` declares `platforms: [.macOS(.v14)]` and depends on GRDB, `posthog-ios` and Sparkle.
The last two are Apple-only by construction.

## The four hard dependencies

**1. The UI does not port.** SwiftUI does not exist on Windows, and AppKit obviously does not. All
14,930 lines of `Views` plus the view-shaped half of `Services` are a rewrite against whatever
Windows UI is chosen. This is the largest single item and it is unavoidable in every option below
except the web-shell one.

**2. The terminal does not port.** `GhosttyKit.xcframework` is 537 MB and ships exactly three slices:
`ios-arm64`, `ios-arm64-simulator`, `macos-arm64_x86_64`. There is no Windows slice and upstream
Ghostty does not target Windows (verify before relying on it). Around it sit 2,367 lines of Swift
(`GhosttyTerminalView` 683, `TerminalHooksService` 424, `GhosttyTerminalController` 386,
`TerminalOutputProcessor` 244, plus probes and spikes). Windows needs ConPTY for the pty and a
different emulator. The cheapest is a JS terminal inside the webview, which also deletes a 537 MB
binary dependency from the Mac build.

**3. The webview ports, but its bridge does not.** Port HTML and JS run unchanged under WebView2,
which is Chromium. What is re-implemented is the host side: `PortBridge` (770 lines) is a JS Proxy
over the registry injected into WKWebView, and WebView2 expresses host objects and messaging
differently. The contract survives; the plumbing is rewritten.

**4. Persistence is unverified on Windows.** `DatabaseService` is 2,133 lines of GRDB across 8 files.
GRDB supports Apple platforms and Linux; Windows support needs checking before it is assumed. If it
is absent the choices are a different SQLite wrapper or moving persistence into the Go side.

Smaller but real: Sparkle (updates) has no Windows equivalent in-tree, PostHog's iOS SDK likewise,
Keychain becomes DPAPI or Credential Manager, and notarization becomes Authenticode signing.

## What nautilus already removes from the problem

Phase 1 deletes code that would otherwise each need a Windows answer. Partial count from the plan's
own list: 4,452 lines, including `AgentAuth` (933), `SyncService` (886), `LLMEngine` (755),
`GeminiEngine` (363), `TunnelService` (363), `AppleAuthService` (137).

Three decisions already point the same way:

- **D9, Port42 never calls a model provider.** The Keychain read of Claude Code's OAuth credential
  goes, which removes the Security framework from the critical path.
- **D5 and D6, libp2p behind a transport seam.** Cross-machine identity stops depending on Apple
  sign-in, and the seam is defined in terms of "listen, dial, peer id, stream", which is portable.
- **"The chrome is ports too"** on the future roadmap. If the shell's own parts become ports, the
  shell becomes HTML, and the Windows UI problem changes shape entirely.

Those deletions shrink the SHELL's porting surface. They do not move the kernel boundary: measured
before and after Phase 1 landed, the portable kernel is the same 30 files either way (see "Re-measured
after nautilus Phase 1"). What blocks the kernel is the seam list, not these features.

## The options

**A. Swift everywhere.** Verified 2026-09-24 at swift.org/install/windows: Swift 6.4.0 officially
supports Windows on x86_64 and arm64, installs through WinGet, and ships SwiftPM. It requires Visual
Studio 2022 and the Windows 11 SDK, so the build host is a Windows machine with a C++ toolchain, not
a cross-compile from a Mac. SwiftUI appears nowhere in that documentation, which matches it being an
Apple framework. So the language ports and the UI does not. Keep the 15,490 neutral service lines,
rewrite the rest against Windows APIs. The risk is not the language, it is being the only consumer of
Swift-on-Windows plus GRDB-on-Windows plus every transitive dependency, with no other users hitting
the bugs first.

**B. Kernel to Go, a native shell per platform.** The Go gateway exists and nautilus already makes it
the door. Move the registry, the port model and persistence into Go; the Swift app becomes the macOS
shell, and Windows gets its own. This is the largest change to the current tree and the only one that
also yields Linux. It turns "port to Windows" into "write a second UI", which is a bounded problem.

**C. A web shell in a native host.** The ports are already HTML in a webview, and the roadmap already
wants the chrome to be ports. Then the Windows app is a WebView2 host over a Go kernel, and macOS
either keeps its native shell or converges on the same one. The only option where the desktop's look
is shared rather than re-implemented twice. The cost is that the ceremony, the dreamscape and the
shell's feel get rebuilt in the browser, and the native-app character is a deliberate product
decision.

**D. A separate Windows-native app.** WinUI 3 or similar, sharing only the Go gateway and the
protocol. Best Windows result, two codebases forever, and every feature lands twice.

## The one decision

**Does the kernel stay in Swift?** Everything else follows from that, and Windows is not really the
question being asked. Today the kernel and the shell are one program. Nautilus is already pulling
that boundary into the open: the registry is the API, the gateway is the door, the transport is a
seam. If a Windows version is a real goal rather than a someday, the cheapest moment to move the
kernel out of Swift is while that boundary is being drawn, not after.

Against that: nautilus's stated method is to work in the existing tree because it is tested and
green, and rewriting it would rediscover fixed bugs. That argument holds for a kernel move too. The
honest position is that B and C are a different project from nautilus, not a phase of it, and
starting them mid-nautilus would stall five passing scenarios.

## What to measure before committing to anything

A spike, not a plan. Each of these is a fact the decision turns on and none is currently known:

1. Does the neutral half of `Services` (15,490 lines) compile under the Windows Swift toolchain?
   That single build tells you whether option A is real. It is a day of pointing a compiler at
   existing code, and it either fails fast or changes the whole analysis.
2. Does GRDB build on Windows, and if not, what replaces `DatabaseService`?
3. ConPTY plus a JS terminal in a webview, driving one agent session end to end. This also tests
   whether the Mac build can drop the 537 MB Ghostty dependency.
4. Can WebView2's host-object model express the `PortBridge` proxy contract as it stands?
5. Does the Go gateway build and run on Windows unchanged? It should, and it is the one part of the
   tree with a plausible claim to already being portable.

## Where this sits relative to nautilus

Nothing here asks for a change to Phase 0. The recommendation is to finish nautilus, because it
deletes the most Apple-coupled code in the tree and draws the kernel boundary that any port depends
on, and to run spikes 1, 2 and 5 alongside it, because they are cheap, they are measurements rather
than commitments, and their answers change which option is even available.

## Measured by building it, 2026-09-25

Produced by a compiler rather than by reading. `spikes/windows-kernel/carve.sh` generates a package
from the tree's own files, builds it, and prunes whatever fails until it is green, printing every
drop. Nothing in `Sources` is edited and nothing is duplicated in git. The dropped list is the
deliverable: it is the seam list between kernel and shell.

### The candidate kernel and where it leaks

58 files, 11,449 lines qualify as candidates: no Apple-framework import, minus everything nautilus
Phase 1 deletes. Building them alone on macOS, 22 references reach out of that set into the shell:

| Symbol | References | Where it lives |
|---|---|---|
| `AppState` | 88 | `Services/AppState.swift`, 4,015 lines, imports AppKit |
| `GatewayProcess` | 78 | an AppKit-importing service |
| `ShellState` | 54 | the shell's own state |
| `Port42AuthStore` | 34 | Keychain, so Security |
| `TerminalPortConfig` | 24 | the Ghostty side |
| `AppUser` | 24 | a Model, but Keychain-backed so Security |
| `PortPanel` | 22 | **`Views/PortWindowManager.swift`** |
| `Zoom`, `ClaudeSessionId`'s peers, `SpaceCrypto`, `PortContextItem`, `keeperManifest` | 10 or fewer each | |

Two of those are structural rather than incidental. `PortPanel` is the port's own data model and it
is defined inside a view file, so `DatabaseService` (persistence) depends on the window manager. And
`AppState` at 4,015 lines is referenced by `BridgeDispatcher`, `BridgeReference`,
`BridgeServiceStorage`, `CommandAgent` and `TerminalHooksService`: the registry's dispatch path runs
through the shell's god object.

### Three Apple frameworks hide in files that import no UI

The import scan misses them because they arrive through Foundation-looking code:

- **CryptoKit**, 5 files. `swift-crypto` is API-compatible, so a conditional import is the whole fix.
- **CoreGraphics**, 4 files. `CGPoint`, `CGSize`, `CGRect` and `CGFloat` come from Foundation off
  Apple, so again a conditional import is the whole fix.
- **Combine**, and this one is real. **15 of 96 service files are `ObservableObject`s with
  `@Published` properties**, which binds them to Apple's observation model without importing any UI
  framework. Six of the 15 are deleted by Phase 1; the rest (`AppState`, `PermissionCoordinator`,
  `PortBridge`, `GatewayDoor`, `GatewayProcess`, `ToolExecutor`, `InstructionService`,
  `CLIInstallService`, `ClaudeCodeSetup`) need an observation story off Apple: OpenCombine, or
  callbacks and `AsyncStream`.

### One four-line Apple-ism was blocking the registry

`BridgeValue.fromJSONObject` tells a bool-carrying `NSNumber` from a numeric one with `CFGetTypeID`,
which does not exist off Apple. That single check took `BridgeArgs`, `BridgeRegistry`, `NotifyBus`
and `PublishedDocs` down with it. Replacing it with the `objCType` equivalent (in the generated copy
only, to measure) moved the Linux result from 25 files and 3,014 lines to **30 files and 3,818
lines**. The registry layer is portable; it was one type check away.

### Results

| Platform | Kernel | GRDB |
|---|---|---|
| macOS | builds | builds |
| Linux (`swift:6.0`) | **30 files, 3,818 lines**, only `AutomationBridge` excluded, which is AppleScript and macOS by nature | builds, with `libsqlite3-dev` present |
| Windows (Swift 6.2, windows-2022) | **30 files, 3,818 lines**, the same set as Linux | **does not build**: no system `sqlite3.h`, so `CSQLite` fails |

Run 36107519772: Windows green after 8 prune rounds, Linux green after 9, both landing on the same
30 files. The portable set is the port model and the registry's own types:

```
ActorProbe AgentProtocol ArrangeLog BridgeArgs BridgeErrorCode BridgeRegistry BridgeValue
ClaudeSessionId CodexConfigMerge CompanionCodename FileDropUtil NotifyBus PortActivity PortAddress
PortConsole PortCreate PortEventKind PortInput PortInputProbe PortObject PortOwnedResource
PortPermission PortPresence PortResolution Principal PublishedDocs RecordFraming ShellExec
TerminalOutputProcessor ToolNaming
```

**GRDB does not build on Windows.** `CSQLite` fails with `'sqlite3.h' file not found`, because
Windows ships no system SQLite. On Linux the same probe passes once `libsqlite3-dev` is installed.
So persistence needs either a vendored SQLite (GRDB supports a custom build) or a different store.
That is question 2 of the spike, answered: not a blocker, but not free either.

**Two constraints on the Windows toolchain, both established by failure:**

- `windows-latest` carries Visual Studio 18 (MSVC 14.51), whose STL rejects any compiler older than
  Clang 20: `error STL1000: Unexpected compiler version, expected Clang 20 or newer`. Swift 6.2's
  bundled Clang is older, so the build fails before reading any Port42 source. The workflow pins
  `windows-2022`. Swift on Windows is sensitive to the MSVC it is paired with, which is a standing
  maintenance cost rather than a one-time setup step.
- The harness reports a result only when the build's exit code is zero, and refuses to print a
  survivor count otherwise. Both guards are load-bearing: GitHub runs `shell: bash` with `-e`, so a
  `grep` that finds no errors kills the step at the moment a build succeeds, and a prune loop that
  exhausts its rounds will otherwise report "still failing" as a survivor count.

So roughly 3,800 lines of the kernel are portable today with three conditional imports and one type
check. That is not the whole kernel. What it is, precisely, is the part that does not touch
`AppState`, and the distance between 3,818 and the full 15,490 is almost entirely the cost of
untangling one 4,015-line object and moving `PortPanel` out of a view file.

### What follows from this

The obstacle to a Windows port is not Swift and not the frameworks. It is that kernel and shell share
one object graph. `carve.sh` is therefore a fitness function beyond this question: run it in CI and
the kernel boundary is enforced by the compiler instead of asserted by a document.

## The seam list, priced

The 27 files the prune dropped were each dropped for naming something on the shell's side of the
line. Grouping them by what they name turns "untangle the kernel" into a list with prices. Counting
code references only, ignoring comments:

| Reach for | Files blocked | Lines blocked | What cutting it means |
|---|---|---|---|
| `GRDB` | 5 | 2,849 | Not a real seam: the spike's kernel target deliberately excludes GRDB, so these were never in scope. Adding it helps Linux and does nothing for Windows, where `CSQLite` cannot find `sqlite3.h`. |
| `ShellState` | 3 | 2,528 | `PortPlacement` and `PortPresentation` reach up into shell state for `parkWidth`, `minTileSize` and `Zoom`. Geometry constants living on the shell rather than beside the geometry. |
| `PortPanel` | 2 | 2,305 | The port's own data model, defined in `Views/PortWindowManager.swift`. Moving it to `Models` is the single highest-value structural fix in this list. |
| `AppUser` | 1 | 2,133 | `DatabaseService` needs it, and it is Keychain-backed. Phase 1 already drops the signing keys from `users`, which may remove this by itself. |
| `AppState` | 6 | 1,491 | `BridgeDispatcher`, `BridgeServiceStorage`, `BridgeReference`, `CommandAgent`, `TerminalHooksService`, `Port42Members`. The registry's dispatch path reaching into a 4,015-line object. |
| `GatewayProcess` | 4 | 870 | `GatewayDoor`, `CLIInstallService`, `InstructionService`, `BridgeReference` want the gateway's port number and lifecycle, which is a small interface behind an AppKit-importing class. |
| `Port42AuthStore` | 2 | 436 | Keychain. D9 already removes the app's reason to hold provider credentials. |
| `TerminalPortConfig` | 1 | 386 | Lives with the Ghostty side; it is a config struct, not a terminal. |
| `ClaudeCodeSetup` | 1 | 71 | |

**Nothing on that list is about Windows, or about Swift.** Every entry is a type
that sits on the wrong side of a line the project already believes in. The three biggest are a data
model inside a view file, geometry constants on the shell object, and a god object in the dispatch
path. Fixing them is refactoring Port42 into what its own documents say it is, and a Windows build
is a side effect.

That is also the argument for `carve.sh` outliving this question. Run it in CI and the boundary
stops being a claim: a service that reaches into the shell fails a build, the same way a re-grid on
spawn now fails a test.

## Where the five questions ended up

| | Question | Answer |
|---|---|---|
| 1 | Does the neutral kernel compile on Windows? | **Yes, 30 files and 3,818 lines of it**, the same set as Linux. The rest is blocked by the seam list above, not by the platform. |
| 2 | Does GRDB build on Windows? | **No.** `CSQLite` fails on a missing `sqlite3.h`; Windows ships no system SQLite. Needs a vendored build or a different store. Builds on Linux with `libsqlite3-dev`. |
| 3 | ConPTY plus a JS terminal for the terminal ports? | **Answered: it is the route.** libghostty cannot back a Windows surface (no renderer backend, `PlatformTag` is macOS and iOS only, and the portable "libghostty" is a different library). Ghostty's own `src/pty.zig` is a working ConPTY reference. Full evidence in `docs/spike-libghostty-windows.md`. |
| 4 | Can WebView2 express the `PortBridge` contract? | Not attempted. |
| 5 | Does the Go side build on Windows? | **Yes, all three.** `gateway` and `shim` cross-compile untouched. `cli` needed one function: `isInteractive()` used a hand-rolled `TIOCGETA` ioctl, replaced with `term.IsTerminal`. Ten lines, tests still pass, demonstrated on this branch. |

## Re-measured after nautilus Phase 1 landed (run 36111898137)

Phase 0 finished and Phase 1 steps 1 to 4 landed while this spike was running: the sync client,
ngrok, the invite payloads and the hub's columns are gone. The tree shrank by about 3,965 lines.

| | Before (6d37d0d) | After Phase 1 (c0c4eff) |
|---|---|---|
| Views | 25 files, 14,930 lines | 21 files, 13,337 |
| Services | 96 files, 28,935 | 89 files, 26,563 |
| CryptoKit importers | 5 | 0 in the top imports |
| **Kernel portable on Linux and Windows** | 30 files, 3,818 lines | **30 files, 3,869 lines** |

**The portable set did not grow.** Phase 1 deleted several thousand lines of Apple-coupled code and
the kernel's portable fraction stayed where it was, because the deleted code was never what blocked
it. What blocks it is the seam list: `PortPanel` inside a view file, geometry constants on
`ShellState`, `AppState` in the dispatch path.

Deleting Apple-coupled features shrinks the SHELL's porting surface and leaves the KERNEL boundary
where it is. Only moving types moves that. The two are different problems that share a direction.

## Persistence: the license is not the problem, the wrapper is

Verified 2026-09-25 at sqlite.org/copyright.html. **SQLite is public domain**: "free to copy, modify,
publish, use, compile, sell, or distribute the original SQLite code... for any purpose, commercial or
non-commercial, and by any means." Shipping it inside a closed-source commercial product needs no
license and no attribution. Hwaci sells a Warranty of Title, which is indemnity paperwork for
organizations that need proof of provenance or that operate where public domain dedication is not
recognized. It is optional.

So the Windows failure (`CSQLite` cannot find `sqlite3.h`) is not a licensing question. It is that
GRDB uses the operating system's SQLite by default and Windows ships none.

**GRDB's own support statement**, from its README: "iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ /
watchOS 7.0+ • SQLite 3.20.0+ • Swift 6.1+ / Xcode 16.3+", and "Linux support is provided by
contributors. It is not automatically tested, and not officially maintained." Windows is not
mentioned at all.

Three options, in preference order:

1. **Vendor SQLite into the build.** GRDB documents custom SQLite builds, so `DatabaseService`'s
   2,133 lines survive untouched. The cost is not the license, it is becoming the maintainer of a
   GRDB configuration that upstream does not test on a platform upstream does not claim.
2. **Drop GRDB and talk to SQLite's C API through a thin Swift wrapper.** SQLite is C and builds
   everywhere. You rewrite the GRDB-flavored parts of `DatabaseService` and own a small wrapper
   instead of depending on an unsupported configuration of a large one.
3. **Move persistence to Go.** `modernc.org/sqlite` is pure Go with no cgo and builds for Windows
   without ceremony. Only sensible if the kernel is moving to Go anyway, in which case it is free.

## Ghostty: the app has no Windows build, but Port42 does not embed the app

Ghostty's install documentation covers macOS and Linux only; Windows is not mentioned. The GUI is
macOS SwiftUI plus Linux GTK.

But Port42 embeds **libghostty**, not the app, and Ghostty's README describes libghostty as
"compatible for macOS, Linux, Windows, and WebAssembly". The `GhosttyKit.xcframework` in this tree
ships `ios-arm64`, `ios-arm64-simulator` and `macos-arm64_x86_64` and nothing else (measured), so the
Windows door is unbuilt rather than closed: it would mean building libghostty from source for Windows
and writing a host layer, against today's AppKit `NSView` hosting a Metal surface.

**Answered, 2026-09-25, in `docs/spike-libghostty-windows.md`: no. Use ConPTY plus a JS terminal in
WebView2.** The spike cross-compiled Ghostty rather than reading about it, and three findings each
settle it on their own:

- **The portable libghostty is a different library.** Ghostty's own `build.zig:213-240` says of the
  target that produces the header declaring `ghostty_surface_new`: "This is NOT libghostty (even
  though its named that for historical reasons). It is just the glue between Ghostty GUI on macOS and
  the full Ghostty GUI core." The README's portability sentence scopes itself to `libghostty-vt`,
  which is a VT parser and screen state, with no surface, no pty and no renderer.
- **The build stops at the renderer, not at a detail.** `zig build -Dtarget=x86_64-windows-gnu
  -Demit-lib-vt=true` succeeds. The full library fails, and patching past the first error (`pwd.h`)
  reaches the real wall: the "opengl" backend is EGL and DRM, which is the Linux GTK renderer.
  `grep -rln "wgl\|WGL" pkg/opengl/ src/renderer/` returns nothing. The three backends are opengl,
  metal and webgl. Windows has no backend.
- **Even a built library could not make a surface.** `src/apprt/embedded.zig:431-440` defines
  `PlatformTag` as `macos = 1, ios = 2`, and every other tag returns `error.UnsupportedPlatform`.
  `GhosttyTerminalView.swift:529` sets exactly that tag.

**The unlooked-for finding: Port42 is not on upstream Ghostty.** `vendor/GhosttyKit-LICENSE.txt` pins
the `manaflow-ai/ghostty` fork, which carries 14 API symbols upstream does not have. Port42 calls
three, and one is load-bearing: `ghostty_surface_set_pty_tee_cb` is how `TerminalHooksService` and
`TerminalOutputProcessor` see terminal output at all, and upstream has no equivalent. So porting this
would not be work against a 61k-star project with CI. It would be work against a fork, maintained
through the port, which upstream has no reason to take back while it moves cross-platform effort into
`libghostty-vt` instead. That is worth knowing regardless of Windows.

**Ghostty's ConPTY implementation is a gift to the other route.** `src/pty.zig:326-490` is a complete
`CreatePseudoConsole` / `ResizePseudoConsole` implementation. Ghostty's core is Windows-capable; only
its surface is Apple-only. So the fallback route starts from a 165-line reference rather than a blank
page.

**And the coupling is smaller than the earlier count suggested.** Of the 2,367 lines, 
`TerminalHooksService` (424) is a socket receiver with no terminal knowledge,
`TerminalOutputProcessor` (244) is a pure byte pipeline, and `GhosttyTerminalController` (386)
contains no `ghostty_*` calls at all and already sits behind a seam. The genuinely bound code is
`GhosttyTerminalView.swift` (683) plus about 114 lines of app and probe glue.

The honest cost of the chosen route: no GPU cell rendering on Windows, and macOS and Windows terminal
ports will diverge on VT edge cases. That is a deliberate trade, not an oversight. Against it, the
alternative's first step is writing a graphics backend for a terminal emulator inside a forked Zig
codebase, and this one's first step is calling `CreatePseudoConsole`.

## The recommendation on the boundary

Written up separately and in full in **`docs/recommend-kernel-boundary.md`**, so it can travel on its
own. In short: make three mechanical moves (`PortPanel` into `Models`, the geometry constants off
`ShellState`, `GatewayProcess` behind a protocol), wire `carve.sh` into CI so the boundary is
enforced rather than asserted, and defer both the `AppState` split and the kernel-language question
until nautilus lands and a second client is real. None of the three is a Windows change. If Windows
never happens they are all still right.
