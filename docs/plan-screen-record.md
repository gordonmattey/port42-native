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

### Step 0: the spikes above
Land the three findings (record+audio works, occlusion-proof + glitch status, sourceRect coordinate
space). Gate the rest on Spike A and C passing.

### Step 1: the recording session core (`window:self`, video + system audio, start/stop)
- `ScreenRecorder.start/stop` for the simplest target (`window:self`), `capturesAudio` from `audio`,
  `SCRecordingOutput` to a temp `.mov`, returns the real path + metadata.
- **Test:** unit — `RecordConfig.from(opts:)` maps fps/scale/dimensions/cursor/audio correctly (pure).
  Live (Port42Dev) — record 5s of self with `audio:"system"`, assert the returned path exists, is a
  valid movie with a video + audio track, `seconds`/`bytes` are sane.

### Step 2: target resolution + framing math
- `RecordTarget` resolution → filter + `sourceRect`; the **pure union-bbox** function (rects + padding →
  bounding CGRect) and the `aspect`/`fit` → `width×height` derivation.
- **Test:** unit — union bbox over 1/2/N rects with padding; `aspect:"16:9"` derives correct dimensions;
  `fit: cover`/`exact` map to the right `sourceRect`+size; empty/one-port edge cases. Live — record two
  ports; the output frames exactly their union + padding (Spike C coordinate space applied).

### Step 3: the bridge methods + permissions
- Register `screen.record.start/stop/status` + the convenience; wire `.screen` (and `.microphone` for
  `mic|both`) through the `PermissionCoordinator`.
- **Test:** unit — the schema/param-consistency (update the count) and a dispatch test that `start`
  without a display errors cleanly, that `mic` triggers the microphone gate. Update the `llms.txt` gate.
  Live — call `screen.record({seconds:5})` over the gateway; get a path back.

### Step 4: options coverage (fps, scale, cursor, dimensions, format, aspect, region/display targets)
- Fill in the remaining option fields and the `region`/`display`/`window:id` targets.
- **Test:** unit — each option maps to config; `format: mp4` sets the right file type. Live — a 60fps
  cursor-on take and a 16:9 take come out at the requested fps/size.

### Step 5: the timed convenience + status + cleanup
- `screen.record({seconds})` auto-stop; `screen.record.status`; ensure a stream always finalizes (stop
  on app quit / port teardown, so a recording can't leak like the mic did — reuse the 0.5 teardown seam).
- **Test:** unit — status shape, elapsed math. Live — timed take stops itself; killing the owning port
  mid-record finalizes the file (no orphaned stream).

### Step 6: `fit: contain` letterbox (deferred slice)
- If `SCRecordingOutput` can't letterbox natively, add a compose step (an `AVAssetWriter` consumer that
  draws the cropped frame into a padded canvas). Scoped separately because it is the one case needing a
  custom pipeline.
- **Test:** live — a `contain` take of a non-16:9 target comes out 16:9 with bars, not stretched.

### Step 7: live end-to-end (the spec's director examples)
- Run the three shot-list examples (say-it-see-it, coordination two-port frame, synth hero with system
  audio + cursor at 60fps) in Port42Dev; confirm each produces a correctly-sized, correctly-audio'd clip.

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
