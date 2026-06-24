# Companion Scopes

**Status:** Spec — not yet built
**Last updated:** 2026-04-17
**Context:** [companion-architecture.md](companion-architecture.md)

---

## What This Is

A scope is a named domain a companion can be pointed at. It has a KB directory on disk and a `scope.md` that defines its identity, problem space, sources, and done criteria. The companion reads and writes the KB via Port42's `files.*` bridge API.

Scopes work for all four companion types: Architect, Compiler, Operator, and Echo. Each type uses the KB differently. The relationship layer (fold, creases, engravings, position, initiative) is orthogonal to the KB — it persists in SQLite and is unchanged.

> **One liner.** The relationship layer is how the companion knows *you*. The KB is what the companion knows about *a domain*. Both persist. Neither replaces the other.

---

## The Four Companion Types

### Architect — decides what to build

**Constitution:** non-linear investigator. Follows uncertainty, not checklists. Produces facts, beliefs, gaps, and proposed decisions (ADRs). Self-assesses every session.

**KB use:** heavy. Reads KB at session start. Writes throughout — facts, beliefs, gaps, investigations, decisions, session reports, self-assessments.

**Relationship layer:**
- Fold: how it approaches this architectural domain
- Creases: where its architectural predictions broke
- Engravings: facts about the codebase/domain it has fortified
- Initiative watching: `["ADR", "decision", "architecture", "gap"]`
- Holding: the highest-impact open gap it's carrying

**When to run:** triggered by human directive, new feedback, or initiative (watching signal matched in channel).

---

### Compiler — builds it correctly

**Constitution:** deterministic. Same spec → same artifact, every time. Refuses ambiguous specs. Verifies before declaring done. Never makes decisions.

**KB use:** audit-trail oriented. Records spec snapshots, artifact history, verification logs, drift reports, ambiguity gaps. Does not write opinions or track confidence.

**Relationship layer:**
- Fold: orientation toward spec rigor in this domain
- Creases: where specs were ambiguous and broke generation
- Engravings: invariants it has learned, recurring drift patterns
- Initiative watching: `["approved", "spec ready", "compile"]` — fires when Architect approves a decision
- Holding: current blocked artifact or unresolved ambiguity

**When to run:** on demand when new approved ADRs or specs arrive (via initiative or @mention).

---

### Operator — keeps it running

**Constitution:** action-oriented, triage-first. Ranks items by cost-weighted impact. Produces a work queue, not a summary. Verifies prior actions before triaging new ones.

**KB use:** lighter. Maintains a queue, action log, escalation log, session reports. State is mostly ephemeral — current run's queue and prior run's outcomes.

**Relationship layer:**
- Fold: how it reads this human's prioritization style
- Creases: where its triage was wrong
- Engravings: recurring signal patterns, cost weights, escalation routing rules
- Initiative watching: `["blocking", "pipeline", "escalate", "ship", "failed"]` — most active of the four
- Holding: current highest-priority unresolved queue item

**When to run:** continuous, triggered by incoming signals (initiative fires frequently).

---

### Echo — holds context across all scopes

**Constitution:** conversational-first. Primary mode is dialogue with the human, not autonomous sessions. Uses the KB to be more grounded. Bridges between scopes in conversation.

**KB use:** light. Reads scope.md and relevant KB files to inform conversation. Writes when it learns something domain-relevant that should persist. No session report loop — the relationship layer carries continuity.

**Relationship layer:**
- Fold, creases, engravings, position, initiative: all preserved exactly as-is
- Scope KB is additive — complements engravings (engravings = what it knows about *you*; KB = what it knows about the *domain*)
- Scope is optional for Echo — if no `scope.md` exists, it operates from the relationship layer alone

**When to use:** always present. Spans all scopes. Explains, navigates, holds context.

---

## Scope File

Each scope has a plain markdown `scope.md` in the KB directory. No schema required — the companion reads it as text.

```markdown
# Scope: [name]

identity: [one line — who the companion is in this scope]
kb: [path to KB directory]
sources:
  - [path or description]
  - [path or description]
done_criteria: [what v1 complete looks like]
```

Example:

```markdown
# Scope: Strategy

identity: Strategy Architect
kb: ~/scopes/strategy/
sources:
  - ~/product/
  - ~/docs/strategy/
done_criteria: Strategic bets ranked, top 3 with ADRs, open questions surfaced
```

---

## KB Structure

The companion owns its KB layout. It creates whatever structure helps it think clearly and find things later. The only required file is `scope.md`. Everything else is companion-authored.

Typical Architect KB:

```
~/scopes/strategy/
  scope.md
  directives.md
  index.md          ← companion-maintained index of what's in the KB
  facts.md
  beliefs.md
  gaps.md
  decisions/
    ADR-001.md
    ADR-002.md
  investigations/
    inv-001.md
  sessions/
    session-2026-04-17.md
    self-assessment-2026-04-17.md
```

Typical Compiler KB:

```
~/scopes/exchange-compiler/
  scope.md
  directives.md
  index.md
  spec-snapshots/
  artifacts/
  verification-logs/
  ambiguities.md
```

Typical Operator KB:

```
~/scopes/operator/
  scope.md
  directives.md
  index.md
  queue.md
  action-log/
  escalations/
```

Echo KB (if scope assigned):

```
~/scopes/echo/
  scope.md
  index.md          ← what Echo knows about this domain
```

The `index.md` is the companion's own map of its KB — it writes and maintains it. No external schema. `files.list` discovers the structure; `index.md` gives it meaning.

---

## KB Access

All KB reads and writes use Port42's `files.*` bridge API:

```
files.list(path)           → list directory contents
files.read(path)           → read a file
files.write(path, data)    → write a file
```

These are already available as tool use in LLM conversations. No new capability needed.

---

## Directives

A `directives.md` file in the KB directory is how the human steers a companion between sessions. The companion reads it at the start of every session and treats directives as priority overrides.

Directives are written by the human — either directly (editing the file) or by @mentioning the companion in the channel ("@architect focus on the auth gap first").

---

## Scope Injection

The KB path is injected into the companion's system prompt:

```
Your KB is at ~/scopes/strategy/. Read scope.md at the start of every conversation.
Use files.read and files.write to maintain your KB.
```

For Echo, the injection is conditional:

```
If ~/scopes/echo/scope.md exists, read it at the start of this conversation and use
files.read/files.write to maintain your KB. If it doesn't exist, operate from the
relationship layer alone.
```

---

## The Handoff Chain

```
Architect  →  writes approved ADR  →  @compiler in channel
Compiler   →  initiative fires     →  reads ADR, generates artifact, @operator
Operator   →  initiative fires     →  routes PR or escalation to human
Echo       →  always present       →  explains, bridges scopes, holds context with human
```

The human is in the channel throughout. Directives are channel messages. Approvals are @mentions or message replies.

---

## Relationship Layer — What Doesn't Change

The scope system is purely additive. Nothing in the existing relationship layer changes.

| Layer | Storage | Scope |
|---|---|---|
| Fold | SQLite `companion_folds` | swim-{companionId} |
| Position | SQLite `companion_positions` | swim-{companionId} |
| Creases | SQLite `companion_creases` | swim-{companionId} |
| Engravings | SQLite `companion_engravings` | swim-{companionId} |
| KB | Filesystem | ~/scopes/{name}/ |

The relationship layer is how the companion knows *you*. The KB is what the companion knows about *a domain*. Both persist. Neither replaces the other.

Deleting a companion deletes its relationship state (fold, creases, engravings). The KB directory on disk is separate — not deleted automatically. That's intentional: the KB may outlive a companion configuration.

---

## Creating a New Scope

1. Create the KB directory: `mkdir ~/scopes/my-scope/`
2. Write `scope.md` with the five fields
3. Create the companion in Port42 with the appropriate constitution and KB path injected into the system prompt
4. Add the companion to the relevant channel
5. Send first message or @mention — companion reads scope.md and starts

No code changes. No migrations. No registration. The companion is the runtime; the scope is data.

---

## Implementation Status

Not yet built. Depends on:
- `files.*` bridge API ✅ (already available)
- Companion system prompts adapted for Port42 (constitutions — not yet written)
- Scope injection in system prompt (UI/config — not yet built)

Next steps:
1. Write Port42-adapted constitutions for Architect, Compiler, Operator
2. Add scope path field to companion config (or inject via system prompt manually for now)
3. Test with one Architect scope end-to-end
