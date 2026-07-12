# The Generative Interface — Concept Spec

> **Superseded as thesis (2026-07-11) by [`../the-membrane.md`](../the-membrane.md).**
> The framing here — "generative interface / say-it-see-it" with a nine-loop latency stack — was the
> wrong slice: it describes the *agent-side response pipeline of one instrument*, not the product.
> The product is the **membrane** between the human loop and the agent loops (watching + steering).
> Generation is a capability of the membrane, not the point. This doc survives for its engine
> engineering (three-layer surface architecture, the DSL path) and for the gestures that recast as
> membrane primitives (knock, speculation, dreams, semantic LOD, keep/melt, anneal). Read the-membrane
> first.

*2026-06-25 — companion doc to `spec-mvp-extraction.md`. Ports are v0 of this; the Shell is its first host.*

**Deep-dives (with diagrams):**
- [`spec-gi-loops.md`](spec-gi-loops.md) — the full Loop Stack (loops 0–8), escalation flow, per-loop budgets/signatures/metrics
- [`spec-gi-flywheel.md`](spec-gi-flywheel.md) — the preference-data flywheel, tuple schema, privacy posture, why it gates training
- [`spec-gi-material-gestures.md`](spec-gi-material-gestures.md) — material physics (temperature/annealing/decay state machine), the gesture grammar table, wilder concepts, ship order

## Thesis

The interface is a **living material**. Today ports are "ask for an app, get an app" — a request/response artifact economy. The end state is an interface that continuously reshapes under your hands, where the boundary between *using* software and *making* software dissolves. The unlock is **speed**: when structural change drops from ~10s to ~200ms, generation stops being a feature and becomes the substrate.

The strategy has two halves:

1. **The protocol** — the surface lifecycle contract (`create / patch / push / exec / history / restore` + events + capability negotiation). Publish it. Any agent can drive any conforming host. This is the HTML-of-agents; Port42's port API is already its v0.
2. **The runtime** — the best host for that protocol (the Shell). Runtimes are the moat; protocols are the adoption engine.

---

## Loop Engineering — the Loop Stack

Don't spec features; spec **loops**. Every behavior of the system lives in exactly one loop, and every loop has a latency budget, a fallback, and a *visible signature* (the user should always be able to feel which loop they're in). Loops nest: inner loops handle what they can and escalate outward.

| # | Loop | Budget | What runs | Example |
|---|------|--------|-----------|---------|
| 0 | **Reflex** | <16ms | local JS, no model | hover, drag physics, typing |
| 1 | **Push** | <100ms | transport only | live data into existing bindings (`port.push`) |
| 2 | **Morph** | 100ms–1s | *small local model / constrained decoding* | UI reshapes as you gesture — **doesn't exist yet; this is the frontier** |
| 3 | **Patch** | 1–10s | frontier model, structural edit | `port.patch`, scribble-to-repair |
| 4 | **Regenerate** | 10s–min | frontier model, whole surface | new port from intent |
| 5 | **Composition** | minutes | multi-agent negotiation | wiring ports, pipelines, choirs |
| 6 | **Session** | hours | layout/attention learning | workspace reconfigures to the task |
| 7 | **Relationship** | days–weeks | epistemic layer | fold/creases/engravings tune generation to the person |
| 8 | **Evolution** | weeks–months | the flywheel | usage data → fine-tunes → new capability |

Notes:
- **Loop 2 (Morph) is the product bet.** Everything "crazy" below depends on sub-second structural change. It is also the loop that eventually justifies a custom model.
- **Escalation policy**: a gesture tries Reflex, falls to Morph, falls to Patch. The UI signals escalation honestly (see Sound, below) instead of pretending everything is instant.
- **One metric per loop**: TTFP (loop 4), time-to-modification (loop 3), morph rate (loop 2), push latency (loop 1), plus saturation metrics for 6–8.
- The same loop shape runs the *company* (tick → gate → ship → learn). Loops all the way down; the kernel that builds the product and the product itself share an architecture.

---

## Material Physics

Give surfaces physical properties that map to real engineering costs:

- **Temperature** — how model-attached a surface is. **Molten** surfaces stay connected to the model (every interaction can reshape them; costs tokens). **Frozen** surfaces are compiled static artifacts (free, fast, dumb). *Pin = freeze. Melt = reattach.* This makes the economics of generative UI a tangible gesture instead of a hidden bill.
- **Annealing / self-compiling UI** — a surface starts as pure model improvisation, then hardens with use: interactions the model keeps handling the same way get **compiled into local JS by the model itself**. The surface literally learns to run without the model. Model → code migration as the default lifecycle; the flywheel's first product.
- **Viscosity** — how readily a surface morphs. New/exploratory surfaces are runny (aggressive speculative reshaping); established workflow surfaces are stiff (stable, change only on explicit ask). Viscosity is set by the Relationship loop — the companion learns what should stay put.
- **Weight / decay** — unpinned generated surfaces fade and park themselves. Ephemerality is the default; permanence is earned or granted. (The park rail is already half of this.)

---

## Gesture Grammar

Core set (from the review riff):

- **Semantic lasso / circle-to-change** — select any region + say/type the change. Flagship gesture. (Patch loop; Morph when fast enough.)
- **Point-and-say (deixis)** — "make THIS bigger" while pointing. Voice + cursor position resolved together.
- **Version scrub** — `port.history` as a physical timeline on every surface. Undo for generation; time-travel as gesture.
- **Fork-apart** — pull a tile in two → two live variants → keep one. Choice is a preference label (see Flywheel).
- **Scribble-to-repair** — scratch anything out = "wrong, fix it."
- **Wiring** — drag a line between ports; agents negotiate the data contract. Composition without code.
- **Freeze / melt** — pin compiles to static; melt reattaches the model.
- **Solidify / fidelity dial** — push a sketch toward polish with pressure; generation arrives in stages (sketch → functional → polished) so the Regenerate loop feels alive instead of blocked.
- **The knock** — an unfocused agent requests attention (aura, lean, pulse); the human grants or denies. Attention as negotiated resource — the "AI employees" frame made spatial.
- **Negative-space summon** — drag a rectangle on empty desktop to pull a new surface out of nothing; **the size of the drag is the ambition budget** (small = widget, huge = app).

## Wilder Concepts

- **Speculative UI (branch prediction for interfaces)** — idle Morph-loop capacity renders *ghost tiles* of what you might want next, at the periphery (peek rail). Glance and grab → solidifies. Ignored → decays. Wrong ghosts cost nothing; right ones feel like telepathy.
- **Semantic LOD** — surfaces render at different information densities by attention distance, like game-engine level-of-detail: watched tile = full UI; unwatched = compressed glyph/aura of its live state; galaxy view = one pixel of meaning. Same surface, multiple projections, chosen by attention.
- **The choir** — for a big intent, several agents render candidate surfaces simultaneously; the desktop briefly becomes a marketplace of proposals; human picks; losers decay. Fork-apart made systemic.
- **Desire paths** — every gesture leaves residue. Trodden interaction paths widen: controls you use grow and migrate toward your hand; flows you repeat compress into one-touch macros the companion proposes. The interface erodes toward its user.
- **The interface dreams** — heartbeat loops use idle time to draft reorganizations, syntheses, and cleanups of your workspace; proposals park in a *dreams rail* for the morning. (Space heartbeats already exist — this is what they're for.)
- **Loop sonification** — each loop class has an audio signature: Reflex silent, Push ticks, Morph hums, Regenerate has a build-sound. You *hear* the system thinking; latency honesty through sound instead of spinners.
- **Multiplayer material** — two humans + agents molding the same surface; everyone's cursor carries an aura; a space is a shared workbench, not a chat log with attachments.
- **Every surface is a port everywhere** — the DSL projects to more than WKWebView: TUI projection (terminal hosts), and later watch/AR. Same generative surface, multiple hosts — the protocol play again.

---

## The Surface Architecture — three layers

A generative UX engine has to separate three concerns that "a port is HTML" collapses into one. This is a design decision, not a critique of any format: each layer is optimized against a *different* constraint, so binding them to a single technology forces one technology to be good at three unrelated jobs.

| Layer | The job | Optimized for | Bound to a loop |
|-------|---------|---------------|-----------------|
| **Authoring target** | what the model *emits* | token economy + generation reliability | Morph / Patch / Regenerate — the model is in this layer |
| **Representation** | what is *stored, versioned, diffed* | semantic diffability + provenance | annealing, version-scrub, the flywheel live here |
| **Runtime** | what actually *renders & runs* | fidelity, latency, host reach | Reflex / Push — the surface executes here |

**Why separate them:**
- The **authoring** layer is where the fast loops are gated. If the model emits thousands of tokens per surface, Morph (<1s) is impossible — authoring must be *compact*. And if the format is unconstrained, coherence is luck — authoring must be *constrained enough that a valid surface is the only thing expressible*.
- The **representation** layer is what annealing and semantic edits operate on. "Make this denser," "swap these two," "this behavior is now permanent" need a structure you can diff and transform semantically — not a string you regex. This is also the flywheel's substrate: every stored version + patch is a training tuple.
- The **runtime** layer is a swap-in detail. Multiple hosts (WKWebView, TUI, native, later watch/AR) should render the *same* representation. Binding the product to one runtime forecloses the multi-host projection the protocol strategy depends on.

The shape that falls out: **model emits authoring format → engine holds a structured representation → engine compiles to whatever runtime the host needs.** Authoring and representation may converge into one structured grammar; runtime stays plural.

## Evaluation framework — choosing each layer

Don't pick a technology; score candidates against the loops they have to serve. A candidate for any layer is rated on:

| Criterion | Question | Which layer cares most |
|-----------|----------|------------------------|
| **Compactness** | tokens per surface / per edit? | authoring |
| **Constraint** | can it express an *invalid* or off-system surface? | authoring |
| **Generation reliability** | does the model produce correct output first try? | authoring |
| **Semantic diffability** | can "make it denser" be a structured transform, not a rewrite? | representation |
| **Provenance / versioning** | can every state be attributed, diffed, restored? | representation |
| **Anneal-ability** | can repeated behavior compile down toward Reflex? | representation |
| **Render fidelity** | how rich can the surface be? | runtime |
| **Runtime latency** | Reflex/Push budgets on the host? | runtime |
| **Host reach** | how many surfaces (web/TUI/native/AR) can it target? | runtime |
| **Ecosystem cost** | build/borrow; how much do we own vs inherit? | all |

Run each candidate — **raw HTML, a component DSL, a retained scene-graph, native widget trees, a hybrid** — through this rubric per layer. The winner is almost certainly *different per layer* (that's the point of separating them), and the scores will move as the flywheel data arrives.

**Where HTML lands today, by this rubric:** strong on render fidelity and ecosystem cost (we inherit the whole web), weak on compactness, constraint, and semantic diffability. So it's a strong *runtime* candidate and a weak *authoring/representation* one — which is exactly why it's right for the prototype (fidelity + zero cost now) and wrong as the permanent authoring target.

**Sequencing — the rubric needs data.** The authoring/representation grammar should be *derived from the flywheel*, not designed up front: the component vocabulary is whatever people actually generate and patch. So ship HTML ports now (it wins runtime + cost today), instrument the flywheel, and let the corpus tell us the grammar. HTML is the scaffold the real authoring layer is learned from.

## The DSL → Model Path (speed is the reason to train)

1. **Flywheel first (now).** Instrument everything as tuples: *(intent, context, surface, every patch, every gesture, outcome)*. Gesture streams are preference gold — every scrub-back is a negative label, every pin a positive, every fork-choice a preference pair. **A generative desktop produces RLHF data as a side effect of normal use.** Nobody else has gesture-level preference streams over generated UI; this is the defensible dataset.
2. **Surface DSL (next).** Retarget generation from raw HTML to a compact component grammar with runtime-enforced design tokens. Coherence for free; 10–50× fewer tokens per surface; projectable to multiple hosts.
3. **Small models for fast loops (then).** Fine-tune a 3–8B local model on the flywheel for Morph-loop work: patch prediction, intent→component mapping, speculative rendering. Frontier models keep Regenerate/Composition.
4. **Custom model (only if).** When DSL + fine-tunes cap out. The justification is **latency, not quality** — Morph at 200ms local is a different product, not a faster one.

## Requirements Framework

- Every proposed feature must name its **loop** and meet that loop's budget, or name its escalation path.
- Every gesture must have a **degraded form** in the next-slower loop (lasso works at Patch speed today, gets magical at Morph speed later).
- Every surface state must be **legible**: temperature, loop-in-flight, provenance (which agent), version depth.
- Every interaction must **feed the flywheel** (loggable as a preference tuple).
- Ship order: instrument flywheel → semantic lasso + version scrub + freeze/pin (all buildable on today's Patch loop) → DSL → speculative ghosts + Morph loop.

## Prototype First

1. **Semantic lasso** on existing ports (patch-loop speed is acceptable to prove the gesture).
2. **Version scrub** (data already exists in `port.history`).
3. **Freeze/melt** (pin-to-static is mostly plumbing; makes the token economy visible).
4. **Flywheel logging** underneath all three.
