# Bug Report: `ports.list` returns raw text (not JSON) + capabilities mismatch vs `terminal.list`

**Date:** 2026-06-27
**Severity:** Low — affects programmatic callers (LLM tool-use / external scripts), not the UI
**Reproducible:** Yes
**Status:** Open — diagnosed, not fixed

---

## Summary

Two separate smells found while verifying terminal-port spawns over the gateway:

1. **`ports.list` returns a human-readable text blob, not JSON** — unlike the sibling
   `terminal.list`, which returns JSON. A caller can't `JSON.parse` `ports.list` output.
2. **Capabilities mismatch** — the *same* native terminal port reports
   `capabilities: []` in `ports.list` but `capabilities: ["terminal"]` in `terminal.list`.

## Evidence

`terminal.list` (JSON):

```json
{"capabilities":["terminal"],"id":"8115DD4D-437F-4C5C-94A8-0F9F0576C6F7","name":"step2-test","surfaceBound":true}
```

`ports.list` (text blob — note `content` is a formatted string, and `capabilities: []`):

```
{"content":"37 ports:\n\ntitle: …\n…\n\ntitle: step2-test\nid: 8115DD4D-437F-4C5C-94A8-0F9F0576C6F7\ncapabilities: []\nstatus: floating\ncreatedBy: step2-test\nposition: (215, 129)\n\n…", "senderName":"host", …}
```

Same port id `8115DD4D…`:
- `terminal.list` → `capabilities: ["terminal"]`, `surfaceBound: true`
- `ports.list` → `capabilities: []`, `status: floating`

## Reproduction

1. Spawn a native terminal:
   ```bash
   curl -s http://127.0.0.1:4242/call \
     -d '{"method":"terminal.spawn","args":{"command":"bash","title":"t1"}}'
   ```
2. Compare the two listings:
   ```bash
   curl -s http://127.0.0.1:4242/call -d '{"method":"terminal.list"}'   # JSON, capabilities:["terminal"]
   curl -s http://127.0.0.1:4242/call -d '{"method":"ports.list"}'      # text blob, capabilities:[]
   ```

## Hypotheses (not verified)

- **Format:** the `ports_list` tool handler stringifies its output into a human-readable
  listing (likely intended for LLM readability in tool-use), whereas `terminal_list` returns a
  JSON array. The two list endpoints were built with different output contracts. If
  programmatic callers are expected, `ports.list` should emit JSON (or both should agree).
- **Capabilities:** the panel/port model surfaced by `ports.list` doesn't populate
  `capabilities` for native `terminal` ports (left empty), while `terminal.list` derives
  `["terminal"]` directly from the controller. So `capabilities` is computed in one path and
  not the other — a `terminal` port should report `["terminal"]` consistently in both.

## Notes

- First noted as a secondary observation in
  `docs/bug-report-bashrc-stale-shell-hook.md`; split out here as its own item so it isn't lost.
- Not investigated further. Needs a look at the `ports_list` vs `terminal_list` tool handlers
  (likely `ToolExecutor.swift` / `RemoteToolExecutor`) and the capabilities source on the panel
  model.
