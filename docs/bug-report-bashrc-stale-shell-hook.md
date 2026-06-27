# Bug Report: spawned `bash` terminal prints `port42-shell-hook: command not found`

**Date:** 2026-06-27
**Severity:** Low — cosmetic noise, no functional impact; NOT caused by this app
**Reproducible:** Yes (machine-wide, any interactive bash)
**Status:** Open — diagnosed, not fixed (RCA only)

---

## Summary

A native terminal spawned with `terminal.spawn {command:"bash"}` shows:

```
gordon@MacBookPro ~ % bash

bash: port42-shell-hook: command not found

The default interactive shell is now zsh.
...
$
```

The `port42-shell-hook: command not found` line repeats on every command typed in
that bash shell.

## Root cause

A **stale legacy hook in the user's `~/.bashrc`** (added 2025-09-19, long before the
native-app terminal work), left behind by the *old* Port42 CLI product whose uninstaller
never stripped it:

```bash
# PORT42_SHELL_HOOK
port42_preexec() {
    [[ -n "$COMP_LINE" ]] && return
    [[ "$BASH_COMMAND" == "$PROMPT_COMMAND" ]] && return
    port42-shell-hook track "$BASH_COMMAND"
}
trap 'port42_preexec' DEBUG
# END_PORT42_SHELL_HOOK
```

A bash `DEBUG` trap fires before every command and calls `port42-shell-hook track …`.
That binary is **no longer installed** (`which port42-shell-hook` → not found; only
`port42-companion` survives in `~/.local/bin`). So bash prints "command not found"
before each command.

## Why the spawned terminal surfaced it (chain)

1. `terminal.spawn {command:"bash"}` does **not** exec bash as the surface process —
   the Ghostty surface launches the user's **login shell (zsh)**, then *types* `bash\r`
   as the `startupCommand` (`GhosttyTerminalView.swift:13` — "command is TYPED IN via
   startupCommand rather than exec'd as the surface process"). Hence the zsh prompt
   first, then `bash`.
2. Interactive bash sources `~/.bashrc` → installs the DEBUG trap.
3. The trap fires on the next command → runs the missing `port42-shell-hook` →
   "command not found".

## What this is NOT

- **Not a bug in port42-native.** No reference to `port42-shell-hook` anywhere in
  `Sources/`, `gateway/`, or resources. The app's hooks machinery is unrelated
  (`TerminalHooksService` → `PORT42_HOOKS_SOCKET` env + bundled `port42-claude-shim`),
  and it is gated by `isHooksCapable`, which is true **only** for `claude`/`gemini`.
  A plain `bash` terminal receives none of it.
- **Not terminal-specific.** The same error fires in Terminal.app or any interactive
  bash on this machine. The spawn path *exposed* it, did not cause it.

## Suggested fix (when actioned)

Remove the `# PORT42_SHELL_HOOK … # END_PORT42_SHELL_HOOK` block from `~/.bashrc`
(user-machine cleanup, not a code change). Optionally: if the new product is ever going
to ship a shell hook, make the trap no-op gracefully when the binary is absent
(`command -v port42-shell-hook >/dev/null && port42-shell-hook track …`).

---

## Secondary observation (separate, unfixed): `ports.list` vs `terminal.list` inconsistencies

Noticed while verifying the above. Two smells in the gateway tool output:

1. **Format inconsistency.** `ports.list` returns a **human-readable text blob**
   (`"37 ports:\n\ntitle: …\nid: …"`), while `terminal.list` returns **JSON**. Callers
   can't parse `ports.list` as JSON.
2. **Capabilities mismatch.** The same native terminal port reports
   `capabilities: []` in `ports.list` but `capabilities: ["terminal"]` in
   `terminal.list`.

Not investigated further; logged here so it isn't lost. Likely candidates: the
`ports_list` tool formatter (stringifies for LLM readability) and a capabilities field
that isn't populated on the panel model used by `ports.list`.
