# PORT42 // SHELL — the GUI shell that replaces the desktop, not the OS

**Status:** **S1 + S2 shipped in-app** (2026-06-30, w/ gordon) on branch `shell-s1`, behind
`PORT42_SHELL`. The takeover (borderless kiosk fullscreen), the zoom spine (galaxy ↔ space ↔ focus),
the real shell desktop (Chrome + tiled ports + chat-as-tile + focus-dive), the prototype ambient
background + per-space accent themes all run on the real `AppState`/`PortWindowManager`. The kiosk
shell (`prototypes/p42shell`) remains the interaction reference; the production design is captured in
**`spec-shell-reimplementation.md`**. **Adoption is decided: the shell replaces the app surface for
everyone (Plan D, §8a)** — build behind `PORT42_SHELL`, then flip and delete `ContentView`. **Next:
S3** (movable tiles + park + tile↔floating + real arrange/exposé). See §8 for the shipped-vs-planned
deltas.

**One line:** Port42 boots into a fullscreen surface with **no macOS Dock and no menu bar**, and the
desktop is made of **live ports** floating over a living ambient background. macOS stays underneath as
the substrate; Port42 owns 100% of what the human sees and touches.

> **North star:** boot into Port42, not the Finder desktop. One ambient surface is the screensaver,
> the lock screen, the boot screen, and the desktop background — and the chrome (dock, launcher,
> ports) is *summoned on top of it*. Same registered port whether it's a tile on the wall or a
> floating panel.

---

## 1. The idea

A "computer," as the human experiences it, is mostly its **shell** — the desktop, the dock, the menu
bar, the launcher, the windows. The part nobody wants to rewrite — kernel, drivers, scheduler, power,
security, the display server — is the part you should be *grateful* the OS handles.

So don't replace the OS. **Replace the shell.** Own the desktop so completely that macOS disappears,
and let it keep doing the boring, hard, reliable work underneath.

This is the strong version of the Port42 wedge. Port42's primitive is the **port** (a live interactive
surface). A fullscreen wall of ports with no Dock and no menu bar *is a desktop environment*. The
shell isn't a side-quest — it's the port model with the chat surface swapped for a desktop.

Lineage of this exact move: ChromeOS, every airport/POS kiosk, the iPad home screen, in-car cockpit
UIs. Each is "an OS" to its user and a **shell on a boring substrate** to its builder.

---

## 2. Shell, not OS — the honest boundary

What a borderless fullscreen app **genuinely takes over**:

- The **entire screen** — a borderless window at `mainMenuWindow + 1` covering `NSScreen.frame`.
- The **Dock** and **menu bar** — hidden via `NSApp.presentationOptions = [.hideDock, .hideMenuBar]`.
- **Cmd-Tab / force-quit** — optionally killable via `.disableProcessSwitching` / `.disableForceQuit`.

What it has **not** replaced (and shouldn't want to):

- **`loginwindow`** is still the session's real shell and our parent. macOS doesn't let you swap the
  session shell the way Linux swaps a DE — we're its guest, drawn on top.
- **WindowServer** still owns the compositor, GPU surfaces, and input routing. Our fullscreen window
  is one of its clients; we don't get our own display server.
- **Kernel, drivers, power, networking, Secure Enclave, sandbox/TCC** — all still macOS.

**Ceiling to know:** can't intercept *everything* (power button, some firmware chords, recovery); GPU
compositing still goes through WindowServer; Apple can change `presentationOptions`/MDM behavior
between releases. For "boot into Port42 instead of Finder," none of that matters.

---

## 3. The ambient surface — screensaver = lock screen = desktop background (the spine)

The key synthesis (gordon, 2026-06-29): **the launcher's fullscreen background IS the screensaver.**
Port42 should not have a separate screensaver, lock screen, boot screen, and desktop wallpaper — it
has **one persistent ambient surface** at different *summon levels*. And the app **already renders
this surface** (`TransitionRoot.swift`).

**Three layers, one surface:**

```
Layer 0  AMBIENT   (always alive, never torn down)  = DreamscapeVideoLayer      ← the screensaver
Layer 1  TRANSITION (transient, crossing states)    = AquariumBreakout / dive   ← wake / sleep
Layer 2  CHROME+PORTS (summoned / dismissed)        = status bar · dock · ⌘K · wall of port tiles
```

**States are summon levels of the same surface, not different screens:**

| State | What's shown | Already in app? |
|---|---|---|
| **Idle / locked** | Layer 0 only — the living Dreamscape | ✅ `appState.showDreamscape` ("lock screen stays until unlock()") |
| **Waking / boot** | Layer 1 carries 0 → 2 (breakout/dive) | ✅ `AquariumBreakoutView`, `TransitionPhase {none, playingVideo, fadingOut}`, `diveProgress`, boot cinematic |
| **Active (desktop)** | Layer 2 composited over the *still-running* Layer 0 | ⚠️ partial — ports exist; "wall over the ambient background" is the new presentation |
| **Idle-out / lock** | reverse Layer 1 → back to Layer 0 | ✅ the unlock/lock path exists; needs an idle timer to drive it |

So **boot-into-Port42** means: the Mac boots to the **Dreamscape screensaver**, which **breaks out**
(transition you already built) into the **desktop of ports**; walk away and it settles back to the
Dreamscape. Screensaver, lock screen, boot surface, and desktop background are the **same one
surface**. Layer 0 and Layer 1 are **done**; the shell adds Layer 2's summonable chrome over them.

---

## 4. What ALREADY exists in the app (corrected — we have ~70% of the bones)

An earlier draft of this plan wrongly called the desktop/placement model "net-new." It is not. The
app already has a **per-space, persisted, dockable, positioned port window manager, and chat is
already a port** (`PortWindowManager.swift`):

| Capability | Where it lives today |
|---|---|
| Ports carry a **space** and a **position** | `PortPanel { spaceId, position: CGPoint? }` (`:8`) |
| **Ports swap when you switch spaces** | `switchToSpace(_:)` (`:713`) — hides old-space panels, shows `panels where spaceId == …` |
| **Dock / undock / move / resize**, each **persisted to DB** | `persistPanel` / `unpersistPanel` (`:216/:228`), move/resize observed + persisted (`:650`) |
| **Layout restored on launch** | "Restore persisted port panels from the database after app launch" (`:123`) |
| **Per-port placement exposed** | `allPorts()` returns `x`/`y` per port (`:517`) |
| **Chat is already a port** | `ensureChatPort` / `isChatPort` / `isBackground` (`:742`) — the conversation is a panel |
| **Adopting, reparenting webview host** (the Step 8 crux) | `PortWebViewHost: NSViewRepresentable` (`:966`) — `makeNSView` reparents, `updateNSView` no-ops, no destructive `dismantleNSView` |
| **The ambient surface (Layer 0/1)** | `TransitionRoot`, `DreamscapeVideoLayer`, `AquariumBreakoutView`, `showDreamscape` |
| **Create any port** | `port.create({type, html\|command, …})` — uniform primitive, Steps 1–7 done (`plan-uniform-port-create.md`) |
| **Drive / list ports** | `port.push`, `ports.list` (one verb each, type-dispatched) |
| **Launcher (⌘K)** | Quick Switcher already bound to ⌘K (`QuickSwitcher.swift`, `Port42App.swift` commands) |
| **The app already does window surgery at launch** | `AppDelegate.applicationDidFinishLaunching` grabs the main window, `setFrame(screen.visibleFrame)` (`Port42App.swift`) |

**What's genuinely different for the shell** (and what "probably not implemented well" means):

1. **Presentation substrate.** Today each port is its own **`NSPanel`** floating over / docked-to the
   main window — separate OS windows. The shell composites them as **tiles inside one fullscreen
   surface** over Layer 0. Same model (`PortPanel` + `position` + `spaceId`), different host —
   *re-present, not rebuild.*
2. **The takeover** — fullscreen + hide Dock/menu bar (the easy ~15 lines; extends the existing
   AppDelegate window-grab).
3. **Layer 2 over Layer 0** — chrome + port tiles composited over the *still-running* Dreamscape,
   summoned/dismissed by activity (idle timer drives the existing lock/unlock path).

So the shell is **mostly a new arrangement of an existing space-scoped, persisted, dockable port
window manager, hosted over an ambient surface the app already renders** — not a new window manager.

---

## 5. The prototype — the design, running

`prototypes/p42shell/` — the fullscreen GUI shell, no bundle, no signing
(`setActivationPolicy(.regular)` + `NSApplication.run()` + an `NSWindow` is all it takes to be a GUI
app). Dock + menu bar hidden; a desktop of live WKWebView ports (clock, animated canvas, fake system
monitor, typeable terminal), each draggable and closable; a Port42 dock; a ⌘K command palette; a boot
sequence; a synthwave `Canvas` background (a stand-in for `DreamscapeVideoLayer`). Escape hatches:
**Esc / ⌘Q / ⏻**, and `applicationWillTerminate` restores the Dock + menu bar. ~1320 lines, single
`main.swift`.

The one architectural bet it rests on — **a live WKWebView survives re-parenting between hosts with no
reload** — is settled: it ships in `PortWebViewHost` and is guarded by `ReParentStabilityTests`. So
`re-parent` (not overlay, not snapshot/restore) is the model the shell builds on.

---

## 6. Boot-into-Port42 — the four tiers

"Boot-into" does **not** replace the boot chain (firmware → kernel → launchd → loginwindow runs as
always). It means: **at the end of normal login, the first and only thing seen is Port42, not the
Finder desktop.** A spectrum:

- **Tier 0 — launch like an app (today).** Double-click; macOS desktop is home. With the shell flag,
  a fullscreen takeover you start manually.
- **Tier 1 — launch at login.** *Out of scope — not pursued.*
- **Tier 2 — single-app lockdown (kiosk-grade).** Enforced by an **MDM profile** with **Autonomous
  Single App Mode**: the Mac runs *only* Port42, no Cmd-Tab, no force-quit, no exit without the
  profile. Apple's *supported* appliance path. Requires MDM enrollment — **an app cannot self-enroll
  into this.**
- **Tier 3 — replace the login shell (not really possible on macOS).** macOS won't let you swap
  `loginwindow` / make Port42 *the* session shell. "Boot-into-Port42" tops out at "Finder is loaded
  but never seen," not "Finder is gone." Known ceiling.

**Lockdown-as-a-setting (gordon's instinct).** We can ship an **app-level "lockdown mode" toggle**
now — flip on `[.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
.disableSessionTermination]` + fullscreen. That's strong and real, app-level. The **unbreakable**
version (survives relaunch, literally cannot exit) is the **MDM profile** — a deployment artifact, not
app code. So: ship the toggle in-app (covers ~90% of "make this Mac an appliance"); the MDM profile
closes the last 10% for dedicated/deployed machines.

---

## 7. Architecture — reuse map (almost nothing new below the surface)

The shell is a **new top-level presentation** over the **existing** ambient surface + port machinery.

| Shell piece | Reuses (existing in `port42-native`) |
|---|---|
| Ambient background (screensaver/lock) | `DreamscapeVideoLayer`, `TransitionRoot`, `showDreamscape` — **Layer 0, done** |
| Wake / sleep transition | `AquariumBreakoutView`, `TransitionPhase`, `diveProgress` — **Layer 1, done** |
| Port tile / floating panel | `PortWindowManager.webViews[id]` + `PortWebViewHost` (`:1110`) — adopting reparenting host (no reload on re-parent) |
| Per-space desktop / swap on space change | `PortPanel { spaceId, position }` + `switchToSpace(_:)` (`:713`) |
| Layout persistence + restore | `persistPanel` / `unpersistPanel`, launch restore (`:123`) |
| Chat as a surface in the shell | `ensureChatPort` / `isChatPort` — chat is already a panel |
| Spawning a port | **`port.create`** (uniform primitive, Steps 1–7 done) — dock + ⌘K + companion call it |
| Driving / listing ports | `port.push`, `ports.list` |
| Terminal tiles | `port.create({type:"terminal"})` → `GhosttyTerminalView`, driven by `port.push` |
| Launcher | Quick Switcher (⌘K) already exists |
| Window surgery at launch | `AppDelegate.applicationDidFinishLaunching` already grabs + resizes the main window |
| Inline↔floating move, no reload | the **re-parent** transition from `plan-uniform-port-create.md` Step 8 (ships in `PortWebViewHost`) |

**New, and small:**
- A **`ShellWindow`** (borderless, `canBecomeKey = true`, fullscreen, kiosk `presentationOptions`)
  chosen at startup over the normal `WindowGroup` host when shell mode is on.
- A **`ShellView`** root: Layer 0 (Dreamscape) + Layer 2 (status bar + desktop tile layer + dock +
  ⌘K), instead of `ContentView`'s `NavigationSplitView`.
- A **shell-mode toggle** (`PORT42_SHELL=1` env / Settings switch) picking `ShellWindow` at startup.
- A **tile presentation** for `PortPanel` (`presentation: tile | floating`) — generalizes the
  `presentation` field Step 8 adds; `tile` composites the registry webview over Layer 0 instead of in
  an `NSPanel`.
- An **idle timer** driving Layer 2 dismiss → Layer 0 (reuses the existing lock/unlock path).

### 7a. The Chrome (Layer 2 top bar) — what moves up from the sidebar (gordon)

Today the **global app status + actions** live at the *top of the sidebar column*, not in a global
bar. In the shell they belong in the **Chrome** (the Layer-2 top status bar), and the **PORT42
logo/mark goes back top-left**. Two concrete facts make this clean:

- The status cluster is a **38pt header bar in `ContentView.swift` (`:185`)** with
  `.padding(.leading, 68)`. That 68pt left gap exists **only to clear the macOS traffic-light
  buttons**. A borderless `ShellWindow` has **no traffic lights**, so that gap is freed — **that is
  the home for the PORT42 mark, top-left.**
- These are plain SwiftUI items already bound to `appState` — moving them into the Chrome is a
  re-parent of views, not new behavior.

**Chrome layout (the menu-bar replacement):**

```
[ ◢ PORT42 mark ]            … (space / companion title, optional) …            [ status + actions ] [⏻]
  ^ freed 68pt gap                                                               ^ moved from ContentView/SidebarView
```

| Chrome slot | Moves from | Element |
|---|---|---|
| **Top-left mark** | (was lost) | **PORT42 logo/mark** — back in the freed traffic-light gap |
| Right cluster | `ContentView.swift:188–240` | user display name; **gateway** `bolt.fill`/`bolt.slash`; **tunnel** `globe` (when `publicURL`); **API key** `key.fill`; **AI pause** `pause.circle`; **token usage** `chart.bar`; **settings** `gearshape` → `SignOutSheet` |
| Global actions | `SidebarView.swift:73–95` | **New Space** (`number`), **New Companion** (`person.crop.circle.badge.plus`) — global create actions; can also live on the dock / ⌘K |
| Far-right | new | **⏻ exit** + live clock (shell-only) |

The sidebar's *conversation list* (spaces / companions / friends / background ports) stays as a
list — but it becomes one summonable port/panel in the shell (or a left rail), not the frame. Only the
**global status + actions** and the **mark** graduate into the Chrome.

---

## 8. Implementation path (incremental; each ships runnable)

> Order (re-sequenced w/ gordon — the SPINE comes first): takeover **+ the ambient surface** → **the
> spatial shell (zoom spine + port desktop + chrome)** → movable/park/float → companions + chat →
> idle-out + boot fusion. The ambient surface (Layer 0 = the living desktop) and the zoom spine are
> **foundational** — they frame every other surface and the whole first-run ("zoom out to swim in open
> water") rides on them, so the spine is built *first within* the spatial-shell phase, not retrofitted
> last. Lean on what already exists at every step.

### Phase S1 — Takeover + the ambient surface (Layer 0) — ✅ SHIPPED
> **As built (delta):** takeover is `ShellMode.applyTakeover(to:)` applied from `ShellView.onAppear`
> (the reliable site). The cheapest-cut resize wasn't enough — a `.titled` window's frame is clamped
> to leave the menu-bar strip (a black bar up top), so the window goes **borderless** + raised level
> (`mainMenuWindow+1`) to cover the full `screen.frame`. Flag: env `PORT42_SHELL` **or** the persisted
> `UserDefaults` key. Escape hatches: Esc (yields to focused text) / ⌘Q; `applicationWillTerminate`
> restores Dock + menu bar. Gate: `ShellModeTests` (flag parsing + headless fallback frame).

- `ShellWindow` (borderless, kiosk `presentationOptions`, key-capable) + escape hatches (Esc / ⌘Q /
  exit; restore Dock + menu bar on terminate). Extends the existing `applicationDidFinishLaunching`
  window code; default off.
- `ShellView` root = **`DreamscapeVideoLayer` (Layer 0) as the living desktop background** — the
  ambient surface is the spine from step one, not bolted on at the end (screensaver = lock = desktop,
  already unified in the app).
- **Cheapest first cut:** the flag takes today's window fullscreen + hides Dock/menu bar over the
  dreamscape. Proves takeover **and** the ambient background on the real app in ~an hour.
- **Ship:** `PORT42_SHELL=1 ./build.sh --run` boots fullscreen into the living ambient surface; without
  the flag, nothing changes.
- **Test gate:** *manual* — flag on boots fullscreen over the dreamscape; Esc / ⌘Q restore Dock + menu
  bar; relaunch without the flag is byte-identical to today. *Automated* — shell-mode flag selection
  picks `ShellWindow` vs `WindowGroup`; the `guard let screen = NSScreen.main` fallback frame holds when
  `main` is nil (headless, no display).

### Phase S2 — The spatial shell: spine + port desktop + Chrome — ✅ SHIPPED
> **As built (delta):** `ShellState` (zoom ladder, selection, pinch latch, per-space `accent`, mouse
> parallax) drives `ShellView`; galaxy/focus are **translucent `.zIndex` siblings over a still-mounted
> desktop** (mirrors the prototype — no unmount hack), so the desktop dims *behind* them. `createPort`
> gained `presentation: "inline"|"floating"|"tiled"` + `position` (replacing the dead `inline: Bool`);
> tiled ports register via `registerTiledPort`. **Chat is a desktop tile** (replaces the sidebar);
> `ContentView` is no longer used in shell mode. `PortWindowManager.createWindow` **no-ops in shell
> mode** so legacy ports never float as OS windows over the shell. Ambient background = the prototype's
> **Canvas dreamscape signed-in**; the **video** dreamscape is the screensaver (signed-out/locked only).
> Per-space **accent** = a 7-color palette by space position (the persisted `spaces.accent` column is
> deferred). Chat draft hoisted to `AppState.chatDrafts` (survives tile↔focus). Gates: `ShellStateTests`
> (zoom ladder) + `PortWindowLifecycleTests` (tiled createPort, per-space scoping).

*Build the spine FIRST within this phase (it frames the rest), then fill the space rung with the
desktop. Merged because the "space" and "focus" rungs are only demoable with content in them.*
- **Spine (build first):** the **zoom ladder** on `ShellState` — galaxy (all spaces) ↔ space ↔ focus,
  driven by ⌘↑/↓ + **pinch** (one rung per gesture) + hover-dive in galaxy. **Reuse the dive transition**
  (`TransitionRoot` / `diveProgress`) AS the zoom animation — the dive/water metaphor *is* the spatial
  model (focus = close · space = your room · galaxy = open water). This is what the first-run line
  **"zoom out to swim in open water"** (§8a) rides on. (Demoable immediately on the existing per-space
  chat port — galaxy → space → focus(chat) — before any other tile exists.)
- **Spaces:** galaxy renders `appState.spaces` as worlds; `switchToSpace` swaps the space; ⌘1…N jump.
- **Port desktop:** render the current space's **tiled `PortPanel`s** via
  `PortWebViewHost(webView: registry[id])` (adopt, don't recreate), positioned by `PortPanel.position`.
- **Chrome (§7a):** **PORT42 mark top-left** (in the freed traffic-light gap); re-parent the global
  status + action cluster + New-Space / New-Companion actions out of `ContentView.swift` /
  `SidebarView.swift` — view move, still bound to `appState`.
- Dock + ⌘K call `appState.createPort(...)` → **registered tiled ports** (real bridge/id, addressable
  by `port.push`/`ports.list`); auto-arrange. Lands `ShellState` DI + real content.
- **Ship:** pinch / ⌘ to move galaxy ↔ space ↔ focus over the ambient surface; spawn clock/terminal/web
  ports from the dock; drive a terminal tile with `port.push`; the desktop swaps per space.
- **Test gate:** `ShellStateTests` — the zoom ladder transitions galaxy ↔ space ↔ focus as pure state
  (one rung per step; ⌘1…N jumps space; bounds clamp at the ends). Extend `PortWindowLifecycleTests` —
  `createPort(presentation:"tiled", position:)` yields a tiled panel on the active space, and
  `switchToSpace` shows only the current space's tiled panels (hides the rest).

### Phase S3 — Movable tiles + park + tile ↔ floating (no reload) — ⬅ NEXT (current)
> **Carried over from S2:** tiles are currently locked to a render-time auto-grid, so the Chrome
> **arrange (⌘L) is ~a no-op and exposé (Tab) isn't built** — both need movable tiles first, so they
> belong here. Also lands the `z` field + persistence migration and the `ReParentStabilityTests`
> tiled/parked no-reload gate.

- Drag/resize tiles (persist on drag-end). The **right-edge parking dock** (drag-to-park +
  click-restore). "Pop out" re-parents the **same** webview into a floating `NSPanel` (Step 8);
  dock-back reverses; presentation flag flips; **no reload**. z-order on focus.
- **Ship:** a counter/terminal tile keeps state across tile → float → park → tile — live state, no reload.
- **Test gate:** `ReParentStabilityTests` — every presentation flip (`inline ↔ floating ↔ tiled ↔
  parked`) keeps the **same** `webViews[id]` instance (object identity preserved = no recreate = no
  reload — the registry-level proxy for the no-reload invariant, which a live surface confirms in-app).
  Persistence — `persistPanel` saves `tiled`/`parked`, still skips `inline`; `parked` ports are excluded
  from the desktop render and from `arrange`/`exposé`.

### Phase S4 — Companions + chat (the room)
- The per-space `isChatPort` tile with the **member header** (you + `getAgentsForSpace`) + live
  companion status. The **companion → `port.create` → arrange** loop: a chat message arranges the
  desktop.
- **Ship:** talk to your companion; tiles appear and the desktop arranges.
- **Test gate:** the member row composes you + `getAgentsForSpace(spaceId)` (and wraps, never
  h-scrolls); the send → companion → `port.create` → arrange loop lands a tiled panel on the active
  space. (The LLM step is stubbed/mocked; the arrange + member-row logic is asserted.)

### Phase S5 — Idle-out + boot fusion (the ambient loop closes)
- **Idle timer** dismisses Layer 2 → Layer 0 (dreamscape) via the existing lock path; activity summons
  it back through the breakout transition. **Fuse the onboarding BIOS boot with the shell boot** (§8a /
  D1) so it's one continuous sequence.
- **Tier 2 (optional)** MDM Autonomous Single App Mode for deployed kiosks; in-app lockdown toggle.
- **Ship:** a Mac that boots into the ambient surface and settles back to it when idle.
- **Test gate:** *automated* — an idle-timer fire drives the existing lock path (`showDreamscape ==
  true`) and shell-window input resets the timer + summons Layer 2 back. *Manual* — the idle-out / wake
  animation and the fused onboarding-BIOS → shell boot are a visual review.

---

## 8a. Adoption & first-run — the shell becomes THE app (Plan D, decided w/ gordon)

**Decision: the shell replaces the app surface for *everyone* — new and existing users. No
coexistence, no on-ramp for existing users, no backward-compat surface to maintain.** The shell is a
different top-level View over the *same* `AppState` / `PortWindowManager` / spaces / companions, so
"integration" is a surface swap, not a migration. End state: `ContentView` (the `NavigationSplitView`)
is **deleted**.

### Why first-run is already solved (we don't seed anything)

The existing onboarding already creates the new user's world AND is already shell-shaped. `SetupView`
runs phases `.boot` (a faked **BIOS POST terminal** — enter username + auth Claude) → `.transition` →
`.swim` (a chat with the **first companion**, Echo), then exits into the **general** space it created.
So a new user finishes onboarding already holding: the general space, a first companion, and a chat
with it. The shell's thesis ("a room with people + companions") is therefore true at t=0 with **zero
seeding** — the companion is in the chat's member row and the conversation is the anchor tile.

### First-run interaction — NO control tour; one poetic instruction (reuse existing language)

There is **no tutorial, no coach-marks, no companion-led tour.** The shell's one essential gesture
(zoom out) is taught by reframing language the product *already speaks*:

- `SetupView.swift:811` has a literal **"swim in open water"** button — today's graduation from the
  intimate first-companion *swim* (just you + Echo) out into the broader app. `echo-prompt.txt` already
  says: *"when they're ready, they can swim in open water … where channels, other companions, and
  humans are all swimming together."* The dive/water metaphor is fully wired (`diveProgress`
  0=surface→1=submerged, the dive transition in `TransitionRoot`, `diveIn`/`diveRequested`).
- **In the shell, the "swim in open water" BUTTON becomes the zoom-out GESTURE.** Dropped into your
  space focused on the chat = swimming close with your companion. The single first-run line, where the
  button used to be: **"zoom out to swim in open water."** Zoom out (pinch / ⌘↑) → the chat recedes,
  the space opens, and the **galaxy = open water** "where channels, other companions, and humans are
  all swimming together" (Echo's exact words). Shown once, on first landing; gone after.
- This maps the zoom ladder onto the dive metaphor exactly: **focus (close) ↔ space ↔ open water
  (galaxy).** The existing dive transition (`TransitionRoot`) can *be* the zoom-out animation.

### Visually fused boot — one continuous sequence, not two boots

Onboarding's `.boot` BIOS terminal and the shell's boot are the **same surface**. A new user's POST
terminal → auth → first-companion chat flows directly into the shell coming alive (Layer-1 breakout);
an existing user just gets the shell boot. No double-boot. The shell's Layer-1 breakout *is* the
onboarding boot surface.

**The concrete handoff (the mechanics #9):**

1. **Where it hands off.** Today `SetupView`'s `.swim` "swim in open water" button posts
   `.enterAquariumRequested` → the dive transition → `ContentView`. In shell mode the *same* signal
   (and `isSetupComplete`) lands in **`ShellView`**, in the **general** space, **zoomed to focus on the
   chat tile** (the first-companion chat is the anchor). The dive transition (`TransitionRoot` /
   `diveProgress`) *is* the zoom-in animation — no new code, a re-target of the destination.
2. **One `TransitionRoot`, no second boot.** `.boot` and `.transition` already render on
   `TransitionRoot` / `AquariumBreakoutView`; the shell's S1 boot is the *same* `TransitionRoot`. New
   user: `.boot → .transition(breakout) → .swim → ShellView` is one continuous run. Existing user
   (already `isSetupComplete`): launching shell mode plays that Layer-1 breakout straight into
   `ShellView`.
3. **The one-time hint.** A persisted flag (`UserDefaults`/DB `hasSeenShellSwimHint`). On the **first**
   landing in the shell focused on chat — where the button used to be — show the single caption
   **"zoom out to swim in open water."** Clear the flag on the first zoom-out (⌘↑ / pinch-out), or once
   shown. Applies to new **and** existing users' first shell launch.
4. **Button → gesture.** The `.swim` button is gone; **zoom-out is the graduation**: chat recedes →
   space → galaxy (open water). The dive metaphor maps onto the zoom ladder exactly — focus (close) ↔
   space ↔ galaxy (open water).

### Phasing (D0 → D2)

> The build (S1–S5 above) is unchanged — it's the *engineering* of the shell behind `PORT42_SHELL`.
> D0–D2 are the *adoption*: how it becomes the only surface. Per the build spec
> (`spec-shell-reimplementation.md`), each ships runnable behind the flag, default off until D2.

- **D0 — Build behind the flag.** `ShellView` over the real `AppState`, phases S1–S5. Flag off = today's
  app, untouched. Dogfood via a runtime toggle. No first-run impact yet.
- **D1 — First-run handoff.** Swap the post-setup surface from `ContentView` → `ShellView`: onboarding
  lands you in the shell's general space (companion in the member row, chat as the anchor tile);
  fuse the onboarding boot with the shell boot; replace the "swim in open water" button with the
  zoom-out gesture + the one-time "zoom out to swim in open water" line (gated on a one-time flag, for
  new AND existing users on their first shell launch). Still behind the flag.
- **D2 — Flip the default + delete the old surface.** `ShellView` becomes the root for everyone (swap
  at the `@main`/window level). Keep a hidden reverse fallback to `ContentView` for a release or two,
  then **delete `ContentView`** and the flag.

---

## 9. Relationship to existing plans

- **`plan-uniform-port-create.md`** — the shell is the *payoff* of that plan. `port.create` spawns
  ports; `port.push` drives them; `ports.list` enumerates the desktop; Step 8's "one port all the way
  down" + re-parent **is** the tile↔floating mechanic. The shell gives Step 8 a second, vivid host (a
  desktop) beyond the chat. This doc **consumes** that plan; it does not change it.

---

## 10. Risks / open questions

- **Multi-display** — `presentationOptions` hides the Dock globally; a tile desktop per `NSScreen` vs.
  one primary + secondaries is unspecified — single-display is the only case the prototype covers.
- **Tile substrate change** — moving ports from per-port `NSPanel`s to composited tiles over Layer 0
  is the main real work; needs care that drag/dock/persist (already wired for panels) carries over.
- **Focus / key handling** — borderless windows need `canBecomeKey`; global monitors (⌘K, Esc) coexist
  with port webviews wanting keystrokes. Tractable (the kiosk prototype handles it); needs care at scale.
- **System UI occlusion** — at high window levels, alerts / notification banners / volume HUD may be
  hidden; decide what surfaces through.
- **Recovery / trap-safety** — never ship lockdown without a documented exit + MDM escape; dev builds
  keep force-quit enabled.
- **Performance** — N live WKWebViews + the Dreamscape video + per-frame compositing; budget how many
  port tiles a desktop sustains.

---

## 11. The prototype (committed under `prototypes/`)

**`prototypes/p42shell/`** — the fullscreen GUI shell (rev 8), the live reference behind
`spec-shell-reimplementation.md`: the ambient surface with summoned chrome+ports, the zoom ladder, two
docks, and registry-owned webviews re-parented with **no reload** (tiled ↔ floating ↔ parked). Run:
`cd prototypes/p42shell && swift run p42shell` (Esc / ⌘Q / ⏻ to exit). ~1320 lines, single `main.swift`.

The prototype is disposable — the real work is Phases S1–S5 inside `Sources/Port42Lib`, reusing the
ambient surface (`TransitionRoot`/`DreamscapeVideoLayer`), the port window manager
(`PortWindowManager`), the bridge (`PortBridge`), and `port.create`.
