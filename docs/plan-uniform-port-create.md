# Uniform `port.create({type})` — one creation primitive for all port types

**Status:** proposal for review. Not started. Sequel to `plan-first-class-terminal-ports.md`
(which is done). Steered by `summer2026-todo.md` ("a terminal is just another port type", like
"a swim is just a space").

---

## Problem

There is **no single "create a port" API**. Port creation is asymmetric and partly out-of-band:

| Want | How it's created today | Surface |
|---|---|---|
| **Web port (inline)** | a companion emits a ```` ```port HTML``` ```` **text fence**; the message renderer detects it (`ConversationContent.messageSegments`) and instantiates an `InlinePortView` (a `WKWebView`). id is **derived from the message** (`entry.id[-pN]`). | inline in chat |
| **Web port (floating)** | user/companion hits "pop out" → `popOut(html:, portType:"web")` → a persisted `PortPanel` + `NSPanel`. | floating window |
| **Terminal port** | `terminal_spawn` **tool** → `spawnNativeTerminalPort` → `popOut(portType:"terminal")`. | floating window |

Consequences:
- A web port is a **message-text-derived view** (no create call, no registration) until popped out.
  A terminal port is **always a registered panel**. Two different mental models for "a port."
- `terminal.exec` (run a command, return stdout — headless, no surface) was **wrongly removed from
  the JS bridge** with the xterm sweep (D1). A web port can no longer run a command at all. This is
  a regression: `terminal.exec` is a utility, not the xterm-PTY path.
- No `port.create` means callers can't make a port of a chosen type uniformly — terminals need a
  bespoke method, web floats need `popOut`, web inlines need a magic text marker.

## The seam that already exists

Internally everything registered converges on **one** call:

```
popOut(html: String, bridge:, spaceId:, createdBy:, messageId:, title:, portType: "web"|"terminal", in:) -> String  // port id
PortWindowManager.swift:239
```

`portType` is already the discriminator; for a terminal port the `html` field simply carries a
JSON-encoded `TerminalPortConfig` (command/cwd) instead of HTML. `spawnNativeTerminalPort` is a thin
wrapper over `popOut`. **So the uniform primitive is one method away — it's just not exposed.**

## Target model

**`popOut`-with-`portType` becomes the one creation primitive, exposed as `port.create`.** Every
front-end (the ```` ```port ```` fence, `terminal_spawn`) becomes a thin caller of it.

```
port.create({
  type: "web" | "terminal",
  title?: "...",
  space_id?: "...",          // which space the port belongs to (see "space ownership" below)

  // type:"web":
  html?: "<...>",            // a full port HTML body

  // type:"terminal" — the FULL CLI-companion field set (parity with the create sheet /
  // AgentConfig.createCommand; see NewCompanionSheet command mode):
  command?: "claude",       // executable or CLI name (claude/gemini get the hooks shim)
  args?: ["--continue"],
  cwd?: "/path",            // working directory (sheet: workingDir)
  systemPrompt?: "...",     // companion framing / personality (sheet: commandSystemPrompt)
  env?: { KEY: "val" },     // custom env vars (sheet: commandEnvVars)
  persist?: false,          // also save it as a companion (AgentConfig) — see D6
}) -> { id, title }
```

**Parity requirement (gordon):** `port.create({type:"terminal"})` must accept **everything the
front-end create sheet passes for a CLI companion** — `command, args, cwd, systemPrompt, env,
title/name`. Today `spawnNativeTerminalPort` is missing `env` (and `systemPrompt` arrives as the
pre-baked `companionPrompt`); the method must be widened so programmatic creation == manual sheet
creation. Source of truth for the field list: `AgentConfig.createCommand` + `NewCompanionSheet`
command mode.

Surfaces (both bridge + tool, same as the membership/terminal work):
- **JS bridge:** `port42.port.create({...})` — a web port can now create another port (incl. a
  terminal) first-class.
- **Tool / `/call`:** `port_create` / `port.create` (dot maps).

Returns the **port id** — the registry key (`terminalControllers[id]` for terminals; `PortPanel.id`
generally), addressable by `port.update`, `terminal_send`, `port.close`, etc.

## Companion methods that fold in

- `terminal_spawn` → becomes `port.create({type:"terminal", ...})`. **Decision D1:** keep
  `terminal_spawn` as a back-compat alias, or delete it?
- The ```` ```port ```` fence stays — it's the LLM-text shorthand for an **inline** web port. It is
  NOT replaced (inline-in-message is its own thing; see D2).

## Sub-work bundled here (same consistency pass)

1. **Restore `terminal.exec` to the bridge** (regression). Re-add the `PortBridge` case → calls the
   headless `executeCommand` (no surface, no xterm), and re-add its `PortPermission` case
   (`terminal.exec → .terminal`). `spawn/send/resize/kill` stay removed.
2. **Reconcile `fs.*` vs `files.*`** — the bridge implements `fs.read/write/pick`; `llms.txt` +
   global CLAUDE.md document `files.list/read/write`. Pick one canonical name, alias the other,
   fix the docs. **Decision D4:** canonical = `files.*` (matches docs/other platforms) or `fs.*`
   (matches code)?

## Decisions to resolve (review)

- **D1 — `terminal_spawn` fate:** alias to `port.create` (back-compat) vs delete. *Lean: alias for
  one release, then drop.*
- **D2 — does `port.create` make inline ports?** *Lean: no.* `port.create` makes a **registered
  standalone port** (the `popOut`/`PortPanel` path), floating by default. Inline-in-a-message web
  ports remain the ```` ```port ```` fence's job (they're message-derived). A `port.dock`/inline
  flag could come later, but creation-by-method = a real registered port.
- **D3 — `chat` type:** excluded from `port.create` (the chat surface is system-owned per space, not
  user-created). `type` ∈ {`web`, `terminal`}.
- **D4 — `fs` vs `files` canonical name → RESOLVED: `fs.*`** (gordon). The bridge already
  implements `fs.read/write/pick`; make `fs.*` canonical and fix the docs (`llms.txt`, global
  CLAUDE.md) which currently say `files.*`. (Optionally keep `files.*` as a thin alias.)
- **D5 — space ownership (which space the new port belongs to).** Every port belongs to a space
  (`PortPanel.spaceId`) — that's how it shows in the right sidebar/space and how a terminal's
  messages route. The only question is: when the caller doesn't pass `space_id`, how do we pick?
  Resolution: `space_id` from the call → else the caller's own space (a companion has
  `PORT42_SPACE_ID`; the bridge knows its `spaceId`) → else the UI's current space. Just a
  fallback order so a port never lands orphaned. (Same rule `terminal_spawn` already uses.)
- **D6 — `persist`: does `port.create({type:"terminal"})` also create a companion?** A manual CLI
  companion from the sheet is a saved `AgentConfig` (a space member you can @mention). `port.create`
  spawns a *port*. *Lean: default `persist:false` (just the terminal port); `persist:true` also
  `addCompanion(...)` so it becomes a first-class, @mentionable, restart-surviving companion —
  giving programmatic parity with the sheet (which always persists).*

## Migration steps (incremental, each builds + commits green)

1. **Restore `terminal.exec`** (bridge case + permission) + a test that a port can run a command.
   *(Standalone regression fix — do first.)*
2. **Add `port.create`** core: a `PortBridge` case + `port_create` tool that validates `type` and
   calls `popOut(portType:)` (terminal builds the `TerminalPortConfig` via `spawnNativeTerminalPort`;
   web passes `html`). Returns `{id, title}`. Permission: `.terminal` for terminal type; web port
   creation reuses existing port perms.
3. **Fold `terminal_spawn` → `port.create`** (alias per D1). Update tool docs + `ports-context.txt`
   + `llms.txt` so companions are told to use `port.create`.
4. **Reconcile `fs`/`files`** (D4) — alias + doc fix.
5. **Docs sweep** — `llms.txt`, `ports-context.txt`, global CLAUDE.md all describe one creation API.

## Verification

- `port42.port.create({type:"terminal", command:"htop", space_id:"..."})` from a web port → a native
  terminal port opens in that space; `terminal_send <id>` drives it.
- `port42.port.create({type:"web", html:"<...>"})` → a floating web port appears, registered (shows
  in `ports.list`), `port.update` works on the returned id.
- `port42.terminal.exec({command:"date"})` from a web port → returns stdout (regression fixed).
- A ```` ```port ```` fence still renders an inline web port (unchanged).
- `terminal_spawn` still works (alias) OR is gone (per D1) with docs updated.
- `fs.*`/`files.*` resolve to the same handlers; docs match the canonical name.
