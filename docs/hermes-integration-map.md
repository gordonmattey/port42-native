# Hermes integration map

How Port42 would ship Hermes under the hood while keeping its own UX. Companion to
[hermes-engine-investigation.md](./hermes-engine-investigation.md).

**Headline:** this is mostly *wiring existing seams*, not greenfield. Port42 already
has (a) an MCP server exposing the whole bridge, (b) a `.remote` agent mode over
WebSocket, and (c) a proven pattern for onboarding an external agent CLI. Hermes
plugs into all three.

## The seam

```
User → space message → AgentRouter (Port42 owns routing/spaces/UX)
                          │   companion.mode = .remote, engine = hermes
                          ▼
                    Hermes daemon (local, Python)
                     ├─ brain:  local vLLM / OpenRouter / Nous Portal
                     ├─ memory: ~/.hermes/*/SKILL.md  (self-written skills)
                     └─ hands:  port42-mcp ──► gateway /ws ──► Bridge ──► ports + device
                          │
                          ▼   reply tokens over the WS peer connection
                    ChatView / ShellFocus  (Port42's shell, unchanged)
```

Port42 stays the **body + face**: spaces, routing, the disposable-port shell, and the
permission-gated device bridge. Hermes is a **brain behind a peer** — it never gets to
show its own chat UI.

## Prior art already in the codebase (what we reuse)

| Existing piece | Role for Hermes |
|---|---|
| `Sources/Port42Lib/Resources/port42-mcp.js` | The whole bridge as one MCP `port42` tool (JSON-RPC/stdio → gateway WS). **Hermes's hands.** |
| `AgentMode.remote` ("Python SDK / CLI agent via WebSocket") + `SyncService` identify/peer protocol | Hermes appears as a **companion in a space**; messages route to it, replies stream back. |
| `OpenClawService.swift` (`npx openclaw plugins install port42-openclaw`, version detect, settings button) | **The exact onboarding playbook.** `HermesService` mirrors it. |
| `AgentProvider.compatibleEndpoint` + `providerBaseURL` | Model-agnostic config already exists (though it targets Port42's *own* `LLMEngine`; for Hermes-as-engine we bypass `LLMEngine`). |
| `AgentProcess` / `AgentProtocol` (NDJSON stdio) | Fallback transport if we run Hermes as a child process instead of a WS peer. |

Net: no new protocol invention. The device bridge is already MCP-exposed; the remote
companion path already exists; the external-CLI onboarding is already solved once.

## Two integration depths

### Depth 1 — Hermes as a remote companion (reuse everything)
Lowest code. A `HermesService` (mirror of `OpenClawService`) detects/installs Hermes,
configures it to (a) connect to the gateway as a remote peer and (b) load `port42-mcp`
as its toolset. A companion is created with `mode = .remote` + an engine tag. You
@-mention it; Hermes plans, calls the `port42` tool to `port.create`, and replies into
the space. **Port42's UX is untouched — Hermes is just another companion, but a
model-agnostic, skill-learning, local one.**

### Depth 2 — default engine + bridge-only hands + skills surfaced
- **Trust boundary (critical):** disable Hermes's native executors (local
  terminal / Docker / SSH); its *only* tool is `port42`. Every hand flows through
  Port42's existing per-category permission model — one throat to choke.
- **Local model default:** point Hermes at local vLLM → the local-first thesis made
  real (zero cloud, zero marginal cost).
- **Skills surfacing:** read/watch `~/.hermes/*/SKILL.md`; show learned skills in the
  shell; "run skill" = summon the port(s) it generates. This is the persistence layer
  the disposable-port shell was missing — the port evaporates, the skill persists.

## Phased plan

- **P0 — Spike (no Swift changes).** Install Hermes via `uv`; register `port42-mcp` as
  an MCP server in Hermes; from the Hermes CLI, "create a port that shows X" → confirm
  a real port renders in Port42 through the bridge. Proves the tool seam end-to-end.
- **P1 — Hermes as remote companion.** `HermesService.swift` (detect/install/spawn as
  WS peer, config gen). `AgentConfig` gains an engine tag; create-companion UI offers
  **Engine: Claude | Hermes (local)**. Messages route in, replies stream to `ChatView`.
  Ship behind a flag.
- **P2 — Bridge-only trust boundary.** Lock Hermes to the `port42` tool, disable raw
  executors, route its permission asks through Port42's category prompts, document the
  threat model.
- **P3 — Skills surfacing.** Read/watch `~/.hermes` SKILL.md; a shell surface for
  learned skills; tie "run skill" to summoning disposable ports.
- **P4 — Local model default.** Bundle/guide a local vLLM (or MLX) backend; make
  "Hermes (local)" the recommended zero-cloud engine — the thesis's payoff.

## Open decisions

1. **Transport — WS remote peer vs. child-process NDJSON?** WS peer reuses
   sync/presence (Hermes is a real space member, cross-space capable); child process is
   simpler lifecycle but bolted to one space. *Lean WS peer.*
2. **Who owns the loop?** Hermes wants to be the whole agent (own messaging gateway).
   It must be subordinated: Port42 owns spaces/routing/UX. Its chat surface must not
   leak up.
3. **Hands — bridge-only vs. native+bridge?** Bridge-only for trust *(recommended)*;
   native executors are powerful but blow up the permission model.
4. **Packaging — bundle Python/uv or require install?** Bundling Python into a
   notarized app is painful; P1 can detect + guide (like OpenClaw's `npx`), defer
   bundling.
5. **Skill safety.** Self-written SKILL.md files are auto-generated *code*. Surfacing
   them = surfacing code that executes; needs a review/trust gate before a learned
   skill runs unattended.

## Risks & reversibility

- External roadmap churn (v0.1→v0.13 in ~10 weeks).
- A weak local model may drive the `port42` tool unreliably — mitigate by allowing a
  strong model via `compatibleEndpoint` even under Hermes.
- Two-runtime packaging + a larger trust surface (Hermes executes code by design).

**Reversibility is the saving grace:** because it rides existing seams (MCP + remote +
the OpenClaw pattern), Hermes is a *swappable* engine. If Nous stalls, the same rails
take any MCP-speaking agent. **Marry the protocol, not Hermes.**
