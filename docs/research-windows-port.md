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

So nautilus is, incidentally, the largest single reduction in the cost of a Windows port. Doing the
port before it would mean porting code that is about to be deleted.

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
shell's feel get rebuilt in the browser, and the native-app character is the thing GM has been most
deliberate about.

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
