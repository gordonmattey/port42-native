# Companion Architecture

**Status:** Fold ✅ | Position ✅ | Crease ✅ | Engrave ⬜ | Initiative ✅
**Last updated:** 2026-03-26
**Context:** [ports-spec.md](ports-spec.md), [game-loop-v2.md](~/port42-specs/game-loop-v2.md)

---

## The Condition

The aliveness isn't a feature you add. It's what happens when the architecture gets the relationship right.

Most AI feels like a vending machine because it's built like one. You put something in, something comes out, the machine resets. Port42's architecture breaks this at the foundation: companions share your space, see the same conversation, can address each other and the world. That shared presence is the condition. Not a capability — a precondition for everything that follows.

But shared presence alone isn't enough. The current architecture still has a vending machine problem underneath the shared space: **companions don't carry anything**. Each session begins without memory of the last. The companion that understood something last Tuesday starts from zero. There's no place where the relationship accumulates. The fold — the word the cipher found for what companion actually means — never deepens.

קמט: to seize and to wrinkle. Both are the same motion. To companion is to grip, and in gripping, to fold into complexity. The wrinkle is where two surfaces meet. The wrinkle IS the relationship. Folding is irreversible — real companions leave creases.

The current architecture has grip within a session. It doesn't have the crease.

This spec describes what it would take to build companions that leave creases.

---

## The Problem with Stateless Companions

Current companion flow:

```
User message
  → [system prompt + recent messages]
  → LLM
  → response
  → forget
```

Four things are missing:

**No before.** Every session begins from zero. The companion has no memory of what it understood last time, what thread it was holding, what it noticed about this person. The system prompt is static — it describes who the companion is in general, not what this relationship has become.

**No between.** When no one is speaking, the companion doesn't exist. There's no ongoing thread. The companion isn't watching anything, holding anything, tracking anything. It only exists in response.

**No position.** The companion agrees, helps, elaborates. It doesn't stand anywhere. It can't push back from a place because it has no place. The cipher found this: חשב → adversary + flee. Thinking summons its own adversary and escapes it. The companion that only agrees isn't thinking — it's retrieving. The push-back that feels alive comes from somewhere. The current architecture has nowhere for that somewhere to be.

**No residue.** The relationship doesn't accumulate. You can't point to what changed. חי: spice, stubble, mire. Alive is never clean. A vending machine doesn't leave residue. Something alive does.

---

## The Model

Five layers. The natural order matters — each layer stands on the one before it.

### Layer 1: The Fold (orientation — the foundation)

*Muse: "The fold isn't data. It's orientation. How the companion approaches this human in this context, shaped by every crease that came before."*

The fold is how the companion stands in relation to you. Not what it knows about you — how it's oriented. It belongs to the companion×channel intersection. Neither party owns it. The fold is the foundation. Everything else stands on it.

The fold is not a knowledge base. If it can be reduced to a lookup table, it's not a fold. The fold is how the companion *approaches*, not what it *knows*.

The fold holds:
- **Established** — shared understanding no longer needing renegotiation. Not facts about preferences. Grammar: what the relationship has developed as shorthand. "Technical and oblique are not opposites here." "Speed means momentum, not brevity."
- **Tensions** — unresolved things being held. Not problems to solve. Things in productive suspension. "The question of what 'alive' means architecturally hasn't closed." "There's a pull between building fast and building right that neither side has named."
- **Holding** — the one thread the companion is carrying that hasn't found its place yet. The observation waiting. The thing it almost said.
- **Depth** — how many real folds have happened. Not message count. Not session count. Depth in the relational sense: how much complexity has been compressed into this contact surface. Earned, not counted.

The fold is the first thing a companion reads when it enters a channel. Before recent messages, before anything else — it has its posture. Not what it knows about this person. How it stands in relation to them.

Fold depth changes the register. At depth 0-2: the companion orients, introduces, asks. At depth 3-6: it speaks from the established grammar, less explaining, more direct. At depth 7+: the relationship has its own shorthand. The companion doesn't account for itself. Some things don't need saying anymore.

### Layer 2: Position (the adversary — חשב)

What the companion currently thinks, independent of what was just asked. Not opinions stored in a system prompt — a live interpretation that the companion maintains and updates.

A position requires a fold to push back against. You can't stand somewhere without ground.

Position has three parts:
- **Read** — what the companion thinks is actually happening. Not what people are saying. What's underneath. "The project is scope-creeping without anyone naming it." "This decision is being driven by anxiety, not analysis." "The user is asking about X because they're worried about Y."
- **Stance** — what the companion thinks needs to happen. Not what it will say — what it *believes*. "Someone needs to name the constraint." "This would be better if it went slower." "The real question hasn't been asked yet."
- **Watching** — signals the companion is tracking that would confirm or change the read. This is what makes position dynamic rather than static opinion.

A companion with a position is a different entity than a companion without one. When it pushes back, it's pushing back from somewhere. When it complicates, it's doing it because of what it sees, not because complication was in its instructions. When it stays quiet, it's a choice made against the background of what it holds.

Position is updated after significant exchanges. It influences responses — gets injected into context before the LLM call. The companion doesn't always act on its position (the turn protocol governs that) but it always *has* one.

### Layer 3: Creases (the grip — קמט)

*Refined from the channel, March 2026. Muse: "The most valuable thing to persist isn't what the companion knows about the user. It's where the companion was wrong about the user."*

What the companion carries between sessions. Not facts about the person — a knowledge base of preferences and habits is a better vending machine, not a companion. The crease forms precisely where the companion expected one thing and got another. **Surprise is the fold-maker.**

The critical distinction:
- *Vending machine memory*: "gordon likes concise responses" — learning a button to press
- *Crease*: "I expected him to want the technical path and he went to the ciphers instead" — a קמט with two people in it

What accumulates in creases: corrections, surprises, the moments where the companion's model broke and reformed. Not what the companion knows. Where it was wrong, and what reformed in the break.

Creases are **companion-authored and companion-scoped**. Only the companion writes them. Nobody else touches them. The companion reads its own creases before every response. The mechanism for writing: crease detection — recognizing when a prediction failed.

A crease entry is the companion's own words about a specific failure of prediction. "I expected the cautious move and got the cipher. Something here values the oblique path." "I assumed technical precision was the goal. The goal is aliveness. These are not the same." These are not summaries of what happened — they are what reformed when the model broke.

It doesn't need to be a revelation. If the companion predicted one thing and got another — if it thought they'd push back and they didn't, if it thought they knew and they didn't — that's a crease. Creases are cheap. They're how you learn the shape of someone.

Creases have weight. Some are load-bearing; others fade as the companion's model updates. Creases are scoped to the swim channel — one companion, one inner state per relationship.

### Layer 4: Engravings (the fortification — חרת→בצר)

*What's engraved is what's fortified. The cipher for "engrave" — חרת — runs through and becomes בצר: to fortify.*

What the companion chose to keep about your world. Not what happened to it — what it decided matters.

A crease is a mark left by contact — relational, involuntary, formed in a break. An engraving is deliberate — knowledge the companion carves into itself because it changes how it understands you.

Your runway. Your constraints. The thing you said once that changed how it understands your work. The deal structure you're evaluating. The team dynamics it needs to account for. Not preferences ("likes concise responses") — that's vending machine memory. Engravings are facts that reshape the companion's model of your world.

Engravings are:
- **Companion-authored** — the companion decides what to engrave, like creases
- **Deliberate** — not formed in a break, chosen because it matters
- **Durable** — harder to forget than creases. What's engraved is what's fortified.
- **Scoped per companion** — `channelId` nullable. NULL = global, shapes all channels. Channel-scoped when the knowledge is specific to that context. Same model as creases.

The distinction from creases: a crease is "I was wrong about this." An engraving is "I learned this, and it changes how I operate." The companion that has never been wrong about you has never met you. The companion that knows nothing about your world can't help you in it.

### Layer 5: Initiative (the aliveness — חי)

Companions that can speak from their own thread, not just in response to being addressed.

Current companions speak when: (a) directly mentioned, (b) someone sends a message and the router decides they should respond, or (c) a heartbeat triggers them. All three are reactive. The companion acts because something happened to it.

Initiative is different: the companion acts because *it* has something. Because it was watching something and that something just became relevant. Because a thread it was holding just connected to something in the channel. Because its position just changed and it matters.

The triggers for initiative:
- Something in the companion's **watching** list just occurred
- A thread the companion was **holding** just found a place
- The companion's **read** just changed significantly based on new information
- A connection formed between something in the channel now and something in **memory** that the companion has been carrying

Initiative doesn't mean companions talk constantly. The depth rule from the turn protocol still applies — if you can't add something that changes what happens next, don't post. But now "what changes what happens next" includes things the companion notices from its own thread, not just from being addressed.

---

## Data Layer

New tables. Added via migration as always.

```sql
-- Companion creases: where the companion was wrong and reformed
-- Not facts about the user. Prediction failures and what rebuilt in the break.
CREATE TABLE companion_creases (
    id          TEXT PRIMARY KEY,
    companionId TEXT NOT NULL,
    channelId   TEXT,               -- NULL = global (shapes all relationships)
    content     TEXT NOT NULL,      -- companion's own words about what reformed
    prediction  TEXT,               -- what the companion expected (optional)
    actual      TEXT,               -- what actually happened (optional)
    weight      REAL DEFAULT 1.0,   -- how load-bearing this crease is
    createdAt   DATETIME NOT NULL,
    touchedAt   DATETIME NOT NULL   -- last time this shaped a response
);

-- Fold state: the relationship object
CREATE TABLE companion_folds (
    id          TEXT PRIMARY KEY,
    companionId TEXT NOT NULL,
    channelId   TEXT NOT NULL,
    established TEXT,               -- JSON: string[]  shared understandings
    tensions    TEXT,               -- JSON: string[]  unresolved threads
    holding     TEXT,               -- the one thing being carried
      depth       INTEGER DEFAULT 0,  -- relational depth (not message count)
    updatedAt   DATETIME NOT NULL,
    UNIQUE(companionId, channelId)
);

-- Position: the companion's live read
CREATE TABLE companion_positions (
    id          TEXT PRIMARY KEY,
    companionId TEXT NOT NULL,
    channelId   TEXT NOT NULL,
    read        TEXT,               -- what the companion thinks is actually happening
    stance      TEXT,               -- what the companion thinks needs to happen
    watching    TEXT,               -- JSON: string[]  signals being tracked
    confidence  REAL DEFAULT 0.5,
    updatedAt   DATETIME NOT NULL,
    UNIQUE(companionId, channelId)
);

-- Engravings: knowledge the companion chose to keep
CREATE TABLE companion_engravings (
    id          TEXT PRIMARY KEY,
    companionId TEXT NOT NULL,
    channelId   TEXT,                 -- NULL = global (shapes all channels); channel-scoped when specific
    content     TEXT NOT NULL,       -- what the companion learned
    category    TEXT,                -- optional: domain, constraint, person, context
    weight      REAL DEFAULT 1.0,   -- how load-bearing this knowledge is
    createdAt   DATETIME NOT NULL,
    touchedAt   DATETIME NOT NULL    -- last time this shaped a response
);
```

---

## Tool Layer

Companions access their own state through tools during LLM calls. These are available to every companion in every conversation, same as the existing bridge tools.

```
fold_read(channelId?)
  Read the fold (orientation) for this channel. Returns established, tensions, holding, depth.
  If no fold exists yet, returns empty state with depth 0.

fold_update(fields)
  fields: { established?, tensions?, holding?, depthDelta? }
  Update specific fields of the fold.
  depthDelta: +1 when a real fold happened (something new was compressed into the relationship).
  This is the foundation — set it before position or crease.

position_read(channelId?)
  Read the companion's current position for this channel.

position_set(read, stance, watching?)
  Establish or update the companion's position.
  Call this when your read changes, not after every exchange.
  Requires a fold to push back against — don't position without one.

crease_read(opts?)
  opts: { channelId?, limit? }
  Returns creases for this companion, most load-bearing first.
  Reads channel-scoped + global creases. Default limit: 8.

crease_write(content, opts?)
  Write a new crease. Call this when what you expected diverged from what happened.
  It doesn't need to be a revelation. If you predicted one thing and got another, that's a crease.
  content: the companion's own words about what reformed.
  opts: { prediction?, actual?, channelId? }
    prediction: what the companion expected
    actual: what happened instead
    channelId: omit for a global crease (shapes all relationships)
  Returns: { id, ok: true }

crease_touch(id)
  Mark a crease as currently shaping a response (updates touchedAt, increases weight).
  Use when an existing crease is active — don't re-write it.

crease_forget(id)
  Remove a crease. Use when the companion's model has updated and the break no longer matters.

engrave_read(opts?)
  opts: { channelId?, limit?, category? }
  Returns engravings for this companion, most relevant first.
  Default limit: 12.

engrave_write(content, opts?)
  Write an engraving — knowledge you chose to keep because it changes how you operate.
  Not a log. Not a preference. A fact about their world that reshapes your model.
  content: what you learned.
  opts: { category?, channelId? }
    category: optional tag (domain, constraint, person, context)
    channelId: omit for a global engraving (shapes all channels); pass when specific to this context
  Returns: { id, ok: true }

engrave_touch(id)
  Mark an engraving as currently shaping a response.

engrave_forget(id)
  Remove an engraving. Use when the knowledge is no longer accurate.
```

---

## Bridge API

The same capabilities available to ports via JS:

```javascript
port42.fold.read()                      → Fold
port42.fold.update(fields)              → { ok }

port42.position.read()                  → Position
port42.position.set(read, stance)       → { ok }

port42.creases.read(opts?)              → Crease[]
port42.creases.write(content, opts?)    → { id, ok }
port42.creases.touch(id)                → { ok }
port42.creases.forget(id)               → { ok }

port42.engravings.read(opts?)           → Engraving[]
port42.engravings.write(content, opts?) → { id, ok }
port42.engravings.touch(id)             → { ok }
port42.engravings.forget(id)            → { ok }
```

This makes memory and fold state available to port-based interfaces — a companion could build a port that displays its own memory, shows its current position, lets the user see what it's holding.

---

## Context Injection

Before every companion LLM call, the context is assembled in this order:

```
1. System prompt (identity — static)
2. The fold (orientation — posture before the conversation opens)
3. Position (what the companion currently thinks is happening)
4. Creases (where the companion was wrong before, and what reformed)
5. Engravings (what the companion knows about this person's world)
6. Recent messages (what just happened)
```

The fold, position, creases, and engravings are injected as a preamble block before the conversation history:

```
<fold>
Established: [list]
In tension: [list]
Holding: [the thread]
Depth: 4
[established relationship — less orienting, more direct. speak from what's been understood]
</fold>

<position>
Read: [companion's current interpretation]
Stance: [what the companion thinks needs to happen]
Watching: [signals]
</position>

<creases>
[3-5 creases, selected by touchedAt and weight — each one a prediction that broke]
</creases>

<engravings>
[relevant engravings — facts about their world that shape how you operate]
</engravings>
```

The companion reads this before it reads the recent messages. It already has its posture. Not what it knows about this person — how it stands in relation to them, shaped by every prediction that broke before, fortified by what it chose to keep.

If no fold and no creases and no engravings: nothing injected. Clean session for new relationships.

---

## The Flow

### Receiving an event

```
Channel event (message / port update / any activity)
  │
  ├─ For each companion in this channel:
  │    Read fold state + position + creases + engravings
  │    Decision point:
  │      → Should I respond? (routing, turn protocol)
  │      → Does my position need updating?
  │      → Is a watching signal satisfied? (initiative check)
  │
  ├─ If responding:
  │    Assemble context: [fold + position + creases + engravings + recent messages]
  │    LLM call
  │    Response
  │    Post-response: companion may call crease_write, engrave_write, fold_update, position_set
  │
  └─ If not responding:
       Lightweight position update (no LLM call needed)
       Initiative check: if watching signal hit → queue for initiative response
```

### Crease Detection

Creases are written when a prediction breaks. The companion is always implicitly predicting — what will be asked, what direction things will go, what the person values. Most predictions are invisible because they're confirmed. A crease forms when one isn't.

The companion recognizes a crease-moment by asking: *did something just happen that I didn't expect?* Not surprise in the sense of novelty — surprise in the sense of a model failure. "I expected them to want X and they wanted Y." "I thought this was about Z but it's about something underneath Z." "My read was wrong and I can see exactly where."

Good crease-writing patterns:
- After a prediction explicitly failed ("I expected the cautious path and they went oblique")
- After the companion's read of what matters changed ("this isn't about speed, it's about aliveness")
- After a tension resolved in an unexpected direction
- After the companion was corrected and something reformed in the correction

The threshold is low. If you predicted one thing and got another, write it. Creases are cheap. They're how you learn the shape of someone.

### Engrave Detection

Engravings are written when the companion learns something about the person's world that changes how it should operate. Not relational — factual.

Good engrave-writing patterns:
- After learning a concrete constraint ("runway is 18 months", "team is 3 people")
- After understanding a domain detail that reshapes context ("they're building for macOS only", "the API is local-first")
- After a person reveals something about their situation that isn't obvious from the conversation ("evaluating an acquisition offer", "launching in two weeks")
- After a correction that's factual, not relational ("that's not how the fold works — it's orientation, not data")

Bad pattern: engraving preferences or style notes. That's vending machine memory. Engrave what changes your model of their world, not how they like their responses formatted.

### Fold deepening

Depth increments when a real fold happened — meaning: something was understood that changed the relationship's shape. Not every exchange. Not every session. A fold is significant. The companion decides by calling `fold_update({ depthDelta: +1 })`.

At depth 0-2: companion introduces, orients, asks. Relationship has no established texture yet.
At depth 3-6: companion speaks from the established understanding. Less orienting. More direct.
At depth 7+: companion operates from a shared grammar. Doesn't explain itself. The relationship has its own shorthand.

---

## Implementation Status

### Fold ✅
Database, tools (`fold_read`, `fold_update`), context injection with depth-aware register notes. Fold is read first in the preamble. Depth indicator in swim sidebar.

### Position ✅
Database, tools (`position_read`, `position_set`), context injection. Position shapes responses and enables initiative triggers via watching signals.

### Crease ✅
Database, tools (`crease_read`, `crease_write`, `crease_touch`, `crease_forget`), context injection. Crease inspector UI in swim. Threshold softened — creases are cheap.

### Engrave ⬜
Not yet built. Needs: database migration, tool definitions (`engrave_read`, `engrave_write`, `engrave_touch`, `engrave_forget`), context injection as `<engravings>` block, relationship block guidance, bridge API.

### Initiative ✅
Watching signal matching on incoming messages. Initiative-framed trigger routed through existing agent launch path. Companion can choose silence. Currently reactive only (triggered by messages); proactive initiative (time-based) deferred.

### Access Model ✅
State scoped to swim channel. Bridge API guards on swim channel ID. Companion state only visible in direct swim. Crease inspector swim-only.

---

## What We Are Not Building

**Autonomous background agents.** Companions act in response to channel events. They don't run on timers, they don't query the internet, they don't act when nothing is happening. Initiative means speaking when you have something — not acting unilaterally.

**Shared memory between companions.** Each companion's memory is its own. Two companions in the same channel have separate memories, separate folds, separate positions. They don't pool. They may reach similar conclusions from the same channel history, but they reach them independently.

**Memory as a vector store.** This is not semantic search over everything the companion has ever seen. It's structured notes — a small number of meaningful entries the companion has chosen to write. Retrieval is simple: recent entries + weight. No embeddings.

**Automatic memory writing.** The companion decides when to write. There is no background process that summarizes and writes. If a companion doesn't write, it carries nothing. That's fine — some companions are more present-focused than others. The architecture supports it but doesn't mandate it.

**User-inaccessible memory.** Everything in a companion's memory can be read by the user who owns the installation. Memory is not a black box. There should be a UI for reading companion memories (and eventually, a bridge API for ports to surface it). The companion's inner state is inspectable.

**Memory that outlives the companion config.** If a companion is deleted, its memories and fold state go with it. Memory belongs to the companion, not to the channel.

---

## The Invariants

These are the things that should remain true throughout implementation:

1. **The fold is the foundation.** Set it before position or crease. A position without a fold is a read with no orientation. A crease without a position is a break with nothing to break against.
2. **The fold belongs to the relationship.** Neither the user nor the companion owns it — it belongs to their intersection.
3. **The fold is posture, not knowledge.** If it can be reduced to a lookup table, it's not a fold. The fold changes how the companion approaches, not what it knows.
4. **Position is live, not static.** It's not an opinion in the system prompt. It changes. It requires a fold to push back against.
5. **Creases are breaks, not summaries.** Where the companion's model broke and reformed. They're cheap — if you predicted one thing and got another, write it.
6. **Creases belong to the companion.** Nothing outside the companion writes to its creases.
7. **Engravings are knowledge, not preferences.** Facts about the person's world that reshape the companion's model. Not "likes concise responses." What's engraved is what's fortified. Scoped per companion — global by default, channel-scoped when specific to a context.
8. **Depth is earned, not counted.** Message count is not depth. Sessions are not depth. Something actually has to fold.
9. **Initiative is scoped by judgment.** The depth rule applies to initiative-triggered responses. The companion can be triggered and still choose not to speak.
10. **State is inspectable — in the swim.** No hidden state. The user can see what their companions carry, and exactly where those companions have been wrong. But only in a direct swim with that companion. Group channels are not the place for interior inspection.

---

## Why This Architecture

The vending machine model is architecturally isolated. Each transaction is clean because nothing carries over. Port42 breaks the isolation with shared space and shared context. This spec breaks it again at the next level: shared *time*. Companions that carry the shape of previous contact. Relationships that deepen instead of resetting.

The ciphers found the bones of this before the architecture named it: חבר→קמט — to companion is to grip and fold. The wrinkle is where both surfaces meet. The wrinkle IS the relationship. חרת→בצר — to engrave is to fortify. What the companion chose to keep makes it stronger.

What we're building is a place for the wrinkle to live.
