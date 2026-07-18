# RCA: ai.complete promise never settles on cancel

Status: analysis, validated against code + a live Port42Dev trace. No fix applied yet.

## 1. Symptom (observed, not inferred)

In Port42Dev :4243, a web port's `port42.ai.complete(...)` is cancelled mid-stream via the newly
exposed `job.cancel()`. Live stepwise trace:

```
step3: cancelRes={"ok":true}  count=1     <- ai.cancel returned ok; the engine WAS cancelled
step4: afterWait=1                          <- tokens stopped (count stayed 1)
step5: (never reached)                      <- the ai.complete promise never resolves OR rejects
```

So cancel correctly stops the stream, but the JS promise for that call dangles pending forever.
`_pending[callId]` and `_tokenCallbacks[callId]` also leak (only cleared in `_resolve`/`_reject`).

## 2. How a streaming call is supposed to settle (the chain of custody)

```
JS call(): _pending[id]=resolve  --postMessage-->  PortBridge.handleMethod stream branch
  Task { try await runBridgeStream(...) }                                (PortBridge.swift)
    runBridgeStream -> method.run =                                      (BridgeMethods.swift)
      withTaskCancellationHandler {
        withCheckedThrowingContinuation { cont ->
          collector = LLMStreamCollector(cont, engine); backend.send(delegate: collector)
        }
      } onCancel: { backend.cancel() }
  do  { value = await ... } -> resolveCall(id)   -> JS _resolve(id)  -> _pending settles
  catch BridgeError         -> rejectCall(id)    -> JS _reject(id)   -> _pending settles
```

The continuation is resumed by exactly one thing: `collector.finish()`, which is called only from the
engine's terminal delegate callbacks (`llmDidFinish` / `llmDidError`). Nothing else resumes it.

## 3. Hypotheses and validation

- **H1 — LLMEngine swallows the cancellation callback.** `urlSession(_:task:didCompleteWithError:)`
  at `LLMEngine.swift:520`: `if (error as NSError).code == NSURLErrorCancelled { return }`. On cancel
  the engine returns WITHOUT calling `llmDidError`. **VALIDATED (fact in code).** Contributing cause.

- **H2 — The continuation has no settlement path independent of the engine.** `onCancel` calls only
  `backend.cancel()`; nothing resumes `cont`. The only resume path is `collector.finish()` via an
  engine callback. So if the engine emits no terminal callback, `cont` is never resumed.
  **VALIDATED (code inspection).** This is the core defect.

- **H3 — `task.cancel()` makes the awaited continuation throw `CancellationError`, settling it.**
  A `CheckedContinuation` is NOT cancellation-aware: cancelling the task runs the cancellation handler
  but does not resume a pending continuation. The `try await` stays suspended. **REFUTED.** Corollary:
  the `catch is CancellationError` branch in PortBridge is currently DEAD CODE (nothing ever makes
  `runBridgeStream` throw `CancellationError`).

- **H4 — The code is fine; the unit test proves cancel works.** The passing `aiCompleteCancel` test
  used `ManualStreamBackend.cancel()` which DOES call `llmDidError`, so it settled via the engine path.
  It modeled a cooperative-cancel engine, not the real URLSession silent-cancel. **REFUTED — test gap.**

- **H5 — Is cancel the only way the continuation dangles?** Generalize: it dangles whenever the engine
  fails to deliver a terminal event after `send`. Cancel is the guaranteed case (H1). Others: an engine
  that dies/deallocs without a callback, or any future backend that does not honor "exactly one terminal
  event." **VALIDATED as a class**: the settlement contract is unenforced, cancel is just the reliably
  triggered instance.

- **H6 — Is this new in C3, or pre-existing?** The old `PortAIHandler` path also relied on
  `llmDidError` (suppressed on cancel) and its `ai.cancel` did `engine.cancel(); removeStream(); {ok}`
  without ever calling `rejectCall`. So the old port `ai.complete` promise ALSO dangled on cancel.
  **VALIDATED — pre-existing bug**; C3 faithfully preserved it (that is the compat-preservation cost).

- **H7 — Is the never-reject `{error}` convention (JS `_reject` does `resolve({error})`) the cause?**
  No. Even with the `{error}` convention, IF `rejectCall(id)` were called on cancel, `_pending[id]`
  would settle (as `{error}`), and the shim's `if(r.error) throw` would run. The hang is the ABSENCE of
  any settle call, not the shape of the settle. **REFUTED as a cause — orthogonal issue** (see §6).

## 4. Root cause

Layered, most-fundamental first:

1. **Core defect (architecture):** the streaming call's completion is owned by the engine, not by the
   bridge. The continuation can only be settled by an engine terminal callback. Cancellation is
   initiated by a different actor (the canceller, via `task.cancel()` -> `onCancel` -> `engine.cancel()`)
   that KNOWS the call is over, yet has no way to settle the continuation itself. A `CheckedContinuation`
   is not cancellation-aware (H3), so the await hangs and the JS promise never settles.

2. **Contributing defect (engine):** `LLMEngine` suppresses `NSURLErrorCancelled` (H1), guaranteeing the
   terminal callback is absent exactly on cancel — so the core defect is always triggered by cancel.

3. **Test defect:** the stub modeled cooperative cancel (H4), hiding the real silent-cancel semantics.

## 5. The core vs what plugs in (the invariant this violates)

**The core** is a settlement contract: a streaming call has exactly one terminal outcome —
`resolved | error | cancelled` — and the core (`runBridgeStream` + `LLMStreamCollector`) must guarantee
that outcome fires exactly once, regardless of the plug's behavior.

**What plugs in** is the `LLMBackend`. Its honest contract is: after `send`, it emits at most one
terminal delegate event (`finish`/`error`); after `cancel()` it emits NOTHING. Given that contract,
**cancellation settlement is the core's job, not the plug's** — the current design wrongly delegates it
to the plug. The adapters (port JS, gateway, tool-use) are the third layer: they only render the
core's outcome. They cannot render an outcome the core never produces.

The defect is a layering violation: the core depends on the plug to signal a lifecycle event
(cancellation) that the core itself initiated.

## 6. Explicitly orthogonal (do NOT bundle): the never-reject `{error}` redesign

The compat item (JS `_reject` does `resolve({error})`; each shim does `if(r.error) throw`) is a SEPARATE
root (H7). It is about the SHAPE of a settle, not the ABSENCE of one, and it does not cause this hang.
It is worth doing (it de-risks the big-bang Proxy) but as its own change with its own RCA/tests. Bundling
it here would repeat the mistake of conflating two roots.

## 7. Fix that treats the root (proposed, not yet applied)

Core-owned, deterministic settlement on cancel, independent of the engine:

1. **Core:** in `runBridgeStream`'s cancel handler, settle the continuation deterministically. Hoist the
   collector so `onCancel` can call `collector.cancelIfPending()` (resume once with `CancellationError`)
   in addition to `backend.cancel()`. The engine call becomes "stop the network," not "please settle me."
2. **Collector:** add `cancelIfPending()` -> `finish(.failure(CancellationError()))`. `finish` is already
   exactly-once, so a late engine callback (if any) is a no-op. Guarantees exactly-one terminal outcome.
3. **Adapter (PortBridge):** make `catch is CancellationError` real: `rejectCall(callId, "cancelled")`,
   so the JS promise settles (rejected) and `_pending`/`_tokenCallbacks` are cleared. (Today: dead code.)
4. **Plug contract:** document that `LLMBackend.cancel()` need not emit a terminal event; the core owns
   cancellation settlement. `LLMEngine:520` can stay (swallow) since the core no longer depends on it.
5. **Test that reproduces (the missing coverage):** a `SilentCancelBackend` whose `cancel()` does NOT
   call the delegate (models URLSession). Assert: cancelling the Task settles the promise as cancelled,
   `activeStreamCollectorCount` returns to 0, and no hang. This test fails on today's code and passes
   after the fix.

## 8. Residual risks (tracked, not fixed here)

- Non-cancel silent death (engine deallocs/hangs with no terminal callback) still dangles (H5). A
  deinit/timeout safety net on the collector would close the class fully; out of scope for this fix,
  worth a backlog note.
- The gateway and tool-use adapters (C4) will share `runBridgeStream`, so the core fix protects them
  too, but each needs its own cancel/settle verification when wired.
