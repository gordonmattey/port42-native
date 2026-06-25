# Native Terminal Ports (GhosttyKit)

## Context

Terminal ports today are WKWebView + xterm.js (`cli-terminal.html`). The goal is to replace
the default terminal port with a **native Ghostty terminal view** inside Port42's existing
floating `NSPanel` system — no WKWebView, no JavaScript, no xterm.js for the terminal port
type. Everything else stays the same.

**Engine: GhosttyKit.xcframework** from manaflow's fork of Ghostty (`github.com/manaflow-ai/ghostty`).
GPU-accelerated, full ligatures, Sixel, Kitty graphics. Downloaded as a pre-built
xcframework (~130MB) from their CI at build time. Ghostty owns the PTY — it spawns the
shell, manages IO, handles resize. We observe output via a byte-tee callback and inject
input via the C API.

### License / IP Note

manaflow/cmux is **GPL-3.0** (dual-licensed: GPL or commercial from Manaflow, Inc.).
**No cmux code is copied.** Port42 implements the same conceptual approach independently:
the hook injection mechanism, socket protocol, and transcript parsing are all derived from
public Anthropic documentation and standard Unix patterns — none of which are copyrightable.
All Port42 naming is independent (no "cmux" identifiers anywhere in code or comments).

---

## Two Coexisting Terminal Paths

After this change, two distinct terminal paths exist in parallel:

| Path | PTY owner | Used by |
|------|-----------|---------|
| **TerminalBridge** (unchanged) | Port42 (`forkpty`) | PortBridge `terminal.*` JS API — user-built web ports, custom xterm ports |
| **GhosttyKit surface** (new) | Ghostty internally | `portType == "terminal"` — the native CLI companion terminal |

**TerminalBridge is completely unchanged.** `spawn`, `send`, `resize`, `kill`, `addOutputObserver` — all stay. They back the PortBridge `terminal.*` JS methods which must remain available for user-built web ports.

---

## PortBridge Impact

**Nothing removed from PortBridge.** `terminal.*` handler block stays intact:
- User-built web ports can still call `terminal.spawn()` / `terminal.send()` / etc.
- `terminal.loadXterm()` still serves xterm.js for those ports

**What is removed:**
- `cli-terminal.html` — the HTML template that creates the default terminal port (replaced by native view)
- `xterm.js`, `xterm.css` — no longer bundled; user-built ports that want xterm can load from CDN

---

## GhosttyKit C API (confirmed from cmux research)

**Text injection into terminal** (for @mention routing):
```c
ghostty_surface_text_input(surface, text, len)  // keystroke-style, splits \n → CR
ghostty_surface_text(surface, text, len)         // paste mode (bracketed paste)
```

**PTY output observation** (for game loop / `<p42>` detection):
```c
ghostty_surface_set_pty_tee_cb(surface, callback, userdata)
// fires on Ghostty's IO thread BEFORE the VT parser, with every PTY byte chunk
// bytes pointer valid ONLY during callback — must be copied to Swift before returning
```

**Lifecycle:**
```c
ghostty_surface_new(app, &config)   // Ghostty spawns the shell here; NSView must exist first
ghostty_surface_free(surface)       // call on main actor only
ghostty_surface_set_size(surface, uint32_t width_px, uint32_t height_px)  // PIXELS, not cols/rows (verified Step 4) — Ghostty derives the grid from cell size
ghostty_surface_set_content_scale(surface, dx, dy)  // must fire on screen/display change
ghostty_surface_set_display_id(surface, id)         // hooks CVDisplayLink to correct display
```

**App init (mandatory callbacks — not optional):**
```c
ghostty_app_new(&runtime_config, &app_config)
ghostty_app_tick(app)  // must be called from wakeup_cb to drive IO
```
`ghostty_runtime_config_s` requires: `wakeup_cb`, `action_cb`, `close_surface_cb`, clipboard
callbacks. These are not optional — without `wakeup_cb` calling `ghostty_app_tick()`, the
terminal processes no IO.

**Surface config — key fields:**
```c
ghostty_surface_config_s {
    .platform_tag = GHOSTTY_PLATFORM_MACOS,
    .platform.macos.nsview = nsViewPointer,  // NSView must exist before this call
    .working_directory = cwd,
    .command = commandPath,  // binary path; args passing TBD (see gap #8)
    .env_vars / .env_var_count,
    .io_mode, .io_write_cb, .io_write_userdata
}
```

---

## Output Routing — Two Paths

For native terminal ports, two companion output paths coexist:

| Path | Mechanism | Used for |
|------|-----------|----------|
| **Hooks path** (primary for tools that support it) | Shim injects Port42 hooks config into CLI invocation; hook events arrive over a Unix socket; `Stop` event delivers clean response text | Claude Code companions today; extensible to other CLIs |
| **`<p42>` tag path** (fallback/generic) | Tee callback bytes → `TerminalOutputProcessor.extractP42Tags` → post to space | Any CLI tool that emits `<p42>` tags — companions, custom commands, non-Claude tools |

Both paths call the same `AppState.sendMessageAsCompanion()` endpoint. The hooks path is
preferred when available because it delivers structured response text without terminal output
parsing. The `<p42>` path remains as the universal fallback.

---

## PTY Environment Injection (general primitive)

Port42 controls the full environment of every Ghostty surface at spawn time via
`ghostty_surface_config_s.env_vars`. This is a general-purpose capability — not limited to
hooks. Port42 assembles a `TerminalEnvironment` before creating each surface:

```swift
struct TerminalEnvironment {
    var path: [String]      // prepended to existing PATH
    var vars: [String: String]  // additional env vars
}
```

**Uses:**
- **Hooks socket path** — `PORT42_HOOKS_SOCKET` → tool shims know where to report events
- **Credential injection** — `ANTHROPIC_API_KEY` (from Port42 keychain) → `claude` CLI never prompts for auth inside Port42 terminals; same principle applies to any API key Port42 holds
- **Session identity** — `PORT42_SESSION_ID`, `PORT42_SPACE_ID`, `PORT42_SPACE_NAME` → tools can self-identify which space they're operating in. `TerminalPortConfig` already carries `spaceId` and `spaceName`; wire both into env vars at spawn time.
- **Real claude path** — `PORT42_CLAUDE_PATH` → absolute path resolved by `ClaudeCodeSetup.findBinary("claude")` at spawn time; the shim execs this directly instead of searching PATH, avoiding any risk of finding itself.
- **Custom tool path** — per-session temp dir prepended to PATH for shims and wrappers

The user never needs to configure any of this. Port42 bootstraps the environment from its
own stored credentials before the PTY starts.

**Deferred:** richer context injection (working directory as explicit context, CLAUDE.md generation, SessionStart metadata, skills-based instruction strategy) — deferred until hooks are running and actual needs are clear.

---

## Terminal Hooks System (Port42-owned, general)

Port42 owns the hooks infrastructure. The **receiver** (`TerminalHooksService`) is completely
general — it does not know or care which tool sent an event. The **sender side** is
tool-specific: each AI CLI needs its own injection adapter, but the adapters all speak the
same socket protocol.

**All three major AI CLIs support hooks with the same stdin/stdout JSON model:**

| CLI | Config mechanism | Events |
|-----|-----------------|--------|
| Claude Code | `--settings '{"hooks":{...}}'` flag | Stop, PreToolUse, PostToolUse, PermissionRequest, UserPromptSubmit, SessionStart, SubagentStart/Stop |
| Gemini CLI | `settings.json` file (`hooks` key) | AfterAgent (≈Stop), BeforeTool/AfterTool, SessionStart/End, BeforeModel/AfterModel |
| OpenAI Codex | `config.toml` file (`hooks` key) | Stop, PreToolUse, PostToolUse, PermissionRequest, UserPromptSubmit, SessionStart |

Codex and Claude share nearly identical event vocabulary. Gemini uses different names but
maps to the same lifecycle moments.

### Injection adapters — one per CLI

**Claude:** PATH shim required (config is a runtime flag, not a file).

**Gemini and Codex:** Port42 writes a temp config file at spawn time (via `TerminalEnvironment`)
pointing hooks at `PORT42_HOOKS_SOCKET`. These tools read config from a known location on
startup — no shim binary needed, just a file write before surface creation.

This phase only implements the Claude adapter. Gemini/Codex adapters come in a follow-on.

### `port42-claude-shim` binary

A small Go binary (bundled in `Port42.app/Contents/MacOS/`) that:
1. Detects if it is being invoked as `claude` (via `os.Args[0]`)
2. Reads `PORT42_HOOKS_SOCKET` from env
3. Builds a Claude Code settings block pointing to that socket:
   ```json
   {"hooks":{"Stop":[{"type":"command","command":"<notifier>"}],"PermissionRequest":[...]}}
   ```
4. Prepends `--settings <json>` to the real `claude` argv and execs real `claude`
5. If `PORT42_HOOKS_SOCKET` is absent or invocation is not `claude`, passes through unchanged

Symlinked as `claude` in a per-session temp dir that is the first PATH component.
**No shell rc modification. Invisible to the user.**

### Port42 normalized event vocabulary

Port42 defines its own event taxonomy. Each CLI adapter translates from the CLI's raw event
format to this vocabulary before writing to the socket. `TerminalHooksService` never sees
CLI-specific event names.

| Port42 event | Claude raw | Gemini raw | Codex raw | Meaning |
|---|---|---|---|---|
| `turnComplete` | `Stop` | `AfterAgent` | `Stop` | AI finished its turn; response text available |
| `toolStarting` | `PreToolUse` | `BeforeTool` | `PreToolUse` | AI about to execute a tool |
| `toolFinished` | `PostToolUse` | `AfterTool` | `PostToolUse` | Tool call completed |
| `approvalRequired` | `PermissionRequest` | — | `PermissionRequest` | AI needs user approval |
| `inputSubmitted` | `UserPromptSubmit` | — | `UserPromptSubmit` | User submitted a prompt |
| `sessionStarted` | `SessionStart` | `SessionStart` | `SessionStart` | Session started |
| `sessionEnded` | — | `SessionEnd` | — | Session ended |

The Claude shim translates at the notifier command layer — the small binary/script that
Claude calls when a hook fires writes Port42's normalized JSON to the socket, not Claude's
raw payload.

### `TerminalHooksService`

`Sources/Port42Lib/Services/TerminalHooksService.swift` — general hooks receiver:
```swift
actor TerminalHooksService {
    let socketPath: String
    init(sessionId: String)   // creates socket at Support/Port42/hooks-<sessionId>.sock
    func events() -> AsyncStream<TerminalHookEvent>
    func stop()
}

enum TerminalHookEvent {
    case turnComplete(text: String, exitCode: Int)
    case toolStarting(tool: String, input: String)
    case toolFinished(tool: String, output: String)
    case approvalRequired(tool: String, input: String, sessionId: String)
    case inputSubmitted(prompt: String)
    case sessionStarted
    case sessionEnded
}
```

`GhosttyTerminalView` creates one `TerminalHooksService` per surface at `makeNSView`, passes
socket path via `TerminalEnvironment`, observes the event stream. `turnComplete` events fire
`appState.sendMessageAsCompanion(text:spaceId:companionName:)`.

### Transcript parser (future — not in this phase)

A `TerminalTranscriptParser` can read `.claude/projects/<encoded-cwd>/transcript.jsonl`
for rich conversation history. Deferred — the `Stop` hook delivers sufficient response text
for the initial release.

---

## Architecture

### What changes

- `spawnTerminalAgentPort()` — instead of loading `cli-terminal.html`, creates `TerminalPortConfig`, encodes as JSON, calls `popOut` with `portType: "terminal"`
- `PortWindowManager.popOut` — gains `portType:` parameter (currently missing from signature)
- `PortWindowManager.createWindow(for:in:)` — branches on `portType == "terminal"`, creates NSPanel with `GhosttyTerminalView` as contentView instead of WKWebView
- `AppState.routeMentionsToTerminals()` — adds Ghostty surface lookup; calls `ghostty_surface_text_input()` for native terminal ports
- `TerminalAgentLoop` — receives bytes from Ghostty tee callback instead of `addOutputObserver`
- `TerminalOutputProcessor` — gains `extractP42Tags(from:)` static method and `onP42Output` callback
- `ClaudeHooksService` (new) — Unix socket hook event receiver, one per companion session
- `port42-claude-shim` (new) — Go binary bundled in MacOS/, injected into PATH at PTY spawn

### What is unchanged

- `TerminalBridge` — all methods untouched
- `PortBridge` — all `terminal.*` handlers stay
- `PortWindowManager` — NSPanel creation, WKWebView path for web ports, position/size persistence
- `AppState` game loop (`TerminalAgentLoop`), `@mention` routing structure

---

## Pre-Implementation Findings (session 2026-06-24)

Verified from codebase before starting — do not re-derive:

- **`ClaudeCodeSetup.findBinary("claude")`** — exists at `Sources/Port42Lib/Services/ClaudeCodeSetup.swift:206`. Used as-is in Step 7.
- **`openInTerminal: Bool`** — exists in `AgentConfig` (`Sources/Port42Lib/Models/AgentConfig.swift:47`). No schema change needed.
- **`PortPanel.portType: String = "web"`** — already a field on `PortPanel` (`Sources/Port42Lib/Views/PortWindowManager.swift:24`). Only `popOut`'s signature needs updating (see Gap #2 below).
- **Shim module** — standalone Go module at `shim/` (repo root-level sibling of `gateway/`), its own `go.mod`. Not part of the gateway module. Built separately in `build.sh`.

### Step 1 findings (verified 2026-06-24 — corrections to original plan)

- **GhosttyKit ships as a static `.a`, not a dylib.** The macOS slice is `ghostty-internal.a` (an `ar` archive). Consequences:
  - **`otool -L | grep Ghostty` will NEVER match** — static symbols fold into the binary. The plan's Step 1 verify command is wrong. Use `nm <binary> | grep ghostty_info` instead (symbol shows as `T`). Secondary signal: the Port42 binary grows ~18MB → ~49MB.
  - **No dylib/framework needs bundling into `.app`** — Ghostty is compiled in. No extra `cp`/`codesign` step in `build.sh`.
- **SwiftPM requires the static lib to be `lib`-prefixed.** The macOS slice violates this (`ghostty-internal.a`), producing `error: unexpected binary name … Static libraries should be prefixed with lib`. **Fixed in `build.sh`**: after extraction it renames to `libghostty-internal.a` and patches the xcframework `Info.plist`. (iOS slices are already `libghostty-internal-fat.a`.)
- **Carbon.framework must be linked.** The archive references Text Input Source symbols (`TISCopyCurrentKeyboardLayoutInputSource`, `TISGetInputSourceProperty`, `kTISPropertyInputSourceID`, `kTISPropertyUnicodeKeyLayoutData`). **Fixed in `Package.swift`**: `.linkedFramework("Carbon")` on `Port42Lib` (propagates to the executable). All other frameworks Ghostty needs are already satisfied transitively — only these 4 symbols were undefined.
- **`ghostty_config_new()` exists** (header line 1095) — the plan's warning not to assume it was incorrect. So does `ghostty_init(uintptr_t, char**)` (line 1089), a likely-mandatory global init to call before `ghostty_app_new` (confirm in Step 2).
- **Probe uses `ghostty_info()`**, not `ghostty_app_new()` — a pure function needing no app/surface/callbacks, the cheapest call that proves linkage. Lives in `Sources/Port42Lib/Services/GhosttyProbe.swift`, called from `applicationDidFinishLaunching`.

---

## GhosttyKit Release (pinned 2026-06-24)

```
GHOSTTY_COMMIT="fc2d507dcf4d67228e56c6d69ad9e9aa2080a6dc"
GHOSTTYKIT_SHA256="cbe4a8b5f8c00ea9ffe4274e5e764009b6efe2dc877646fd6fa12d34146ce8fe"
```

**✅ SHA256 verified 2026-06-24** — actual checksum of the downloaded tarball matches
the pinned value exactly. No re-pin needed.

Commit message: "Clamp pixel scroll only past viewport boundaries" (2026-06-16). Releases are frequent; re-pin if a breaking API change is needed.

**Runtime probe confirmed (Step 1, 2026-06-24):**
```
[Port42] GhosttyKit probe: true (version=1.3.2-cmux-ios-pixel-scroll-49cb-+fc2d507dc, build=release-fast)
```
The embedded library is a **release-fast** build of Ghostty 1.3.2 at commit fc2d507dc.

---

## Critical Gaps

These must be resolved during implementation — they are not assumptions that can be deferred:

1. **No checksums file** — cmux's `ghosttykit-checksums.txt` does not exist in releases. ✅ RESOLVED: commit SHA pinned above; `shasum -a 256` verification added to `build.sh` template. Verify SHA256 on first build.

2. **`popOut` has no `portType` parameter** — current signature is `popOut(html:bridge:spaceId:createdBy:messageId:title:in:)`. Must add `portType: String = "web"` and wire through to `PortPanel` init. (`PortPanel.portType` field already exists — only the `popOut` call-site plumbing is missing.) Also: the existing-panel re-activation branch unconditionally calls `destroyWebView` + `createPortWebView` — must be guarded to skip WKWebView recreation when `portType == "terminal"`.

3. **`ghostty_runtime_config_s` callbacks are mandatory** — `wakeup_cb`, `action_cb`, `close_surface_cb`, clipboard callbacks. Stubs required. Without `wakeup_cb → ghostty_app_tick()` the terminal processes no IO.

4. **NSView must exist before `ghostty_surface_new`** — in `makeNSView`, create the wrapper NSView first, pass it to `ghostty_surface_config_s.platform.macos.nsview`, then call `ghostty_surface_new`. The surface does not produce the NSView.

5. **Tee callback bytes must be copied synchronously** — bytes pointer is only valid during the callback. Must `String(bytes:encoding:)` before returning; do not capture the raw pointer into a `Task`.

6. **`ghostty_app_tick` event loop** — must be driven from `wakeup_cb`. Ghostty calls `wakeup_cb` when it needs processing; handler must call `ghostty_app_tick(app)` on MainActor.

7. **Screen-change / HiDPI handling** — `ghostty_surface_set_content_scale` and `ghostty_surface_set_display_id` must fire when the window moves to a different display. Wire to `viewDidChangeBackingProperties` and `NSWindow.didChangeScreenNotification`.

8. **Shell args passing** — `ghostty_surface_config_s.command` may accept binary path only. Confirm from the header whether multi-word commands and args arrays are passed separately or concatenated. Resolve before rewriting `spawnTerminalAgentPort`.

9. **`<p42>` during warmup** — `TerminalOutputProcessor` discards all output until first prompt. Tags emitted before warmup completes are silently lost. `extractP42Tags` must also run on the raw buffer path during warmup, bypassing the discard for tag extraction only.

10. **JIT / executable-memory entitlement (Apple Silicon) — REQUIRED, discovered Step 2.** GhosttyKit allocates **anonymous executable memory at runtime** (GPU/font path, hit the moment a surface renders — NOT during the lightweight `ghostty_info()` probe). On Apple Silicon the kernel kills the process with `EXC_BAD_ACCESS / SIGKILL (Code Signature Invalid)`, namespace `CODESIGNING`, "Invalid Page" — the faulting PC sits in anonymous memory just past the app image. ✅ RESOLVED: added `com.apple.security.cs.allow-jit` + `com.apple.security.cs.allow-unsigned-executable-memory` to **all three** entitlement files (`Port42.dev.entitlements`, `Port42.entitlements`, `Port42.release.entitlements`). Mirrors what the upstream Ghostty.app ships with; notarization permits them. This applies to **every** build config — debug (took effect even with hardened runtime off, `flags=0x0`) and the future notarized release.

---

## Step 2 findings (verified 2026-06-24)

Confirmed from the header + a working harness (`GhosttyDebugHarness.swift`, DEBUG-only menu "Ghostty Debug → Test Ghostty Surface"):

- **Init sequence that works:** `ghostty_init(0, nil)` (once/process) → `ghostty_config_new()` + `ghostty_config_finalize()` → fill `ghostty_runtime_config_s` (all 7 callbacks) → `ghostty_app_new(&rt, cfg)` → create `NSView` → `ghostty_surface_config_new()` + set `platform_tag`/`nsview`/`scale_factor`/`command` → `ghostty_surface_new(app, &sc)` → `ghostty_surface_set_content_scale` → `ghostty_app_tick`.
- **Gap #3 resolved** — the 7 mandatory callbacks: `wakeup_cb` (drives `ghostty_app_tick` on main via `DispatchQueue.main.async`), `action_cb`→false, `read_clipboard_cb`→false, `confirm_read_clipboard_cb`/`write_clipboard_cb`/`close_surface_cb`/`tmux_control_cb` no-op. `userdata` = `Unmanaged.passUnretained(harness).toOpaque()` so the C callback can reach the app handle.
- **Gap #4 resolved** — NSView created before `ghostty_surface_new`; pass `Unmanaged.passUnretained(view).toOpaque()` into `sc.platform.macos.nsview`.
- **Gap #8 resolved** — `command` is a single `const char*`; `/bin/zsh` with no args works. Pass via `withCString` so it stays valid across the `ghostty_surface_new` call. `io_mode` defaults to `GHOSTTY_SURFACE_IO_EXEC` (Ghostty owns the PTY) — no need to set it.
- **`NSLog` variadic form is unavailable** in Port42Lib under this SDK — use string interpolation (`NSLog("…\(x)")`), matching the existing Port42Lib convention.
- **Keyboard input is NOT wired at Step 2** — a bare `NSView` renders and the shell runs, but nothing forwards `keyDown:` → `ghostty_surface_key()`. Typing arrives in Step 4 (NSView subclass) / Step 5 (NSViewRepresentable). Expected, by design.
- **Ghostty app handle is a process-wide singleton** — create it once (`ghostty_init` → `ghostty_app_new`) and NEVER free it mid-process. It registers global/atexit cleanup with JIT trampolines; calling `ghostty_app_free` while the process keeps running unmaps those pages and `exit()`'s `__cxa_finalize` later jumps into the freed page → crash. The harness now frees only the **surface** on window close; the app singleton lives for the whole process. The production `NSViewRepresentable` (Step 5) must follow the same rule.

### Dev-workflow gotcha — NEVER rebuild over a running instance (cost ~an hour of false crashes)

Several `EXC_BAD_ACCESS / SIGKILL (Code Signature Invalid) / CODESIGNING "Invalid Page"` crashes during Step 2 debugging were **NOT Ghostty bugs** — they were a build-hygiene artifact:

- `build.sh` copies the binary with `cp` (in place, same inode) and then `codesign --force` (rewrites in place). Doing this to a **live** process mutates the file backing its mmap. macOS maps the mach-o lazily; a page touched only later (e.g. a C++ static-mutex destructor at `exit()`, or a not-yet-rendered Ghostty code path) gets paged in *after* the overwrite, its hash no longer matches the signature, and the kernel kills the process with `CODESIGNING Invalid Page`.
- **Tell-tale:** faulting address is in a **file-backed `__DATA`/`__TEXT` page** (`vmRegionInfo` shows `SM=COW … /Port42`), and the termination namespace is `CODESIGNING`, not `KERN_INVALID_ADDRESS`. A genuine use-after-free looks different.
- **Distinguish from the real JIT crash (gap #10):** that one faults in **anonymous** executable memory (not in any image) and is fixed by `allow-jit`. This one faults in the **signed binary's own pages** and is fixed by not rebuilding over a running app.
- **Fix (in `build.sh`):** `pkill -x Port42` before the `cp`/`codesign` packaging step. **For manual testing during these steps, run an immutable copy outside Dropbox** (`cp -R .build/Port42.app /tmp/Port42-test.app && open /tmp/Port42-test.app`) so neither a rebuild nor Dropbox can mutate the bundle mid-run. Confirmed: the `/tmp` copy survives surface-create → window-close → ⌘Q cleanly.

### Dev-workflow gotcha — how to read the verification logs (cost ~an hour of chasing the wrong log window in Step 3)

The running Port42 instance is a **live dev environment**: it restores ~28 port panels on launch, including a `port42-dev` CLI terminal companion that is itself running a **Claude Code TUI** (this is often the very session driving the build). Two consequences pollute the logs and made Step 3's `[Ghostty]`/`[tee]` evidence nearly impossible to find:

- **Legacy xterm port floods the log.** `cli-terminal.html` (the path Step 10 deletes) calls `log()` on *every* PTY output chunk (`[Port42:port:log] [p42-terminal:…] chunk #N …` and `extractTaggedContent text[0..200]…`). A static shell logs almost nothing, but an **animated agent TUI repaints several times/sec** → hundreds of lines/second, each a snapshot of the screen (often the build conversation echoed back). **Do not close this panel to quiet it — it may be the session you are working in.** Filter it instead.
- **`[sync]` presence spam.** The WebSocket sync layer logs continuous online/offline presence churn.

**Process logs like this:**
1. **Capture each run's stderr to a uniquely-named file** (e.g. `p3.log`, `p4.log`) and **read by PID** — launch races (`pkill; sleep 1; launch &` plus SwiftUI reopen) routinely produce 2+ instances writing the same file. Confirm which PID wrote the probe line and follow that PID only.
2. **Filter the noise on read** to get the real app lifecycle:
   ```bash
   grep -vE 'p42-terminal|\[sync\]' run.log | grep -E '\[Ghostty\]|\[tee\]|GhosttyKit probe'
   ```
3. **Beware buffering:** stderr→file is block-buffered, but the companion/sync spam flushes it constantly, so freshly-written `[Ghostty]` lines do appear — if they're genuinely absent, the harness didn't run (don't assume buffering).
4. **NSLog does not reach `log show`** for this app under `get-task-allow` debug builds — it goes to stderr only. The unified log is a dead end; always redirect stderr to a file.

> Step 3 lesson: the `[Ghostty] app created`, `surface created`, and `[tee] "Last login: …\r\n"` lines were present the whole time — buried under thousands of `p42-terminal` redraw lines from an accidentally-launched second session. Filter first, then conclude.

---

## File-by-File Changes

### 1. Build infrastructure

**`build.sh`** — add before `swift build`:
```bash
GHOSTTYKIT_SHA256="cbe4a8b5f8c00ea9ffe4274e5e764009b6efe2dc877646fd6fa12d34146ce8fe"  # verify on first build
GHOSTTY_COMMIT="fc2d507dcf4d67228e56c6d69ad9e9aa2080a6dc"
GHOSTTYKIT_URL="https://github.com/manaflow-ai/ghostty/releases/download/xcframework-${GHOSTTY_COMMIT}-crashsubdir-cmux-crash-v1/GhosttyKit.xcframework.tar.gz"
if [ ! -d "$DIR/GhosttyKit.xcframework" ]; then
    echo "[build] Downloading GhosttyKit..."
    curl -L -o /tmp/ghosttykit.tar.gz "$GHOSTTYKIT_URL"
    echo "$GHOSTTYKIT_SHA256  /tmp/ghosttykit.tar.gz" | shasum -a 256 -c -
    tar -xz -C "$DIR" -f /tmp/ghosttykit.tar.gz
fi
```

**`Package.swift`**:
```swift
.binaryTarget(name: "GhosttyKit", path: "GhosttyKit.xcframework"),
// Port42Lib target dependencies: add "GhosttyKit"
```

Add `GhosttyKit.xcframework` to `.gitignore`.

### 2. New `Sources/Port42Lib/Views/GhosttyTerminalView.swift`

`NSViewRepresentable`. Key constraints:
- Create wrapper `NSView` first, pass to config, then call `ghostty_surface_new`
- Install tee callback immediately after creation; copy bytes synchronously before returning
- Register surface in `AppState.ghosttyTerminalSurfaces[companionName.lowercased()]` on makeNSView
- Unregister and call `ghostty_surface_free` in `dismantleNSView`
- Handle `viewDidChangeBackingProperties` → `ghostty_surface_set_content_scale`
- Handle frame resize → `ghostty_surface_set_size(surface, UInt32(width_px), UInt32(height_px))` — **PIXELS** (points × backingScaleFactor), NOT cols/rows (verified Step 4)
- Handle `NSWindow.didChangeScreenNotification` → `ghostty_surface_set_display_id`

Config struct (JSON-encoded in `PortPanel.html`):
```swift
struct TerminalPortConfig: Codable {
    let command: String
    let args: [String]
    let cwd: String
    let spaceId: String
    let spaceName: String
    let companionName: String
    let createdBy: String
}
```

### 3. `Sources/Port42Lib/Services/TerminalOutputProcessor.swift`

Add:
```swift
static func extractP42Tags(from text: String) -> [String]
// regex: /<p42>([\s\S]*?)<\/?p42>/gi — returns all matched inner strings, trimmed
```

Add `onP42Output: (([String]) -> Void)?`. Call `extractP42Tags` in `flush()` **before** the
`guard trimmed != lastPosted` dedup check. Also call during warmup discard path (bypass
discard for tag extraction only — warmup still discards for `onFlush`).

### 4. `Sources/Port42Lib/Views/PortWindowManager.swift`

Add `portType: String = "web"` to `popOut` signature, thread through to `PortPanel` init.
Guard the re-activation branch: skip `destroyWebView`/`createPortWebView` when `portType == "terminal"`.

In `createWindow(for:in:)`:
```swift
if panel.portType == "terminal", let config = panel.terminalConfig {
    makeGhosttyWindow(panel: panel, config: config, windowFrame: windowFrame)
    return
}
```

Add to `PortPanel`:
```swift
var terminalConfig: TerminalPortConfig? {
    guard portType == "terminal" else { return nil }
    return try? JSONDecoder().decode(TerminalPortConfig.self, from: Data(html.utf8))
}
```

### 5. `Sources/Port42Lib/Services/AppState.swift`

**`spawnTerminalAgentPort()`** — replace `PortLibrary.load("cli-terminal", slots:)` block:
```swift
let config = TerminalPortConfig(command: command, args: args, cwd: cwd,
    spaceId: spaceId, spaceName: spaceName, companionName: name, createdBy: currentUser?.id ?? "")
let json = (try? String(data: JSONEncoder().encode(config), encoding: .utf8)) ?? "{}"
let bridge = PortBridge(appState: self, spaceId: spaceId, messageId: portMessageId, createdBy: name)
portWindows.popOut(html: json, bridge: bridge, spaceId: spaceId, createdBy: name,
                   messageId: portMessageId, title: name, portType: "terminal", in: bounds)
```

**Add** `ghosttyTerminalSurfaces: [String: OpaquePointer] = [:]`

**`routeMentionsToTerminals()`** — after existing TerminalBridge lookup, add:
```swift
if let surface = ghosttyTerminalSurfaces[key] {
    let line = "[\(senderName)]: \(content)\r"
    line.withCString { ghostty_surface_text_input(surface, $0, UInt(strlen($0))) }
}
```

### 6. New `shim/main.go` → built to `Contents/MacOS/port42-claude-shim`

Standalone Go module (`shim/go.mod`, module name `github.com/port42/shim`). Built separately from the gateway in `build.sh`. Small Go binary. Logic:
```
if basename(argv[0]) == "claude" && PORT42_HOOKS_SOCKET != "" {
    settings := buildHooksSettings(socketPath)
    exec real claude with ["--settings", settings] + argv[1:]
} else {
    exec argv[0] with argv[1:]  // passthrough
}
```

`build.sh` builds this alongside the gateway. Bundle structure:
```
Contents/MacOS/
  port42-claude-shim      # the shim binary
```

At PTY spawn in `GhosttyTerminalView.makeNSView`:
- Create a temp dir per session: `/tmp/port42-shim-<uuid>/`
- Symlink `claude → /path/to/port42-claude-shim` inside it
- Also symlink `port42-claude-shim → port42-claude-shim` (for passthrough calls)
- Prepend this temp dir to PATH in surface env_vars
- Set `PORT42_HOOKS_SOCKET` in env_vars to the session socket path
- Clean up temp dir in `dismantleNSView`

### 7. New `Sources/Port42Lib/Services/TerminalHooksService.swift`

General-purpose hooks receiver — no knowledge of Claude internals.
See design in "Terminal Hooks System" section above.

The notifier command Port42 passes to Claude via `--settings` is a small inline shell
snippet (or a bundled binary) that writes the JSON hook payload to the socket path.
Claude Code's hooks docs specify `"type": "command"` — the command receives the event on stdin.

### 8. Remove files (Step 10 only)

- `Sources/Port42Lib/Resources/ports/cli-terminal.html`
- `Sources/Port42Lib/Resources/xterm.js`
- `Sources/Port42Lib/Resources/xterm.css`

---

## Incremental Delivery Steps

Every step delivers observable evidence and eliminates a risk class. Do not proceed to the
next step until the current one is verified.

---

### Step 1 — GhosttyKit links and app launches

**Do:** Add `build.sh` download block with `shasum` check, `.binaryTarget` in `Package.swift`,
`"GhosttyKit"` dep on Port42Lib, `.gitignore` entry. Add one probe file:
```swift
// Sources/Port42Lib/Services/GhosttyProbe.swift
import GhosttyKit
func ghosttyProbe() -> Bool {
    // Use ghostty_app_new as the probe — it is the documented entry point.
    // Confirm the exact function name against the xcframework headers before implementing;
    // do NOT assume ghostty_config_new exists (it is not listed in the C API section).
    // Minimum viable probe: call ghostty_app_new with fully stubbed configs, log the pointer,
    // immediately call ghostty_app_free if it succeeds.
    return true  // placeholder — replace with real call once headers are confirmed
}
```
Call at app launch and log the result.

**Verify:** `./build.sh` succeeds. App launches. Log shows `[Port42] GhosttyKit probe: true`.
GhosttyKit is a **static** archive, so verify linkage with
`nm .build/debug/Port42 | grep ghostty_info` (symbol present as `T`), NOT `otool -L`
(static symbols don't appear there). ✅ Done 2026-06-24.

**Risk eliminated:** SPM binary target integration, architecture compatibility, header
bridging, build system conflicts. Nothing else can proceed until this is green.

---

### Step 2 — App + surface create without crash ✅ DONE 2026-06-24 (positively verified)

> Result: window opens, `/bin/zsh` renders with a live prompt, `process_exited=false`. Closing
> the window frees the surface and the app stays alive; the harness then **positively verifies
> shutdown** — it captures the PTY shell PID via `ghostty_surface_foreground_pid`, frees the
> surface, and confirms `kill(pid,0)==ESRCH` (`✅ reaped`), proving Ghostty killed/reaped the
> child with no orphan. Not just "no crash" — provable correct teardown.
>
> Two real issues surfaced and were fixed (neither was a Ghostty bug):
> 1. **JIT entitlement** (gap #10) — Apple Silicon SIGKILLs the process the moment the surface
>    renders without `allow-jit`. See "Step 2 findings".
> 2. **CODESIGNING "Invalid Page" crashes were the build environment**, not Ghostty: the binary
>    was being modified on disk while running — by Dropbox racing/evicting `.build`, and by
>    `build.sh` rebuilding over the live bundle in place. Fixed by symlinking `.build` outside
>    Dropbox + `pkill` before packaging in `build.sh`. (See ghostty-teardown-rca.md.)
>
> Harness teardown follows cmux's `disposeSurface()` ordering: a `tearingDown` flag gates
> `tick()` and the surface ref is nulled before `ghostty_surface_free`, so no `ghostty_app_tick`
> can run against a freed surface. `windowShouldClose` returns false + `orderOut` so closing the
> throwaway debug window doesn't terminate the host SwiftUI app.

**Do:** Behind `#if DEBUG`, add a menu item "Test Ghostty Surface": create
`ghostty_runtime_config_s` with stubbed callbacks (wakeup calls `ghostty_app_tick`, others
no-op), call `ghostty_app_new`, create a plain `NSView()` on MainActor, fill
`ghostty_surface_config_s` with that view and `/bin/zsh` as command, call
`ghostty_surface_new`, log the pointer. Keep the surface alive for 1s (via a
`DispatchQueue.main.asyncAfter`) to let the shell start, then call `ghostty_surface_free`.

**Verify:** No crash. Log shows a non-nil surface address. Shell prompt appears in the
NSView within 1s (confirms gap #8 resolved: `/bin/zsh` with no args works as `command`).
`ghostty_surface_process_exited()` returns false before free.

**Risk eliminated:** Mandatory callback wiring, `ghostty_app_new` ABI, struct layout,
NSView-before-surface constraint. **Gap #8 (shell args format) explicitly resolved here** —
do not proceed to Step 3 until the shell prompt is confirmed visible.

---

### Step 3 — Tee callback fires with copyable bytes

**Do:** Extend Step 2's harness (same debug menu item — do not delete Step 2's code).
Install the tee callback after surface creation. Drive the event loop by scheduling a
repeating `Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true)` on the main
RunLoop that calls `ghostty_app_tick(app)` — this is the same mechanism `wakeup_cb` uses
in production. Keep the surface alive for 3s then free. In the C trampoline: copy bytes
to `String` synchronously before returning, then `Task { @MainActor in print("[tee]", str) }`.

**Verify:** Log shows `[tee]` lines with shell startup output. No crash. Bytes valid.

**Risk eliminated:** Confirms the cmux fork's `pty_tee_cb` extension exists. Confirms the
bytes-copy-before-return pattern. Eliminates all `<p42>` capture risk at the byte level.

---

### Step 4 — Ghostty renders in a real NSPanel (no SwiftUI) ✅ DONE 2026-06-24

> Result: positively verified. A `GhosttyInputView: NSView` subclass (in `GhosttyDebugHarness.swift`)
> forwards AppKit input to the surface and keeps size/scale/display in sync. The tee stream proved
> typing reaches the PTY — keystrokes (`echo hello`) echoed back, and **arrow-key history works**
> (`\u{1B}[A` up-arrow recalled a prior command), confirming the `text=nil → Ghostty synthesizes
> from keycode+mods via Carbon` path for non-printable keys. Resize reflow confirmed by hand. No crash.
>
> **Step 4 findings:**
> - **`ghostty_surface_set_size` takes PIXELS** (`width_px, height_px`), not cols/rows — the original
>   plan was wrong. `ghostty_surface_size_s` distinguishes `columns/rows` (u16) from `width_px/height_px`
>   (u32); `set_size` takes the u32 pair. Pass `points × backingScaleFactor`.
> - **`keycode` = macOS virtual `event.keyCode`** (u32 in `ghostty_input_key_s`). Ghostty maps it via
>   the Carbon keymap linked in Step 1 — that Carbon dependency is exactly for this.
> - **Text policy that works:** provide `key.text` only for printable chars (first scalar ≥ 0x20, not
>   DEL, not 0xF700–0xF8FF function PUA, not while ⌘ is held); leave `text=nil` otherwise so Ghostty
>   generates control/nav/arrow sequences itself. IME / dead keys deferred to Step 5 (`NSTextInputClient`).
> - **mods bitmask:** combine `GHOSTTY_MODS_*.rawValue` and build with `ghostty_input_mods_e(rawValue:)`.
> - **Focus:** `becomeFirstResponder`/`resignFirstResponder` → `ghostty_surface_set_focus`. Window must
>   `makeFirstResponder(view)` and the view must return `acceptsFirstResponder = true`, or keys never arrive
>   (and AppKit beeps — that beep in Steps 2/3 was the *absence* of this, not a bug).
> - **Retina/multi-monitor (#3) not hardware-verifiable here** (no second display). The `content_scale`
>   path is wired to `viewDidChangeBackingProperties` — the same callback that set the correct initial
>   scale — and `set_display_id` to `viewDidMoveToWindow` + `didChangeScreenNotification`. Correct by
>   construction; re-verify on a HiDPI/multi-display machine before shipping.
> - **Teardown safety:** null the view's `surface` ref *before* `ghostty_surface_free` so queued AppKit
>   events (key/resize/mouse) can't call into a freed surface.

**Do:** Standalone debug `NSWindowController` (no SwiftUI). Real `NSView` subview passed to
surface config. Drive wakeup loop. Show panel.

**Verify:** Terminal renders, shell prompt appears, typing works. Resize via
`ghostty_surface_set_size` reflows the terminal. Move to Retina display — text stays sharp
(confirms `viewDidChangeBackingProperties` → `ghostty_surface_set_content_scale` fires).

**Risk eliminated:** Metal/CAMetalLayer rendering in a non-Ghostty host. AppKit event
forwarding. CVDisplayLink. HiDPI. Isolated from SwiftUI so Step 5 failures are unambiguously
SwiftUI-specific.

---

### Step 5 — NSViewRepresentable wrapping works inside NSHostingView ✅ DONE 2026-06-24

> Result: positively verified through the production stack (`GhosttyTerminalView` →
> `NSHostingView` → `NSPanel`). Renders, types (`tee:swiftui` shows keystrokes flowing),
> resize reflows, and focus/cursor-blink toggles on window key changes. No crash.
>
> **Step 5 architecture (done as part of this step):**
> - **Extracted `GhosttyApp` (`Services/GhosttyApp.swift`, production `@MainActor` singleton)** —
>   owns `ghostty_init`, config, the 7 runtime callbacks, the app handle, `ensureApp()`, `tick()`.
>   **One app, many surfaces.** The debug harness now uses `GhosttyApp.shared` too, so there is a
>   single process-wide app (never freed) regardless of how many terminals open.
> - **Promoted `GhosttyInputView` to production** (`Views/GhosttyTerminalView.swift`); was DEBUG-only.
> - **`GhosttyTerminalView: NSViewRepresentable` + `Coordinator`** — `makeNSView` creates view→surface
>   (view ptr first, gap #4), installs the tee (delivers via `onTee`; Step 6 wires `TerminalOutputProcessor`),
>   stashes the surface in the Coordinator. `dismantleNSView` → `Coordinator.teardown()` clears the tee +
>   nulls the view ref before `ghostty_surface_free`.
> - **`TerminalPortConfig` introduced now** (Codable) so the view signature doesn't churn in Step 8;
>   env/hooks fields present but unused until Steps 7–8.
>
> **Step 5 findings:**
> - **Focus must track WINDOW key state, not first-responder.** When a window resigns key the view stays
>   its first responder, so `resignFirstResponder` never fires → cursor kept blinking on an unfocused
>   terminal. Fix: observe `NSWindow.didBecomeKey/didResignKeyNotification` on the view's window →
>   `ghostty_surface_set_focus`. (Mirrors how Ghostty.app itself drives focus.)
> - **Scale is unknown at `makeNSView`** (view not yet in a window) — set `sc.scale_factor = 2.0` as a
>   placeholder, then apply the real `backingScaleFactor` in `viewDidMoveToWindow` + `viewDidChangeBackingProperties`.
> - **NSPanel must take key** (`becomesKeyOnlyIfNeeded = false`) or typing/focus never reach the surface.
> - **IME / dead keys still deferred** to a later polish step (`NSTextInputClient`); ASCII + special keys work.

**Do:** Wrap Step 4 in `GhosttyTerminalView: NSViewRepresentable`. Place in `NSHostingView`
inside `NSPanel` — the exact production stack.

**Verify:** Terminal renders. Retina display move — no blur. Window edge drag — terminal
reflows. Focus/unfocus — cursor blink toggles.

**Risk eliminated:** SwiftUI layout fighting Metal layer. NSViewRepresentable lifecycle
mapping to Ghostty surface lifecycle.

---

### Step 6 — `<p42>` detected from live terminal output

**Do:** Wire tee bytes into `TerminalOutputProcessor.receive()` for the live terminal from
Step 5. Add `extractP42Tags`. Manually type `echo '<p42>hello</p42>'`. Confirm via `print`
(no AppState yet). Also test with a large prefix that forces the tag to span a tee chunk
boundary.

**Verify:** `extractP42Tags` returns `["hello"]`. Warmup discard doesn't eat the tag.
Fragmented delivery handled correctly.

**Risk eliminated:** Real PTY output (ANSI echo, carriage returns, shell decoration) doesn't
corrupt tag extraction. Warmup bypass works. Fragmentation-safe.

---

### Step 7 — Hooks shim injects into `claude`, `Stop` event received

**Do:**
1. Write `port42-claude-shim` Go binary: detects invocation as `claude`, reads
   `PORT42_HOOKS_SOCKET`, execs real `claude` with `--settings '{"hooks":{...}}'` prepended.
   Passthrough if not `claude` or no socket path. Add to `gateway/` subdir, build in `build.sh`.
2. Write `TerminalHooksService`: creates Unix domain socket at hooks path, accepts connection,
   decodes JSON events, publishes `TerminalHookEvent` via `AsyncStream`.
3. In `GhosttyTerminalView.makeNSView`: build `TerminalEnvironment`:
   - Shim temp dir prepended to PATH
   - `PORT42_HOOKS_SOCKET` = session socket path
   - `PORT42_CLAUDE_PATH` = `ClaudeCodeSetup.findBinary("claude")` resolved at spawn time
   - `PORT42_SPACE_ID` = `config.spaceId`
   - `PORT42_SPACE_NAME` = `config.spaceName`
   - `ANTHROPIC_API_KEY` injected from keychain if present
   Create `TerminalHooksService`, pass env to surface env_vars.
4. Subscribe to `TerminalHookEvent.turnComplete` → `print` the response text.

**Notifier command (pin before implementing):** The command Claude runs when a hook fires
is an inline shell one-liner written into the `--settings` JSON by the shim:
```sh
read -r payload; printf '%s' "$payload" | nc -U "$PORT42_HOOKS_SOCKET"
```
`nc -U` writes stdin to the Unix domain socket and exits. This is portable on macOS (no
extra binary needed). The shim encodes this as the `command` value for each hook type.

**Verify:** In the live Ghostty terminal, run `claude -p "say the word banana"`. Log shows:
- Shim detected `PORT42_CLAUDE_PATH` and exec'd it (add a shim log line for this)
- `PORT42_SPACE_ID` and `PORT42_SPACE_NAME` visible in terminal env (`printenv | grep PORT42`)
- `TerminalHookEvent.turnComplete` received with text containing "banana"
No `<p42>` tag needed.

**Risk eliminated:** Shim exec chain works. Hook socket handshake works. `turnComplete` event
carries clean response text. Space context env vars wired. All without terminal output parsing.

---

### Step 8 — One companion, one native terminal, hooks post to space

**Do:** Add `portType:` to `popOut`. Add `portType == "terminal"` branch in `createWindow`.
Rewrite `spawnTerminalAgentPort` to use JSON config. Wire `TerminalHookEvent.turnComplete` →
`sendMessageAsCompanion` (primary for Claude engine). Wire `onP42Output` →
`sendMessageAsCompanion` (fallback for non-Claude tools). Keep a `useGhosttyTerminal` flag
to preserve old xterm path as fallback during transition.

**Verify:** Claude Code companion with `openInTerminal: true` opens a native Ghostty window.
`@claude-code say hello` → Claude responds → response posts in space via hooks (no `<p42>`
tag emitted). For the `<p42>` fallback path: create a command companion whose command is
`bash -c 'echo "<p42>hello from bash</p42>"'` — it should post "hello from bash" to the
space via the tag path. Port window position/size persist across restarts.

**Risk eliminated:** Full end-to-end delivery on both output paths. Integration plumbing
proven.

---

### Step 9 — @mention routing reaches terminal stdin

**Do:** Register surface in `ghosttyTerminalSurfaces` on makeNSView, unregister on dismantle.
Note: SwiftUI calls `dismantleNSView` on view deallocation, not on panel close — wire
`NSWindow.willCloseNotification` in the `Coordinator` to explicitly unregister the surface
when the NSPanel closes, so the registry is cleared immediately on close rather than waiting
for SwiftUI dealloc. Add Ghostty lookup in `routeMentionsToTerminals`.

**Verify:**
- `@claude-code do something` from chat → text arrives in terminal stdin
- Close the port panel → confirm `ghosttyTerminalSurfaces[key]` is nil (log it on unregister)
- Send `@claude-code` again after panel is closed → no crash, mention is silently dropped

---

### Step 10 — Remove xterm path, verify no regression

**Do:** Remove `cli-terminal.html`, `xterm.js`, `xterm.css`. Remove `useGhosttyTerminal` flag.

**Verify:** All items in the verification checklist pass. Web port calling `terminal.spawn()`
still works.

**Risk eliminated:** Regression in user-built web ports. Dead code removed cleanly.

---

## Verification Checklist

1. `swift build` — clean compile, GhosttyKit linked, `port42-claude-shim` in MacOS/
2. Claude Code companion (`openInTerminal: true`) added to space → native Ghostty window opens, no WKWebView in view hierarchy
3. Type in terminal → keystrokes reach the shell
4. Resize window → terminal reflows correctly
5. Move to Retina display → text stays sharp
6. Claude Code companion responds to prompt → response posts to space via hooks `Stop` event (no `<p42>` tag needed)
7. Non-Claude companion emits `<p42>hello</p42>` → "hello" posts to space via tag path (fallback works)
8. `@claude-code do something` from chat → text arrives in terminal stdin
9. Port window position/size persists across restarts
10. Web port calling `terminal.spawn()` still works (TerminalBridge path unchanged)
11. `cli-terminal.html` and `xterm.js` absent from built `.app` bundle
12. No `cmux` identifiers anywhere in code, comments, or log output
