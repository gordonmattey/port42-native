# prototypes

Throwaway spikes that prove mechanics in isolation, outside the app bundle. They back
`docs/plan-port42-shell.md` and `docs/plan-uniform-port-create.md` (Step 8). Disposable — the real
work lives in `Sources/Port42Lib`, reusing the registry / bridge / `port.create` / ambient surface,
not this code.

A macOS `.app` bundle is just packaging; `setActivationPolicy(.regular)` + `NSApplication.run()` +
an `NSWindow` is all it takes to be a GUI app — which is why these run via `swift run` with no
bundle, no signing.

## `wkspike/` — the re-parent crux (Step 8 blocker)
Proves a **live** WKWebView survives re-parenting with **no reload**: a JS counter (`window.__c`,
+1 every 50ms) is moved (A) across a raw AppKit `removeFromSuperview`/`addSubview` into an `NSPanel`,
and (B) through 3 full SwiftUI `dismantleNSView`→`makeNSView` cycles. Counter stays monotonic
(`16 → … → 107`); a reload would reset it toward 0. Verdict: **re-parent** is viable (not overlay /
snapshot-restore).

```
cd prototypes/wkspike && swift run wkspike      # prints PASS/FAIL, self-terminates
```

## `p42shell/` — the fullscreen GUI shell (rev 8)
The `plan-port42-shell.md` thesis, live: one ambient surface (dreamscape = screensaver = desktop) with
the chrome+ports summoned on top; idle (9s) dissolves them back to the dreamscape. Ports are
registry-owned WKWebViews re-parented with no reload between hosts (tiled desktop ↔ floating window ↔
parked dock). The design is captured for production in `docs/spec-shell-reimplementation.md`.

**A space is a room — people + companions + the desktop their conversation produces:**
- **Chat is a port.** Each space has a native chat tile (mirrors the real `isChatPort`) with a **member
  header** — *you* + the space's companions — and live companion status.
- **Companions are a primitive of the space** (not chrome) — shown in the chat member row and on each
  space's galaxy world; one companion can belong to several spaces (e.g. Echo→main+music, Nova→music+ui).
- **The loop:** type into chat → a companion *thinks* → *ports* → tiles appear and it replies, then the
  desktop auto-arranges. The conversation drives the desktop (stand-in for the real companion→`port.create`
  loop). Try: *“open a clock and a system monitor”*, *“@Nova show me the matrix”*, *“dashboard”*.

**Navigation & layout:**
- **One flat level — spaces (no modes).** Each space has its own accent, dock, companions, chat.
- **Zoom ladder:** galaxy (all spaces) → space → focus (one port). `⌘↑/↓` or **pinch** (one rung per
  squeeze); in galaxy, **hover a world + pinch-in / ⌘↓ dives in**. Galaxy grid is responsive (max 3 across).
- **Two docks:** bottom launcher **creates** ports; the right-edge rail **parks** (minimize) them — drag
  a tile into the right strip to park, click a chip to restore. Exposé (`Tab`), drag+resize, z-order.

```
cd prototypes/p42shell && swift run p42shell    # TAKES OVER THE SCREEN
```

Hides the macOS Dock + menu bar. **Exits (never trapped): Esc · ⌘Q · ⏻ top-right.**
Keys: `⌘K` palette · `⌘J` chat · `Tab` exposé · `⌘1…7` spaces · `⌘↑/↓` or pinch zoom · `⌘L` arrange.
