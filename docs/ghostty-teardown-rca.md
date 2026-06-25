# Ghostty surface teardown — crash RCA & lifecycle review

Status: **investigating.** Crash on closing the Ghostty debug window.

## The crash (observable)

- `EXC_BAD_ACCESS / SIGKILL (Code Signature Invalid)`, namespace `CODESIGNING`, "Invalid Page".
- Reported on **closing the Ghostty debug window** (Step 2 harness).
- Multiple historical reports, faulting in two different region types:
  - **anonymous executable memory** (not in any image) — e.g. build 1653, 1659. This is the
    signature of executing/reading **freed or unmapped JIT/executable memory**.
  - **file-backed `__DATA` of the binary** — e.g. build 1662, and a *pre-Ghostty* PostHog
    crash on 2026-06-22 (build 1638). This signature is "the file changed under the running
    process" — attributable to build-hygiene (rebuild-in-place) / Dropbox, now mitigated.

## Corrections to earlier (wrong) conclusions

- "The signature is invalid" — **wrong.** The app launches; `codesign --verify --deep --strict`
  passes. `CODESIGNING Invalid Page` at runtime is a *per-page* fault at page-in, not a malformed
  signature.
- "It's app-quit (`terminate:`)" — that was read off a **stale** report (build 1662). macOS
  **deduplicates** crash reports, so recent window-close crashes may have produced **no new
  `.ips`**. We must capture the real current stack before trusting any conclusion.
- "Dropbox is the cause" — was built on an **unverified** assumption that a `/tmp` copy passed.
  `.build` is now excluded from Dropbox sync and a kill-before-rebuild guard was added to
  `build.sh`, removing the file-mutation vectors. If it still crashes, those are excluded.

## Build-hygiene fixes already in place (eliminate the file-backed crash class)

- `build.sh` now `pkill`s app+gateway before `cp`/`codesign` (no rebuild over a live bundle).
- `.build/` excluded from Dropbox sync.

## What runs on window close (current harness — GhosttyDebugHarness.swift)

```
windowWillClose            (main thread)
  └─ ghostty_surface_free(surface)
  └─ surface = nil; window = nil
```
Concurrently possible:
- Ghostty per-surface **IO/render threads** (Ghostty owns the PTY + a Metal render path).
- A queued `DispatchQueue.main.async { tick() }` from `wakeup_cb` → `ghostty_app_tick(app)`.

## Code-review findings (line-referenced, current code)

1. **Direct `ghostty_surface_free` bypasses Ghostty's close protocol.** `close_surface_cb`
   (line 58) is a no-op. Upstream drives teardown *through the app*. Calling
   `ghostty_surface_free` directly (line 133) may leave the app's internal surface list pointing
   at freed memory.
2. **`tick()` (lines 126-128) guards on `app` but not on surface existence.** A `tick` queued
   just before close runs `ghostty_app_tick(app)` *after* the free → walks a dangling surface →
   UAF. A Ghostty surface owns **executable/JIT memory** (Metal/render), so the UAF lands in
   anonymous executable memory → **exactly the `CODESIGNING Invalid Page` anon-memory signature.**
3. **`view` passed unretained (line 100); window is `isReleasedWhenClosed = true` by default.**
   On close the contentView is released while Ghostty still holds the raw pointer; a late
   render/tick touches a freed view. (Also latent ARC over-release: we hold a strong `window`
   ref AND let AppKit release it.)
4. **No thread synchronization around free** vs Ghostty's render/IO threads.

## Hypotheses, stack-ranked

| # | Hypothesis | Evidence (code) | Test |
|---|---|---|---|
| H1 | UAF: `ghostty_app_tick`/render runs against the freed surface (direct free + un-stopped ticks) | lines 52, 127, 133; surface owns JIT mem → CODESIGNING anon | real crash stack shows tick/render; OR stop ticks + don't free → crash gone |
| H2 | Free not routed through Ghostty close protocol → app keeps dangling surface ptr | `close_surface_cb` no-op (58); direct free (133) | compare to upstream/cmux teardown order |
| H3 | NSView freed (releasedWhenClosed) while Ghostty holds unretained ptr | line 100 + AppKit default | `isReleasedWhenClosed=false`, retain view |
| H4 | Render thread (Metal/CVDisplayLink) races the free | — | faulting thread in fresh stack: main vs render |
| H5 | Actually app-quit, not window-close | stale 1662 = `terminate:` | fresh stack + reproduce close w/o quit |
| H6 | File mutation (Dropbox/rebuild) | now mitigated | fresh stack confirms excluded |

## Open question this doc will answer next

**What is the official surface-teardown sequence?** Pull the upstream Ghostty macOS app +
the manaflow/cmux consumer and document, in order:
1. Surface creation (compare to ours).
2. Surface teardown: is `ghostty_surface_free` called directly, or via `close_surface_cb`?
   On which thread? In what order relative to the NSView's removal?
3. How ticks/wakeup are gated during teardown (is there a "closing" flag? is the surface
   removed from the app first?).
4. NSView ownership/lifetime (retained? released when?).

IP note: study the *conceptual* lifecycle/ordering only (functional, not copyrightable).
Prefer upstream Ghostty (source-available) as the canonical reference over GPL cmux code.

## Test plan (pending approval)

1. **Capture the real window-close crash stack** — move aside old `Port42-*.ips` so dedup
   can't suppress a fresh report; reproduce once; read the actual stack. Decides H1/H4/H5.
2. **Diff our create/teardown against upstream** (this doc, next section).
3. Apply the official teardown order; re-test from an immutable build.

## Upstream/cmux teardown comparison

Source studied (conceptual lifecycle only, not copied): manaflow/cmux
`Packages/iOS/CmuxMobileTerminal/.../GhosttyRuntime.swift` + `GhosttySurfaceView.swift`.
(iOS uses `CADisplayLink`/`uiview`; macOS uses `CVDisplayLink`/`nsview` — same C lifecycle.)

### cmux's official `disposeSurface()` ordering (the canonical teardown)

1. **`stopDisplayLink()`** — stop the render loop FIRST so no frame renders against a
   surface about to be freed.
2. **`unregister(surface:)`** — remove from the surface→view registry.
3. **`self.surface = nil`** — null the ref so no *new* surface work gets enqueued.
4. **`bridge.detach()`** — null the bridge's weak `surfaceView`, so any in-flight C callback
   (which fired on Ghostty's IO thread) becomes a no-op when it hops to the main actor.
5. **`Unmanaged.passRetained(bridge)`** — keep the userdata alive *through* the free
   (libghostty references it until free completes).
6. **`outputQueue.async { ghostty_surface_free(surface); retainedBridge.release() }`** — free on
   the **same serial queue** that runs `process_output` / `render_now` / `binding_action`.
   FIFO guarantees the free runs *after* every already-enqueued block that captured the C
   surface pointer → **structurally impossible to use-after-free.**

Their own comment: *"FIFO ordering guarantees the free runs after every already-enqueued block
that captured the pointer, so a dismantled/removed surface's queued libghostty work can never
use-after-free against the free."* This is exactly hypothesis **H1**, confirmed as a real,
deliberately-engineered-around hazard.

### Key architectural differences (matter for our model)

- **IO mode.** cmux uses `GHOSTTY_SURFACE_IO_MODE` = **MANUAL** (`io_write_cb` + they own the
  PTY, e.g. over SSH; they feed bytes via `process_output`). **We use EXEC** (Ghostty spawns
  `/bin/zsh` and owns the PTY + its IO thread). Simpler for us, but it means Ghostty owns the
  threads that `ghostty_surface_free` must stop.
- **Surface userdata = a per-surface `GhosttySurfaceBridge`** carrying a *lock-guarded weak*
  ref to the view. C callbacks (`close_surface_cb`, `io_write_cb`) resolve through it and hop
  to `@MainActor` via `Task`. **We pass no surface userdata at all** and our `close_surface_cb`
  is a global no-op.
- **Rendering is embedder-driven** via `displayLink → render_now` on `outputQueue`, *separate*
  from `ghostty_app_tick` (called only from `wakeup`). **We drive everything through
  `ghostty_app_tick`** from `wakeup_cb` on the main queue (no explicit render loop).
- **App handle** is created once in `GhosttyRuntime.shared()`, freed only in `deinit`
  (process end). ✅ matches our singleton.

### Diff: our harness vs the canonical teardown

| Step | cmux | Our `windowWillClose` | Gap |
|---|---|---|---|
| Stop render loop before free | `stopDisplayLink()` first | — (no explicit loop; ticks via wakeup) | **ticks can still fire during/after free** |
| Null surface ref before free | `surface = nil` *before* free | `surface = nil` *after* free | **wrong order** |
| Guard against post-teardown work | bridge.detach + nil ref stop new work | `tick()` guards `app` but **not** surface/teardown | **`ghostty_app_tick` can run against a freed surface** |
| Free serialized after queued work | free on the serial `outputQueue` (FIFO) | free **inline on main**, no ordering vs queued ticks | **no FIFO guarantee** |
| Keep userdata alive across free | `passRetained(bridge)` | n/a (no surface userdata) | lower risk for us, but no bridge to detach |

### Root cause (high confidence, pending stack confirmation)

**Use-after-free at teardown (H1).** We call `ghostty_surface_free` inline while a
`DispatchQueue.main.async { tick() → ghostty_app_tick(app) }` (queued by `wakeup_cb` firing on
Ghostty's IO thread as the surface tears down) can run against the just-freed surface. A Ghostty
surface owns Metal/render **executable memory**, so the UAF lands in anonymous executable memory
→ the `CODESIGNING Invalid Page` signature. cmux prevents this structurally by serializing the
free behind all other surface work and nulling refs first; our harness does neither.

### Fix direction (faithful to cmux's *concept*, adapted to our EXEC + main-tick model)

1. Set a `tearingDown` flag and **null `surface` BEFORE** the free.
2. `tick()` guards: `guard !tearingDown, surface != nil` (well, surface is harness-level; gate on
   the flag) so no `ghostty_app_tick` runs once teardown starts.
3. Free on the **same execution context that drives ticks** (the main queue) — which we already
   use — but only after the guard is in place, so no queued tick can touch the freed surface.
4. (When we add a real render loop / tee in Steps 3-5, stop it before free, and adopt the
   per-surface bridge + `passRetained` pattern.)
5. Confirm with the real crash stack first (below).

### Next: confirm the stack

Move aside old `Port42-*.ips` (defeat dedup), reproduce the window-close crash once, read the
real stack. Expect to see `ghostty_app_tick` / a Ghostty render/IO frame on the faulting thread
→ confirms H1 before we change code.
