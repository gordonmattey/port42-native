# Hermes as engine, Port42 as shell — investigation summary

A side-quest exploring: *what if Port42 shipped Hermes Agent under the hood but kept
its own UX?* Companion to [shell-with-intelligence-thesis.md](./shell-with-intelligence-thesis.md).

## What Hermes Agent is

Nous Research's open agent **engine** (MIT, launched Feb 2026, moving fast — v0.13 by
May 2026). It is the part Port42 currently hand-rolls:

- **Python daemon** in `~/.hermes/`, runs as a systemd service, zero telemetry, local-first
- **Executes code** three ways: local terminal / Docker sandbox / SSH remote
- **Model-agnostic**: OpenRouter (200+ models), any OpenAI-compatible endpoint,
  **local vLLM**, or Nous Portal
- **Self-writing skills**: detects a repeated workflow and crystallizes it into a
  portable `SKILL.md` (agentskills.io standard) — gets more capable the longer you use it
- **Interfaces**: CLI + a messaging gateway (Telegram/Discord/Slack/WhatsApp/Signal)
- **Ships a desktop app** — but it's a near-copy of Claude/ChatGPT: single-companion,
  chat-focused. The generic face.

## The core insight

Port42 and Hermes are photo-negatives:

- **Port42** = beautiful native shell (ports, spaces, zoom ladder, disposable
  surfaces) on a **Claude-locked, hand-maintained brain** (`LLMEngine.swift`,
  `ToolExecutor.swift`, `ToolDefinitions.swift`, the agent loop).
- **Hermes** = model-agnostic, self-improving, local **brain** with **no UX worth
  showing** — just a CLI, chat bots, and a me-too desktop app.

They out-engineered everyone on the *engine* and then defaulted to the most imitative
possible *face*. That's a tell: building a novel shell is hard and isn't a research
lab's strength.

## Why this hardens Port42's position

1. **The engine is now a commodity you can rent.** Self-improving, local,
   model-agnostic, MIT-licensed. You don't have to build it *or* beat it.
2. **The shell is the open lane.** The best-engineered agent on the market chose the
   chat box. Claude, ChatGPT, and Hermes have all converged on identical UX — when
   three serious players wear the same clothes, that lane is closed and the *shell*
   lane is empty.
3. **Hermes is a free A/B test.** Same engine class, their generic chat UX vs. Port42's
   disposable-port shell. The comparison *is* the pitch: "here's the smartest local
   agent — now here's what it feels like when it isn't trapped in a chat box."

## What adopting it (via a clean protocol) would resolve

Maps directly onto the thesis's open questions:

| Open question | Resolution |
|---|---|
| **#6 model dependence / cost** | Model-agnostic overnight; **local vLLM = zero marginal cost, zero cloud** |
| **#2 local-first purity** | A genuinely **local brain** — the biggest unlock; "AI lives on your machine" stops being aspirational |
| **#5 disposable vs. keep** | The port is disposable; the **`SKILL.md` that generates it persists**. The shell forgets surfaces but remembers how to make the ones you keep asking for |
| **maintaining an agent loop** | Delete `LLMEngine`/`ToolExecutor`; stop competing with Nous on plumbing; focus on the shell |

**The killer unlock:** self-writing skills + disposable ports = "make my morning
dashboard" becomes a learned skill after the second time. UI stays ephemeral and
need-shaped; the intelligence that shapes it accumulates. The thesis's design law made
real — cheap to summon *because the shell learned the summon.*

## The honest costs

- **Two runtimes to ship** — a signed/notarized SwiftUI app *plus* a bundled Python
  daemon (hardened-runtime + Python is a packaging headache).
- **Trust surface explodes** — Hermes executes code (local/Docker/SSH) by design; your
  per-category permission model must now gate *its* hands or inherit its threat model.
  Makes open-question **#1 harder, not easier.**
- **External roadmap dependency** — v0.1→v0.13 in ~10 weeks; hard coupling is risk.
- **Weak local model may not drive ports reliably** — hand-tuned Claude tool schemas
  exist for a reason; an 8B local model calling `port.create` well is unproven.

## Recommendation

**Don't marry Hermes — marry the protocol.** Make Port42's bridge speak MCP /
OpenAI-tools cleanly so *any* engine plugs in underneath as a swappable brain
(Hermes today, something else tomorrow). The device bridge (`port.create`,
`clipboard.read`, `screen_capture`, …) becomes the *toolset the engine calls*.

- Ship Hermes as the **default recommended engine** (local-first + self-improving skills).
- Keep the Claude path as the **premium/turnkey** option.
- Keep coupling at the protocol layer — rent *the brain*, never inherit *their product
  decisions*. Their chat UX is exactly what must not leak up into Port42.

**Moat shifts** from "our agent loop" to "the disposable-port shell + device bridge +
spaces" — where Port42 was actually differentiated all along.

> One line: **Port42 is the shell and the hands; let the best available mind — ideally
> a local one — rent them through a clean protocol.**

## Sources

- Hermes Agent (official): https://hermes-agent.org/
- NVIDIA — self-improving agents on RTX / DGX Spark: https://blogs.nvidia.com/blog/rtx-ai-garage-hermes-agent-dgx-spark/
- Hermes Agent desktop app overview (Medium): https://medium.com/@tentenco/hermes-agent-desktop-app-everything-you-need-to-know-about-nous-researchs-self-improving-ai-agent-3cb59bd31e5f
