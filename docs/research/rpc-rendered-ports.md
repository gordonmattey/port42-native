# Rendering a port over RPC, without shipping its code

Against `nautilus` with `research` merged, at `5d15499`, 2026-09-26. A design note, not an approved
plan and not scheduled. It answers one cell of the table in
[invite-over-libp2p.md](invite-over-libp2p.md): the **third kind of state** (the live surface) under
the **first mode** (RPC), for a guest with no Port42 installed.

The question: today `gateway/guestpage.go:116` calls `port.getHtml` and `:119` assigns
`surface.srcdoc = SHIM + html`, so the guest's browser holds the port's source. What would it take
for the host to render and the guest to receive output instead?

## Verdict

**Viable for one port class and one only: a port whose surface is markup and CSS, read-only, with no
canvas, no animation loop, and no host-side interaction.** For that class the cheapest correct
mechanism is a server-rendered snapshot plus content patches, and it is a small extension of
machinery that already exists (`port.getDom`, `port.subscribe`, the `state` event).

**Not viable, on measured grounds, for the port classes Port42 actually promotes.** Three blockers,
each independent:

1. **A canvas or WebGL port has no readable DOM.** Its content is GPU pixels behind one element.
   Every DOM-shaped option renders it as an empty rectangle. The only option that carries it is pixel
   streaming, which costs (measured) 2.4 to 17.3 Mbit/s per viewer for one tile.
2. **The platform tells ports to stop rendering when the host is not looking at them.**
   `ShellState.presentation` (`Sources/Port42Lib/Services/PortPresentation.swift:79-120`) returns
   `visible: false` for parked, off-desktop, galaxy-zoom and occluded ports, and the port manual
   instructs authors to cancel their `requestAnimationFrame` loop on that signal
   (`Sources/Port42Lib/Resources/ports-core.txt:12`). A remote viewer watching a port the host has
   parked receives frames of a port that has correctly stopped drawing.
3. **Replayed input is structurally second class.** The input listener at
   `Sources/Port42Lib/Views/PortWindowManager.swift:1048` discards any event with
   `isTrusted !== true`, deliberately, because a port was caught seizing right-of-way by simulating
   pointer events. Remote input replayed with `dispatchEvent` is untrusted by definition, so it
   drives the port while being invisible to presence and to the activity token.

**The three claims in `README.md:79-84` do not all hold.** "Works for ports whose live state cannot be
replicated" holds and is the real prize. "The code and data never leave the machine" holds for code
only, and only under pixel streaming. "The fork flag becomes enforceable on the web" holds under pixel
streaming and fails under every DOM-shaped option, because the DOM you must ship to make a port look
right includes its CSS, and `port.getDom` already returns `document.documentElement.outerHTML`
(`Sources/Port42Lib/Services/BridgeMethods.swift:354`), scripts included.

## What ships today, measured

The guest page is 8,046 bytes (`gateway/guestpage.go:18-182`), served from the gateway at `/port`
(`gateway/main.go:53-56`) so it is same-origin with `/call`.

What the guest's browser holds after a successful load:

| Held by the guest | Evidence |
|---|---|
| The port's full source HTML, including every `<script>` and `<style>` | `guestpage.go:116` (`port.getHtml`), `:119` (`srcdoc = SHIM + html`) |
| A 928-byte shim that proxies `window.port42.*` calls to the host over `/call` | `guestpage.go:86-101` |
| The bearer token, held by the parent frame; the sandboxed iframe never sees it | `guestpage.go:44` (`sandbox="allow-scripts"`), `:63-81` |

So the guest runs the port. Every `port42.*` call is already RPC, and that half is done. What is not
done is **rendering**: there is no channel over which output, rather than source, crosses.

**What the live stream carries today.** `port.subscribe` yields the port's Notify envelopes over `/ws`
(`BridgeMethods.swift:46-73`). On a content change the guest gets a `state` event, and that event
**carries the token, not the content**, by explicit design
(`Sources/Port42Lib/Services/PortEventKind.swift:42-58`). The guest's response is to re-read, which
today means calling `port.getHtml` again and replacing the whole `srcdoc` (`guestpage.go:147`). Every
change is a full document reload and a loss of runtime state.

**What a port document is made of.** Measured on the manual's canonical complete example, a stateful
todo port (`Sources/Port42Lib/Resources/ports-context.txt:84-258`):

| Part | Bytes | Share |
|---|---|---|
| `<script>` | 4,834 | 65% |
| `<style>` | 2,029 | 27% |
| Markup | 546 | 7% |
| Total | 7,409 | |

Plus a fixed 3,237-byte wrapper every port document gets
(`Sources/Port42Lib/Views/PortWindowManager.swift:1191-1259`), whose CSP is `default-src 'none'`
(`:1199`), and an 8,518-byte console-forwarding user script injected at document start (`:971-999`,
source at `:1262`).

That table is the whole economics of this question. **Markup is 7% of a port.** Withholding the code
means withholding 92% of what makes the port look and behave as it does, and the 27% that is CSS has
to be shipped anyway for the markup to mean anything on screen.

**The transport, as it stands.** WebSocket messages are capped at 2 MB (`gateway/gateway.go:28`) and
**compression is off**: `websocket.Accept` is called with `AcceptOptions` that set only
`OriginPatterns` (`gateway/gateway.go:160-162`), and in `nhooyr.io/websocket` the zero value of
`CompressionMode` is `CompressionDisabled`
(`~/go/pkg/mod/nhooyr.io/websocket@v1.8.17/compress.go:26`). Every byte figure below is a wire byte.

## The four options

### Option 1: streamed DOM mutations

A `MutationObserver` in the host's webview reports changes; the guest applies them to a local tree.
The injection mechanism exists: the console forwarder and the input listener are already
`WKUserScript`s at `.atDocumentStart` in an isolated content world
(`PortWindowManager.swift:971-999`, `:1038-1074`), so an observer needs no cooperation from the port.

**What the guest receives:** an initial tree, then a stream of `MutationRecord`-shaped deltas.

**What the host must run:** the port's webview, mounted and visible (see Cost), plus the observer and
a serializer. One observer serves all viewers if they all see the same tree.

**What breaks:**

- **CSS.** The port's `<style>` is 27% of the document and is not a mutation. Ship it and you have
  shipped code. Withhold it and the guest renders unstyled markup.
- **Canvas.** `MutationObserver` reports nothing about pixels drawn into a `<canvas>`. A shader port
  streams as one empty element forever.
- **Anything not in the DOM.** Form control `value` is a property, not an attribute, so typed text is
  not a mutation. Scroll position, focus, selection, `<details>` open state driven by the UA, CSS
  animation and transition phase, and shadow roots not explicitly observed are all invisible.
- **Behavior.** A guest holding markup with no script has a picture of a UI, not a UI. Every click has
  to round-trip (see Inputs), so the guest's latency floor is one network RTT per interaction on a
  surface that locally responds in one frame.
- **Volume.** A port that rewrites a list on every keystroke emits a mutation burst per keystroke.
  Unmeasured in this tree; see Unknowns.

### Option 2: server-rendered snapshot plus content patches

The host reads its own live DOM and sends a snapshot, then sends further snapshots or diffs when the
port's content moves. This is the option the existing seams almost describe: `port.getDom` returns the
live DOM with a token from the same instant (`BridgeMethods.swift:317-364`), and the `state` event
already says "re-read, and here is what to re-read against" (`PortEventKind.swift:42-58`).

**What the guest receives:** HTML for a subtree, plus CSS, on a change-driven cadence.

**What the host must run:** the port's webview, and a diff step if patches rather than whole snapshots
are wanted. Nothing new is needed to know *when*: the `state` event is the trigger and it already
fires on every write through the dispatcher.

**What breaks:**

- **The same canvas hole as Option 1.** `outerHTML` of a canvas element is `<canvas …></canvas>`.
- **The same CSS problem, and it is worse here.** The honest version of this option ships markup plus
  style and withholds script, which is 35% of the document. That is not "no code", it is "no
  behavior".
- **Source leaks unless stripped.** `port.getDom`'s fixed expression is
  `document.documentElement.outerHTML` (`BridgeMethods.swift:354`), which contains the port's
  `<script>` bodies. A render path built on it leaks exactly what the no-fork flag is meant to
  withhold, unless scripts are stripped on the way out, and stripping them is what removes the
  behavior.
- **Granularity.** The `state` event is deliberately content-free so that a two-line patch and a whole
  document replacement have the same event shape. Turning it into a content channel changes that
  design decision, and device frames ride the same topic
  (`PortEventKind.swift:51-54`, `:68-72`).
- **Interaction, as Option 1.**

### Option 3: pixel streaming

The host captures the port's rectangle and sends frames. **The capture primitive already exists.**
`screen.record` accepts a `{port: <udid>}` target which lands on the self-window filter with a
`sourceRect` set to the union of the ports' tile rects
(`Sources/Port42Lib/Services/ScreenRecorder.swift:19-24`, `:53`). `screen.stream` already pushes live
JPEG frames as Notify events: defaults `scale: 0.5`, `fps: 4`, capped at 10 fps
(`Sources/Port42Lib/Services/ScreenBridge.swift:197-198`), encoded at JPEG quality 0.6 (`:360-361`)
and carried base64 with its mime type (`:367`).

**What the guest receives:** frames. Nothing else.

**What the host must run:** a `ScreenCaptureKit` stream per distinct viewport, a `CIContext` and a
JPEG encode per frame, and the port's webview, visible and unpaused.

**What breaks:**

- **The Screen Recording permission.** Every capture path here goes through TCC
  (`ScreenBridge.handleTCCError`, `ScreenBridge.swift:206`, handler at `:320`). Sharing a port would prompt for a system permission
  that has nothing to do with sharing, and a denial is fatal to the feature rather than degrading it.
- **The capture target is the host's composited window.** `sourceRect` is the union of *tile rects*.
  A port with no tile rect on the current desktop, meaning parked, on another space, or in the galaxy,
  has no rectangle to capture. This is the same blocker as (2) in the verdict, arriving through the
  capture layer rather than the render layer.
- **Text quality.** JPEG at quality 0.6 on monospace text at `scale: 0.5` is a lossy render of a
  text-dense surface. Measured sizes below; legibility unmeasured.
- **No video codec on the wire.** There is no WebRTC anywhere in the tree (`Package.swift:8-10` lists
  GRDB, PostHog and Sparkle only; grep for `webrtc` across `Sources/` and `gateway/` is empty). H.264
  exists but only inside `AVAssetWriter` writing a file (`ScreenRecorder.swift:458`), not as a live
  stream. So "pixel streaming" over today's transport means base64 JPEG over an uncompressed
  WebSocket, which is the most expensive form of it.
- **One presentation per port.** See Cost.

**Measured frame cost.** JPEG quality 60, encoded with `sips` from `docs/screenshot.png`, a real
Port42 UI capture at 3456x2234, resampled to each size. Base64 inflation is 4/3 and is exact.

| Frame | JPEG bytes | Base64 bytes | At 4 fps | At 10 fps | Share of the 2 MB message cap |
|---|---|---|---|---|---|
| 400x259 | 19,239 | 25,652 | 0.82 Mbit/s | 2.05 Mbit/s | 1.2% |
| 800x517 | 56,692 | 75,592 | 2.42 Mbit/s | 6.05 Mbit/s | 3.6% |
| 1600x1034 | 162,217 | 216,292 | 6.92 Mbit/s | 17.30 Mbit/s | 10.3% |
| 1728x1117 | 190,593 | 254,124 | 8.13 Mbit/s | 20.33 Mbit/s | 12.1% |
| 3456x2234 | 526,035 | 701,380 | 22.44 Mbit/s | 56.11 Mbit/s | 33.4% |

Read the 800x517 row as one ordinary tile and the 1728x1117 row as the whole shell window at 1x.

### Option 4: headless render on the host

A second, hidden webview per remote viewer, rendered without being on screen, so the remote viewer's
size and visibility are independent of the host's.

**This one is refuted in the tree.** `PortRenderProbe` exists to catch port blanking, and its stated
invariant is that "the live view's window is never nil (windowless implies surface discarded implies
blank)" (`Sources/Port42Lib/Services/PortRenderProbe.swift:8-9`). A WKWebView with no window does not
hold a render surface, so there is nothing to observe, snapshot or capture.

It is not refuted for an **off-screen real window**, which is a different thing: a webview in an
`NSWindow` placed outside every display's bounds still has a window. Whether WebKit keeps compositing
and ticking `requestAnimationFrame` there is unmeasured. There is indirect evidence that the platform
signals such a window as not visible: the shell's own ambient background pauses on
`NSWindow.occlusionState` and that pause took its cost from 35.5% of a core to 0.4%
(`docs/plan-nautilus-phase2.md:108-111`, `:124-131`), which is the app choosing to stop drawing exactly
when the OS says nobody can see it.

**What it would buy if it worked:** the only option that gives a remote viewer its own size, its own
`visible: true`, and its own interaction state, without the host having to keep the port on screen.
That is the difference between "watch what I am looking at" and "use my port". It also multiplies the
host cost by the viewer count (see Cost).

## Comparison

| | Guest receives | Host runs | Canvas survives | Code withheld | Host may look away |
|---|---|---|---|---|---|
| **Today** (ship the code) | source HTML | nothing extra | yes | no | yes |
| **1. DOM mutations** | tree plus deltas, and CSS | webview plus observer | no | script only | no |
| **2. Snapshot plus patches** | HTML subtree, and CSS | webview | no | script only | no |
| **3. Pixel frames** | JPEG frames | webview plus SCStream plus encoder | yes | yes | no |
| **4. Headless render** | any of 1 to 3 | a webview per viewer | depends on 1 to 3 | depends | yes, if it works |

## Which port types survive

Port42's own documentation defines the port classes. `type` is one of `web`, `terminal`, `browser`,
`chat` (`BridgeMethods.swift:97-120`). The manual's own examples include "WebGL shader playground that
writes its own shaders" and "Collaborative drawing atelier, many AI models take turns on one canvas"
(`docs/port-examples.md:14-16`, `:28-29`), and "set this shader port as my background" (`:56`). The
resident core devotes a full non-negotiable to animation discipline, naming "a shader that never
animates" as the failure it prevents (`Sources/Port42Lib/Resources/ports-core.txt:12`). The input
listener's own comment names "a canvas/game/shader port … driven by pointers with nothing editable in
sight" (`PortWindowManager.swift:1061-1063`). **Canvas ports are not a corner case in this product,
they are a promoted example.**

| Port type | Option 1 DOM | Option 2 snapshot | Option 3 pixels | Option 4 headless |
|---|---|---|---|---|
| Static markup readout (chart as SVG or HTML, table, log) | works read-only | **works read-only** | works, wastefully | works |
| Stateful DOM app (the manual's todo port) | render yes, behavior no | render yes, behavior no | works with input replay | works with input replay |
| Canvas or WebGL shader | **empty rectangle** | **empty rectangle** | works | works |
| Terminal port | no live DOM; it is Ghostty, not a webview | same | works as pixels | same |
| Browser port | foreign site, full source leak | foreign site, full source leak | works | works |
| Chat port | its content is the transcript, and a transcript is an op log, so **Mirror, not RPC, is the right mode** (see `invite-over-libp2p.md:85-89`) | same | wasteful | same |

**A WebGL or canvas shader port, specifically.** Under Options 1 and 2 the guest receives
`<canvas id="gl" width="800" height="600"></canvas>` and renders nothing, because the pixels live in a
GPU context that has no serialization in the DOM. There is no partial credit here. Under Option 3 it
works and is the most expensive case, because a shader changes every pixel every frame, so the frame
sizes in the table above are the floor rather than a worst case, and 4 fps is not what a shader is
for. Under Option 4 it is the case that most needs its own window, because a shader as a remote
viewer's wallpaper at the viewer's own size cannot share the host's render.

**A port that uses `port.exec`.** Two separate things.

If the port is the *target* of `port.exec` from elsewhere, nothing changes: `port.exec` runs JS in the
host's webview (`BridgeMethods.swift:285-315`, via `PortExecJS.run` at
`Sources/Port42Lib/Services/PortExecJS.swift:170-199`), the port's DOM moves, the dispatcher publishes
a `state` event, and the render path picks it up like any other write. RPC rendering is actually
*better* here than today's guest page, which reloads the whole `srcdoc` on every such event.

If the *guest* holds `port.exec`, the render path is irrelevant to the fork question, because
`port.exec` reads `document.documentElement.outerHTML` and returns it. This is already recorded
(`README.md:72-73`). So a no-fork grant must exclude `port.exec`, and excluding it is not free: it is
the method a remote driver uses to call into a port. An RPC-rendered no-fork share is therefore
`port.push` in, render out, and nothing else.

## How inputs travel back

Today they do not, because the port runs in the guest. Under every option above they must.

**What has to be captured in the guest and replayed on the host:** `pointerdown`, `pointermove`,
`pointerup`, `click`, `wheel`, `keydown`, `keyup`, `beforeinput`, `input`, `compositionstart`,
`compositionupdate`, `compositionend`, `paste`, `drop`, `focus`, `blur`, `scroll`, plus the target
node identity and the coordinates translated from the guest's viewport to the host's.

**Two blockers in the tree, both measured.**

**1. Replayed events are untrusted, and Port42 already refuses to count untrusted events.** The input
listener's first line is `if (!e || e.isTrusted !== true) return;`
(`PortWindowManager.swift:1048`), and the comment says why: without it a port claims the pen by
simulating input, "caught live on the onboarding shader, which fires its own pointer events and so
held the human's lease forever, locking companions out of a port nobody was touching". Any replay
mechanism built on `dispatchEvent` produces `isTrusted: false`. So replayed remote input would drive
the port while being invisible to presence and to the activity token, which means the CAS token would
stand still while the document moved, which is precisely the defect that listener exists to close.
There is **no synthetic event injection anywhere in the tree** to reuse: grep across `Sources/` for
`CGEvent`, `postEvent`, `new MouseEvent`, `new KeyboardEvent` and `PointerEvent` returns nothing.

**2. The composition family cannot be captured as keys and pointers, and this is measured.** Spike C,
2026-07-26, with a real human at real input devices, logged 11 real content changes on a web port and
found a `keydown` plus `pointerdown` listener saw 8
(`docs/plan-port42-protocol-local-bus.md:1264-1320`). The three it missed:

| What it was | Events actually fired |
|---|---|
| The emoji picker | `composition*`, `beforeinput`, `input` |
| Dictation | `composition*`, `beforeinput`, `input` |
| Right-click Paste | `paste`, `beforeinput`, `input` |
| Dragging text in from another app | `drop`, `beforeinput`, `input` |

None involve a key or a pointer. A remote input path that forwards keys and pointers is blind to
exactly these, on evidence gathered in this codebase rather than by inference.

**What cannot be replayed at all.**

- **IME.** Composition is a negotiation between the OS input method, the focused element and the
  editing host. Forwarding `compositionupdate` text from the guest can insert the *result*, but the
  guest's own IME candidate window is the guest's OS, and the host's editing context is a different
  document. Round-tripping each keystroke through the host to place a candidate window is a
  per-keystroke network RTT, which is not usable.
- **File drops.** Structurally impossible as designed. `handleFileDrop` dispatches **paths, not
  bytes** (`Sources/Port42Lib/Services/PortBridge.swift:176`, `:205`), and it grants those paths to
  the port's principal so the port's subsequent `fs.read` succeeds (`:184-187`). A guest's dropped
  file is a path in the guest's filesystem. Forwarding it hands the host a path it does not have,
  and the grant would authorize the host to read a host path of the guest's choosing.
- **Clipboard.** `clipboard.read` and `clipboard.write` act on the host's pasteboard
  (`BridgeMethods.swift:917-933`). A guest pasting would either paste the host's clipboard, which
  leaks, or would need its own clipboard forwarded, which means the guest's clipboard crosses the
  network on every paste.
- **Focus.** There is one focused element per document. With N viewers on one host-rendered port there
  is one focus, so two viewers cannot type in two fields. Under Option 4 each viewer has its own
  document and its own focus, which is the strongest argument for Option 4 and the reason it is worth
  measuring.
- **Scroll.** One scroll position per rendered document, same argument.

## What it costs

**Per-viewer host CPU, from a measured baseline.** The webview eviction plan records: "88 WebContent
processes at 101 ports, ~90% idle CPU" (`docs/plan-webview-eviction.md:4-5`). That is **1.02% of a
core per idle, unpaused webview**. Eviction is a plan, not built: grep for `evictWebView` across
`Sources/` returns nothing, so the registry still holds one webview per port ever created
(`plan-webview-eviction.md:11-14`), and the proposed cap is roughly 50 mounted web or browser
webviews (`:158`).

That cap is the constraint Option 4 collides with. One extra webview per remote viewer, on a machine
already holding one per port, spends the working-set budget on viewers instead of on the user's own
desktop.

**Per-viewer render cost, for a thing that draws.** The only measured continuous renderer in the tree
is the ambient background, a `TimelineView`: uncapped it costs 27.4% of a core, capped at 24 fps it
costs 9.6% (`docs/plan-nautilus-phase2.md:37`), and after the occlusion pause landed, 10.5% visible
against 0.4% hidden (`:124-131`). Estimate, not measurement: a continuously animating port costs the
same order, so **roughly 10% of a core per animating surface at 24 fps**, and a per-viewer headless
renderer multiplies that by the viewer count.

**Encode cost.** Unmeasured. `screen.stream` does a `CIContext.createCGImage` plus an
`NSBitmapImageRep` JPEG encode per frame on the stream's sample queue
(`ScreenBridge.swift:347-361`), and the code carries a note that allocating a `CIContext` per frame
"visibly stutters the pointer" (`:337-339`), which is evidence the path is not free but not a number.

**Bandwidth.** Option 3 is in the table above: 2.42 Mbit/s for one 800x517 tile at the default 4 fps,
17.3 Mbit/s for a 1600x1034 tile at the 10 fps cap, base64 over an uncompressed WebSocket
(`gateway/gateway.go:28`, `:160-162`). Options 1 and 2 are much cheaper per event and unmeasured in
aggregate: one snapshot of the manual's example port is 2,575 bytes of markup plus style, against
7,409 bytes for the full source, and a patch is smaller again. The cadence, not the size, is the
unknown.

**Latency.** Every option puts one network round trip between a guest's click and the pixel that
answers it, because the render happens on the host. Local is one frame. Over the Phase 4 transport the
stream round trip was measured sub-millisecond on a LAN (`docs/plan-shell-only.md:274`, Spike F),
so on a LAN this is tolerable and over a relay it is not. Unmeasured for a relayed path.

**One presentation, not N.** `ShellState.presentation` is a pure function of the **host's** shell
state: `isBackground`, `mode`, `size`, `zoom`, `onDesktop`, `isPeeking`, `area`
(`PortPresentation.swift:79-120`). There is no viewer parameter, and `w, h` are forced to `0,0`
whenever `visible` is false (`:43-47`). A host-rendered port therefore has exactly one size and one
visibility for all viewers, and the port itself is instructed to size from `p.w`/`p.h` and to pause
when `visible` is false (`ports-core.txt:12`,
`Sources/Port42Lib/Resources/ports-context.txt:331-335`). Serving two viewers at two sizes requires
either Option 4 or a per-viewer presentation, which is a change to a signal the whole port contract
rests on.

## The three claims, tested

From `README.md:79-84`.

**"The fork flag becomes enforceable on the web." Partly false.** It holds under Option 3, where the
guest receives pixels and there is nothing to extract but a screen recording. It fails under Options 1
and 2, because `port.getDom` returns `document.documentElement.outerHTML` including scripts
(`BridgeMethods.swift:354`), and because a stripped version still ships the CSS, which is 27% of the
document and is code. And it fails under all options if the grant includes `port.exec`, which is
already recorded but bears restating: the render path is not where this flag is won or lost. **The
flag is a capability boundary, and RPC rendering changes which methods it must exclude, not whether
exclusion is the mechanism.**

**"The port's code and data never leave the machine." Half true, and the half that fails is the half
people mean.** Code can be withheld, cleanly under Option 3 and partly under Options 1 and 2. Data
cannot, under any option, because rendering *is* showing the data. A pixel frame of a revenue chart
contains the revenue. What RPC rendering actually buys is that the data leaves in **exactly the shape
the port chose to show it**, and no other shape: no underlying array, no storage keys, no history, no
`port.history` version list. That is a real and defensible property, and it should be stated that way
rather than as "data never leaves".

**"It works for ports whose live state cannot be replicated at all." True, and it is the only claim
that holds unconditionally.** The live surface does not replicate
(`invite-over-libp2p.md:78-81`). RPC rendering does not attempt to replicate it: the host remains the
sole place it exists, and the guest sees output. This is the claim worth building on, and it is also
the one that makes a phone a viewer rather than a peer.

## Is there a cheap partial?

Yes, and it is much cheaper than any of the four options.

**The recommended partial: a read-only render, opt-in per port, no input path.**

1. **The port declares it.** `port.setCapabilities` already exists and already stores a declared
   string array returned by `ports.list` (`BridgeMethods.swift:1654-1663`). A port that declares
   `"remote-render"` is asserting that its surface is markup and CSS, that it has no canvas, and that
   it is meaningful without interaction. A declaration, not a detection, for the same reason
   `port-shape.md` argues shape should be declared: the platform cannot infer it and guessing wrong
   is worse than asking.
2. **The host renders on the existing trigger.** The `state` event already fires on every write and
   already carries the token (`PortEventKind.swift:42-58`). The guest's reaction changes from "reload
   the whole `srcdoc`" (`guestpage.go:147`) to "fetch and swap the rendered subtree".
3. **A read verb, not a new stream.** `port.getDom` is already honestly read-only, and honestly so by
   *shape*: it has no `js` parameter, so a caller cannot smuggle a mutation through it
   (`BridgeMethods.swift:340-346`). What it needs is a variant that strips `<script>` and returns
   markup plus style, so a no-fork grant can include it. That variant is the only new method.
4. **No input path.** The guest gets no `dispatchEvent` replay, no synthetic events, no focus and no
   clipboard. `port.push` remains the one way in, which the guest page already does
   (`guestpage.go:162-171`), and which is a well-formed JSON payload the port chose to accept rather
   than an impersonation of a human.

**What that avoids:** the `isTrusted` problem entirely, the IME and file-drop and clipboard problems
entirely, the per-viewer webview cost entirely, the Screen Recording permission entirely, and the
canvas problem by having the port say up front that it is not that kind of port.

**What it delivers:** a live, styled, no-fork, read-only view of a DOM port in a stranger's browser,
with `port.push` as the interaction channel. In the vocabulary of `invite-over-libp2p.md:85-89` this
is RPC mode done properly for the one kind of state that mode can serve, with the port's consent.

**A second, smaller partial worth noting.** Even without any of this, the guest page's current
behavior is wrong in a way that is cheap to fix and independent of this whole question: it reloads the
entire `srcdoc` on every `state` event (`guestpage.go:147`), destroying the guest's scroll, focus and
runtime state on every host keystroke that lands as a write. That is a defect in the ship-the-code
path, not an argument for replacing it.

## What could not be determined

| Unknown | What would settle it |
|---|---|
| Whether a WKWebView in an **off-screen `NSWindow`** keeps compositing and ticking `requestAnimationFrame`. This is the whole of Option 4. | A spike: mount a webview in an `NSWindow` positioned outside every display, run a `requestAnimationFrame` counter, read the tick rate, and call `takeSnapshot`. Non-blank snapshots at full rate makes Option 4 live; blank or throttled kills it. |
| **Mutation volume** for a real port. Options 1 and 2 are cheap per event and unknown per second. | Inject a counting `MutationObserver` as a `WKUserScript` (the mechanism at `PortWindowManager.swift:971`) and log records-per-second and bytes-per-second while a human drives a real port. |
| **Real port document sizes** in the field. The only figures here come from the manual's examples; no port HTML is checked into the tree (a `find` for `*.html` outside `docs/`, `dist/` and `.build/` returns nothing). | `SELECT length(html) FROM port_panels` against a dev database. Attempted and refused by this session's data-handling policy, so it stands unmeasured. |
| **JPEG legibility** of monospace text at quality 0.6 and `scale: 0.5`, which is `screen.stream`'s default. | Capture one real text-dense port at those settings and look at it. |
| **Encode cost per frame** on the host. | Instrument the `createCGImage` plus JPEG encode in `ScreenStreamDelegate.stream` (`ScreenBridge.swift:347-375`) and read CPU time per frame. |
| **Relayed latency.** Spike F's sub-millisecond figure is a LAN stream round trip. A render round trip through Circuit Relay v2 is the case that matters and is unmeasured. | Milestone C's real-network measurement, which is already planned for Phase 4 (`docs/plan-shell-only.md:303-304`). |
| Whether **stripped markup plus style** actually renders a real port recognizably. Asserted here, untested. | Take a real DOM port, strip its `<script>`, render the remainder in a plain browser, compare. |

## What would have to be true before this is worth starting

In order. None of these is a schedule.

1. **Phase 4's transport exists and is measured on a real network.** Every option here is a stream
   between two peers. Until the pipe exists there is nothing to render into.
2. **Port42 to Port42 share has shipped, and the fork flag is enforced as a capability boundary
   there.** `README.md:79` already scopes this. If the flag turns out to be the wrong mechanism
   between two Port42 instances, RPC rendering inherits that mistake.
3. **Reads are scoped.** `plan-shell-only.md:307-310` records that any caller can currently list every
   port in every space. A remote renderer is a remote reader, and this is a precondition of the whole
   phase, not of this feature.
4. **Ports declare something about themselves.** `port-shape.md` argues for a declared shape intent.
   Remote-renderability is the same kind of declaration and should ride the same mechanism rather than
   inventing a parallel one. If shape lands first, this is one more intent; if it does not, this
   feature has to build the declaration machinery alone.
5. **Someone has asked for a port whose code must not travel.** The three claims resolve to one real
   one: it works for surfaces that cannot replicate. That is a capability argument, not a secrecy
   argument, and the demand for it is a product question with no evidence in this document either way.
6. **Option 4 has been measured.** If an off-screen window does not render, the ceiling on this whole
   line of work is "all viewers see what the host sees, at the host's size, only while the host is
   looking at it", and the honest name for that is screen sharing of one tile. Knowing that costs one
   spike and changes what the feature can be promised to do.
