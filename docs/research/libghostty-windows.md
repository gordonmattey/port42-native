# Spike: can libghostty back a Windows terminal port?

Date: 2026-09-25. Research only; no product code changed. Evidence gathered by building Ghostty, not by reading it.

## Verdict

**No. Use ConPTY plus a JS terminal in WebView2.** Confidence: high, on build evidence rather than inference.

Three independent findings, any one of which is sufficient:

1. The Ghostty API Port42 calls is not the cross-platform `libghostty`. Ghostty's own build
   system labels it "NOT libghostty ... just the glue between Ghostty GUI on macOS and the
   full Ghostty GUI core". The README's "macOS, Linux, Windows, and WebAssembly" claim is
   scoped, in the same sentence, to `libghostty-vt`, a different library with no surface,
   no pty, and no renderer.
2. The GUI-core library does not cross-compile to Windows. It fails on the first POSIX
   header. Patch past that and it fails again inside the OpenGL renderer, which is the
   Linux/GTK renderer (EGL with a Mesa-specific platform enum, plus DMA-BUF export). There
   is no WGL, no D3D, no portable GL path.
3. Even with a hypothetical Windows build, `ghostty_surface_new` cannot succeed on Windows.
   The embedded app runtime's platform union has exactly two variants, `macos = 1` and
   `ios = 2`, carrying an `NSView` or a `UIView`. Any other tag is a compile-time
   `error.UnsupportedPlatform`.

A fourth finding raises the cost of the libghostty path regardless of platform: Port42 does
not depend on upstream Ghostty at all. It vendors a third-party fork, and three of the C
functions it calls exist only in that fork.

## 1. Port42's dependency surface on libghostty

`import GhosttyKit` appears in 6 files:

```
Sources/Port42Lib/Views/GhosttyTerminalView.swift:3
Sources/Port42Lib/Services/AppState.swift:4
Sources/Port42Lib/Services/GhosttyProbe.swift:2
Sources/Port42Lib/Services/GhosttyApp.swift:2
Sources/Port42Lib/Services/GhosttyResizeSpike.swift:33
Sources/Port42Lib/Services/GhosttyDebugHarness.swift:4
```

### C functions called (28)

Lifecycle and app: `ghostty_init`, `ghostty_info`, `ghostty_app_new`, `ghostty_app_tick`.

Config: `ghostty_config_new`, `ghostty_config_load_string`\*, `ghostty_config_finalize`,
`ghostty_surface_config_new`.

Surface lifecycle: `ghostty_surface_new`, `ghostty_surface_free`,
`ghostty_surface_process_exited`, `ghostty_surface_foreground_pid`.

Geometry and focus: `ghostty_surface_set_size`, `ghostty_surface_set_content_scale`,
`ghostty_surface_set_focus`, `ghostty_surface_set_display_id`.

Input: `ghostty_surface_key`, `ghostty_surface_text`, `ghostty_surface_text_input`\*,
`ghostty_surface_preedit`, `ghostty_surface_ime_point`, `ghostty_surface_mouse_pos`,
`ghostty_surface_mouse_button`, `ghostty_surface_mouse_scroll`.

Selection: `ghostty_surface_has_selection`, `ghostty_surface_read_selection`,
`ghostty_surface_free_text`.

Output tap: `ghostty_surface_set_pty_tee_cb`\*.

Types consumed: `ghostty_app_t`, `ghostty_surface_t`, `ghostty_runtime_config_s`,
`ghostty_input_key_s`, `ghostty_input_mods_e`, `ghostty_input_action_e`,
`ghostty_input_mouse_state_e`, `ghostty_input_mouse_button_e`,
`ghostty_input_mouse_momentum_e`, `ghostty_text_s`, `ghostty_env_var_s`.

\* = exists only in the vendored fork, see section 4.

The surface is small, 28 functions, and it is entirely "feed a surface input, let the
surface draw itself". There is no function in the list that returns renderable cell data.
Port42 never reads the grid. That matters: the dependency is not on Ghostty's parser, it is
on Ghostty owning the pixels.

## 2. What libghostty actually is, from source

Clone: `https://github.com/ghostty-org/ghostty` at `982fe90d941e4b4aab4905ffcbcfdea60bd83343`
(2026-09-24), version `1.3.2-dev`, `minimum_zig_version = "0.16.0"` (`build.zig.zon:6`).

### The naming is load-bearing

`build.zig:213-240`:

```zig
    // Runtime "none" is libghostty, anything else is an executable.
    if (config.app_runtime != .none) {
        ...
    } else if (!config.emit_lib_vt) {
        // The macOS Ghostty Library
        //
        // This is NOT libghostty (even though its named that for historical
        // reasons). It is just the glue between Ghostty GUI on macOS and
        // the full Ghostty GUI core.
        const lib_shared = try buildpkg.GhosttyLib.initShared(b, &deps);
        const lib_static = try buildpkg.GhosttyLib.initStatic(b, &deps);
```

The artifacts this produces are named `ghostty-internal.dll` / `ghostty-internal.a`. That
is the target whose header declares `ghostty_surface_new` (`include/ghostty.h:1170`),
`ghostty_app_new` (`:1154`) and `ghostty_init` (`:1131`), which is to say: the target
Port42 links.

The README's portability claim is about the other library. `README.md:157-159`:

> `libghostty-vt` is already available and usable today for Zig and C and
> is compatible for macOS, Linux, Windows, and WebAssembly.

`libghostty-vt` ships as `include/ghostty/vt/*.h` (37 headers: terminal, screen, osc, sgr,
selection, key encoder, mouse encoder). Grepping those headers for `surface_new` returns
nothing. It is a VT parser and screen-state library. It does not open a pty, spawn a
process, or draw anything.

### Windows-specific code does exist, in the core

`src/pty.zig:19-20`:

```zig
pub const Pty = switch (builtin.os.tag) {
    .windows => WindowsPty,
```

`WindowsPty` (`src/pty.zig:326-490`) is a real ConPTY implementation: named pipe via
`CreateNamedPipeW`, `CreatePseudoConsole` returning an `HPCON` (`:443`),
`ResizePseudoConsole` in `setSize` (`:474`), `ClosePseudoConsole` in `deinit`. Process
spawn has a Windows path too: `src/Command.zig:173` `.windows => try self.startWindows(arena)`,
65 `windows` references in that file. `src/termio/Exec.zig` has a
`ReadThread.threadMainWindows` (`:142`), `TerminateProcess` teardown (`:1160`), and
defaults the shell to `cmd.exe` (`:762`, `:841`).

So the pty question has a positive answer: Ghostty's terminal core can drive ConPTY. That
is not where this dies.

### The renderer is where it dies

`src/renderer/backend.zig:20-24`:

```zig
        if (target.os.tag.isDarwin()) return .metal;
        return .opengl;
```

Three backends exist: `opengl`, `metal`, `webgl` (`src/renderer/backend.zig:5-9`). There is
no D3D and no Vulkan. Windows would take `opengl`. But Ghostty's OpenGL renderer is the
Linux one:

- `src/renderer/OpenGL.zig:52-54` initializes the display with
  `egl.c.EGL_PLATFORM_SURFACELESS_MESA`. EGL, and a Mesa-specific platform enum.
- `grep -rln "wgl\|WGL" pkg/opengl/ src/renderer/` returns nothing. No Windows GL binding.
- `src/renderer/Dmabuf.zig:1-9` states its own scope: "This may be used on apprts like GTK
  that require us to manually export each frame". It carries a DRM fourcc and a DRM
  modifier, and closes plane fds with `std.posix.system.close`.

### The embedded runtime accepts only Apple views

`src/apprt.zig:44-49` routes the `.lib` artifact to `apprt/embedded.zig`. That file is
2,525 lines and is written against Objective-C: `const objc = @import("objc")` at line 11,
`nsview`, `initMetal(device: objc.Object)`, `ghostty_inspector_metal_init`.

The decisive lines are `src/apprt/embedded.zig:431-440`:

```zig
pub const PlatformTag = enum(c_int) {
    // "0" is reserved for invalid so we can detect unset values
    // from the C API.

    macos = 1,
    ios = 2,
};
```

and `:388-397`:

```zig
    // If our build target for libghostty is not darwin then we do
    // not include macos support at all.
    pub const MacOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        nsview: objc.Object,
    } else void;
```

Port42 sets exactly this, at `Sources/Port42Lib/Views/GhosttyTerminalView.swift:529-530`:

```swift
        sc.platform_tag = GHOSTTY_PLATFORM_MACOS
        sc.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
```

On a non-Darwin build, `MacOS` is `void`, and `Platform.init` returns
`error.UnsupportedPlatform` for every possible tag. There is no third enum case to add
without designing a new host contract from scratch.

## 3. The build attempt

Toolchain: Zig 0.16.0, the version `build.zig.zon` requires, downloaded to a scratch dir.

```
curl -sL -o zig.tar.xz https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz
```

### Attempt 1: default Windows triple

```
zig build -Dtarget=x86_64-windows --summary all
```

Result: `EXIT=1`. Every C dependency failed with `'stdio.h' file not found`,
`'sys/types.h' file not found`. Cause is environmental, not Ghostty's: `src/build/Config.zig:105-111`
forces `abi = .msvc` when no ABI is given, and MSVC libc headers are not redistributable, so
they are absent when cross-compiling from macOS. Not a real signal. Retried with the GNU ABI,
whose mingw-w64 headers Zig ships.

### Attempt 2: mingw ABI

```
zig build -Dtarget=x86_64-windows-gnu --summary all
```

Result: `EXIT=1`, **123 of 131 steps succeeded**. Every C dependency (freetype, harfbuzz,
png, zlib, oniguruma, glslang, spirv-cross, simdutf, highway, dcimgui) built clean for
`x86_64-windows-gnu`. Two things happened:

`install ghostty-vt success`, meaning libghostty-vt cross-compiled to Windows from a Mac with no
intervention.

`compile lib ghostty Debug x86_64-windows-gnu` failed:

```
./.zig-cache/o/e8e99dbf2cf1a32be40f37649cd919cd/posix_c.h:2:10: fatal error: 'pwd.h' not found
#include <pwd.h>
```

Source: `src/build/SharedDeps.zig:219-229` unconditionally imports `errno.h`, `pwd.h`,
`signal.h`, `sys/types.h`, `unistd.h` as the `posix_c` module, described in the comment
above it as "POSIX C imports that are used throughout Ghostty on a general basis".

### Attempt 3: patch past the POSIX headers

Patched `src/build/SharedDeps.zig` to include only `errno.h` when
`target.result.os.tag == .windows`, then rebuilt with the same command. New wall, inside
the renderer:

```
pkg/opengl/Buffer.zig:75:17: error: expected type 'c_long', found 'isize'
pkg/opengl/egl.zig:80:59: error: expected type '?*anyopaque', found 'c_int'
    const display = c.eglGetPlatformDisplay(platform, id, attribs) orelse return mustError();
src/renderer/Dmabuf.zig:44:46: error: expected type '*anyopaque', found 'comptime_int'
    fds: [max_planes]std.posix.fd_t = @splat(-1),
src/renderer/Dmabuf.zig:55:20: error: incompatible types: '*anyopaque' and 'comptime_int'
            if (fd >= 0) _ = std.posix.system.close(fd);
error: 4 compilation errors
```

`std.posix.fd_t` is `*anyopaque` on Windows, not an integer, so DMA-BUF's fd array does not
even typecheck. These are not four typos. They are the OpenGL renderer telling you it was
written for Linux with Mesa and GTK.

### Control: the actually-portable library

```
zig build -Dtarget=x86_64-windows-gnu -Demit-lib-vt=true --summary all
```

Result: `EXIT=0`. Artifacts produced on a Mac, for Windows:

```
zig-out/bin/ghostty-vt.dll          7,545,344
zig-out/lib/ghostty-vt-static.lib  21,728,920
zig-out/lib/ghostty-vt.lib             54,724
```

This is the clean statement of the situation. The library that cross-compiles to Windows is
the one with no surface API. The library with the surface API is the one that does not
cross-compile.

## 4. Port42 is on a fork, not upstream

`vendor/GhosttyKit-LICENSE.txt`:

```
Source: https://github.com/manaflow-ai/ghostty (a fork of https://github.com/ghostty-org/ghostty)
Pinned commit: fc2d507dcf4d67228e56c6d69ad9e9aa2080a6dc
```

Comparing `GHOSTTY_API` declarations in the vendored `ghostty.h` (115) against upstream's
(102): 14 symbols exist only in the fork, 1 only upstream. The low count in the reverse
direction says upstream drift since the fork point is small, so the 14 are genuine fork
additions:

```
ghostty_config_load_string
ghostty_surface_clear_selection
ghostty_surface_process_output
ghostty_surface_read_screen_clipboard_text
ghostty_surface_render_grid_json
ghostty_surface_render_now
ghostty_surface_scroll_to_offset
ghostty_surface_select_cursor_cell
ghostty_surface_select_cursor_line
ghostty_surface_select_screen_rows
ghostty_surface_selection_screen_rows
ghostty_surface_set_pty_tee_cb
ghostty_surface_set_renderer_realized
ghostty_surface_text_input
```

Port42 calls three of them: `ghostty_config_load_string`, `ghostty_surface_text_input`, and
`ghostty_surface_set_pty_tee_cb`. The last is load-bearing: the pty tee is how
`GhosttyTerminalController` and `TerminalHooksService` see terminal output at all. Upstream
has no equivalent.

Practical consequence: "port libghostty to Windows" is not a task against a 61k-star
upstream project with a Windows CI lane. It is a task against a fork of it, which would
have to be maintained through the same Windows work, and which upstream has no reason to
accept back given that upstream is deliberately moving the cross-platform story to
`libghostty-vt` instead.

Unknown: whether the manaflow fork has any Windows work of its own. Its published
xcframework ships only `ios-arm64`, `ios-arm64-simulator`, `macos-arm64_x86_64`, which is
evidence against, but not proof. Determining it needs a clone of that fork and the same
three build attempts.

## 5. Hosting cost on Windows, both routes

### What Port42's terminal stack is actually made of

```
Sources/Port42Lib/Views/GhosttyTerminalView.swift          683
Sources/Port42Lib/Services/TerminalHooksService.swift      424
Sources/Port42Lib/Services/GhosttyTerminalController.swift 386
Sources/Port42Lib/Services/GhosttyResizeSpike.swift        260
Sources/Port42Lib/Services/GhosttyDebugHarness.swift       256
Sources/Port42Lib/Services/TerminalOutputProcessor.swift   244
Sources/Port42Lib/Services/GhosttyApp.swift                 78
Sources/Port42Lib/Services/GhosttyProbe.swift               36
                                                          2367
```

That total overstates the coupling. `TerminalHooksService` (424) is a Unix-domain-socket
receiver for a normalized event vocabulary, with no terminal knowledge. It has one
platform tie, `import Darwin` for the socket calls, and would move to a named pipe on
Windows. `TerminalOutputProcessor` (244) is a pure byte-stream pipeline: accumulate, strip
ANSI, dedupe, extract `<p42>` tags. Emulator-agnostic as written.

`GhosttyTerminalController` (386) is already behind a seam. It writes through
`typealias TerminalSurfaceWriter = (TerminalWrite, @escaping () -> Void) -> Void`
(`GhosttyTerminalController.swift:97`) bound by `bindSurface`, and reads through
`receiveTee`. It contains no `ghostty_*` calls, only one in a comment.

The genuinely Ghostty-and-AppKit-bound code is `GhosttyTerminalView.swift` (683) plus
`GhosttyApp.swift` (78) and `GhosttyProbe.swift` (36). The two spike and harness files (516)
are dev tooling.

### Route A: libghostty on Windows

The Windows host would have to deliver, in order:

1. A Windows build of the fork. Requires: Windows-conditional POSIX imports in the build;
   a renderer backend that exists (D3D11/12, Vulkan, or a WGL/ANGLE path), because neither
   Metal nor the Mesa-EGL OpenGL renderer applies; a `.windows` variant of
   `apprt.embedded.PlatformTag` and `Platform`, plus the whole `Surface` host contract for
   it, which today is written in Objective-C against `NSView`; the same for the Dear ImGui
   inspector, which is Metal-only. This is upstream work in Zig on a fork, and the renderer
   piece alone is not a port, it is a new backend.
2. Re-implementation of `GhosttyInputView` (683 lines) against Win32/WinUI: key events into
   `ghostty_surface_key` with a fresh mods/keycode mapping, IME via
   `setMarkedText`/`unmarkText` equivalents (`ITfContextOwnerCompositionSink` or `WM_IME_*`),
   mouse and scroll with momentum, backing-scale change, display id, drag and drop,
   selection to clipboard.
3. A surface for the renderer to draw into, and a swapchain presentation contract that does
   not exist yet in the library.

Step 1 has no upper bound that evidence can bound. It is open-ended engineering in a
language and codebase Port42 does not otherwise touch, on a fork, with no upstream to
absorb it.

### Route B: ConPTY plus a JS terminal in WebView2

The webview is already the port substrate. `Sources/Port42Lib/Views/PortView.swift:66`
renders companion-generated HTML/CSS/JS in a `WKWebView`, and 17 files under
`Sources/Port42Lib/` reference `WKWebView`. A Windows Port42 needs WebView2 for web ports
regardless of what happens to terminals. A terminal port then costs:

1. ConPTY host in whatever language the Windows app is written in:
   `CreatePseudoConsole` / `ResizePseudoConsole` / `ClosePseudoConsole` plus two pipes and
   `CreateProcess` with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE_ATTRIBUTE`. Ghostty's own
   `src/pty.zig:326-490` is a 165-line reference implementation of exactly this.
2. xterm.js in the webview. No terminal emulator to write, no renderer to write, no IME
   layer to write, no key mapping table to write. xterm.js handles VT parsing, reflow,
   selection, and IME in the browser engine.
3. Two glue functions: pipe bytes to `term.write()`, and `term.onData` back to the pipe.

The existing controller seam takes this without redesign. `TerminalSurfaceWriter` becomes a
webview `evaluateJavaScript` call. `receiveTee` becomes the ConPTY read loop. The
`<p42>` tag extraction, the hooks socket, and the whole
`TerminalHooksService`/`TerminalOutputProcessor` layer are untouched, because they only ever
saw bytes.

### Size comparison

Route B also deletes 537 MB of xcframework from the Windows artifact and replaces it with a
JS bundle in the low hundreds of kilobytes.

### The honest cost of Route B

Route B is not free. Windows loses GPU-accelerated cell rendering, so very high-throughput
output will be slower than Ghostty on macOS. xterm.js is a different emulator, so macOS and
Windows terminal ports will not be byte-identical in edge-case VT behavior, and anything
Port42 later builds on fork-only APIs (`ghostty_surface_render_grid_json`,
`ghostty_surface_select_screen_rows`) would need a second implementation. That is a real
divergence and should be a conscious decision, not a surprise.

It is still the right trade. Route A's first step is writing a graphics backend for a
terminal emulator in a forked Zig codebase. Route B's first step is calling
`CreatePseudoConsole`.

## What this spike did not determine

- Whether `manaflow-ai/ghostty` carries Windows work upstream does not have. Its shipped
  xcframework has only Apple slices, which is suggestive but not conclusive. Determined by:
  cloning that fork and repeating the three build commands in section 3.
- Whether a Windows Ghostty renderer exists in an unmerged branch or PR. Determined by:
  searching ghostty-org PRs for `renderer` plus `windows`, and checking whether
  `apprt/embedded.zig` gains a non-Apple `PlatformTag` in any of them.
- Actual xterm.js throughput against Port42's real output volumes on Windows. Determined by:
  measuring with the existing `TerminalOutputProcessor` fixtures once a ConPTY prototype
  exists.
- Whether Windows Port42 will use WebView2 at all, or some other shell. This spike assumed
  it will, on the grounds that web ports need one. If that assumption is wrong, Route B's
  cost changes.

## Commands run

```
git clone --depth 50 https://github.com/ghostty-org/ghostty.git
  # -> 982fe90d941e4b4aab4905ffcbcfdea60bd83343, 2026-09-24, v1.3.2-dev

curl -sL -o zig.tar.xz https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz
  # -> zig version 0.16.0, matching build.zig.zon minimum_zig_version

zig build -Dtarget=x86_64-windows --summary all
  # -> EXIT=1. All C deps: 'stdio.h' file not found. Cause: forced MSVC ABI
  #    (src/build/Config.zig:105), MSVC libc headers unavailable on macOS.

zig build -Dtarget=x86_64-windows-gnu --summary all
  # -> EXIT=1, 123/131 steps OK. 'install ghostty-vt success'.
  #    'compile lib ghostty' fails: posix_c.h:2:10: fatal error: 'pwd.h' not found

# patch: src/build/SharedDeps.zig, posix_c includes -> errno.h only when os.tag == .windows
zig build -Dtarget=x86_64-windows-gnu --summary all
  # -> EXIT=1. 4 errors: pkg/opengl/Buffer.zig:75, pkg/opengl/egl.zig:80,
  #    src/renderer/Dmabuf.zig:44 and :55

zig build -Dtarget=x86_64-windows-gnu -Demit-lib-vt=true --summary all
  # -> EXIT=0. ghostty-vt.dll (7.5 MB), ghostty-vt-static.lib (21.7 MB)
```

Scratch dir: `/private/tmp/claude-501/ghostty-spike/`. Nothing outside this worktree was
modified.
