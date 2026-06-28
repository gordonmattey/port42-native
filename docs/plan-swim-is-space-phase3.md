# Swim → Space — Phase 3 detailed plan (UI teardown + `activeSwimCompanion` derivation)

**Scope of this phase:** remove swim-era code that is now either dead or redundant, *without
behaviour change*. Two parts:

- **Part A — delete dead views** (zero references): `SwimView`, `ChatHeader`, `SpaceHeader`.
- **Part B — collapse `activeSwimCompanion`** from a manually-maintained `@Published` field into a
  value **derived from `currentSpace`**, then delete `exitSwim` (its only purpose was clearing that
  field + `currentSpace`).

**Out of this phase:** dropping the `isSwim` column and the `Space.swim` factory (that's Phase 4),
and any sidebar/grouping redesign.

**Resolved decisions (2026-06-28):**
- **Delete `activeSwimCompanion` entirely.** It is a redundant *singular* special-case of an array we
  already maintain: **`spaceCompanions: [AgentConfig]`** (the current space's companions). A space has
  companions uniformly — 1 for a DM, N for a team space — so there is no separate "the DM companion"
  concept. No rename, no derived field, no `didSet` machinery.
- **`spaceCompanions` is the model** (already exists at AppState:677, repopulated on every space
  change at 1192/1701/2517/2535, already used by mention routing at 1962).
- **Keep `currentSpace`** as the active-space source of truth (not renamed to `activeSpace`).
- **Lock:** `lockApp` preserves `currentSpace`/`spaceCompanions`; nothing companion-specific to clear.

**Guiding invariant:** behaviour is preserved at every read site by mapping the singular
`activeSwimCompanion` to the equivalent expression over `spaceCompanions` (mostly
`spaceCompanions.first` / membership checks), with **one deliberate behaviour decision** at the
implicit-mention-routing site (below).

---

## Part A — delete dead views (no behaviour change)

Confirmed unreferenced anywhere except their own definitions (`grep 'SwimView|ChatHeader|SpaceHeader'`):

| View | File | Lines to delete | Note |
|------|------|-----------------|------|
| `SwimView` | `Views/SwimView.swift` | whole file (132 lines) | only the old per-companion DM view; its eye/inspector now lives in `PortPanelTitleBar` |
| `SpaceHeader` | `Views/ChatView.swift` | `165`–`293` (struct only) | **must preserve `MemberAvatar` at 294+** — still used by `PortPanelTitleBar` |
| `ChatHeader` | `Views/ContentView.swift` | `262`–`411` (MARK + struct) | next symbol is `// MARK: - Help Overlay` at 412 |

Risk: low. `swift build` will immediately fail if any reference was missed. Deleting `ChatHeader`
also removes its `activeSwimCompanion` read (ContentView:313) for free.

---

## Part B — delete `activeSwimCompanion`, use `spaceCompanions`

### Setters to DELETE (the field is gone)
- `startSwim` (2616): `activeSwimCompanion = companion`
- `selectSpace` (1673): `if space.type != "direct" { activeSwimCompanion = nil }`
- `lockApp` (2632), `powerOff` (2640), `resetApp` (2667): `activeSwimCompanion = nil`
- the `@Published var activeSwimCompanion` declaration (741)

### Read sites → `spaceCompanions` equivalent
`spaceCompanions` holds the current space's companions (1 for a DM). Map each site:

| Site | Today | Becomes |
|------|-------|---------|
| PortBridge `space.current` (361) | `if let companion = activeSwimCompanion, space.type=="direct"` | list `state.spaceCompanions` as members (already the right data) |
| PortBridge system prompt (1384) | `"private swim with X and \(companion)"` | describe via `state.spaceCompanions` (1 → "1:1 with X and <c>"; N → team) |
| SidebarView space row (204) | `activeSwimCompanion == nil && currentSpace?.id == space.id` | `currentSpace?.id == space.id` (space rows are non-direct, so the guard was redundant) |
| SidebarView companion row (335) | `activeSwimCompanion?.id == companion.id` | `currentSpace?.type == "direct" && spaceCompanions.contains { $0.id == companion.id }` |
| SidebarView friend row (370) | `activeSwimCompanion == nil && currentSpace?.id == dmId` | `currentSpace?.id == dmId` |
| SetupView first message (768) | `if let companion = activeSwimCompanion` | `if let companion = appState.spaceCompanions.first` (onboarding DM has exactly echo) |
| TransitionRoot (194) | `onChange(of: activeSwimCompanion != nil)` | `onChange(of: currentSpace?.type == "direct")` |

### The one behavioural decision — implicit mention routing (AppState:1971)
```swift
routeMentionsToTerminals(..., implicitCompanion: activeSwimCompanion)
```
`implicitCompanion` is who an un-`@`'d message routes to. Today that's non-nil **only in direct
spaces** (which have exactly one companion). Two options:
- **(A) Uniform (matches "same whether 1 or 1+ people"):**
  `implicitCompanion: chCompanions.count == 1 ? chCompanions.first : nil`. Any single-companion space
  (DM *or* a team space that happens to hold one companion) implicit-routes. Slightly *more* uniform;
  a real behaviour change for 1-companion team spaces. Also fixes the cross-space case (uses
  `chCompanions`, the correct space's companions, not the current one).
- **(B) Preserve exactly:** `implicitCompanion: (space.type == "direct") ? chCompanions.first : nil`.
  No behaviour change; keeps a `type=="direct"` check.

**DECIDED: (B)** — preserve exactly. `implicitCompanion: (space.type == "direct") ? chCompanions.first : nil`.
No behaviour change this phase.

---

## Part C — delete `exitSwim`

- Single caller: `deleteCompanion` (AppState:2565). Replace:
  ```swift
  if activeSwimCompanion?.id == companion.id { exitSwim() }
  ```
  with a check against the current space's companions (capture *before* the delete wipes membership):
  ```swift
  let wasViewingThisDM = currentSpace?.type == "direct"
      && spaceCompanions.contains { $0.id == companion.id }
  // ... existing delete work ...
  if wasViewingThisDM { currentSpace = nil; spaceCompanions = [] }
  ```
- Delete `func exitSwim()` (AppState:2623).

---

## Tests

### Existing coverage that CARRIES OVER (re-pointed off the deleted property)
- `SwimUnificationTests` Step 4: keep "startSwim sets currentSpace to the companion's direct space",
  "companion is assigned to its direct space after startSwim", idempotency — these already pin the
  real behaviour via `currentSpace` + membership, no `activeSwimCompanion` needed.
- `DirectSpaceLookupTests` Phase 2: `companionId(ofDirectSpaceId:)` + `getAgent` — unchanged.

### Tests to UPDATE/REMOVE (they reference the deleted `activeSwimCompanion` / `exitSwim`)
- `SwimUnificationTests`: "startSwim sets activeSwimCompanion" → **remove** (covered by the
  currentSpace + membership tests). "exitSwim clears activeSwimCompanion and currentSpace" →
  **rewrite** as "deleteCompanion of the open DM clears currentSpace". "selectSpace with regular
  space clears activeSwimCompanion" → **remove** (property gone).
- `SwimTests`: "Exit swim clears session" → **remove/rewrite** (no `exitSwim`). "Delete companion
  clears active swim if matching" → **rewrite** to assert `currentSpace == nil` after deleting the
  open DM's companion.

### NEW tests to add first (lock the array model)
- **"spaceCompanions reflects the current direct space"** — after `startSwim`, `spaceCompanions`
  contains exactly the companion (await the selectSpace settle, or assert via `getAgentsForSpace`).
- **"deleteCompanion of the open DM clears currentSpace"** — open a companion's DM, delete it, assert
  `currentSpace == nil` and no crash.
- **"deleteCompanion NOT in the open space leaves currentSpace intact"** — guard the `wasViewingThisDM`
  condition.
- **"implicit routing target is direct-only"** — a `direct` space yields its companion as the implicit
  target; a `team` space yields nil (decision B).

All use `DatabaseService(inMemory: true)` + `AppState` factory helpers (same pattern as
`SwimUnificationTests`).

---

## Build / verify gate
1. `swift build` green after Part A (catches any missed view reference).
2. `swift test` — the 7 pre-existing failures stay; **no new failures**; updated + new Phase 3 tests pass.
3. Manual smoke on the **peer** (fresh + returning):
   - open a companion → DM opens, eye/inspector + members work; un-`@`'d message still routes to the
     companion (mention-routing path through derived `activeSwimCompanion`);
   - switch to a team space → sidebar highlight correct, no implicit companion;
   - delete the companion whose DM is open → view clears (no crash, no stale row);
   - lock/unlock → restores the same space.

## Sequencing & commits
1. **Commit 1 — dead views.** Delete the 3 views, `swift build` + `swift test` green.
2. **Commit 2 — derive `activeSwimCompanion` + delete `exitSwim`.** Add new tests first, then the
   didSet derivation, delete setters + `exitSwim`, repoint `TransitionRoot` onChange, update the 2
   exitSwim tests. `swift test` green + peer smoke.

(Two commits so Part A's low-risk deletion is bisectable separately from the behavioural Part B.)
