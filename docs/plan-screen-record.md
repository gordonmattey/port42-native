# Implementation plan: `screen.record` (native demo capture)

Eng plan for the `screen.record` capability. The API interface spec (the product contract, source of
truth for WHAT) lives in `port42-growth/specs/screen-record-api.md` — filed there because the driving
use case is native demo capture, but it is a product/API doc, not a go-to-market one. This doc is the
eng scope for HOW, with testing at each step and de-risking spikes up front. Reuses the existing
`ScreenBridge` ScreenCaptureKit setup; the genuinely new work is a recording session, system-audio
capture, and the framing math.

## Decisions (settled with GM 2026-07-21)

- **Target macOS 15+ for this feature.** Current macOS is 26; 15 is a safe floor. Gate the recording
  code with `@available(macOS 15, *)` (no app-wide deployment bump); `screen.record*` returns a clear
  "requires macOS 15" error on older systems. This unlocks `SCRecordingOutput` (stream → file in a few
  lines) instead of a hand-rolled `AVAssetWriter`.
- **System audio via `SCStreamConfiguration.capturesAudio`** (no loopback, rides the Screen grant). The
  Core Audio process-tap (isolate one port's audio) is a noted future upgrade, not v1.
- **Recording pipeline:** `SCStream` (video + optional audio) + `SCRecordingOutput` to a file. No custom
  frame pipeline for the happy path. `fit: contain` letterboxing is the one case that may need a compose
  step; it is deferred to a later step (v1 ships `cover`/`exact` via `sourceRect`, `contain` after).

## File destination + retention (settled with GM 2026-07-21)

The recording is a real file (never base64 — `screen.capture` returns base64, fine for a screenshot but
a non-starter for a 30MB+ video), and `screen.record` returns the real `path`. Where it lands:

- **Default: `<space.workingDirectory>/recordings/<recordingId>.mov`** when the CALLING space has a cwd
  set. The space's working directory is the project folder the director works in; a **command companion
  running in that cwd reaches the file directly** (relative path), and it is visible to the user. Space
  is resolved from the calling `Principal.spaceId`; the cwd via the existing `resolveTerminalCwd` path.
- **Fallback: `~/Library/Application Support/Port42/recordings/`** (`BridgeFilePaths.dataDir`) when the
  space has no cwd (home default). Contained (no video dumped in the user's home) and reachable by the
  sandboxed `fs.*` API.
- **`~/.port42` is NOT used** — that dir belongs to the CLI / claude-code companion side, not the Swift
  app; the app never writes there.
- **`path` option overrides**: relative → resolved against the destination base above; absolute →
  allowed (the app is not sandboxed), with the caveat that a `fs.*`-sandboxed web port can only read it
  if it is under `dataDir`.
- **Consumer note:** a command companion (in the cwd) or the gateway uses the returned path directly; a
  web port (`fs.*`-sandboxed to `dataDir`) can only `fs.*`-read a recording in the fallback location.

**Retention** (recordings are large — the "nothing releases what it acquired" class), split by owner:
- The app-owned fallback dir (`dataDir/recordings/`) gets a cap + evict-oldest (keep last N or X MB).
- The space-cwd `recordings/` dir is USER-owned — cap gently, never aggressively delete the user's files.
- Add `screen.record.list` so the set is legible rather than silently accumulating.

## What already exists in `ScreenBridge` (reuse)

| Need | Already there |
|---|---|
| Window-scoped, occlusion-proof capture | `SCContentFilter(desktopIndependentWindow:)` (:140, :213) |
| Cursor on/off | `config.showsCursor` (:127, :145) |
| Crop / region framing | `config.sourceRect` (:116) |
| Output dimensions / scale | `config.width/height`, scale math (:124, :142) |
| Window enumeration (`screen.windows`) | `availableContent` → window list (:37-51) |

New: `capturesAudio`, `SCRecordingOutput`, the union-bbox framing, and the start/stop/status lifecycle.

## De-risking spikes (do FIRST, throwaway code, before Step 1)

Three unknowns carry the risk. Each spike is a tiny `#if DEBUG` harness or a scratch method behind a
one-shot defaults flag, run live in Port42Dev, verified by inspecting the output file. Kill the code
after; the finding is the deliverable.

- **Spike A — record self-window with system audio to a file (the core unknown).** `SCStream` on
  `desktopIndependentWindow(self)` + `capturesAudio = true` + `SCRecordingOutput` for ~5s while the synth
  port plays. **Pass:** a `.mov` exists with BOTH a video track and a non-silent audio track
  (`ffprobe`/`AVAsset` shows two tracks; audio RMS > silence). This proves the whole happy path in
  isolation; if `SCRecordingOutput` + `capturesAudio` don't co-operate, we learn it here, not in Step 3.
- **Spike B — occlusion-proof + pointer-glitch check.** Record `{window:self}`, then cover Port42 with
  another app and move the mouse over it during the take. **Pass:** the frame shows only Port42 (no other
  app leaks in, no black), AND note whether the 2.4 pointer glitch appears in the recording (it lives on
  the `SCStream` path; the window filter may sidestep it). Names the risk before we build on it.
- **Spike C — `sourceRect` crop under a window filter.** Record `{window:self}` cropped to one port's
  sub-rect via `sourceRect`. **Pass:** the output frames exactly that port. Resolves the coordinate-space
  question (window-relative vs display-relative, points vs pixels/scale) that the union-bbox framing
  depends on — the single most likely place to get the math wrong.

Spikes A and C are the gating ones; B is a risk-namer that can run in parallel.

## Architecture

- `ScreenRecorder` (new, in `ScreenBridge.swift` or a sibling): owns an `SCStream` + `SCRecordingOutput`
  per active recording, keyed by a `recordingId`. Holds the filter, config, output URL, start time.
- **Target resolution** (pure where possible): `RecordTarget` → `(SCContentFilter, sourceRect?)`.
  `window:self`/`window:id` → `desktopIndependentWindow`; `port`/`ports` → self-window filter +
  `sourceRect` = union of tile rects + padding; `region` → display filter + `sourceRect`; `display` →
  display filter.
- **Options → config** (pure): `RecordConfig.from(opts:)` computes `width/height` from
  `width|height|aspect|fit|scale`, sets `fps` (`minimumFrameInterval`), `showsCursor`, `capturesAudio`.
- **Lifecycle:** `start` builds and starts the stream, returns `{recordingId, width, height, target}`;
  `stop` stops + finalizes the output, returns `{path, width, height, seconds, fps, bytes}`; `status`
  reports `{recording, elapsed}`; the timed convenience is `start` + `Task.sleep` + `stop`.
- **Permissions:** `screen.record*` require `.screen` (system audio included). `audio: mic|both` also
  requires `.microphone`; the method asks for it via the `PermissionCoordinator` before starting.

## Bridge methods (registry-first, `BridgeMethods.swift`)

```
screen.record.start(opts)      → { recordingId, width, height, target }   permission .screen (+.microphone if mic/both)
screen.record.stop(recordingId)→ { path, width, height, seconds, fps, bytes }
screen.record.status(id?)      → { recording, elapsed }
screen.record(opts+{seconds})  → { path, ... }   convenience, auto-stop
```

Declared once in the registry with self-describing schema; reachable from port JS, tool use, and the
gateway. Adding methods bumps the `BridgeParamConsistencyTests` count and the `llms.txt` freshness gate
(both known, both cheap to update).

## Implementation steps, with testing at each step

Capture cannot run headless (needs a real display + TCC), so the split is: **pure logic is unit-tested;
the capture path is spike- and live-verified.** Each step builds green before the next.

### Step 0: the spikes above — DONE (2026-07-21, verified live in Port42Dev)

Throwaway harness `ScreenRecordSpike.swift` (`#if DEBUG`, Debug menu + one-shot
`PORT42_RECSPIKE_A/B/C_AUTORUN` flags), recording the self-window to `/tmp/screenrec-<mode>.mov`,
verified with `ffprobe`/`ffmpeg` + frame extraction. Findings (the deliverable):

- **A — PASS (gating).** `SCRecordingOutput` + `SCStreamConfiguration.capturesAudio=true` produce ONE
  `.mov` with an H264 video track AND an AAC stereo 48kHz audio track. No separate `.audio`
  `SCStreamOutput` is needed. Audio was non-silent (a looping `NSSound` played through the app during
  the take; `volumedetect` mean −30.1 dB / max −8.9 dB, vs ~−91 dB for true silence).
  `excludesCurrentProcessAudio` defaults false, so this process's own audio (the synth) is captured.
- **B — occlusion-proof PASS; recorded pointer clean (risk-namer).** Recorded the self-window with
  `showsCursor=true` while Finder and Terminal covered Port42. Every frame showed ONLY Port42's
  surface (no leak, no black) — the `desktopIndependentWindow` filter is private regardless of
  occlusion. The captured cursor rendered cleanly (no doubling/smear). The 2.4 glitch is about the
  LIVE on-screen pointer, which a recording can't show; left as a live-observation note for Step 4's
  cursor-on cases.
- **C — PASS (gating).** With a `desktopIndependentWindow` filter, `config.sourceRect` is
  **window-relative, in POINTS, origin top-left.** A centered 50%-size rect
  `(432, 269.75, 864, 539.5)` on a 1728×1079-point window (3456×2158-px backing) cropped to the
  centered half of the window content, not a pixel-space sub-patch and not offset by the window's
  screen position. This is the coordinate space the union-bbox framing math in Step 2 uses.

**Gate cleared** (A and C pass), Step 1 unblocked. Carry-forward: the spike hard-coded `scale = 2`
(output came out at 2× the point size); Step 1's `RecordConfig.from(opts:)` must derive
`width/height` from the requested `scale`/dimensions so takes land at the asked-for size.

### Step 1: the recording session core (`window:self`, video + system audio, start/stop) — DONE (2026-07-21)

`ScreenRecorder.swift`: the pure `RecordConfig.from(sourceSize:displayScale:opts:)` derivation
(scale/dimensions/fps/cursor/audio/format → output px + SCStreamConfiguration shaping), `RecordTarget`
(`.selfWindow` now, rest stubbed), and `ScreenRecorder` (`@MainActor`) owning an `SCStream` +
`SCRecordingOutput` per `recordingId`. `start(.selfWindow, opts)` → `{recordingId, width, height,
target}`; `stop(id)` finalizes via the delegate + a 3s watchdog → `{path, width, height, seconds, fps,
bytes}`; `cleanup()` is the teardown seam (owner-port `releaseIfOwned` wiring lands in the teardown
step). Step 1 writes to a temp `.mov`; the space-cwd/fallback destination lands with the bridge methods.

- **Unit — PASS (13 tests, `RecordConfigTests`):** default scale = display scale; `scale:1` → point
  size (the scale fix); `scale:2` → 2×; explicit width/height override; fps default/floor; cursor;
  each `audio` value → correct `capturesAudio`/`captureMicrophone`; `format` → file type; Int-scale
  from JSON. Headless.
- **Live — PASS (Port42Dev, via the repointed spike A):** `start(.selfWindow, {audio:"system",
  scale:1})` → `width:1728, height:1079`; 5s take; `stop` → a real temp path, `seconds:5.0`. ffprobe:
  H264 **1728×1078** (h264 rounds the odd 1079 height down to even), AAC stereo 48kHz, mean −28.9 dB
  (non-silent). Scale fix confirmed live.
- **Carry-forward:** dimension math should prefer even width/height so the encoder does not silently
  round (the 1079→1078 case). Fold into Step 2/4's derivation.

### Step 2: target resolution + framing math — DONE (2026-07-21, verified live)

`RecordFraming.swift` (pure): `unionBBox(rects, padding)`, `parseAspect`, `evenInt` (fixes the odd-height
carry-forward), and `resolve(bbox, aspect, fit, width, height, scale) → (sourceRect, width, height)`.
`ScreenRecorder` gained `.port(id)`/`.ports([id])` targets: a `portFrameLookup` closure supplies each
tile rect (keeps the recorder decoupled from AppState), union + padding → bbox, `resolve` → `sourceRect`
+ dims on the self-window filter.

- **v1 fit policy (GM 2026-07-21):** `cover` and `exact` supported; `contain` (letterbox) deferred to
  Step 6. A `contain` request whose aspect differs from the box returns a legible error ("pass fit:cover
  or fit:exact, or omit aspect") rather than a silently wrong frame. With no aspect/dims requested every
  fit collapses to the box (no crop, no bars, no error).
- **Unit — PASS (14 tests, `RecordFramingTests`):** union over 0/1/N rects + padding; aspect parse;
  even rounding; no-mismatch collapse; matching-aspect no-error; contain-mismatch throws; exact stretch;
  cover widen/heighten (centered); explicit-width derivation.
- **Live — PASS (Port42Dev, mode D):** two ports at known positions, `record({ports:[a,b], padding:32,
  aspect:"16:9", fit:"cover", scale:1})` → 1266×712 (16:9). The extracted frame shows BOTH ports fully
  in view with padding and cover breathing room. Confirms `portFrame` (desktop coords) equals the
  `sourceRect` window-point space — no chrome offset — and the union/cover math end to end. The shell
  had re-arranged the ports; the recorder framed their actual rendered rects (the director pattern).

### Step 3: the bridge methods + permissions — DONE (2026-07-21, verified live over the gateway)

Four registry methods in `BridgeMethods.swift` (near `screen.stream`), all `paramNames:["options"]` bags
except stop/status (`recordingId`):
- `screen.record.start` (`.screen`, tool) → `recorder.start(...)`; `screen.record.stop` (`recordingId`);
  `screen.record.status` (no perm); `screen.record` convenience (`.screen`, tool) = start → sleep
  `seconds` → stop.
- **Permissions:** `.screen` is auto-prompted by `BridgeDispatcher`; `audio:mic|both` additionally asks
  `.microphone` in the body via `appState.permissions.request`.
- **Destination:** calling space's `workingDirectory/recordings/`, else `BridgeFilePaths.dataDir/
  recordings/`; a `path` option overrides (absolute as-is, relative under the dest dir). `~/.port42` is
  never used. `ScreenBridge` now holds the `ScreenRecorder`; `.port`/`.ports` get `portFrameLookup =
  { appState.portWindows.portFrame(by:) }`.
- `ScreenRecorder` gained `status(recordingId:)`, an `outputURL` override, `Active.startedAt`, and the
  pure `RecordTarget.parse` (self/port/ports; window:id/region/display → Step 4 error).

- **Unit — PASS:** `RecordTargetTests` (7). `BridgeParamConsistencyTests` B1+B2 pass (schemas consistent
  with the bodies); method count updated 67 → 71. `llms.txt` regenerated (`PORT42_REGEN_DOCS=1`), the
  docs-export freshness gate passes.
- **Live — PASS (Port42Dev gateway :4243):** `screen.record.status` → `{recording:false}`;
  `screen.record({seconds:3, audio:"system"})` → a real path under `dataDir/recordings/` (gateway peer
  has no space, so the fallback — correct), 3456×2158, 3s. ffprobe: H264 + AAC stereo. No permission
  card blocked it (screen already granted).

### Step 4: options coverage + region/display/window:id targets — DONE (2026-07-21, verified live)

Most options (width/height/scale/fps/cursor/audio/format via `RecordConfig`; aspect/fit/padding via
`RecordFraming`) shipped in Steps 1-2. This step added the remaining targets. `ScreenRecorder.start`
now resolves the target from ONE `SCShareableContent` fetch → `(filter, baseSize, label)`:
- `self`/`port`/`ports`/`window:<osId>` → occlusion-proof `desktopIndependentWindow` filter.
- `display:<id>` / `region:{x,y,w,h}` → display filter (NOT occlusion-proof — a raw display grab; the
  method description says so). `region` sets `sourceRect` in screen points. `screen.displays` exposes no
  display ids yet, so `{display:true}`/non-numeric resolves to the main display.
- Two fixes found live: `stop()` falls back to the on-disk file size when `recordedFileSize` reads 0
  (was returning bytes:0 for some sources); display parse accepts a truthy value as the main display.

- **Unit — PASS (`RecordTargetTests`, 10):** window:id/region/display parse; region x/y/w/h and
  width/height keys; region needs positive w/h. `llms.txt` regenerated, docs-export gate green.
- **Live — PASS (gateway :4243):** self 60fps+cursor (3456×2158 @60), window:id (valid H264; a STATIC
  external window yields a short clip because SCK emits window frames only on content change — an
  animating window records the full duration), display:true (full display 3456×2234, 2.1s), region
  800×600@(100,100) (→ 1600×1200 @scale 2). All valid H264.

### Step 5: the timed convenience + status + cleanup — DONE (2026-07-21, verified live)

Timed convenience + `status` shipped in Step 3. This step wired the teardown seam so a recording cannot
leak (the "nothing releases what it acquired" class):
- `ScreenRecorder.releaseIfOwned(byPortId:)` finalizes recordings the given port started (keyed on
  `Active.ownerPortId`, set from `Principal.portId` at start); fire-and-forget `stopCapture` with the
  captured `rec` keeping the stream+delegate alive until the file finalizes.
- `ScreenBridge.releaseIfOwned` calls `recorder.releaseIfOwned` BEFORE the stream early-return (a
  recording and a stream are independent); `ScreenBridge.cleanup` calls `recorder.cleanup`. So the
  existing `AppState.releaseAcquisitions(portId:)` path (port close + the deinit backstop) now finalizes
  a port's recordings, exactly like the mic. App-quit is best-effort (a port's deinit backstop + the
  convenience auto-stop cover the realistic cases; a gateway-peer manual start with no stop is the one
  residual, no port to key on).
- **Unit — PASS (5, `ScreenRecorderTeardownTests`):** idle recorder not recording; `status(nil)`/
  `status(id)` shapes; `releaseIfOwned`/`cleanup` safe no-ops (a populated Active needs a real SCStream,
  covered live).
- **Live — PASS (Port42Dev, spike mode E):** a port started a 30s recording; closing the port at ~1.5s
  drove `releaseAcquisitions` → the file finalized (valid mov, H264, 1.65s duration) and
  `recorder.isRecording` went false. No orphaned stream, no unfinalized file.

### Step 6: `fit: contain` letterbox (deferred slice)
- If `SCRecordingOutput` can't letterbox natively, add a compose step (an `AVAssetWriter` consumer that
  draws the cropped frame into a padded canvas). Scoped separately because it is the one case needing a
  custom pipeline.
- **Test:** live — a `contain` take of a non-16:9 target comes out 16:9 with bars, not stretched.

### Framing extension: aspect/fit on ALL targets + cover = crop-to-fill (2026-07-21, DONE)

Two things folded in before Step 7 so the director examples are meaningful:
- **aspect/fit now applies to every target, not just ports.** `ScreenRecorder.start` computes a
  `contentBBox` in the filter's coordinate space (self/window = full window; display = full display;
  region = the rect; ports = the union) and runs `RecordFraming.resolve` whenever an aspect / explicit
  dims are given (or it is a port/region target). A plain window/display take (no aspect) still skips
  framing. This is what makes `screen.record({window:"self", aspect:"16:9"})` actually 16:9.
- **`cover` is now standard crop-to-fill** (was an "expand into surrounding content" that added
  transparent bars on a full-window target). Cover crops the overflow axis, always staying WITHIN the
  box — correct and consistent for window/display/region/ports. "Keep everything at a fixed aspect" is
  `contain` (letterbox, Step 6); ports with no aspect still frame the full union. Reflected in
  `RecordFramingTests` (15).

### Step 7: live end-to-end (the spec's director examples) — DONE (2026-07-21, verified live)

- **V3 say-it-see-it** (`window:self`, `aspect:"16:9"`, `fit:"cover"`, audio none): 3456×1944 (true
  16:9), a clean crop of the 1.60 window — no stretch, no bars (frame inspected).
- **V1 synth hero** (`window:self`, `aspect:"16:9"`, `fit:"cover"`, cursor, `audio:"system"`, 60fps):
  3456×1944 @60fps, AAC stereo.
- **V2 coordination** (two-port union frame): the union + framing math is covered live by spike mode D
  (coordinate space + union confirmed) and the 15 `RecordFramingTests`; cover now crops rather than
  expands (a re-run needs an active space). No-aspect ports still frame the full union.

The `contain` shot (any target whose requested aspect differs from the source) returns the legible
"pass fit:cover or fit:exact" error until Step 6.

## Testing strategy summary

- **Unit (headless, deterministic):** options→config, union-bbox + aspect/fit framing math, target
  resolution, bridge schema/param-consistency, status/elapsed. These are the bulk of the correctness.
- **Spike + live (needs display + TCC, human at the prompts):** the actual capture, audio presence,
  occlusion-proofness, coordinate space, fps/dimensions, teardown. Verified by inspecting output files.

## Risks and rollback

- **`SCRecordingOutput` + `capturesAudio` interaction** — retired by Spike A before any real build.
- **`sourceRect` coordinate space** (window vs display, points vs pixels) — retired by Spike C.
- **2.4 pointer glitch on the shared `SCStream` path** — named by Spike B; the window filter likely
  avoids it, but if a recording shows the glitch it blocks the cursor-on cases until 2.4 is diagnosed.
- **Stream leak** (a recording that never stops) — same class as the 0.5 mic leak; Step 5 funnels stop
  through the teardown seam so an owning-port death always finalizes.
- **Rollback:** the feature is additive and permission-gated. Steps are independent; the registry
  methods can ship `window:self` only (Step 1-3) and gain targets/options incrementally. `fit: contain`
  (Step 6) reverts without touching the rest.
