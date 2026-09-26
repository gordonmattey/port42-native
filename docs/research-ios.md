# Port42 on iPhone

Measured against `nautilus` at `51eab10`, 2026-09-26. Numbers from this tree; external claims are
quoted from the source cited. No effort or schedule figures; scope and timing are GM's.

## The answer in one line

An iPhone can render and drive ports. It cannot host agents, because iOS apps cannot run processes,
and the whole nautilus model is that an agent IS a process in a terminal port.

So Port42 on iPhone is not a smaller Port42. It is the **client half** of one, and the product
question is whether that half is worth shipping on its own.

## Three products, again with different costs

| | Goal | Cost |
|---|---|---|
| A | **See and drive my Mac's ports from my phone.** | Already possible: the guest page is HTML over `/ws`. No app, no build. Unverified on mobile Safari; that test costs one minute. |
| B | **A native iOS app that is a peer in the namespace.** | Phase 4's transport, a SwiftUI shell, web ports in `WKWebView`. No terminals, no local agents. |
| C | **Port42 standalone on iPhone.** | Not available. See "the structural blocker". |

## What ports cleanly

**Web ports run unchanged.** `WKWebView` is the same class on iOS, and 17 files touch it. A web port
is HTML, CSS and JS, and it does not know what it is hosted in. This is the single largest thing in
Port42's favor on iOS: the content model needs no work at all.

**Half the view layer is already portable.** Of 21 view files, 10 (4,579 lines) are pure SwiftUI with
no AppKit symbol in them. The other 11 (8,758 lines) are bound to AppKit, and the binding is
concentrated in the desktop metaphor: `NSView` 42 references, `NSWindow` 25, `NSEvent` 25,
`NSPanel` 22.

**The terminal renderer already ships for iOS.** `GhosttyKit.xcframework` carries `ios-arm64` and
`ios-arm64-simulator` slices alongside macOS. That is more than Windows has. What it does not carry
is anything to display, which is the next section.

**SQLite, GRDB and the Keychain are all first-class on iOS.** GRDB's stated support is
"iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / watchOS 7.0+". Persistence is the one layer that is easier
on iPhone than on Windows.

## The structural blocker: iOS has no processes

An App Store app cannot fork or exec. Nine call sites in this tree spawn a process:

```
Services/GatewayProcess.swift:83     the bundled Go gateway
Services/CommandAgent.swift:90       a command companion
Services/AgentProcess.swift:39       an agent subprocess
Services/ClaudeCodeSetup.swift:241   CLI install and auth
Services/ShellExec.swift:19          terminal.exec
Services/AutomationBridge.swift:58   AppleScript
Services/AppState.swift:1593
```

Three consequences, in ascending order of seriousness.

**The gateway is solvable.** It does not have to be spawned; it can be linked. `gomobile bind`
"creates an XCFramework" for `-target=ios`, callable from Swift. So the Go door becomes a library on
iPhone and a subprocess (or a server) on desktop. **This is an argument for the Go kernel that has
nothing to do with Windows**: a Go kernel is linkable on a platform where a spawned one is illegal.

**Terminal ports become windows onto somewhere else.** The emulator exists for iOS, but a terminal
needs a pty and iOS grants none. A terminal port on iPhone can only be a view onto a pty on another
machine. That is a real feature (it is what people want from a phone terminal) but it is a different
feature from the one the Mac has, and it depends on Phase 4.

**Command companions cannot run at all, and that is the model.** `plan-shell-only.md` is explicit:
"A unix shell does not contain grep, and Port42 does not contain Claude. Claude is a process in a
terminal port, enrolled as a client." On iPhone there is no process, so there is no companion. The
options are: the agent lives on your Mac and the phone talks to it, or Port42 on iPhone calls a model
provider directly, which decision D9 forbids ("Port42 never calls a model provider").

**The iPhone therefore has no Echo of its own.** The first-run experience nautilus Phase 1 is building
(setup lands you in a terminal chat with a CLI agent) has no iOS equivalent. Whatever first run looks
like on iPhone, it is a different design, not a port of this one.

## The device bridges split cleanly

| Bridge | On iOS |
|---|---|
| `CameraBridge`, `AudioBridge` | AVFoundation, works, different permission flow |
| `NotificationBridge` | UserNotifications, works, and push is a better peek than the Mac has |
| `BrowserBridge` | WebKit, works |
| `ClipboardBridge` | `NSPasteboard` becomes `UIPasteboard`, mechanical |
| `FileBridge` | `NSOpenPanel` becomes a document picker, mechanical but different UX |
| `ScreenBridge`, `ScreenRecorder` | ScreenCaptureKit does not exist on iOS. ReplayKit records your own app only. Capturing other apps is impossible by design. |
| `AutomationBridge` | `NSAppleScript` does not exist. No equivalent. |

So of the roughly 26 device-backed registry methods, the screen and automation families (11 methods)
have no iOS implementation and never will. That is not a gap to fill; it is a smaller device surface,
and the registry already reports per-method availability.

## App Store review: the risk is 4.2.7, not 2.5.2

**2.5.2 is the one everyone expects to be the problem** and it quotes as: apps "may not download,
install, or execute code which introduces or changes features or functionality of the app". A
generative port is HTML an agent wrote, delivered at runtime, and rendered.

**4.7 is the carve-out that makes it fine.** Apps "may offer certain software that is not embedded in
the binary, specifically HTML5 and JavaScript mini apps and mini games, streaming games, chatbots, and
plug-ins. You are responsible for all such software offered in your app." A web port is an HTML5/JS
mini app by any reading, and the responsibility clause is satisfiable.

**4.2.7 is the real constraint, and it bites the obvious design.** Remote desktop clients must
connect "to a user-owned host device that is a personal computer... and both the host device and
client must be connected on a local and LAN-based network", and "(e) Thin clients for cloud-based
apps are not appropriate for the App Store".

Product A (the phone drives ports on your Mac) is exactly the shape 4.2.7 governs. Over a LAN it
complies. Over Phase 4's Circuit Relay, across the internet, clause (a) is not met.

There is a real argument that Port42 is not a remote desktop app at all: it does not stream a screen,
it is a client of an API rendering its own native UI, which is what any app with a server does. That
argument is probably correct and it is still a review risk, because it is decided by a reviewer
reading a description. **The way to de-risk it is to make the iPhone a peer that holds its own ports
rather than a window onto a Mac**, which is also the more interesting product.

## Recommendation

**Do product A's free version now.** The guest page is already HTML over a WebSocket. Open one on an
iPhone and see what happens. If it works, you have iPhone access to ports today at zero cost, and
everything below is a question of how much better a native app would be, rather than whether phones
are possible.

**Then build B as a peer, not a viewer.** An iOS app that holds its own ports (web and chat), renders
them in `WKWebView` and SwiftUI, and reaches ports on other machines by address. The phone is a peer
in the namespace, which is the product's own model, and it sidesteps 4.2.7 by not being a remote
desktop.

**Treat the Go kernel decision as the enabling one.** `gomobile bind` produces an iOS XCFramework, so
one kernel serves macOS, Windows, Linux and iOS, linked where processes are forbidden and spawned
where they are not. A Swift kernel gives iOS for free too (it is Apple's platform), but only if the
kernel is separable, which is the same seam list as everywhere else. The kernel-boundary work is the
common prerequisite; the language choice decides whether Windows and Linux come along.

**Accept that agents stay on the desktop.** No local companions, no local terminals, no `terminal.exec`
on iPhone. The phone talks to an agent running on a machine that has processes. That is a coherent
product ("my desk is where the work runs, my phone is where I watch and steer") and it should be
designed as one rather than discovered as a limitation.

## Unknowns worth one test each

- **Does the guest page work in mobile Safari?** Unverified. One minute with a phone on the LAN.
- **Does `WKWebView` on iOS accept the `PortBridge` injection unchanged?** The class is the same; the
  message handler API is the same. Expect yes, but it is a ten-line test.
- **Does libp2p's transport work from iOS under background restrictions?** A phone suspends
  aggressively, and a peer that sleeps is a peer that is not reachable. Push notifications exist to
  wake it, which pulls in an APNs relay and therefore a server, which is the one piece of
  infrastructure the desktop product does not need.
- **How does a touch shell work?** The desktop is drag, park, zoom and a right-edge rail. None of the
  interaction model was designed for a thumb. This is design work, not porting work, and it is
  probably larger than the engineering.
