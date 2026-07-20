# Plan: Phase 3 — the real principal (stop flattening the authenticated identity)

*2026-07-17, branch shell-s1. Status: **SHIPPED** — steps 2-4 landed in 157439c (2026-07-17); the
remainder (the PermissionRequester collapse, the port-principal resolution to its creator, the live
two-caller proof, docs) landed 2026-07-19 per `plan-phase3-gate-matrix.md`, which records the GM
decisions and the acceptance results. This file stays as the design rationale. Test only in
Port42Dev (:4243).*

---

## 0. Decisions locked (GM, 2026-07-17)

- **Stable local principal.** A local `curl` to the gateway has no client identity, so it gets ONE stable
  principal id, `local-http`. The gateway assigns it; it is not per-call and not a truncated prefix.
- **No migration / no backward compatibility.** Old label-keyed grants drop. The `remoteAllow*`
  Always-Allow device settings (UserDefaults booleans) are untouched, so gateway device access is
  unaffected. A real caller re-grants once after upgrade. This removes the plan's original migration step
  and its "silent-drop guard" test.

## 1. Goal

Permission grants key on **who is calling**, not on a display label. Two principal cases, both correct:

- **Local HTTP** (curl / Claude Code on this box): principal id `local-http`.
- **Remote WS peer** (tunnel / external CLI): the authenticated `senderId`.

The human label survives only as `Principal.displayName` (and `ToolExecutor.createdByName`), never as a
permission key. A lost or dismissed prompt must always remain re-requestable, never cached as a silent
permanent deny (ties to the "permission prompt lost when a port pops in" bug in `summer2026-todo.md`).

## 2. What Phase 2 already did (do NOT redo)

- The registry path already builds `Principal(id: senderId, kind: .peer)` (`ToolExecutor.swift:1222`) and
  `runBridgeMethod` keys `companionPermissions` on `principal.id` (`BridgeDispatcher.swift:35`).
- The in-app companion path keys on the companion id; port JS keys on the port id. Both correct, untouched
  by this phase.
- `ToolExecutor` already separates identity from display: `createdBy` (the perm key) and `createdByName`
  (the card label) are distinct fields (`ToolExecutor.swift:11-13,38-39,86-87,134-135`).

The remaining flattening is one gateway edit plus three Swift edits: the gateway's synthetic per-call id,
the label minted in `onCallReceived` (`:1108`), the old fallback executor keyed on that label (`:1201`),
and the registry `Principal.displayName` (`:1222`). Plus one **display consumer** to update so it does not
show the raw new id: `ShellDesktop.swift:1321-1327` `who(_:)` maps the identity string for the port
version-history row and today special-cases `"remote-http"`; after the change a local caller's id is
`local-http`, which no longer matches, so it would render the raw token.

**Note — this is a real bug fix, not a rename.** Today the registry path keys local HTTP on the
unique-per-call `senderId`, so a wired gated method (e.g. `screen.capture`) NEVER persists a grant for
local curl and re-prompts every call; only the old path persisted, via the stable `remote-http-cal` label
bucket. The two local paths are inconsistent now. Step 5.2 (persistence across relaunch) is what proves
the gateway edit is load-bearing, not cosmetic.

## 3. Load-bearing facts verified in code (so the plan is safe)

- HTTP response routing keys on `callID` (`gateway.go:946`, `httpCallbacks[env.CallID]`), checked BEFORE
  `TargetID`. So making `SenderID` stable does not break local response delivery, and concurrent local
  calls stay disambiguated by their unique `callID`.
- WS peer calls already arrive with `env.SenderID = sender.ID` (`gateway.go:931`), the authenticated
  connection id, stable per peer.
- `routeResponse` for a WS peer uses `TargetID`; the host reply sets `resp.targetId = senderId`
  (`SyncService.swift:722`). For local HTTP that `TargetID` is `local-http` but is unused (callID path
  short-circuits), so no collision.

---

## Step 1 — Preflight audit (no code; produces the safety facts)

**Do.** Enumerate which methods still run on the old switch (not `wired` in the registry) and, for each,
whether it uses `createdBy` for **attribution/display** rather than as a key. Known extracted-and-wired
(so their old-path copies are dead): relationship memory (crease/fold/position), storage, ports core,
identity/spaces/companions/messages/bus, files, headless devices, and the wired live-device wrappers
(screen.capture/windows, camera, notify, automation, audio). Known still-on-old-path:
`audio.capture`, camera/screen stream, browser sessions, live port `push`/`exec`/`manage`/`create`,
`rest.call`.

**Test gate.** A written list (in the PR / commit message) of every old-path method and a yes/no on
"reads `createdBy` for display." Confirm none of the still-live old-path methods attribute by `createdBy`
(the `createdBy`-attributing sites at `ToolExecutor.swift:711,1133,1145-1146` all belong to
extracted-and-wired methods, so they are dead on the old path). If the audit finds a live one that does,
it is handled by passing `createdByName` (Step 3), not by keeping the id as a label.
**Done when:** the list exists and shows no live old-path method depends on `createdBy` as a display
string.

---

## Step 2 — Gateway: stable local `SenderID`

**Do.** In `gateway/gateway.go`, `HandleHTTPCall`:
- Keep `callID := "http-" + <nanos>` (response routing only).
- Set the forwarded envelope's `SenderID` to the stable constant `"local-http"` instead of
  `"http-caller-" + callID` (`gateway.go:849,861`).

**Test gate (Go, before any Swift change). This is NEW scaffolding, not a one-line extension.**
`gateway_test.go` mounts only `/ws` (`setupTestServer:34-40`); there is no `/call` route, no
host-peer / `globalHostID` helper, and no existing `HandleHTTPCall` test. So the test must:
- Mount `/call`; connect a WS peer that identifies with `is_host:true` to populate `globalHostID`; run a
  mock host goroutine that reads the forwarded `call` and echoes a `response` with the matching
  `callId`/`targetId` (reuse the existing `dialAndRead` / `sendEnvelope` / `readEnvelope` helpers).
- Assert the envelope the host receives has `SenderID == "local-http"`.
- Concurrency: two overlapping HTTP calls (distinct `callID`s, same `SenderID`) each receive their own
  response (proves routing is keyed on `callID`, not `SenderID`).
- **Command:** `cd gateway && go test ./...`
**Done when:** both Go tests green; existing gateway tests still pass.

---

## Step 3 — Swift: key identity on the id, label only as display

**Do.**
1. `AppState.swift` `onCallReceived` (`:1106-1111`): stop constructing `"remote-\(senderId.prefix(8))"`
   as the executor identity. Keep `senderId` as the id. Derive a human `displayName`:
   `local-http` → "Local (gateway)"; a known peer → its display name if resolvable, else the id.
2. `RemoteToolExecutor.init` (`ToolExecutor.swift:1197-1201`): build the fallback executor with the id as
   the key and the label as display:
   `ToolExecutor(appState:, spaceId: nil, createdBy: senderId, createdByName: displayLabel)`.
   This makes the old-path perm key match the registry path (`senderId`), while the permission card still
   shows the friendly label via `createdByName`.
3. `RemoteToolExecutor.execute` registry branch (`:1222`): pass the same `displayName` into the
   `Principal` so both paths show one consistent label. Id stays `senderId`.

4. `ShellDesktop.swift:1321-1327` `who(_:)`: the version-history display maps the identity string and
   special-cases `"remote-http"` → "API / agent". Update it to also map `local-http` (and, if a peer,
   prefer the resolved display name) so the row never shows the raw token. Display-only, but a real
   consumer of the identity string.

No change to `Principal.swift` semantics is required; add a small display-name helper only if it reduces
duplication.

**Test gate (Swift Testing, headless — new `Tests/Port42Tests/BridgePrincipalTests.swift`).**
*Honest framing: `RemoteToolExecutor.internalExecutor` and `ToolExecutor.grantedPermissions` are `private`
(`:1195,:20`); `@testable` exposes `internal`, not `private`, so the edit cannot be asserted by reaching
in. These unit tests cover the keying MECHANISM and `Principal`/`displayName` construction; the real proof
of the three edits is Step 2 (Go, the gateway id) + Step 5 (the live matrix). Do not let a trivially
passing keying assert stand in for the edits.*
- **Construction:** the identity builder yields id `local-http` for the local case and id `== senderId`
  for a sample peer id, with the friendly label in `displayName`; never `remote-<prefix>` as an id.
- **Keying mechanism (already-correct, pinned as a guard):** `saveCompanionPermissions([.screen],
  createdBy: peer-A, spaceId: nil)`, then assert `companionPermissions(createdBy: peer-B, ...)` excludes
  it and `peer-A` still resolves it under `portPerms.peer-A.global`.
- **Old-path keying (observable proof of edit #3):** `saveCompanionPermissions([.screen], createdBy:
  peer-A, ...)`, construct `RemoteToolExecutor(appState:, senderId: peer-A, senderName: "friendly")`, and
  assert a gated old-path call through it does NOT re-prompt (grant restored under the id key), whereas the
  same grant stored under the label key would not restore. Round-trips through the public perm API only.
- **Command:** `swift test --filter BridgePrincipal`
**Done when:** all green, and the existing bridge suites (`swift test --filter Bridge`) still pass with no
regression.

---

## Step 4 — Negative gate (the label can never be a key again)

**Do.** Add a guard so no authorization path reconstructs a label identity.

**Test gate.**
- Assert `remote-\(` no longer appears as an identity/key CONSTRUCTOR in `Sources/Port42Lib/` (the label
  may survive only as a `displayName`, never fed to `companionPermissions`/`saveCompanionPermissions` or
  `Principal.id`).
- Also grep for `remote-http` as a CONSUMER (not just the constructor) so a stale string match like
  `ShellDesktop.who()` cannot silently mis-render the new `local-http` id. Every hit must be a deliberate,
  updated mapping.
- **Command:** `grep -rn 'remote-\\(' Sources/Port42Lib` (constructors) and `grep -rn 'remote-http'
  Sources/Port42Lib` (consumers), reviewed; optionally pinned as an assertion in `BridgePrincipalTests`.
**Done when:** the gate is green and intentional (a comment explains what it protects).

---

## Step 5 — Build and the live two-caller proof (Port42Dev :4243)

**Do.** `./build.sh` (rebuilds the Go gateway and the Swift app + re-signs), relaunch
`open .build/Port42Dev.app` (ask GM to click the startup Keychain prompt). Then run the acceptance
matrix. A **second stable identity** is required because local curl is now one principal; use a tiny WS
client that identifies as a distinct `sender_id`.

**WS second-caller mechanism.** Connect to the dev gateway WS endpoint `ws://127.0.0.1:4243/ws`, send an
`identify` envelope with `sender_id: peer-test-B` and `is_host` UNSET (setting it would overwrite
`globalHostID`, `gateway.go:280`), then send a `call` envelope for a gated method with an EMPTY
`channel_id` (a global-host call routes to `globalHostID` with no channel membership, `gateway.go:901-904`;
there is no "join" step). Localhost skips auth (`gateway.go:446-447`), so no token is needed. Envelope keys
are `sender_id` / `sender_name` (`SyncService.swift:85-86`); the call reaches `onCallReceived` via
`handleCall` (`SyncService.swift:706-714`). A ~30-line node/python `websocket` script.

**Test gate (the acceptance matrix).**
1. **Distinct callers, distinct decisions.** From local curl (`local-http`) call a gated method
   (e.g. `screen.capture`) and grant it. From `peer-test-B` call the same method: it **still prompts**
   (separate bucket, no shared label). Confirms the core behavior change.
2. **Persistence across relaunch.** Relaunch Port42Dev; from local curl call the gated method again: **no
   prompt** (grant persisted under `portPerms.local-http.global`).
3. **No regression on the shipped paths.** `ports.list` / `port.getHtml` over local curl still return the
   same JSON; an in-app companion and a port's JS still work (registry path unchanged).
4. If any path hangs, `sample Port42Dev <pid>` before killing (per the parked demo-freeze note).
**Done when:** the two callers get separate decisions, the local grant survives a relaunch, and the
shipped read paths are unregressed.

---

## Step 6 — Docs and close-out

**Do.** Mark this phase DONE in `plan-api-unification.md` (replace its stale Phase 3 section with a pointer
to this file and the shipped result). Note the connection to the permission-prompt-lost bug: Phase 3 keeps
a denied/lost prompt re-requestable and never persists a denial.

**Test gate.** N/A (docs). **Done when:** the two docs agree and the shipped behavior is recorded.

---

## Files touched

- `gateway/gateway.go` (`HandleHTTPCall`), `gateway/gateway_test.go`
- `Sources/Port42Lib/Services/AppState.swift` (`onCallReceived`)
- `Sources/Port42Lib/Services/ToolExecutor.swift` (`RemoteToolExecutor.init` / `.execute`)
- `Sources/Port42Lib/Views/ShellDesktop.swift` (`who(_:)` display mapping, `:1321-1327`)
- `Sources/Port42Lib/Services/Principal.swift` (small display-name helper, only if it reduces duplication)
- `Tests/Port42Tests/BridgePrincipalTests.swift` (new)

## Risk

Low, now that migration is dropped. Watch-items, all mitigated:
- The gateway `SenderID` change — response routing is `callID`-keyed (verified §3), so stable ids are safe.
- The old-path `createdBy` swap — the still-live old-path methods do not attribute by `createdBy`
  (Step 1 audit gate), and `createdByName` carries the label, so the card display is preserved.

**Deliberate behavior changes to record (not accidents):**
- **Shared local-http grant bucket.** All local processes hitting the gateway now share ONE principal and
  ONE permission bucket, so a grant made by one local tool applies to every local caller thereafter. This
  crosses no new privilege boundary (local HTTP is already unauthenticated: any local process can call the
  gateway today), but it is a real change from the per-call churn and is the intended meaning of "one
  stable local principal."
- **`remoteExecutors` cache collapse.** `AppState.remoteExecutors` (`:838,1108-1109`) is keyed on
  `senderId`. It collapses from one entry per HTTP call (an unbounded-growth leak today) to a single
  `local-http` entry — an incidental fix, worth noting so it is not mistaken for a regression.

## Sequencing

Self-contained; does not depend on the unification tail. Ship as one arc: Steps 1-4 land with unit/Go
tests green, Step 5 is the live acceptance gate, Step 6 records it. After this, the principal is the
shared prerequisite the stacked items (MCP-as-capability, chrome-as-ports, publish-as-viewer) build on.
