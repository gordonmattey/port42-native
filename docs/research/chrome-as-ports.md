# Research spike: the chrome is ports too

**Question.** `plan-shell-only.md:347` lists "The chrome is ports too" as a future roadmap item: the
background, app bar, dock and rail become ports you author, on the grounds that "once every scope is a
port, the shell's own parts are next."

**Date** 2026-09-26. **Base** `nautilus` at 0369388. Every claim below carries a file:line or a command
output. Where the answer is not in the tree, the line says "unknown" and what would settle it.

---

## Verdict

**One of the four pieces is already a port, and it is the only one whose contract a port can satisfy
today.** The background shipped as a port on 2026-07-17 (`ShellView.swift:70-83`,
`ShellState.swift:53-141`, `port.manage` action `background`, `BridgeMethods.swift:380-383`). Its
remaining defect is small and worth fixing on its own terms.

The other three are not blocked on authoring. They are blocked on three specific mechanisms that do
not exist:

| Piece | The blocker | Kind of blocker |
|---|---|---|
| Park rail | a tile drag is a SwiftUI `DragGesture` hit-tested against pure geometry (`ShellState.parkZone`, `ShellState.swift:965`). It is not an AppKit drag session, so it puts nothing on a pasteboard and no webview can be its drop target. | missing mechanism |
| Dock | 51 `@Published` properties across `ShellState` and `AppState` drive the chrome, and no event kind exists for any of them (`PortEventKind.swift:37-76`). A dock port would poll `ports.list`. | missing push channel |
| Chrome bar | any focused `WKWebView` is classified as an editor (`ShellView.swift:423`), so with the chrome focused every key except four chords is handed to the chrome instead of the shell. The chrome also holds the only route to Settings, sign-out and reset, and nothing in the tree recovers a crashed WebContent process. | input routing + no recovery |

**Recommendation.** Do not sequence this as "background, then dock, then rail, then bar," which is the
order `summer2026-todo.md:3782` proposes on privilege grounds. Privilege is not the binding constraint;
input routing is. Fix the background's visibility defect, then, if the roadmap item is taken up, do the
**rail** second and never do the **Chrome bar**. The argument is in §4.

---

## 1. What the chrome is today

All four pieces measured. "Reads" is the distinct `shell.*` / `appState.*` references in the piece's own
body, counted with `grep -o … | sort -u`.

| Piece | File:lines | Lines | Reads | Calls | Hosted in |
|---|---|---|---|---|---|
| **Chrome bar** | `Views/ShellDesktop.swift:13-129` | 117 | `shell.accent`, `shell.zoom`, `shell.showSettings`, `shell.hasBackgroundPort`, `appState.door.isConnected`, `appState.currentUser`, `appState.currentSpace` | `shell.zoomOut()`, `shell.bumpArrange()`, `shell.clearBackgroundToTile()`, `appState.lockApp()`, `appState.resetApp()`, `NSApp.terminate(nil)` | `VStack` above the desktop (`ShellView.swift:103`) |
| **Dock** | `Views/ShellDesktop.swift:1021-1138` | 118 | `shell.accent`, `appState.spaceCompanions`, `appState.currentSpace`, `ShellState.palette` | `shell.activateCompanion()`, `shell.bringToFront()`, `shell.showNewCompanion`, `shell.settingsTarget`, `portWindows.revealChat()`, `appState.spawnNativeTerminalPort()`, `portWindows.addTiledBrowserPanel()` | ZStack overlay in `ShellView.swift:109`, unmounted at `.focus` |
| **Park rail** | `Views/ShellDesktop.swift:812-884` | 73 | `shell.accent`, `shell.draggingOverPark`, `shell.openDMSpaceIds`, `appState.portWindows.panels`, `appState.currentSpace` | `portWindows.unpark()`, `shell.bringToFront()` | inside the desktop ZStack at `zIndex(10_000)` (`ShellDesktop.swift:226`) |
| **Background, ambient** | `Views/ShellBackground.swift:1-117` | 117 | `shell.accent`, `shell.mouse` | none | Layer 0 (`ShellView.swift:93`) |
| **Background, as a port** | `Views/ShellView.swift:1382-1416` + `Services/ShellState.swift:53-141` | 35 + 89 | none | `port.manage` `background` / `unbackground` | Layer 0 (`ShellView.swift:70-83`) |

**463 lines of chrome**, plus the galaxy (`ShellView.swift:442-730`, 289 lines), which is where spaces are
created, reordered and switched. The galaxy is not in the roadmap item's list but it holds the
space-switching that the Chrome bar's capsule only *toggles into* (`ShellDesktop.swift:24-37`).

Two structural facts that matter more than the line counts:

1. **The three interactive pieces live in three different hosting contexts.** The rail is inside the
   desktop's `coordinateSpace(name: "desktop")` (`ShellDesktop.swift:229`). The Chrome bar is in a
   `VStack` above it, so desktop `y = 0` is the first pixel under the Chrome
   (`design-shell-layout.md:26-28`). The dock is a sibling overlay in `ShellView`'s ZStack. A port host
   needs a rect, and only one of the three already has one in the coordinate space that tile drags read.

2. **`presentation` is a free-form `String` on `PortPanel`, not an enum.** The values in use are `tiled`,
   `parked`, `inline` and `background` (`grep 'presentation == "'` across `Sources`), and
   `setPresentation(id:to:)` (`PortWindowManager.swift:652`) accepts any string. So the slot mechanism a
   chrome port would need already exists, in its weakest form. Adding `chrome` / `dock` / `rail` slots
   costs a slot enum plus render sites, not a new subsystem.

---

## 2. What each piece needs that a port cannot do

A port is HTML in a `WKWebView` with the `window.port42` bridge, a generic Proxy over the registry
(`PortBridge.swift`). The registry holds **74 methods** (`grep -rhno 'r\["[A-Za-z0-9_.]*"\]'
Sources/Port42Lib/Services/*.swift | sort -u`, minus the field-name keys). Piece by piece, against that
list.

### 2.1 Background: satisfied, with one defect

| Need | Method | Status |
|---|---|---|
| render full-bleed behind everything | `port.manage` action `background` | exists, `BridgeMethods.swift:380-383` |
| return to the ambient dreamscape | `port.manage` action `unbackground` | exists, `:382-383` |
| survive restart | `UserDefaults` key `shell.backgroundPortId`, `restoreBackgroundPort()` | exists, `ShellState.swift:64`, `:115-123` |
| keep a running shader alive across the move | re-parent, no reload | exists, `ShellView.swift:71-74` |
| know whether to render | `presentation` + the `presentation` event | **broken, see below** |

**The defect.** `setBackgroundPort` writes `presentation = "background"` (`ShellState.swift:88`).
`desktopTilePanels` filters on `presentation == "tiled"` (`ShellState.swift:544`), so a background port is
absent from `contextItems` (`ShellState.swift:580-583`). `presentationSnapshot` therefore calls the pure
mapping with `item: nil` (`ShellState.swift:607-608`), which means `onDesktop: false`, which the mapping
answers with `.tiled, visible: false` (`PortPresentation.swift:97`).

So **the shell background port is told `{state:"tiled", visible:false}` while it is the only thing on
screen.** `PortPresentation.swift:13` defines `visible` as "the single authoritative *render your pixels
now* bool a port gates its rAF on", and `summer2026-todo.md:3793-3796` names idle-when-not-visible as
non-negotiable for chrome ports. A background port that obeys the contract renders nothing.

The same value drives two more gates: `isVisible` feeds the AI-suspend gate and the heartbeat skip
(`ShellState.swift:614-619`). A `.background` case exists in the state enum (`PortPresentation.swift:20`)
and is only ever produced from `PortPanel.isBackground` (`PortPresentation.swift:89`), which is a
**different flag** meaning docked/minimized (`PortWindowManager.swift:767`, and the comment at `:628` says
so explicitly). Two meanings of "background", one of them unreachable from the shell background.

Read, not measured live: what an actual background port does with the event. A one-line HTML port that
logs `port42.presentation()` and its `presentation` events would settle it.

### 2.2 Park rail: reading is covered, writing is not

| Need | Method | Status |
|---|---|---|
| list the parked ports for this space | `ports.list` returns `status: "parked"` and `spaceId` | exists, `BridgeMethods.swift:1453`, `:1467` |
| restore a chip to a tile | `port.manage` action `restore` / `undock` | exists, `:388-393` |
| raise the restored tile | `port.manage` action `focus` | exists, `:378-379` |
| the close zone | `port.close` | exists |
| **accept a tile dropped on it** | none | **missing** |
| **reorder chips, or accept a drop at an index** | none | **missing; the field does not exist either** |
| a chip's thumbnail or icon | `ports.list` returns no size, no `z`, no image | missing |
| know when the parked set changed | no event kind for it | missing |

**Drop is the hard one, and it is not a permission problem.** The tile drag is
`DragGesture(coordinateSpace: .named("desktop"))` (`ShellDesktop.swift:703`). On `.onEnded` the tile
classifies its own drop point with `ShellState.parkZone(at:in:)` (`ShellDesktop.swift:730-743`,
`ShellState.swift:965-968`), a pure function of the point and the desktop size. The rail view never
receives anything: it reads `shell.draggingOverPark` to draw a highlight (`ShellDesktop.swift:832-833`) and
that is its whole part in the interaction.

So the rail's drop behavior does not depend on the rail being a native view, which sounds like good news
and is not. It means the *geometry is in Swift*, and a port that authored its own rail would define its own
geometry, which Swift would have to be told. Two shapes for that: the rail port declares its drop regions
to the shell (a new method, and Swift keeps doing the hit-test), or the shell forwards pointer positions to
the rail port and asks it (a new event, a round trip per drag frame, and the rail port is then in the
drag's latency path).

Nothing in the tree drags a port. The only AppKit drag destinations registered are `.fileURL`
(`PortView.swift:29`, `GhosttyTerminalView.swift:519`) and `.plainText` for space reordering in the galaxy
(`ShellView.swift:626`, `:726`). A port receives drops as `port42:filedrop` (`PortBridge.swift:205`), file
paths only.

**Reordering does not exist to expose.** `railPanels` is a filter over `appState.portWindows.panels`
(`ShellDesktop.swift:822-827`), so chip order is panel creation/restore order. There is no park index
field. `plan-shell-only.md:240` states the product gap ("Parking places exactly… today it appends") and
confirms it is unbuilt.

### 2.3 Dock: the roster reads, the actions mostly do not

| Need | Method | Status |
|---|---|---|
| list this space's companions with names | `companions.list` | exists, `BridgeMethods.swift:1230` |
| spawn a terminal port | `port.create` `type:"terminal"` with `command`, `cwd`, `title` | exists, `:96-115` |
| spawn a browser port | `port.create` `type:"browser"` with `url` | exists |
| reveal this space's chat | `port.create` `type:"chat"` (idempotent) | exists, `:97` |
| **open a companion's 1:1 as a tile** | none. `shell.activateCompanion` (`ShellState.swift:980`) either reveals the companion's terminal or pushes the DM space id into `openDMSpaceIds` | **missing** |
| **create a companion** | none. `companions.list` and `companions.get` are read-only | **missing** |
| **open a companion's settings card** | none (`shell.settingsTarget`) | missing |
| know when a companion was added, or a port was born | no event kind; `port.subscribe` requires a port id and resolves `PortNotify.topic(forPortKey:)` (`BridgeMethods.swift:61-65`) | **missing** |

The last row is the dock's real cost. `bus.read` is pull-only over recent messages
(`BridgeMethods.swift:1288`) and is backed by the `messages` table that Phase 1 drops
(`plan-shell-only.md:175`). `port.push` (`BridgeMethods.swift:181`) gives Swift a generic channel *into* a
web port as a `port42:data` event, so the shell could feed a dock port. Nothing does, and no shape for it
is declared anywhere.

Absent that, a dock port polls `ports.list` and `companions.list`. That is a timer in a webview whose
whole job is to be always on screen, which is the cost profile §3.4 is about.

### 2.4 Chrome bar: the least covered of the four

| Need | Method | Status |
|---|---|---|
| the current space's name | `space.current` | exists, `BridgeMethods.swift:1157` |
| the user's display name | `user.get` | exists, `:1151` |
| clear the background | `port.manage` `unbackground` | exists |
| switch to a space | `space.switchTo` (`toolExposed: false`) | exists, `:1185` |
| **toggle the galaxy / move the zoom rung** | none (`shell.zoom`, `shell.zoomOut()`) | **missing** |
| **⌘L arrange** | none (`shell.bumpArrange`) | **missing** |
| **gateway connected** | none (`appState.door.isConnected`) | **missing** |
| **open Settings** | none (`shell.showSettings`) | **missing** |
| **sign out / power down / reset** | none (`appState.lockApp`, `NSApp.terminate`, `appState.resetApp`) | **missing** |

Five of nine, and the five include every destructive action in the app. A registry method that erases all
data, reachable from a webview, is a different security question from a method that lists ports. The
north-star note anticipated this ("a port granted *may switch spaces* is a different principal from a
shader", `summer2026-todo.md:3785-3787`), and the grant model has the slot for it (§6). The point here is
narrower: those methods do not exist, and three of them should not be added merely to let a port draw the
bar they sit on.

---

## 3. What breaks when chrome is a webview

### 3.1 Keyboard focus, the load-bearing failure

`responderIsEditor` returns `true` for any `WKWebView`, any responder whose type name contains `WKWeb` or
`WKContent`, and any `NSView` nested inside a `WKWebView` (`ShellView.swift:422-434`). `shouldYieldKey`
returns `isEditor` for every key code except Esc (`ShellState.swift:904-908`). The monitor at
`ShellView.swift:366-407` runs in this order:

1. `shellGlobalChord`, matching ⌘K, ⌘\`, ⇧⌘\`, ⌘1…9, ⌘L. Consumed before the yield check, so these four survive a
   focused webview (`ShellView.swift:369-383`).
2. `shouldYieldKey`. If the responder is a webview, **return the event to it** (`:385-388`).
3. Tab (exposé), Esc (peel the ladder), ⌘↑ / ⌘↓ (`:390-406`). All three sit *after* the yield.

So a focused chrome webview takes Tab, ⌘↑ and ⌘↓. This is already true of every web port, and it is
tolerable there because a web port is a thing you deliberately click into. The Chrome bar is the thing you
click to navigate, so the zoom ladder would stop working as a side effect of using the chrome, until the
user clicked something else. Esc survives only because `shouldYieldKey` special-cases key code 53.

**SwiftUI's hit-testing does not contain a hosted webview.** The click-shield at `ShellView.swift:121-127`
exists for exactly this: "SwiftUI's `allowsHitTesting` doesn't stop the embedded chat WKWebView from
getting AppKit clicks; this real layer does." Any chrome port would need real AppKit shielding at every rung
where the chrome should be inert, not a declarative modifier.

**This is already live on the shipped piece.** The Layer-0 background port is mounted interactive by design
("only the empty gaps fall through", `ShellView.swift:74-76`) and `FileDropWebView` returns
`acceptsFirstMouse == true` (`PortWindowManager.swift:1717`). Unknown, and cheap to settle: whether a click
on a gap in the desktop gives the background port first responder and so breaks ⌘↑ until the next click
elsewhere. One click on a background port and one ⌘↑ answers it.

### 3.2 Drag and drop between a port and the chrome

Covered in §2.2. The summary: there is no drag session, so there is nothing for a webview to be a drop
target of. Building one means either a declared-regions method or a per-frame pointer event, and the second
puts a webview in the drag's latency path.

### 3.3 Hover

**Unknown.** Nothing in the tree measures pointer-event latency into a webview. Two adjacent facts:

- The shell installs a `.mouseMoved` local monitor that does not consume, purely to drive background
  parallax (`ShellView.swift:355-362`). So the main thread already sees every move event; a chrome port
  would add an IPC hop on top of that for its own hover.
- SwiftUI `.help()` silently fails in this window ("borderless/hiddenTitleBar", `ShellShared.swift:68-70`)
  and the Chrome bar relies on an AppKit `NSView.toolTip` workaround. A chrome port would use browser
  `title` attributes instead, which is not worse, but it is a reminder that this window's AppKit behavior is
  already non-standard.

What would settle it: a port with a CSS `:hover` rule and a `mousemove` handler that timestamps against
`performance.now()`, compared against a SwiftUI `onHover` on the same rect. The shell already has a
hover-to-front behavior on tiles to compare against.

### 3.4 Idle CPU

This is the best-measured area in the tree, and it cuts both ways.

The ambient background was the whole idle burn (`summer2026-todo.md:491-588`). Controlled A/B on Dev3, same
data, same build, `PORT42_NO_SHELL_BG`:

| | background ON | background OFF |
|---|---|---|
| idle CPU, 5s delta | 29-30% | **0.4%** |
| main-thread runloop activities / 250ms | 200-360 | **1-11** |

The cadence sweep that followed (`ShellBackground.swift:32-48`): uncapped 27.4%, 30fps 12.3%, **24fps
9.6%**, 12fps 9.8%. An *empty* `Canvas` inside `TimelineView(.animation)` still cost 14.3% of a core, so
per-frame framework overhead sets a floor. 24 is the shipped default.

**Two things follow.**

First, **a webview background could be cheaper than the Canvas it replaces**, not more expensive. The
Canvas costs 9.6% at 24fps with no way under 14.3% uncapped, on the main thread, where it ate the frame
budget a wheel scroll needed (`CanvasDisplayList` 8327 main-thread samples against ~2700 for the entire
conversation layout, `summer2026-todo.md:595-598`). A `WKWebView` renders in its own process. A static
background port would cost approximately nothing on the main thread. That is the strongest measured argument
for the piece that already shipped.

Second, **the frame cap landed and the occlusion pause did not.** `grep -rn "occlusionState\|paused:"
Sources` returns nothing, which confirms `plan-shell-only.md:241` ("pausing it while covered is
unverified"). So the shell has no mechanism for "stop drawing, you cannot be seen" other than the
`presentation` event, and §2.1 shows that event is wrong for the background.

**Eviction does not exist.** `grep -rn "evict" Sources` returns nothing.
`plan-webview-eviction.md:1-7` measured **88 WebContent processes at 101 ports, ~90% idle CPU**, and states
that `webViews` is created eagerly at birth and removed only on close. Chrome ports are "always visible and
never closed" (`summer2026-todo.md:3793`), so they are never eviction candidates anyway, but each one is a
permanent WebContent process on an app that already has no cap. Live, read-only: `ps` puts the production
instance's main process at 9.1-19.3% across three samples with 64 WebContent processes on the machine. The
instance is in use, so that is corroboration of the order of magnitude, not a measurement.

### 3.5 A chrome port crashes, or is edited badly

**No recovery exists.** `grep -rn "ContentProcessDidTerminate" Sources` returns nothing. The two
navigation-failure delegates that do exist (`PortWindowManager.swift:1578`, `:1581`) handle navigation, not
process death. When a port's WebContent process dies the view goes blank and stays blank.

For a tile that is an annoyance. For the Chrome bar it is the loss of the only route to Settings, sign out,
power down and reset (`ShellDesktop.swift:64-75`, `:53`). ⌘K still works (§3.1 item 1), so a user could
reach a space, but not Settings.

**A bad edit is recoverable, out of band.** `port.history` and `port.restore` exist
(`BridgeMethods.swift:1502`, `:1571`), and every port carries a version history, over-carries it, since
`savePortVersion` was writing a full HTML copy per click until the dedupe fix
(`design-shell-layout.md:91-117`, `:189-191`). So a chrome port broken by an edit rolls back via a curl
call. That is a real mitigation and it is worth being precise about its shape: the recovery path is the CLI,
not the UI, which is fine for a background and not fine for the bar that holds the UI.

**Nothing detects a port that rendered nothing.** `PortRenderProbe` checks the three conditions that make
blanking impossible (one `makeNSView` per lifetime, never windowless, never orphaned,
`PortRenderProbe.swift:5-9`) and is `#if DEBUG`, harness-driven, off in production (`:23`, `:31`).

---

## 4. Is there a safe subset?

**Yes, and it is narrower than the privilege ordering suggests.**

`summer2026-todo.md:3782-3783` orders the work by privilege: background (no powers) → dock (space switch +
port launch) → space rail (space list + selection) → top app bar (gateway/tunnel/settings state). That
ordering is sound about privilege and wrong about difficulty, because privilege is not what binds. Every
method the dock and rail need either exists already (§2.2 and §2.3 name eleven that do) or is a small
addition. What binds is input: the rail needs a drop mechanism that does not exist in any form, and the bar
needs keyboard focus semantics that the current monitor actively contradicts.

**First: nothing new. Fix the background's `visible`.** It is the piece that shipped, it is the piece the
whole item is a generalization of, and it is currently lying to its port about the one bool the contract
says to gate on. The fix is a case in the pure mapping (`PortPresentation.swift:89-97`) plus the test beside
the five that already cover the other states (`PortPresentationTests.swift:29-95`). It also settles which of
the two "background" meanings owns the word.

**Second, if the item is taken up: the rail.** Not because it is easy, but because its missing mechanism is
worth building for its own sake. `plan-shell-only.md:240` already owes Phase 2 "parking places exactly", and
there is no park index field to place into. Building park-with-an-index means deciding how a drop names a
target, which is the same decision a rail port needs. One mechanism, two payoffs, and the failure mode is
bounded: a broken rail port costs the ability to park, and parking has a keyboard-free alternative in
`port.manage`.

**Third, and only third: the dock.** Its blocker is a push channel for shell state, which is a larger piece
of design than it looks (51 `@Published` properties, no event kind for any of them) and which the pipe work
in Phase 3 may reshape. A dock port on polling is a timer in an always-visible webview on an app with no
eviction. The dock's actions are the best-covered of the three, which is why it reads as the easy one and is
not.

**Never: the Chrome bar.** Three independent reasons, each measured.

1. **It is the recovery surface.** Sign out, power down, reset and Settings are reachable only from it
   (`ShellDesktop.swift:53`, `:64-75`). A surface with no recovery path (§3.5) must not be the only route to
   the app's recovery actions. Any design that keeps a native fallback for exactly those controls has not
   made the bar a port; it has added a port beside the bar.
2. **It fights the keyboard.** §3.1. The bar is the surface a user clicks *in order to navigate*, so giving
   it first-responder status breaks Tab, ⌘↑ and ⌘↓ precisely during navigation.
3. **It needs the app's destructive verbs in the registry.** Erase-all-data as a bridge method, so that a
   port can draw the button, is a poor trade. The capability-scoping work would make it *safe*; it would not
   make it *worth it*.

A middle position exists and is worth naming rather than pursuing: leave the bar native and let a port occupy
a declared region *within* it, the way Layer 0 is a declared slot. That keeps the recovery controls native and
gives the authoring win on the part people would actually customize. It is a different feature from "the app
bar is a port", and it should be costed as one.

---

## 5. What does it unlock?

The plan's claim is that this follows from "every scope is a port" (`plan-shell-only.md:45-69`, `:347`).
Tested against the code, **it does not follow, and the two claims are about different layers.**

"Every scope is a port" is a claim about *addressing and grants*: a chat lives at a scope, a companion
subscribes to a port, a grant keys on a port object. `plan-shell-only.md:66-68` says what it unifies, and
every item is an addressing or subscription concern ("grants already key on a port object", "addresses
already name ports", "subscription already fans out"). None of those change if the dock is drawn by SwiftUI.
Conversely, the background became a port without any of the scope work: it is a rendering slot plus a
`UserDefaults` key plus a `presentation` string.

So the honest reading is that the two are **independent**. The scope work makes chrome-as-ports *coherent*
(a dock port is addressable and grantable like anything else, for free). It does not make it *easier*, and
nothing in the scope work is blocked on it.

**What is genuinely unlocked, on the evidence:**

- **The background genuinely benefits, on CPU grounds.** §3.4. Replacing a 9.6%-of-a-core main-thread Canvas
  with an out-of-process webview is a measured win, and it is the one place where "it should be a port" and
  "it should be cheaper" agree. The v2 direction in `summer2026-todo.md:3762-3766` (the dreamscape becomes a
  stock ambient *port*, so there is one code path and no native/port fork) is the version of this item that
  pays for itself.
- **Customization of the dock and rail, which subsumes backlog items.** `summer2026-todo.md:3748-3751`
  claims it subsumes "richer space rows", "a different dock view" and ambient activity. That claim holds:
  those are all "draw this list differently", and a port drawing a list is the cheapest possible answer to
  them.
- **The universality argument.** `summer2026-todo.md:3741-3745` treats it as proof that the port primitive
  is universal. That is a real argument, and it is weaker than it reads, because `summer2026-todo.md:3788-3791`
  already concedes the limit: something native must host the first port. With a native kernel hosting native
  slots, "the chrome is ports" proves that the shell's *lists and decorations* can be ports. It does not
  prove there is no privileged app-UI category, because the category is still there, occupied by the host and
  by whatever draws the recovery controls.

**What is not unlocked, despite reading like it is:**

- **Nothing in the five scenarios.** `plan-shell-only.md:16-24` is the spec, and no scenario mentions the
  chrome. Scenario 5 is arranging, which is about where tiles go, not what draws the rail.
- **No new capability for a port.** A dock port can do nothing a desktop port cannot; it is drawn in a
  different rectangle. The capabilities in §2 that do not exist would be added *for* the chrome port, and
  once added, every port has them.
- **No simplification of the shell.** The 463 lines in §1 do not go away. They become a host, a slot enum, a
  set of declared regions, a push channel, and a native fallback for each slot that can fail. Whether that is
  more or less code than 463 lines is unknown, and the honest prior is "more".

---

## 6. Port 0 and the rendering layer

The brief notes that port 0 is the desktop in the grant model, so part of this is already true in the
permission layer. Precisely what that does and does not imply:

**What it means.** `PortObject.swift:8-11` states it: "THE DESKTOP IS A PORT. PORT 0. Clipboard,
filesystem, automation, notify, rest, screen and camera are not portless capabilities sitting outside the
model; they are port 0's, port 0 being the Port42 window itself." Grants therefore key on
`caller -> port -> action -> permission` with no exceptions (`:10-11`), and the measurement that settled it
is at `:13-22`: the old key was `<grantee> x <space>` with the object implicit, and all 144 production
grants turned out to be port 0 capabilities.

**What it implies for the rendering layer: nothing directly, and the file says so.** Two lines matter.

- `PortObject.swift:95` says "Port 0 is the app itself, and its name is the app's name", and then, in the
  same sentence, **"which is why port 0 is not called 'desktop' or anything else invented"**.
  `objectLabel("0")` returns `"Port42"` (`:96-97`). So
  in the code, port 0 is the *application*, not the desktop surface. The plan's phrasing ("The desktop is
  port 0", `plan-shell-only.md:47`) and the code's phrasing name the same object with different words, and
  the code's is the narrower one.
- `PortObject.swift:24-29`: "No production path can name an object other than port 0 today, because every
  `PortPermission` case is a machine capability. The slot is built now because Part 0's OBJECT row is a
  seam… The tests therefore exercise a non-zero object deliberately, since production cannot."

So the permission layer has a *slot* for "this grant is about that port" and production never fills it with
anything but port 0. What that gives chrome-as-ports is real but modest: when a dock port needs "may switch
spaces" as a capability distinct from a shader's, the grant key already has a place to say which object and
which actor, and adding the capability is a `PortPermission` case rather than a schema change. That is the
thing `summer2026-todo.md:3784-3787` calls "the same spine", and it is correct.

What it does not give: a rect, a mount, a slot in the view tree, an input route, or a visibility signal.
Those are the four things §1 through §3 are about, and the grant model touches none of them. The permission
layer being ready is a reason the *privilege* ordering in the north-star note looked like the hard part. §4
argues it is not.

---

## 7. Unknowns, and what would settle each

| Unknown | What settles it |
|---|---|
| What a live background port actually does with `{visible:false}` | a port whose HTML logs `port42.presentation()` and every `presentation` event, set as the background, read from `port.console` |
| Whether clicking a gap in the desktop gives the background port first responder, breaking ⌘↑ | one click on a visible gap, then ⌘↑, on Dev3 |
| Pointer/hover latency into a webview versus SwiftUI `onHover` | a port timestamping `mousemove` against `performance.now()`, same rect, both paths |
| Whether an idle static webview costs less than the 9.6% Canvas | `PORT42_NO_SHELL_BG` plus a static HTML background port, same 5s CPU delta protocol as `summer2026-todo.md:581` |
| Whether the version-history rollback path is usable as chrome recovery | break a background port's HTML deliberately, recover with `port.history` + `port.restore`, with the app still running |
| Whether 463 lines of native chrome becomes more or less code as ports | not answerable before one non-background slot is built |
