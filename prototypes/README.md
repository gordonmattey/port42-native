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

## `p42shell/` — the fullscreen GUI shell (rev 2)
The `plan-port42-shell.md` thesis, live: one ambient surface (dreamscape = screensaver = desktop) with
the chrome+ports summoned on top; idle (9s) dissolves them back to the dreamscape. Ports are
registry-owned WKWebViews; **pop-out** moves the live view into a floating `NSPanel` with no reload
(the proven re-parent), dock-back reverses it. Virtual spaces, Exposé, drag+resize, z-order, a PORT42
mark top-left, and the status cluster moved up from the sidebar (§7a).

```
cd prototypes/p42shell && swift run p42shell    # TAKES OVER THE SCREEN
```

Hides the macOS Dock + menu bar. **Exits (never trapped): Esc · ⌘Q · ⏻ top-right.**
Keys: `⌘K` palette · `Tab` exposé · `⌘1/2/3` spaces · dock icons + ⌘K spawn ports.
