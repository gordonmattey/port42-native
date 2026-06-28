# Swim → Space collapse — a swim *is* a space (full, north-star)

## Status / resume (2026-06-27)

**Decision (gordon): FULL collapse now.** There is no separate "swim" construct. A swim becomes a
normal space (small/private, membership-defined). Delete `isSwim` / `SwimView` /
`activeSwimCompanion` / the `swim-<companionId>` id format; migrate existing `swim-<id>` spaces +
their child rows to plain UUIDs; relationship memory keyed purely by `spaceId`.

**Why first (before the sidebar/scoping work):** the ambient-sidebar (#1), ports-scoped-to-space
(#2), and dock (#4) items must treat swims and team spaces *uniformly*. Doing them on top of the
swim special-case would entrench ~20 `swim-<id>` branches we'd then rip out. Collapse is the
foundation. (See `summer2026-todo.md` Priority.)

**ON RESTART — trust git + the tree, not the chat.** Run `git log --oneline -15`,
`grep -rn 'isSwim\|activeSwimCompanion\|swim-\\(' Sources/` and read the phase table below against
the tree before continuing. Commit after every phase; this is a data migration — never leave it
half-applied.

## Current state (mapped 2026-06-27)

A swim is **already a row in the `spaces` table**, just special-cased:

- `Space.swim(companion:)` (`Space.swift:45`) → `id: "swim-\(companion.id)"`, `type: "direct"`,
  `syncEnabled: false`, `isSwim: true`.
- `getRegularSpaces()` (`DatabaseService.swift:595`) filters `isSwim == false` → swims are excluded
  from the main space list and instead rendered as **companion rows** in the sidebar; entering one
  sets `activeSwimCompanion` and `ContentView` (`:313`) shows `SwimView` instead of `ChatView`.
- `startSwim(with:)` (`AppState.swift:2607`) upserts the swim space + `assignAgentToSpace` (so
  **membership already exists**: the companion is an agent-member; the human is implicit).
- **Relationship memory already keys on `(companionId, spaceId)`** — `fetchFold/Creases/Engravings/
  Position(companionId:spaceId:)` — where `spaceId` is the swim id. So the per-(companion,space)
  model is already general; the only "swim-ness" is the magic id + the `isSwim` flag + the separate
  UI path.

### Tables that store a swim's spaceId (the migration blast radius)

All carry `spaceId`, all FK → `spaces(id)` `ON DELETE CASCADE` (no `ON UPDATE`):
`messages`, `agentSpaces` (PK agentId,spaceId), `port_panels`, `port_storage`, `input_history`,
`companion_positions`, `companion_folds`, `companion_creases`, `companion_engravings`.
Plus `spaces.id` itself. (Also `UserDefaults` `lastActiveSwimCompanionId` / `lastSelectedSpaceId`.)

### The ~20 `swim-<id>` construction/parse sites to replace

- `Space.swift:47` (factory)
- `AppState.swift:448` (relationship preamble), `:1223` (routing companion lookup), `:1478`, `:2206`,
  `:2778`
- `SidebarView.swift:54`, `:316`
- `PortBridge.swift:846`, `:866`
- `DatabaseService.swift:1149` (`getLastSwimTime`) — note `:286` is a one-time legacy migration, leave
- `ToolExecutor.swift:142,164,194,215,245,264,281,301` (crease/engraving/fold/position read+write
  tools default their `spaceId` to `swim-<companionId>`)

## Target model

- A swim/DM is a **plain UUID space**, `type: "direct"`, with the human + one companion as members.
  No `isSwim`. "Find the DM with companion X" = a **membership query** (the `direct` space whose
  sole agent-member is X), not a derived id.
- Relationship memory attaches to a **`spaceId`** (any space). An N-member project space can
  accumulate fold/creases too — one mechanism. (Keying stays `(companionId, spaceId)`; for a DM
  there's one companion, for a team space each companion has its own.)
- Sync stays a per-space flag (`syncEnabled`) — a local companion DM stays unsynced; nothing about
  the collapse forces DMs to sync.
- **Optional** derived-id index `UUIDv5(sorted(human.id, companion.id))` is *only* a lookup
  optimization, NOT the identity. Skip unless the membership query proves slow.

## Decisions

- **D1 — migrate ids vs grandfather.** gordon chose **migrate `swim-<id>` → UUID** (clean end-state,
  no `swim-` anywhere). Executed as: insert new UUID space (copy, `isSwim` dropped) → `UPDATE` every
  child table `SET spaceId=new WHERE spaceId=old` → `DELETE` old space row (now childless, cascade
  safe). FK-safe with foreign_keys ON because the new parent exists before children move.
  *Safety fallback if the bulk update proves hairy in testing:* grandfather old ids (treat the
  `swim-` string as a meaningless historical id, only mint UUIDs for new DMs) — same functional
  end-state, far less data churn. Default to migrate; fall back only if needed.
- **D2 — DM lookup.** Add `db.findDirectSpace(companionId:) -> Space?` (type `direct` + sole agent
  member = companionId). Replaces every `"swim-\(companionId)"`. `getOrCreateDirectSpace(companion:)`
  for the create-on-open path (replaces `Space.swim` + the startSwim upsert).
- **D3 — UI unification.** Delete `SwimView`; render a DM through the same `ChatView` path as any
  space. `activeSwimCompanion` → just `currentSpace` (a `direct` space). The sidebar may still show
  a "companions" affordance, but clicking opens the companion's **direct space** (selectSpace), not
  a swim mode. Last-view restore keys off `lastSelectedSpaceId` (drop `lastActiveSwimCompanionId`).
- **D4 — relationship-memory default space.** The crease/fold/engraving/position tools and
  `buildRelationshipPreamble` default to the companion's **current space** (the space the turn is
  happening in), falling back to its direct space — not a hardcoded `swim-` id. This is what makes
  memory genuinely space-scoped (a companion in #project accrues #project memory).

## Migration phases (incremental, each builds + commits green)

**Phase 1 — DB: membership lookup + data migration (no behaviour change yet).**
- Add `findDirectSpace(companionId:)` + `getOrCreateDirectSpace(...)` (D2).
- Append a GRDB migration: for each `isSwim==1` space, mint a UUID, repoint all 9 child tables, swap
  the `spaces` row, drop the `swim-` id. Keep the `isSwim` column for now (set 0) to avoid a schema
  rewrite mid-phase. **Tests:** an in-memory DB seeded with a `swim-X` space + a message + a crease +
  an agentSpaces row → after migration: new UUID space exists, all child rows repointed, old id
  gone, FK intact. This is the riskiest step — heavy unit coverage here.

**Phase 2 — resolve swims via membership everywhere (kill `swim-<id>` strings).**
- Replace all ~20 sites with `findDirectSpace`/current-space resolution (D2/D4). `getLastSwimTime`
  → `getLastMessageTime(directSpaceOf: companion)`. `routeMentionsToTerminals` swim lookup → check
  if `spaceId` is a direct space and derive its companion via membership.
- **Tests:** `findDirectSpace` (hit/miss/ambiguous), relationship-memory tools resolve to the right
  space given current-space vs default.

**Phase 3 — UI: unify SwimView into the space path; drop `activeSwimCompanion`.**
- `startSwim` → `openDirectSpace(companion)` = `getOrCreateDirectSpace` + `selectSpace`. Delete
  `SwimView`, the `ContentView` swim branch, `activeSwimCompanion`, `exitSwim`. Sidebar companion
  row → opens the direct space. Restore via `lastSelectedSpaceId`.
- Manual verify (no view tests): open a companion DM, send, relationship preamble still loads,
  reload restores it; team space unaffected.

**Phase 4 — delete `isSwim` + `Space.swim` + `getRegularSpaces` filter.**
- Drop the `isSwim` column (append migration), delete `Space.swim`, make `getRegularSpaces ==
  getAllSpaces` (or fold callers onto one). Direct spaces now flow through the same list (decide
  sidebar grouping — "direct" vs "team" is presentation). Build proves all `isSwim` refs gone.
- **Tests:** space list includes direct spaces; no `isSwim`/`swim-`/`activeSwimCompanion` symbols
  remain (grep gate in a test or CI note).

## Risks / guardrails

- **Data migration is irreversible** — back up `port42.sqlite` before first run on a real DB; the
  migration must be idempotent and FK-safe (insert-new-before-delete-old). Test on a copy of a real
  DB with several swims + accrued creases/folds before shipping.
- **Two DMs for one companion** (dup `direct` spaces) — `findDirectSpace` must pick deterministically
  (oldest) and a cleanup step should merge/flag dups found during migration.
- **Sync** — ensure migrated direct spaces keep `syncEnabled=false`; don't accidentally start
  syncing private DMs.
- Don't deepen any `swim-` pattern in new code from here (the whole point).

## Verification (end state)

- Open a companion from the sidebar → a normal `direct` space opens in `ChatView` (no SwimView);
  conversation, relationship preamble, and creases all load.
- A companion in a team space accrues its own `(companion, teamSpace)` creases/fold.
- Existing pre-migration swims (history + creases) survive under their new UUID space.
- `grep -rn 'isSwim\|activeSwimCompanion\|swim-\\(' Sources/` → empty.
- The sidebar/activity model (#1) can treat every row as a space — foundation ready.
