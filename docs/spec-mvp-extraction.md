# Port42 MVP Extraction — Decisions & Plan

*2026-06-25 — distilled from full-codebase review (151 Swift files, ~35.8k lines)*

## Thesis

**Say it, see it.** AI employees in your computer: message in → port/action out. The UX layer — ports, the Shell desktop — is the differentiator and where dev time concentrates. No one else is working quite there yet.

The codebase review confirmed: this is not a swiss-army-knife problem in the guts. The core loop (spaces → companions → ports → gateway) is coherent. The weight is presentation multiplicity — two shells, two API dispatch layers, ~25 doors into companion creation.

## Decisions

1. **Shell is the front-end.** The classic `ContentView` path gets removed after a parity triage. The kiosk Shell (`ShellView`/`ShellDesktop`) is where development already lives.
2. **One API dispatch layer.** `PortBridge` (~70 dot-named methods) and `ToolExecutor`/`RemoteToolExecutor` (~55 underscore-named methods) reimplement the same device surface twice. Consolidate into a single method registry with thin adapters.
3. **Epistemic layer stays as-is — prototype under saturation test.** Deployed via port42-components, being exercised daily inside Claude Code. No deeper investment and no removal until that data comes back.
4. **Tier 1 cleanup proceeds immediately** — requires no product decisions.

## Workstreams

### WS1 — Mechanical cleanup (no decisions required)
- Delete: `Port42B` target, `PortResizeSpike.swift`, `prototypes/wkspike/`, `prototypes/p42shell/`
- Remove checked-in gateway binaries (`./gateway`, `./port42-gateway`, `gateway/gateway`); gitignore them
- `GhosttyDebugHarness` — keep only while terminal bring-up is active; delete when Steps 8+9 settle
- `compatibleEndpoint` stub silently falls back to Anthropic ("Phase 2" comment) — remove the UI option until it's real
- OpenClaw integration (~900 lines: `OpenClawService` + `OpenClawSheet`) — extract to its own repo or cut

**Deliverable:** deletion PR, zero behavior change.

### WS2 — Single API dispatch
- One method registry: name → handler + permission + JSON schema
- Three thin adapters over it:
  - PortBridge JS bridge (dot names, WKWebView)
  - LLM tool-use (underscore names, `ToolDefinitions`)
  - External RPC (`RemoteToolExecutor`, WS/HTTP `/call`)
- Canonical naming: dot notation; underscore kept as alias for LLM tool-use
- Fix-once semantics: every device bridge bug currently needs fixing twice

**Deliverable:** `PortBridge.dispatch` and `ToolExecutor.executeImpl` both delegate to the shared registry.

### WS3 — Shell to default
- Flip `PORT42_SHELL` default on; classic reachable by flag for one burn-in release
- Parity triage: enumerate what classic has that Shell lacks (help overlay, quick switcher, toasts, port permission overlay — verify each)
- Delete `ContentView`, `SidebarView`, and classic-only views after burn-in

**Deliverable:** Shell is the app. Single front-end.

### WS4 — Say-it-see-it activation
- **Metric: time-to-first-port (TTFP)** — from first user message to first live port on screen. This is THE activation number for the thesis.
- Onboarding re-cut to serve TTFP. The cinematic is brand — keep it, make it skippable, and get the user to a working port faster.
- Companion creation collapsed around the "AI employees" frame: hiring presets up front, everything else (15 SaaS presets, constitutions, pods, remote invites) behind an advanced door.

**Deliverable:** a new user says something and sees something within the first session, without touching settings.

## Sequence

WS1 → (WS2 ∥ WS3) → WS4

## Not touched

- Epistemic layer (fold/position/creases/engravings) — prototype under test
- Gateway + `/call` API — enables the component strategy (port42-companion, port42-channels)
- Spaces, messages, sync, crypto
- Ports themselves — they're the product
