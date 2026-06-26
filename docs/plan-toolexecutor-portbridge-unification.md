# Unify the two Port42 API surfaces (ToolExecutor ↔ PortBridge)

## Problem

The Port42 bridge API is exposed through **two independent code paths that hand-roll the
same methods**, and they have drifted:

| Surface | File | Caller | Input shape | Output shape |
|---|---|---|---|---|
| **PortBridge** | `Services/PortBridge.swift` (`handleMethod`) | webview JS in ports (`port42.*`) | positional `[Any]` | raw value (`[String: Any]` / `[Any]` / `NSNull`) |
| **ToolExecutor** | `Services/ToolExecutor.swift` (`execute`) | LLM tool-use + remote `curl` RPC (`/call`) | named `[String: Any]` | `[textBlock(jsonString(...))]` |

Because each method is implemented twice, the two surfaces drift. Concrete example that
prompted this doc: `space.current` returned **`{ id, name, type, members }`** on PortBridge but
**`{ id, name, memberCount }`** on ToolExecutor — different fields for the same method. Every
new method or field has to be added in two places, and reviewers can't see the divergence.

## Goal

One implementation per method. The two surfaces become **thin adapters** that differ only in:
1. **input normalization** — positional array vs named dict → a common arg accessor, and
2. **output wrapping** — raw value vs `textBlock(jsonString(...))`.

All business logic (DB access, AppState reads/writes, shaping) lives in a single core.

## Proposed design

```
Port42API (one func per method)
   ├─ input:  normalized accessor (by name, with positional fallback)
   ├─ logic:  the single source of truth (today duplicated)
   └─ output: a plain value (Any: dict / array / scalar / nil)

PortBridge.handleMethod(method, args:[Any])      → adapt args → Port42API.call → return raw value
ToolExecutor.execute(tool, input:[String:Any])   → adapt input → Port42API.call → wrap as textBlock(jsonString)
```

Sketch:

```swift
@MainActor
enum Port42API {
    /// Normalized arguments: named lookups, with an ordered positional fallback so the
    /// PortBridge positional convention still resolves (e.g. arg("space_id", at: 0)).
    struct Args { /* dict + ordered array */ func string(_ name: String, at: Int? = nil) -> String? ... }

    static func call(_ method: String, _ args: Args, _ app: AppState) async -> Any
    // internally: switch method { case "space.current": return spaceCurrent(args, app) ... }
}
```

Each surface keeps its transport concerns:
- `PortBridge` maps positional `[Any]` → `Args` (index-based) and returns the raw value.
- `ToolExecutor` maps `[String: Any]` → `Args` (name-based) and wraps the value in
  `textBlock(jsonString(value))`. Method names are normalized (`space_current` ↔ `space.current`).

## Down-payment already made

`Services/Port42Members.swift` (`Port42Members.dict` / `Port42Members.companions`) is the first
slice of this: the member/companion shaping logic lives in ONE place and both `space.current`
implementations now call it, so they emit identical member shapes by construction. The
unification generalizes this pattern to every method.

## Migration strategy (incremental, low-risk)

Do it method-by-method, never big-bang:

1. Pick a method (start with the read-only ones: `user.get`, `space.*`, `companions.*`,
   `messages.recent`).
2. Move its body into `Port42API.<method>` returning a plain value.
3. Point both surfaces' `case` at it (PortBridge returns it; ToolExecutor wraps it).
4. Add a **parity test** (below). Repeat.

Mutating/side-effecting methods (`messages.send`, `port.*`, device APIs) come after the
read-only set, since they need careful handling of attribution (`createdBy`/`senderName`) and
permissions, which currently differ between surfaces.

## Risks / things that genuinely differ today (must be preserved, not flattened)

- **Attribution.** PortBridge carries `createdBy` (the port identity) and redirects
  `messages.send` → `sendAsCreator`. The RPC/tool path resolves identity differently
  (`senderName` arg). The core must take an explicit caller-identity parameter rather than
  assume one.
- **Permissions.** Sensitive methods prompt per-surface; keep the permission gate in the
  adapter (or pass a capability context into the core).
- **Errors.** PortBridge returns `["error": ...]`; ToolExecutor returns a `textBlock` string.
  Standardize the core on a typed result and let each adapter render it.
- **Async + MainActor.** Both already run on the main actor (they touch `AppState`); keep the
  core `@MainActor`.

## Testing — parity harness

The whole point is "same logic, same output." Lock it with a test per method that calls the
core once and asserts BOTH adapters render it identically:

```swift
@Test func spaceCurrentParity() async {
    let value = await Port42API.call("space.current", .init(space_id: s.id), app)
    // PortBridge adapter returns `value`; ToolExecutor adapter returns jsonString(value).
    #expect(jsonString(value) == toolExecutorRender("space_current", ["space_id": s.id]))
    #expect(portBridgeRender("space.current", [s.id]) == value)
}
```

`Port42Members.dict` already guarantees member-shape parity; the harness extends that guarantee
to whole-method responses.

## Scope / estimate

Mechanical but broad — it touches the full method list (~40 methods across user/space/messages/
ports/device/storage/ai). Recommended as its **own** change, landed incrementally behind the
parity tests, **not** bundled into feature work. The read-only slice (user/space/companions/
messages.recent) is a good first PR and removes the most-visible drift.
```
