# Test plan — Port Units refactor (concrete, per-step)

Companion to `plan-port-units-render-refactor.md`. That doc's §7 names the tests; this one makes them
**runnable and unambiguous** so no step ships on faith. Every phase has three tiers and a hard gate.

## Why three tiers

The visual bug (grey/blank) is **GPU-composited in a separate WKWebView content process** — you
*cannot* assert pixels from Swift. So we don't test "is it grey"; we test the **three conditions that
make grey impossible** (the invariants), plus the pure logic, plus a human eyeball for the last mile.

| Tier | Runs where | Catches | Automated? |
|---|---|---|---|
| **A · Unit** | `swift test`, headless | wrong geometry / state logic | ✅ fully |
| **B · Probe (instrumented)** | in-app harness, DEBUG | the blank's *cause* (detach / remake / orphan) | ✅ asserts, ▶ human clicks "run" |
| **C · Eyeball** | the human, numbered protocol | crisp render, real feel | manual, scripted |

**If A + B are green, C cannot show a blank** — that's the whole point. C then only judges quality
(crisp, smooth), never correctness of the mount.

---

## Tier B — the probe (build this FIRST, before Phase 0)

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

---

## Phase 0 — tile focus = resize in place

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

---

## Phase 1 — peeks as units

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

---

## Phase 2 — collapse / cleanup

**Change:** delete `ShellFocusContent`'s webview path; terminals + browser + chat onto `PortUnit`.

**A · Unit**
- browser content-rect == `unit.rect` minus address-bar height
- chat unit selects `ChatView(spaceId:)` (no NSView mount → no blank risk, still a unit)
- dead-code removal keeps all state-transition unit tests green (regression guard)

**B · Probe:** browser navigate → focus → out ×5; terminal type → focus → out ×5 → make==1, no windowless.

**C · Eyeball:** browser (address bar in focus chrome, page crisp); terminal (types + focuses clean);
chat (renders, no blank).

**Gate:** all three port kinds green on B; no orphaned old-path code remains.

---

## Phase 3 — regression sweep + persistence

**A · Unit** (`DatabaseService(inMemory:)`)
- an adopted/imported port persists across a space-switch + simulated restart (`adoptedSpaceIds` row)
- `ports(in: space)` returns the right set after move/adopt/close

**B · Probe:** full-desktop cycle (arrange, exposé, drag, space-switch) with several ports → 0 windowless, makes all ==1.

**C · Eyeball:** drag / resize / arrange / exposé; switch spaces (no re-arrange); relaunch restores
tiles at position; an imported port persists in the space it was kept in.

**Gate:** clean B across a busy desktop; persistence unit tests green; manual sweep clean.

---

## The rule this plan enforces

> **No phase merges until its Tier B run prints `PASS` and its Tier A tests are green.** Tier C
> confirms feel, never correctness. "Looks fine on my click-through" is not a gate — the probe is.

This is exactly what was missing on the chat send-bug and the port-render fumble: a *runnable* proof
per step, not a manual glance. Every step here has one.
