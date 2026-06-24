# Companion Scopes — Implementation Plan

**Spec:** [companion-scopes.md](companion-scopes.md)
**Status:** Not started
**Last updated:** 2026-04-17

---

## Goals

- Four companion types (Architect, Compiler, Operator, Echo) each with a Port42-adapted constitution
- Scope = KB directory on disk + `scope.md`. Accessed via extended `files.*` API.
- `scopePath` field on `AgentConfig` — companion knows where its KB lives
- Companion type is a preset (template) in NewCompanionSheet — same pattern as existing presets
- No new bridge API namespace. No `companionType` field. Relationship layer unchanged.

## Non-goals

- Dashboard / KB viewer port (Phase 2 — build after constitutions are proven)
- Cross-scope reads — deferred
- Compiler verification runner — deferred
- Automatic scope creation UI — deferred
- Migrating or replacing any existing companion

---

## What Already Exists

| Capability | Status |
|---|---|
| Relationship layer (fold, creases, engravings, position, initiative) | ✅ Done |
| `systemPrompt` field on `AgentConfig` | ✅ Done |
| NewCompanionSheet with preset support | ✅ Done |
| EditCompanionSheet | ✅ Done |
| `files.*` picker-gated bridge (ports) | ✅ Done |

---

## Decisions

**`files.*` API — one API, two access modes**

`files.*` is the single top-level file API. Routing is by path type:

- **Relative path** → scoped to `~/Library/Application Support/Port42/`. Direct `FileManager` access, no picker, no permission prompt.
  - `files.list("scopes/strategy/")` → lists `~/Library/Application Support/Port42/scopes/strategy/`
  - `files.read("scopes/strategy/scope.md")`
  - `files.write("scopes/strategy/facts.md", data)`
- **Absolute path** → existing picker-gated behavior, unchanged.

Port42 is not sandboxed, so relative-path access requires no entitlement changes.

**Companion type = preset, not a stored field**

No `companionType` field on `AgentConfig`. No new enum. Companion type is just which preset was used to create it — same as CLI presets today. The constitution IS the system prompt. Watching signals are seeded at creation time in `NewCompanionSheet` when the preset is applied.

**Scope injection location**

`ChannelAgentHandler.start()` in `AppState.swift` (~line 193) is where the system prompt is assembled. The `<scope>` block is appended after `<personality>` when `agent.scopePath != nil`.

**KB path convention**

`scopePath` is stored as a relative path (e.g. `scopes/strategy`). The `files.*` API resolves it against the Port42 data directory. No `~` needed in stored values.

---

## Phase 1 — `files.*` Extension

### 1a. Extend `files.*` in ToolExecutor

Add relative-path routing to the existing `file_read`, `file_write`, `file_list` cases in `ToolExecutor.swift`. When a path does not start with `/`, resolve it against the Port42 data directory:

```swift
private func resolveFilePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }  // absolute — picker-gated as before
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("Port42").path
    return (appSupport as NSString).appendingPathComponent(path)
}
```

Update `file_read`, `file_write` cases: call `resolveFilePath` on the incoming path. If the resolved path is inside the Port42 data directory, proceed directly with `FileManager`. If it's absolute, fall through to existing picker-gated `FileBridge`.

Add `file_list` case (currently missing from tool use):

```swift
case "file_list":
    guard let path = input["path"] as? String else {
        return [textBlock("Error: missing 'path' parameter")]
    }
    let resolved = resolveFilePath(path)
    // if relative: direct FileManager directory listing
    // if absolute: require picker grant
```

Also add `file_mkdir` for creating KB subdirectories:

```swift
case "file_mkdir":
    guard let path = input["path"] as? String else {
        return [textBlock("Error: missing 'path' parameter")]
    }
    let resolved = resolveFilePath(path)
    guard resolved.hasPrefix(port42DataDir) else {
        return [textBlock("Error: mkdir only permitted within Port42 data directory")]
    }
    try FileManager.default.createDirectory(atPath: resolved, withIntermediateDirectories: true)
    return [textBlock(jsonString(["ok": true]))]
```

### 1b. Expose `files.*` in gateway HTTP API

Add to `gateway/main.go` — new methods handled in the `/call` endpoint:

```
files.list(path)           → directory listing
files.read(path)           → file contents
files.write(path, data)    → write file
files.mkdir(path)          → create directory
```

Same relative/absolute routing: relative paths resolved to Port42 data dir on the host machine. This makes KB files accessible from Claude Code, scripts, and any external process via `curl`.

### 1c. Update ToolDefinitions

Add `file_list` and `file_mkdir` to `ToolDefinitions.swift` so companions see them in their tool schemas. Update descriptions on `file_read`/`file_write` to document relative path behavior.

---

## Phase 2 — Scope Wiring

### 2a. Add `scopePath` to `AgentConfig`

```swift
public var scopePath: String?  // relative path e.g. "scopes/strategy" — nil = no scope
```

DB migration `v33-agent-scope-path`:

```swift
migrator.registerMigration("v33-agent-scope-path") { db in
    try db.alter(table: "agents") { t in
        t.add(column: "scopePath", .text)
    }
}
```

Update `AgentConfig.init` and `createLLM` to include `scopePath: String? = nil`.

### 2b. Scope injection in `ChannelAgentHandler.start()`

After the `<personality>` block (~line 227 in AppState.swift), append a `<scope>` block when `agent.scopePath != nil`:

```swift
let scopeBlock: String
if let scopePath = agent.scopePath, !scopePath.isEmpty {
    scopeBlock = """

        <scope>
        Your KB is at \(scopePath)/ (relative to the Port42 data directory).
        At the start of every conversation:
          1. Call files.read("\(scopePath)/scope.md") — read your identity, problem space, sources, done criteria.
          2. Call files.read("\(scopePath)/directives.md") — if it exists, treat as priority overrides.
          3. Call files.list("\(scopePath)/") — orient yourself to what's in the KB.
        Use files.read, files.write, files.list, files.mkdir throughout to maintain your KB.
        Your self-assessments, session reports, facts, beliefs, gaps, and decisions all live here.
        </scope>
        """
} else {
    scopeBlock = ""
}
```

Insert `scopeBlock` into `channelPrompt` after `</personality>`.

---

## Phase 3 — Constitutions + Presets

### 3a. Write Port42 constitutions

Four files under `Sources/Port42Lib/Resources/constitutions/`:

```
architect-constitution.md
compiler-constitution.md
operator-constitution.md
echo-constitution.md
```

Adapted from the Engine's generic constitutions:
- Replace CLI file tools with `files.read`/`files.write`/`files.list`
- Remove Engine-specific tooling (sync-from, git log, Slack search)
- Add Port42 context: channel messages, @mentions, initiative triggers
- Add relationship layer guidance: "Your fold, position, creases, and engravings persist across sessions via the relationship layer. Use `fold_read`, `position_read`, `engrave_read` to ground your work."
- Add handoff protocol: Architect signals Compiler via @mention after writing an approved ADR; Compiler signals Operator similarly

Echo constitution differs:
- Conversational-first, not autonomous sessions
- Scope optional — read scope.md if present, operate from relationship layer alone if not
- No session report loop — relationship layer carries continuity

### 3b. Bundle constitutions as resources

Add to `Package.swift` resources:

```swift
.copy("Resources/constitutions")
```

Load in `NewCompanionSheet`:

```swift
func loadConstitution(_ name: String) -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: "md",
                                      subdirectory: "constitutions"),
          let text = try? String(contentsOf: url) else { return "" }
    return text
}
```

### 3c. Companion type presets in NewCompanionSheet

Add a "Companion Type" preset section above existing presets. Four cards: Architect, Compiler, Operator, Echo. Selecting one:

1. Fills `systemPrompt` with the constitution
2. Shows a "KB path" field (relative path, e.g. `scopes/strategy`)
3. Sets `trigger = .mentionOnly`
4. Sets `model = claude-opus-4-6`

On save, seed watching signals into the companion's swim position:

```swift
let watchingByType: [String: [String]] = [
    "architect": ["ADR", "decision", "architecture", "gap", "spec"],
    "compiler":  ["approved", "spec ready", "compile", "artifact"],
    "operator":  ["blocking", "failed", "escalate", "ship", "pipeline"],
]
```

Echo gets no default signals — scope-specific, set by human.

### 3d. KB path field in EditCompanionSheet

Add a "KB path" text field to `EditCompanionSheet` for LLM companions. Updates `scopePath` on save.

---

## Build Sequence

| Step | What | Files |
|---|---|---|
| 1 | `files.*` relative path routing in ToolExecutor | `ToolExecutor.swift` |
| 2 | `file_list`, `file_mkdir` tool cases | `ToolExecutor.swift`, `ToolDefinitions.swift` |
| 3 | `files.*` in gateway API | `gateway/main.go` |
| 4 | `scopePath` on `AgentConfig` + migration | `AgentConfig.swift`, `DatabaseService.swift` |
| 5 | Scope injection in `ChannelAgentHandler.start()` | `AppState.swift` |
| 6 | Write four constitutions | `Resources/constitutions/*.md` |
| 7 | Companion type presets + KB path field in NewCompanionSheet | `NewCompanionSheet.swift`, `EditCompanionSheet.swift` |
| 8 | End-to-end test: Architect scope | manual |
| 9 | End-to-end test: Echo with and without scope | manual |

---

## Files to Create/Change

| File | Change |
|---|---|
| `Sources/Port42Lib/Services/ToolExecutor.swift` | Relative path routing, `file_list`, `file_mkdir` |
| `Sources/Port42Lib/Services/ToolDefinitions.swift` | Add `file_list`, `file_mkdir`; update `file_read`/`file_write` descriptions |
| `gateway/main.go` | `files.list`, `files.read`, `files.write`, `files.mkdir` methods |
| `Sources/Port42Lib/Models/AgentConfig.swift` | Add `scopePath: String?` |
| `Sources/Port42Lib/Services/DatabaseService.swift` | Migration v33 |
| `Sources/Port42Lib/Services/AppState.swift` | Scope injection in `ChannelAgentHandler.start()` + watching signal seeding |
| `Sources/Port42Lib/Views/NewCompanionSheet.swift` | Companion type preset section + KB path field |
| `Sources/Port42Lib/Views/EditCompanionSheet.swift` | KB path field |
| `Sources/Port42Lib/Resources/constitutions/architect-constitution.md` | New |
| `Sources/Port42Lib/Resources/constitutions/compiler-constitution.md` | New |
| `Sources/Port42Lib/Resources/constitutions/operator-constitution.md` | New |
| `Sources/Port42Lib/Resources/constitutions/echo-constitution.md` | New |
| `Package.swift` | Add constitutions to resources |

---

## What We Are Not Building

- A new storage system. KB is just files on disk.
- A new API namespace. `files.*` is one API.
- A `companionType` field. Type lives in the system prompt (the preset).
- Any changes to the relationship layer.
- Any changes to the existing picker-gated `FileBridge` for ports.
