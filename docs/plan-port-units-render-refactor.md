# Plan: Port Units — resize, don't reparent

Fix the shell's shared-webview rendering so tiles, peeks, and focus stop blanking. The
root cause is architectural; this replaces reparenting with a single persistent,
absolutely-positioned per-port unit whose geometry is state-driven.

Status: **spike PASSED — cleared to build Phase 0.**

**Spike result (I1 + I2 validated).** A throwaway floating panel
(`PortResizeSpike.swift`, Debug menu → "Port Resize Spike") hosts one persistent
`SpikeWebHost(WKWebView)` and animates its `.frame`/`.position`/`.zIndex` mini↔fullscreen
10×, plus a chrome swap. Log (`/tmp/spike.log`) per launch: `MAKE #1` exactly **once**
(I2 — SwiftUI reused the single NSView across all geometry + chrome changes),
`superIsContainer=true` throughout (never orphaned), `window=Y` during cycling, and the
in-page JS counter kept ticking crisp with no blank (I1). `CYCLE DONE — PASS`. The
refactor's core bet holds.

---

## 1. The bug this fixes

- **Peek preview goes grey on the 2nd+ preview** (reproducible: preview ONE → zoom out →
  preview TWO → zoom out → TWO is grey; also preview ONE → out → ONE again → out → grey).
- Latent: **desktop-tile focus** has the same fragility (reparent tile→focus→tile).
- Confirmed by instrumentation: the webview is re-attached to the correct, in-window
  container, but its pixels are gone.

## 2. Systems analysis (why it happens)

### Components in scope

| Component | Kind | Role | Real / abstraction |
|---|---|---|---|
| `FileDropWebView` (WKWebView) | AppKit view | The live web content, one per port. Loads HTML once (no-reload guarantee). | **Real, singleton, persistent** |
| `webViews[id]` in `PortWindowManager` | dict | Strong owner; `hostView(for:)` hands it out. | Real (source of truth for the view) |
| `PortWebViewContainer` | AppKit view | Wrapper created **fresh in every `makeNSView`**; first-responder + JS resize. | **Real, transient (per mount)** |
| `ShellPortHost` | `NSViewRepresentable` | The SwiftUI↔AppKit seam: `make` reparents the shared view, `update` is a no-op. | **Abstraction** |
| `ShellTile` / `ShellPeekTile` / `ShellFocusContent` | SwiftUI | **Three independent mount points**, each wrapping the *same* `webViews[id]`. | Abstraction |
| `ShellState` (`zoom`, `peekingPorts`, `tiledPanels`) | `@Published` | Decides which of the three mounts exist. | Abstraction (layout source of truth) |
| SwiftUI diffing / view identity | framework | Decides `make` vs `update` vs `dismantle`. | Abstraction (**non-deterministic**) |

### Dependency map

```
ShellState.zoom / peekingPorts / tiledPanels
        │ (drives which mounts render)
        ▼
ShellTile ─┐   ShellPeekTile ─┐   ShellFocusContent ─┐
           └──────────────────┴───────────────────────┘
                        each constructs
                              ▼
              ShellPortHost(view: hostView(for:id))
                              │ make/update
                              ▼
                 PortWebViewContainer (fresh per make)
                              │ addSubview
                              ▼
                webViews[id]  ◄─ the ONE shared WKWebView ─►  must stay in a window
```

Three mount points → one shared real view. `ShellPortHost` is a many-to-one abstraction
over a resource that can physically be in exactly one place.

### Sequencing — a peek preview

```
t0  peek mounts     → make → webview into miniContainer, IN WINDOW ✓
t1  previewPeek     → peek removed + zoom=.focus (same tick)
t2  focus mounts    → make → webview into focusContainer, IN WINDOW ✓
t3  zoom out        → settleAfterPreview re-adds peek; focus unmounts
t4  focus discarded → webview.superview = nil → WINDOWLESS  ← blank happens here
t5  peek re-mounts  → SwiftUI decides make (works) OR update (no-op → stays blank)  ← non-deterministic
```

Two independent failures: the **windowless gap (t4)** and the **non-deterministic
reparent (t5)**.

### Abstractions vs. real — the impedance mismatch

Two contracts collide:

- **`NSViewRepresentable`:** one representable owns one view; SwiftUI controls its
  lifecycle by diffing, reuse guaranteed in *neither* direction. We violate "owns one
  view" by sharing one webview across three representables and reparenting by hand.
- **`WKWebView`:** must stay in a window continuously; when detached it **discards its
  rendered surface**, and re-attaching does not repaint (GPU-composited via a separate
  content process — `isHidden`/`setNeedsDisplay` nudges proved ineffective).

SwiftUI's non-deterministic reparent inherently detaches the WKWebView for a beat, which
inherently violates the WKWebView contract. No make/update tuning removes the gap,
because SwiftUI discards the old container *while the view is still inside it*, on its
own schedule.

### Root cause

Architectural, not a single-function bug: the shell renders one shared, window-anchored
`WKWebView` through three interchangeable SwiftUI mount points and moves it between them
by imperative reparenting. SwiftUI's lifecycle (a) reparents non-deterministically and
(b) discards the previous container with the view still inside — momentarily removing the
webview from the window, which permanently blanks its surface.

### Why a port can only be in one place

The live thing *is* one `NSView`, and in AppKit an `NSView` has exactly one `superview`.
The singleton is deliberate (no-reload). So "one place" is a hard fact for the live view;
the defect is that we keep **moving** it. **Fix: one permanent home in the window, moved
by frame, never by superview.**

## 3. Target design — Port Units

### The facade — `PortManager` (the one top-level interface)

Consumers — `ShellDesktop`, Chrome, dock, notifications/peeks, the `port.create` API, companions —
hold **no** port state and never reach past this facade. Lifecycle, which-space, presentation-state,
geometry, persistence, and the live-view registry are all sealed behind it. A caller says *open /
present / move* and never touches a webview, a reparent, or a rect.

```swift
@MainActor final class PortManager: ObservableObject {
    @Published private(set) var ports: [Port]              // single source of truth

    // ── lifecycle ──
    func open(_ spec: PortSpec, in space: SpaceID) -> PortID
    func close(_ id: PortID)
    func move(_ id: PortID, to space: SpaceID)             // re-home a port; its state is unchanged

    // ── state (presentation) ──
    func present(_ id: PortID, as state: Presentation)     // the ONLY state mutator
    func bringToFront(_ id: PortID)
    func setFrame(_ id: PortID, _ rect: CGRect)            // drag / resize commit

    // ── layout & queries ──
    func arrange(_ space: SpaceID)
    func ports(in space: SpaceID) -> [Port]
    func port(_ id: PortID) -> Port?
}

struct Port: Identifiable {
    let id: PortID
    var space: SpaceID                                     // which space owns it
    let kind: Kind             // .web · .terminal · .browser · .chat
    var state: Presentation    // .tiled · .peek(Int) · .focus · .parked · .hidden
    var frame: CGRect; var z: Int                          // committed geometry
}
enum Presentation { case tiled, peek(Int), focus, parked, hidden }
```

Behind the facade sit three sealed collaborators: the pure **`placement()`** (state → geometry,
below), the **registry** of one live `NSView` per port (`hostView(for:)`), and the **store**
(`port_panels` persistence). Everything after this subsection is the *rendering half* — how
`PortManager.ports` becomes pixels via `PortUnit` + `placement`, with no reparenting.

> **Migration note.** `PortManager` is the consolidation target: today's scattered verbs —
> `registerTiledPort` / `popOut` / `dock` / `park` / `switchToSpace` / `previewPeek` /
> `surfaceSpaceChat` / `applyArrange` and the raw presentation flags — all fold into
> `open`/`present`/`move`/`arrange`. It can start as a **thin facade over the existing
> `PortWindowManager` + `ShellState`** and absorb their logic phase by phase, so no phase is a
> big-bang rewrite.

### Principle

Every port's live view is mounted **once**, in a persistent, absolutely-positioned
per-port container. Tile / peek / focus stop being separate mounts and become **geometry
states** of that one container. Zoom animates `frame`/`position`/`zIndex`; the webview
never leaves the window → never blanks, and there is no make/update handoff.

### Shape

```
ShellDesktopView
 └─ ZStack
     ├─ focus backdrop (dim; visible only when a unit is focused)     zIndex 11_900
     └─ ForEach(portsInContext) { panel in
            PortUnit(panel)                       ← ONE persistent view per port
              .frame(placement.rect.size)         ← tile size | peek size | focus size
              .position(placement.rect.center)    ← grid slot | rail slot | screen center
              .zIndex(placement.z)
              .id(panel.id)                        ← identity keyed ONLY on port id
            // PortUnit internally:
            //   chrome(for: placement.chrome)      (SwiftUI; may swap freely)
            //   ShellPortHost(hostView(panel.id))  ← mounted ONCE; only its frame changes
        }
```

`portsInContext = tiledPanels ∪ peekingPorts` (deduped). One `ShellPortHost` per port,
structurally stable across state changes ⇒ SwiftUI keeps the same `NSView`, only
re-lays-out its frame. No `make` churn, no reparent.

### The core new abstraction — placement is a pure function

```swift
struct PortPlacement { var rect: CGRect; var corner: CGFloat; var z: Double; var chrome: Chrome; var visible: Bool }
func placement(for panel: PortPanel, zoom: Zoom, tiled: Bool, peeking: Bool, area: CGSize) -> PortPlacement
```

- **focused** (`zoom == .focus(panel.id)`) → `rect = focusRect(area)` (current 0.78×0.8
  centered card), `chrome = .focus`, `z = 12_000`.
- **peeking** → `rect = railSlot(index, area)` (210-wide, stacked from top-left; replaces
  the rail `VStack`), `chrome = .peek`, `z = 10_000 + index`.
- **tiled** → `rect = resolvedPortFrame(panel, area)` (reuse existing), `chrome = .tile`,
  `z = panel.z`.
- **not in context** → `visible = false`.

## 4. Component changes

| Component | Change |
|---|---|
| `ShellDesktopView` | Add the persistent `ForEach(portsInContext) { PortUnit }` layer + focus backdrop. |
| **new** `PortUnit` | Persistent per-port view: state-driven chrome + one `ShellPortHost`, absolutely framed/positioned. |
| `ShellTile` | Folds into `PortUnit`'s `.tile` chrome (border, header, dot, move/resize/close). Its `ShellPortHost` moves into `PortUnit`. |
| `ShellPeekTile` | Folds into `.peek` chrome (mini header, countdown ring, ✕). **Remove the rail `VStack`** — peeks are absolutely positioned by `railSlot`. |
| `ShellFocusContent` | **Delete the webview mount.** Focus = the `.focus` chrome (header + backdrop) of the unit already on screen. |
| `ShellState` | `previewPeek` just sets `zoom = .focus(id)` (no remove/stash/reparent). `settleAfterPreview` only does seen/countdown bookkeeping. **Delete `pendingPreviewPeek`** and the reparent dance. `keepPeek`/countdown/dismiss unchanged. |
| `ShellPortHost` | Struct unchanged, but mounted once per port. `updateNSView` no-op is correct again (nothing competes). |

### Special cases (must keep working)

- **Terminals** (`GhosttyInputView` in `terminalViews[id]`): same treatment — one
  persistent host per terminal unit. Validate resize-in-place (invariant I6).
- **Browser tiles** (`ShellBrowserTile` = address bar + webview): address bar is part of
  `.tile`/`.focus` chrome; content rect = unit rect minus address-bar height.
- **Chat ports** (`ChatView`, pure SwiftUI — not a reparented NSView): no blank risk;
  adopt the same `PortUnit` positioning for consistency; unit renders `ChatView`.

### Interactions that must survive

- **Drag / corner-resize** (`moveDelta`/`resizeCorner`): mutate the unit's placement rect.
- **Hover-to-front / z** (`bringToFront`, `panel.z`): drives `placement.z`. Overlapping
  tiles keep correct z because chrome+webview are one unit (invariant I7).
- **Exposé / arrange** (`applyArrange`, `exposeActive`): operate on placement rects;
  animation becomes "unit frames interpolate."
- **Focus backdrop / tap-to-exit**: dim layer at z 11_900; tap → `zoom = .space`.

### Transition / animation

`withAnimation` on `zoom`/`placement` animates each unit's `frame`/`position`/`corner`.
The webview **resizes** to the focus rect (crisp re-render, not blurry `scaleEffect`).

---

## 5. Load-bearing invariants (what must be true)

Ranked; design-controlled unless noted.

| # | Invariant | Why load-bearing | Confidence | If false → |
|---|---|---|---|---|
| **I1** | A WKWebView that stays in one superview and only changes **frame** does not blank. | The whole thesis. The blank came from window-detachment; resize must be safe. | High, unverified | Approach dead → overlay layer or snapshot. |
| **I2** | SwiftUI keeps the **same** backing NSView (calls `update`, never `make`) when identity is stable and only `.frame`/`.position`/`.zIndex` change. | If it remakes, `make` builds a new container → reparent → detach → blank. **Same non-determinism that caused the grey.** | Medium — **highest risk** | Force stability; if it still remakes, approach dead. |
| **I3** | A view lives its whole life in **one ForEach in one ZStack**, never moved between parents. | Crossing containers = reparent = remake. Peeks + tiles share one container from birth. | High (design) | Restructure so nothing crosses containers. |
| **I4** | `.id()` / structural identity keyed **only on `panel.id`**, never on state. | State in identity remakes on transition → reparent → blank. | High (design) | Audit modifiers; forbid state in `.id`. |
| **I5** | Resize to focus size re-renders **crisply** (frame, not `scaleEffect`). | Blurry focus is unusable; rules out the scale shortcut. | High | Frame only, never scale. |
| **I6** | `GhosttyInputView` tolerates resize-in-place. | Ghostty manages its own PTY size; aggressive resize could corrupt. | Medium | Keep terminals on the old path; revisit. |
| **I7** | One ZStack + per-unit `zIndex` interleaves overlapping tiles correctly. | Why chrome+webview are bound into one unit. | High | — |

**The two that matter: I1 and I2.** I2 is the scary one — it's the same SwiftUI reuse
non-determinism that produced the grey, except now we bet on reuse *happening*.

---

## 6. De-risking: spike before any refactor

Prove I1 + I2 in isolation, ~1 hour, zero production code touched.

- Throwaway `SpikeView`: one persistent `ShellPortHost(webViews[somePort])` in a ZStack;
  a button animates its `.frame`/`.position` between a 210px mini rect and a full-screen
  rect, 10× in a row.
- Reuse the make/update logger. **Pass = exactly one `MAKE`, zero blanks, crisp at both
  sizes, `webview.window != nil` on every frame.**
- Converts the day-long gamble into a one-hour yes/no. Fail cheap.

### Turn "did it blank" into a checkable invariant

Blanking can't be unit-tested, but its cause can be asserted at runtime. For any staged
port, across every transition, assert in debug builds:

- `webview.window != nil` **always** (never windowless),
- `webview.superview === itsUnitContainer` **always** (never orphaned/stolen),
- `make` count **== 1** per port per lifetime.

If those hold, it *cannot* blank — the visual bug becomes a measurable assertion. This
backs the automated checks below.

---

## 7. Phases

Each phase builds, is testable, and has a gate. **The concrete per-phase tests and the cumulative
integration scenario live in §9 (Test plan) — and the render probe there is built FIRST, before
Phase 0.** Below is the *change* and the *gate* for each phase; the gate resolves against §9.

### Spike (pre-Phase 0) — validate I1 + I2
The `SpikeView` above (one persistent host, animate frame 10×). **Gate:** no pass, no refactor.
✅ **PASSED** (see Status, top of doc).

### Phase 0 — tile focus = resize in place (safe surface)
Make desktop-tile focus resize-in-place: `zoom == .focus(tileId)` animates the tile's own
`PortUnit` to `focusRect` + top z + backdrop; delete `ShellFocusContent`'s host for tiles.
**Gate (§9 Phase 0):** Tier B green (make==1, never windowless) on web + chat. Terminals green →
include; red → gate-2.

### Phase 1 — peeks as units
Replace the rail `VStack` with absolutely-positioned peek `PortUnit`s (`railSlot`). Preview =
`zoom = .focus`; the unit resizes mini→focus in place. Delete `previewPeek`'s reparent/stash logic
and `pendingPreviewPeek`.
**Gate (§9 Phase 1):** the in-code peek repro assertion — if `window` ever goes nil, the root
cause isn't fixed; **stop**.

### Phase 2 — collapse / cleanup
Remove `ShellFocusContent`'s webview path; terminals + browser + chat onto the unit. Delete the
remaining reparent workarounds.
**Gate (§9 Phase 2):** all three port kinds green on Tier B; no orphaned old-path code remains.

### Phase 3 — regression sweep + persistence
Full-desktop regression (arrange / exposé / drag / space-switch) + `adoptedSpaceIds` persistence
across space-switch and restart.
**Gate (§9 Phase 3):** clean Tier B across a busy desktop; persistence unit tests green.

---

## 8. Decision gates (kill criteria)

1. **After spike:** blank-on-resize or >1 make → **abandon resize approach**; fall back to
   AppKit overlay layer or a transition snapshot. (Cheapest exit.)
2. **After Phase 0:** tile-focus clean but I6 (terminals) fails → ship the unit model for
   web/chat, keep terminals on the old path, revisit.
3. **After Phase 1:** the instrumented repro assertion is the acceptance test — if `window`
   ever goes nil, the root cause isn't fixed; stop.

---

## 9. Test plan (concrete, per-step)

§7 names the phases; this makes their tests **runnable and unambiguous** so no step ships on faith.
Every phase has three tiers and a hard gate.

### Why three tiers

The visual bug (grey/blank) is **GPU-composited in a separate WKWebView content process** — you
*cannot* assert pixels from Swift. So we don't test "is it grey"; we test the **three conditions that
make grey impossible** (the invariants I1–I7, §5), plus the pure logic, plus a human eyeball for the
last mile.

| Tier | Runs where | Catches | Automated? |
|---|---|---|---|
| **A · Unit** | `swift test`, headless | wrong geometry / state logic | ✅ fully |
| **B · Probe (instrumented)** | in-app harness, DEBUG | the blank's *cause* (detach / remake / orphan) | ✅ asserts, ▶ human clicks "run" |
| **C · Eyeball** | the human, numbered protocol | crisp render, real feel | manual, scripted |

**If A + B are green, C cannot show a blank** — that's the whole point. C then only judges quality
(crisp, smooth), never correctness of the mount.

### Tier B — the probe (build this FIRST, before Phase 0)

The instrument that turns "did it blank" into a crashing assertion. One file, DEBUG-only.

```swift
#if DEBUG
@MainActor enum PortRenderProbe {
    private static var makes: [String: Int] = [:]          // port id → make count (lifetime)
    static var enabled = false                             // on only during a harness run

    /// Call from ShellPortHost.makeNSView. >1 per port ⇒ a reparent/remake happened → the bug.
    static func recordMake(_ id: String) {
        makes[id, default: 0] += 1
        assert(!enabled || makes[id]! == 1, "PortUnit \(id) remade \(makes[id]!)× — reparent leak")
    }
    /// Call on every transition (present/arrange/zoom) for each staged port.
    static func assertHealthy(_ id: String, view: NSView, expectedContainer: NSView) {
        guard enabled else { return }
        assert(view.window != nil,               "PortUnit \(id) went WINDOWLESS → will blank")
        assert(view.superview === expectedContainer, "PortUnit \(id) orphaned/stolen from its container")
    }
    static func reset() { makes.removeAll() }
}
#endif
```

Wire points (Phase 0): `ShellPortHost.makeNSView` → `recordMake(id)`; `PortUnit`'s `.onChange(of:
placement)` (and a per-frame hook during the harness) → `assertHealthy`. In production these are
no-ops (`enabled == false`); the harness flips `enabled` on for its run.

**Harness:** a Debug-menu item **"Port Units — cycle"** that, for a chosen port, runs each phase's
transition sequence 10× with `enabled = true`, then prints `PASS`/`FAIL(id, reason)` to `/tmp/portunit.log`.
Same idea as `PortResizeSpike` but exercising the real `PortUnit`. **This is the acceptance test** — a
FAIL means the root cause isn't fixed; do not proceed.

### Phase 0 — tile focus = resize in place

**Change:** desktop-tile focus animates the tile's own `PortUnit` to `focusRect` + top z + backdrop;
delete `ShellFocusContent`'s webview host for tiles.

**A · Unit** (`PortUnitTests.swift`, headless)
- `placement(for: p, tiled: true).rect == resolvedPortFrame(p, area)`
- `placement(for: p, zoom: .focus(p.id)).rect == focusRect(area)` and `.z == focusZ`
- `placement(for: p, notInContext).visible == false`
- zoom sequence maps `tile → focus → tile` (state, not geometry, is the driver)

**B · Probe** (harness "cycle" on a web tile, then a terminal tile)
- sequence: `focus → space → focus → space` ×10
- assert: `makes[id] == 1`, `window != nil` every step, `superview` stable
- **the terminal case is I6** — Ghostty must survive resize-in-place; if the probe fails only for
  terminals, gate-2 applies (ship web/chat, keep terminals on old path).

**C · Eyeball** (numbered)
1. Focus a web tile → zoom out. Repeat ×5. → **no grey, crisp at both sizes.**
2. Same for a terminal tile ×5. → PTY intact, no corruption.
3. Two overlapping tiles → focus the back one → it comes forward correctly (I7).
4. Drag + corner-resize a tile → still works.

**Gate:** B green (make==1, never windowless) on web+chat. Terminals: green → include; red → gate-2.

### Phase 1 — peeks as units

**Change:** replace the rail `VStack` with absolutely-positioned peek `PortUnit`s (`railSlot`);
`previewPeek` just sets `zoom = .focus`; delete `pendingPreviewPeek` + the stash/reparent dance.

**A · Unit**
- `railSlot(index, area)` positions (0,1,2 stack from top-left, 210 wide)
- `portsInContext == tiledPanels ∪ peekingPorts` (deduped)
- `previewPeek(p)` sets `zoom == .focus(p.id)` **and** `pendingPreviewPeek` field is **gone** (compile-time: deleted)
- `settleAfterPreview` only touches countdown/seen bookkeeping (no peek add/remove/reparent)
- countdown: `tick` decrements; hover pauses; reaches 0 → peek removed; `keepPeek` → `surfacedPortIds` + cancel

**B · Probe — THE regression that would've caught the original grey**
- drive the exact repro **in code**: `preview ONE → out → preview TWO → out → preview ONE → out`
- assert throughout: `window != nil`, and `makes[peekId] == 1` per peek
- also: three peeks open simultaneously, preview each → all stay make==1

**C · Eyeball**
1. The repro matrix by hand (ONE×2, ONE→TWO, three peeks). → no grey on any 2nd+ preview.
2. Countdown ring visibly drains; **hover pauses it**; ignore → evaporates.
3. Drag a peek into the space → **keeps** as a tile; ✕ dismisses.

**Gate (kill criterion):** if `window` ever goes nil in the repro, the root cause isn't fixed — **stop**.

### Phase 2 — collapse / cleanup

**Change:** delete `ShellFocusContent`'s webview path; terminals + browser + chat onto `PortUnit`.

**A · Unit**
- browser content-rect == `unit.rect` minus address-bar height
- chat unit selects `ChatView(spaceId:)` (no NSView mount → no blank risk, still a unit)
- dead-code removal keeps all state-transition unit tests green (regression guard)

**B · Probe:** browser navigate → focus → out ×5; terminal type → focus → out ×5 → make==1, no windowless.

**C · Eyeball:** browser (address bar in focus chrome, page crisp); terminal (types + focuses clean);
chat (renders, no blank).

**Gate:** all three port kinds green on B; no orphaned old-path code remains.

### Phase 3 — regression sweep + persistence

**A · Unit** (`DatabaseService(inMemory:)`)
- an adopted/imported port persists across a space-switch + simulated restart (`adoptedSpaceIds` row)
- `ports(in: space)` returns the right set after move/adopt/close

**B · Probe:** full-desktop cycle (arrange, exposé, drag, space-switch) with several ports → 0 windowless, makes all ==1.

**C · Eyeball:** drag / resize / arrange / exposé; switch spaces (no re-arrange); relaunch restores
tiles at position; an imported port persists in the space it was kept in.

**Gate:** clean B across a busy desktop; persistence unit tests green; manual sweep clean.

### Integration test — the golden path (run cumulatively at every gate)

The per-phase tiers above prove each *change* in isolation. This proves the **whole system still
holds together** end-to-end — every port kind, every state, across spaces, across a restart. It's
**one scripted scenario** that grows as phases land: each phase adds the steps it enables, and **the
full accumulated script re-runs at every subsequent gate** (a phase can't regress what an earlier
phase shipped).

Run it two ways at each gate: **B-instrumented** (`PortRenderProbe.enabled = true` throughout — every
step asserts `window != nil`, `superview` stable, `makes == 1`) and then **C-eyeball** (a human walks
the same numbered script judging crispness/feel). The integration script is the peek/preview repro
plus the tile-focus cycle plus space moves plus persistence, chained — the combinations no single
per-phase test exercises.

#### The script (`GoldenPath`), by the phase that unlocks each act

**Act I — one of each kind, focused in place** *(needs Phase 0)*
1. Open a **web** tile, a **terminal** tile, a **chat** tile in space A. → 3 units, each `make==1`, `window!=nil`.
2. Focus each in turn (`present(.focus)`), zoom back out, ×3. → resize-in-place, no grey, PTY/DOM intact.
3. Two tiles overlap → focus the back one → it comes forward (I7); the other stays mounted (`window!=nil`).

**Act II — peeks from another space, interleaved with focus** *(adds Phase 1)*
4. From space A, drive a notification/peek for a port living in **space B** → it peeks in as a unit.
5. The original grey repro, now *interleaved with Act I state*: `preview peekB → focus webA → out → preview peekB again → out`. → **peekB never blanks on the 2nd preview**; webA's focus cycle unaffected.
6. Three peeks open at once; preview each; **keep** one (drag-in / `keepPeek`) → it becomes a tile in A (`make` still ==1, no remount on adopt); let the other two evaporate.

**Act III — browser + cross-space move** *(adds Phase 2)*
7. Open a **browser** port, navigate, focus, out ×3. → address bar in focus chrome, page crisp, `make==1`.
8. `move(keptPort, to: B)` then switch A→B→A. → the port is present in B, absent from A; **no re-arrange on switch**; every surviving unit stays `window!=nil` across both switches.

**Act IV — persistence across restart** *(adds Phase 3)*
9. With the busy desktop from Acts I–III, trigger arrange + exposé. → 0 windowless, all `make==1`.
10. Simulate restart (`DatabaseService` reload). → tiles restore at position in their spaces; the **kept/moved** port restores in **B**; a parked port restores parked. `ports(in:)` returns the right set per space.

#### What each gate runs

| Gate | Integration acts exercised | New combination it must survive |
|---|---|---|
| **Phase 0** | Act I | focus/zoom across kinds without detach |
| **Phase 1** | Acts I–II | peek repro **while** tiles focus — the cross-feature blank |
| **Phase 2** | Acts I–III | browser + move layered on the peek/focus load |
| **Phase 3** | Acts I–IV | the full desktop survives arrange/exposé **and** a restart |

**Gate rule for the integration run:** the accumulated `GoldenPath` must pass B-instrumented (no
windowless / no remake at any step) **before** the phase's own Tier-C sign-off. A per-phase unit test
can be green while the *integration* of two features blanks — Act II step 5 is exactly that class of
bug (peek fine alone, focus fine alone, blank when interleaved). This script is where those hide.

### The rule this plan enforces

> **No phase merges until its Tier B run prints `PASS` and its Tier A tests are green.** Tier C
> confirms feel, never correctness. "Looks fine on my click-through" is not a gate — the probe is.

This is exactly what was missing on the chat send-bug and the port-render fumble: a *runnable* proof
per step, not a manual glance. Every step here has one.

---

## 10. Effort

~1 day after the spike passes. Phase 0 is a few hours and de-risks the rest. Do **not**
write refactor code before the spike validates I1 + I2.

## 11. Related

- Supersedes the reparent-based peek preview added in `d17f31e` (hover-peek + gesture zoom)
  and the notifications-as-ports lifecycle work.
- Phase 3 folds in the earlier requirement: imported ports must persist across
  space-switch + app restart (`adoptedSpaceIds` on `PortPanel`, DB migration).
