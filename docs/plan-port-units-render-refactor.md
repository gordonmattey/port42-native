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

## 7. Phases + test suite

> Concrete, runnable version: **`docs/test-plan-port-units.md`** — the render probe + three-tier
> (unit / probe / eyeball) suite with a hard gate per phase. Build the probe FIRST.

Each phase builds, is testable, and has a gate.

### Spike (pre-Phase 0) — validate I1 + I2
- Test: the SpikeView above.
- **Gate:** no pass, no refactor.

### Phase 0 — tile focus = resize in place (safe surface)
Make desktop-tile focus resize-in-place: `zoom == .focus(tileId)` animates the tile's own
`PortUnit` to `focusRect` + top z + backdrop; delete `ShellFocusContent`'s host for tiles.
- *Unit (Swift Testing):* `placement(for:tiled)` == `resolvedPortFrame`;
  `placement(for:focused)` == `focusRect(area)`; zoom maps tile→focus→tile.
- *Instrumented assertions:* focusing a tile ⇒ 0 new makes for that host; `window != nil`
  and `superview` stable across focus/unfocus.
- *Manual checklist:* focus a web tile → zoom out ×5 (no blank); a terminal tile ×5; two
  overlapping tiles keep z; drag + corner-resize still work.

### Phase 1 — peeks as units
Replace the rail `VStack` with absolutely-positioned peek `PortUnit`s (`railSlot`).
Preview = `zoom = .focus`; unit resizes mini→focus in place. Delete `previewPeek` reparent
/stash logic.
- *Unit:* `railSlot(index, area)` layout; `portsInContext` includes peeks; `previewPeek`
  sets `zoom` without touching `pendingPreviewPeek` (assert the field is gone);
  `settleAfterPreview` only does countdown bookkeeping; countdown/keep/dismiss/hover-pause.
- *Instrumented assertion (the regression that would've caught today's bug):* run the exact
  repro in code (preview ONE→out→preview TWO→out→preview ONE→out) and assert
  `window != nil` throughout + make-count == 1 per peek.
- *Manual checklist:* repro matrix (ONE×2, ONE→TWO, three peeks), countdown to vanish,
  hover-pause, click-to-keep, ✕.

### Phase 2 — collapse / cleanup
Remove `ShellFocusContent`'s webview path; terminals + browser onto the unit; chat for
consistency. Delete `pendingPreviewPeek` and reparent workarounds.
- *Unit:* browser content-rect = unit rect minus address-bar height; chat unit selects
  `ChatView`; dead-code removal keeps state transitions green.
- *Instrumented + manual:* browser navigate then focus; terminal type then focus; chat —
  0 blanks, 0 new makes.

### Phase 3 — regression sweep + persistence
- *Unit:* `adoptedSpaceIds` persistence (imported port survives space-switch + simulated
  restart) via `DatabaseService(inMemory:)`.
- *Manual:* drag/resize/arrange/exposé; switch spaces (no rearrange); relaunch restores
  tiles; imported port persists in the space it was kept in.

---

## 8. Decision gates (kill criteria)

1. **After spike:** blank-on-resize or >1 make → **abandon resize approach**; fall back to
   AppKit overlay layer or a transition snapshot. (Cheapest exit.)
2. **After Phase 0:** tile-focus clean but I6 (terminals) fails → ship the unit model for
   web/chat, keep terminals on the old path, revisit.
3. **After Phase 1:** the instrumented repro assertion is the acceptance test — if `window`
   ever goes nil, the root cause isn't fixed; stop.

---

## 9. Effort

~1 day after the spike passes. Phase 0 is a few hours and de-risks the rest. Do **not**
write refactor code before the spike validates I1 + I2.

## 10. Related

- Supersedes the reparent-based peek preview added in `d17f31e` (hover-peek + gesture zoom)
  and the notifications-as-ports lifecycle work.
- Phase 3 folds in the earlier requirement: imported ports must persist across
  space-switch + app restart (`adoptedSpaceIds` on `PortPanel`, DB migration).
