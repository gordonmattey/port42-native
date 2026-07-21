# Exhaustive port teardown (the mic/speech leak, and its class)

Spec and step plan for backlog 0.5: "closing a port leaks its mic / speech recognition forever."
The narrow bug is a live microphone that never stops after its port closes. The real target is the
class: a port must release **every** ongoing resource it acquired, and a new capability must not be
addable without teardown.

## Problem and root cause

Two defects, both confirmed in code.

1. **Teardown is gated on the bridge deallocating, and it cannot.** `PortBridge.attach` registers the
   bridge as the `"port42"` `WKScriptMessageHandler` (`config.userContentController.add(self, ...)`).
   `WKUserContentController` retains its handlers strongly, and nothing anywhere calls
   `removeScriptMessageHandler`. So after `close()` the webview's content controller still pins the
   bridge, its `deinit` fires late or never, and the `deinit`-driven device stops never run. The device
   bridges hold the owner `weak`, so they are not the blocker; the message-handler retain is.

2. **Teardown is not exhaustive.** The `deinit` stops exactly three resources (audio capture, camera
   stream, screen stream). Four more ongoing resources a port can acquire have no owner-keyed teardown
   and already slipped past:
   - `audio.speak` (AVSpeechSynthesizer), long text keeps speaking.
   - `audio.play` (AVAudioPlayer), playback keeps going.
   - `browser.open` sessions (an out-of-band WKWebView per session); takes an `owner` but has no
     `ifOwner` release, and browser is not in `deinit` at all.
   - a running `ai.complete` loop (`streamTasks`); `suspendAI()` is called on park and background, not
     on close.

Result: closing a port can leave the mic, the speech recognizer, a speaking synthesizer, an audio
player, a browser session, or a generation loop running, with no surface left to stop them.

## Identity decision: key teardown on the stable port id, not `ObjectIdentifier`

Today the owner match uses `ObjectIdentifier(PortBridge)`. Implications that rule it out for the
general fix:

- **Ephemeral.** It exists only while that exact instance lives, cannot be persisted or reconstructed,
  so teardown can only be fired by code holding the instance. No app-side or gateway-side "stop port X".
- **Address reuse.** A freed bridge's address can be reused by a new bridge, so a stale identity can
  match the wrong instance, precisely in the leak window.
- **Fails the backlog's own requirement.** The item requires "a stop reachable from the app (and ideally
  the gateway), keyed by port id". `ObjectIdentifier` is not the port id.
- **Instance is not the logical port.** A port re-created on restart is a new bridge and a different
  identifier for the same logical port.

Decision: key teardown on the port's stable id, which is `PortBridge.messageId` (verified equal to the
port id / panel udid at every registration site: `registerTiledPort`, `addTiledTerminalPanel`,
`addTiledBrowserPanel`, `registerInlinePort`, `popOut`, and `restoreFromDB`). This is stable across
instance re-creation, is a unique UUID (no address reuse), and can be referenced by the app and gateway
for a future kill switch. The weak `owner` reference stays for event delivery (transcription/frame
pushes); only the match key changes.

Assumption to hold during implementation: a capture-capable port always has a non-nil `messageId`
(captures are started by tiled or inline ports, which do). A port with a nil `messageId` cannot be
targeted by id, and also does not start captures, so it is not a gap in practice. Flag any counterexample.

## Design

A single teardown seam, exhaustive by construction.

- **Protocol.** `protocol PortOwnedResource { func releaseIfOwned(byPortId id: String) }`. Synchronous,
  so the fast, privacy-sensitive stops (the mic) run in the caller's stack. A bridge whose real stop is
  async (screen's `SCStream`) does its async work in an internal `Task` inside `releaseIfOwned`, so the
  protocol stays synchronous while the SCStream tears down shortly after.
- **Conformers.** `AudioBridge`, `CameraBridge`, `ScreenBridge`, `BrowserBridge`. Each releases
  everything it holds for that port id (audio releases capture and speak and play; browser closes all of
  that port's sessions).
- **Owner id recorded at start.** Every start-with-owner records `owner?.messageId` as its owning port
  id. Add this to the currently untracked starts (`audio.speak`, `audio.play`, browser sessions); change
  the three existing ones from `ObjectIdentifier` to the port id.
- **Registered list.** `AppState.deviceBridges: [PortOwnedResource]` holds the conformers.
  `AppState.releaseAcquisitions(portId:)` iterates the list. Move `BrowserBridge` onto `AppState`
  (a `let browserDevice = BrowserBridge()`) so `buildBridgeRegistry` uses `state.browserDevice` and it
  joins the list like the others.
- **One funnel, two triggers.** `PortBridge.releaseAcquisitions()` (an explicit `@MainActor` method)
  calls `appState.releaseAcquisitions(portId: self.messageId)` and also `self.suspendAI()` (cancel a
  running generation). `PortWindowManager.close()` and `stop()` call it before `destroyWebView`. The
  `deinit` backstop captures `self.messageId` as a plain value and funnels to the same
  `AppState.releaseAcquisitions(portId:)`.
- **Break the retain cycle.** `destroyWebView` calls `removeScriptMessageHandler(forName: "port42")` and
  `removeAllUserScripts()` on the webview's content controller, so the bridge can dealloc and the
  `deinit` backstop fires for non-close death paths (quit, sign-out, restore-replace). This also frees
  the webview itself, which helps the never-evicts item.

## Invariants and principles preserved

- **Identity safety.** Release is keyed to one port id, so another port's resources are never collateral.
- **Layering.** Stop logic stays on each device bridge; `PortBridge` orchestrates; `PortWindowManager`
  (the lifecycle owner) triggers via the port's own bridge and never reaches into device bridges.
- **Idempotence.** `releaseIfOwned` is a no-op when the port owns nothing, so calling it from both
  `close()` and the `deinit` backstop is safe.
- **Scope.** This change covers close and stop (the leak). Whether background should also drop the mic is
  a separate policy question (background keeps `suspendAI` today); noted as a follow-up, not folded in.

## Out of scope (follow-ups)

- The app/gateway kill switch and the live capture indicator (backlog requirement #3). The port-id
  keying is the enabler; the UI is a separate change.
- Backgrounded-port capture policy (stop the mic on background, not just on close).

## Implementation steps, with testing at each step

Each step builds and runs green before the next. Test in Port42Dev only. Use exact suite names.

### Step 1: introduce the protocol, re-key the three existing bridges to port id

- Add `PortOwnedResource`. Change `AudioBridge`/`CameraBridge`/`ScreenBridge` to record the owning
  `portId: String?` at start (from `owner?.messageId`) and add `releaseIfOwned(byPortId:)`. Keep the old
  `stopX(ifOwner: ObjectIdentifier)` temporarily or replace its callers in the same step.
- **Test (`AudioBridgeTests`, `CameraBridgeTests`, `ScreenBridgeTests`):** with no live capture, assert
  the ownership guard by id: `releaseIfOwned(byPortId: "other")` is a no-op; the matching id path calls
  the stop. Idempotence: two calls are safe. Live capture is not required for the guard logic.

### Step 2: add owner tracking and release to the uncovered resources

- `audio.speak` and `audio.play` record the owning port id at start; `AudioBridge.releaseIfOwned` also
  stops the synthesizer and player for that id. `BrowserBridge` records each session's owning port id
  and `releaseIfOwned` closes all sessions for that id.
- **Test:** `AudioBridgeTests` asserts speak/play register an owner and are stopped by
  `releaseIfOwned(byPortId:)` for the owner, untouched for a non-owner. `BrowserBridgeTests` asserts a
  session opened by port A is closed by `releaseIfOwned("A")` and a port-B session survives.

### Step 3: the registered list and the central entry point

- Add `let browserDevice = BrowserBridge()` to `AppState`; point `buildBridgeRegistry` at
  `state.browserDevice`. Add `AppState.deviceBridges: [PortOwnedResource]` and
  `AppState.releaseAcquisitions(portId:)` that iterates it.
- **Test (`AppStateTests` or a new `PortTeardownTests`):** `releaseAcquisitions(portId:)` calls
  `releaseIfOwned` on every registered bridge; a stubbed pair of bridges records which port id each was
  asked to release, proving the fan-out and that only the target id is passed.

### Step 4: wire the funnel from close and deinit, plus the AI loop

- `PortBridge.releaseAcquisitions()` calls `appState.releaseAcquisitions(portId: messageId)` and
  `suspendAI()`. `PortWindowManager.close()` and `stop()` call it before `destroyWebView`. Re-key
  `deinit` to capture `self.messageId` and funnel to the same entry point.
- **Test (`PortTeardownTests`):** a fake AppState (or a spy on `deviceBridges`) shows that
  `PortWindowManager.close(id)` triggers `releaseAcquisitions` for that port's id, and that a running
  `streamTasks` entry is cancelled (assert `streamTasks` empty after close).

### Step 5: break the WKScriptMessageHandler retain cycle

- `destroyWebView` removes the `"port42"` script message handler and all user scripts before dropping
  the webview.
- **Test (`PortTeardownTests`, or `PortWindowManagerTests` if present):** hold a `weak var` to a port's
  `PortBridge`, `close()` the port, drain the run loop, and assert the weak reference is nil (the bridge
  deallocated). This is the direct proof the cycle is broken and the `deinit` backstop can fire.

### Step 6: enforcement (a new capability cannot skip teardown)

- **Test (`PortTeardownTests`):** assert every device bridge that exposes a start-with-owner conforms to
  `PortOwnedResource` and is present in `AppState.deviceBridges`. Since Swift has no runtime reflection
  over stored properties, enforce by a fixed inventory check: the test lists the expected conformers and
  fails if `deviceBridges.count` or types drift, with a comment pointing a future author to add their new
  bridge here and to the list. This converts "someone forgot teardown" from a silent leak into a red test.

### Step 7: live verification (the actual mic-down)

- In Port42Dev, open a mic port (`audio.capture({transcribe:true})`), confirm capture, then close the
  port. `sample Port42Dev` and grep for `SFLocalSpeechRecognitionClient` / `com.apple.Speech`; assert
  the recognizer stacks are gone. Repeat for a speaking port, a playing port, a browser-session port, and
  a self-generating port (assert no new `port_versions` after close). This is the end-to-end proof the
  headless unit tests cannot give (TCC-gated capture).

## Risks and rollback

- **Async screen stop inside a sync protocol method.** The SCStream stop is fire-and-forget in a `Task`.
  If ordering ever matters, `AppState.releaseAcquisitions` can gain an async variant the close path
  awaits; not needed for correctness of the mic stop, which is synchronous.
- **`removeAllUserScripts` on a shared config.** Confirm no port relies on user scripts surviving a
  `destroyWebView` that is followed by a re-create in the same instance (`restart` re-runs `attach`,
  which re-adds them, so it is fine). Covered by Step 5's dealloc test plus the existing render tests.
- **Rollback.** Each step is independent and behind its own tests. Reverting Step 5 alone restores the
  old retain behavior without touching the exhaustiveness work; reverting the whole set returns to the
  three-resource `deinit`.

## Relationship

Same class as the gateway-outlives-app fix and the never-evicts items: teardown that only runs on the
happy path is not teardown. The port-id keying is the enabler for the app/gateway kill switch and the
live capture indicator (backlog requirement #3), and for a future "stop everything this port holds" from
anywhere. Pairs with the presentation-state item (a backgrounded port that should also idle its devices).
