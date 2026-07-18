# Continue — PORT42 shell-s1 (API/tool-use unification)

Branch **shell-s1**, in `/Users/gordon/Dropbox/Work/Hacking/workspace/portal-42/port42-native`.
Everything below is committed + pushed through **dd412bc** unless noted.

## Read first
- `docs/plan-api-unification.md` — the map. **Phase 2b (the tail)** has the 10-item test matrix; every
  remaining method has a defined test that must exist before the method is touched.
- `docs/plan-phase3-principal.md` — Phase 3 (done).
- `docs/summer2026-todo.md` — roadmap (restore bugs, #5/#6, filesystem-service, publish, etc.).

## Rules (hard)
- **Test in Port42Dev ONLY** (`com.port42.dev`, gateway **:4243**). Never prod (`:4242`) without an
  explicit say-so. Live-check via `curl -s http://127.0.0.1:4243/call -d '{"method":...,"args":...}'`.
- **Don't commit unless asked**; when asked, commit + push to `shell-s1`. **Commit incrementally** so
  every green step is safe. **No em dashes** in prose. Fix root causes.
- Build with `./build.sh` (dev) or `./build.sh --release --no-dmg` (a runnable prod app, no notarize).
  Relaunch = `open .build/Port42Dev.app`. A **Keychain prompt** at startup is human-only — ask GM.
- **Commit messages: use a heredoc, no backticks** (zsh runs backticked words as commands).

## Shipped this arc (committed + pushed)
- **Unification Phases 0-2**: one `BridgeValue`/`BridgeArgs`/`Principal`/`BridgeRegistry` contract;
  ~40 methods in ONE registry (`BridgeMethods.swift`); all three paths (gateway `RemoteToolExecutor`,
  in-app `ToolExecutor.execute`, port JS `PortBridge.handleMethod`) dispatch registry-first via
  `AppState.runBridgeMethod` (`BridgeDispatcher.swift`) with old-path fallback. Live-verified.
- **Phase 3 — the principal**: local gateway callers get a stable `local-http` id (was per-call); grants
  key on identity, not a label. Fixed a CallID collision under concurrency (`gateway.go`). Verified live.
- **#5 port.exec** (`PortExecJS`, awaits promises + marshals objects), **background-survives-restart**
  (`fetchPortHtml` falls back to `port_versions`).
- **Tail batch 1**: `port.create/push/exec/manage` + `terminal.exec` extracted, verified live.
- **Item 8 (streaming) steps 1-3a**: `BridgeStreamMethod` contract, `runBridgeStream` dispatcher,
  `LLMStreamCollector` (delegate → yield + final). 7 tests green.

## RESUME HERE — item 8, step 3b (register real ai.complete)

Goal: `ai.complete`/`ai.cancel` join the streaming registry so they leave `PortBridge`'s special case.

1. **Generalize backend/model resolution off PortBridge.** `resolvePortAIBackend(state:)`,
   `resolvePortAIModel(state:)`, `makeLLMBackend(for:)`, and `portAIMaxTokens` (=16384) live on
   `PortBridge` (`PortBridge.swift` ~1402 `handleAIComplete`). Move them to `AppState` (or a helper) so a
   registry body can build the engine without a PortBridge. The `isSuspended` token-burn guard is
   port-instance state: resolve the port from `principal.id` (`portWindows` / `findInlineBridge`) and skip
   for non-port principals.
2. **Register `ai.complete`** in `buildBridgeStreamRegistry(appState)` (`BridgeMethods.swift`, currently
   empty). Body: guard suspended; build messages (multimodal if `images`); then
   ```
   return try await withCheckedThrowingContinuation { cont in
       let collector = LLMStreamCollector(yield: yield, continuation: cont)
       // retain collector for the call's lifetime; register for cancel (see 3)
       try? engine.send(messages:..., systemPrompt:..., model:..., maxTokens:..., delegate: collector)
   }
   ```
   `paramNames: ["prompt", "options"]`, `permission: .ai`.
3. **`ai.cancel` via task cancellation.** Wrap the stream in a `withTaskCancellationHandler { engine.cancel() }`.
   The ADAPTER owns callId→Task: `PortBridge` maps its JS `callId` to the running Task; `ai.cancel(callId)`
   → `task.cancel()`. (callId is a port-JS-shim concept, so cancellation stays at the adapter.)
4. **Wire the adapters** to `runBridgeStream`: port JS `yield` → `pushToken(callId, token)`, final →
   `resolveCall`, thrown `BridgeError` → `rejectCall` (**this is the never-reject fix**); gateway → chunked
   or collect; tool-use → collect into final text.
5. **Tests:** unit stubs already green (`BridgeStreamTests`). Live in Port42Dev: a port `ai.complete`
   streams tokens in and resolves; `ai.cancel` mid-stream stops further tokens; an error rejects (the
   port's `catch` runs). Pattern to mirror: `PortAIHandler.swift` + `handleAIComplete`.

## Then — the rest of the tail (plan-api-unification.md Phase 2b matrix)
Items 1-7, 9, 10 each have a defined test in the matrix; then **delete the two old switches** (the
close-out gate: full bridge suite + live cross-path matrix green after deletion, grep for gone case
labels). Sequence: finish item 8, then 1-7/9-10, then switch deletion.

## Uncommitted, not mine (left in the tree)
The earlier CONTINUE session also touched `docs/membrane/membrane-architecture.md` + new
`docs/membrane/plays-with-others.md` (a packs/plugs/canvas architecture edit) and added a
"permission prompt lost when a port pops in" bug note to `summer2026-todo.md`. Review + commit or drop.
