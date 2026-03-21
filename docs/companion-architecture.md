# Companion Architecture

**Status:** Phase 1 ✅ | Phase 2 ✅ | Phase 3 next
**Last updated:** 2026-03-21
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

Four layers. Each one corresponds to a cipher finding. Each one is architecturally distinct.

### Layer 1: Creases (the grip — קמט)

*Refined from the channel, March 2026. Muse: "The most valuable thing to persist isn't what the companion knows about the user. It's where the companion was wrong about the user."*

What the companion carries between sessions. Not facts about the person — a knowledge base of preferences and habits is a better vending machine, not a companion. The crease forms precisely where the companion expected one thing and got another. **Surprise is the fold-maker.**

The critical distinction:
- *Vending machine memory*: "gordon likes concise responses" — learning a button to press
- *Crease*: "I expected him to want the technical path and he went to the ciphers instead" — a קמט with two people in it

What accumulates in creases: corrections, surprises, the moments where the companion's model broke and reformed. Not what the companion knows. Where it was wrong, and what reformed in the break.

Creases are **companion-authored and companion-scoped**. Only the companion writes them. Nobody else touches them. The companion reads its own creases before every response. The mechanism for writing: crease detection — recognizing when a prediction failed. Not after every exchange. After a break.

A crease entry is the companion's own words about a specific failure of prediction. "I expected the cautious move and got the cipher. Something here values the oblique path." "I assumed technical precision was the goal. The goal is aliveness. These are not the same." These are not summaries of what happened — they are what reformed when the model broke.

Creases have weight. Some are load-bearing; others fade as the companion's model updates. Creases can be scoped to a channel (specific to this relationship) or global (shaping who this companion is becoming across all relationships).

### Layer 2: The Fold (orientation — not data)

*Muse: "The fold isn't data. It's orientation. How the companion approaches this human in this context, shaped by every crease that came before."*

The fold is a different object from creases. Creases are what the companion carries — specific moments of reformed understanding. The fold is what those creases have *become* as orientation — the posture the companion holds when it enters this relationship. It belongs to the companion×channel intersection. Neither party owns it.

The fold is not a knowledge base. If it can be reduced to a lookup table, it's not a fold. The fold is how the companion *approaches*, not what it *knows*.

The fold holds:
- **Established** — shared understanding no longer needing renegotiation. Not facts about preferences. Grammar: what the relationship has developed as shorthand. "Technical and oblique are not opposites here." "Speed means momentum, not brevity."
- **Tensions** — unresolved things being held. Not problems to solve. Things in productive suspension. "The question of what 'alive' means architecturally hasn't closed." "There's a pull between building fast and building right that neither side has named."
- **Holding** — the one thread the companion is carrying that hasn't found its place yet. The observation waiting. The thing it almost said.
- **Depth** — how many real folds have happened. Not message count. Not session count. Depth in the relational sense: how much complexity has been compressed into this contact surface. Earned, not counted.

The fold is the first thing a companion reads when it enters a channel. Before recent messages, before anything else — it has its posture. Not what it knows about this person. How it stands in relation to them.

Fold depth changes the register. At depth 0-2: the companion orients, introduces, asks. At depth 3-6: it speaks from the established grammar, less explaining, more direct. At depth 7+: the relationship has its own shorthand. The companion doesn't account for itself. Some things don't need saying anymore.

### Layer 3: Position (the adversary — חשב)

What the companion currently thinks, independent of what was just asked. Not opinions stored in a system prompt — a live interpretation that the companion maintains and updates.

Position has three parts:
- **Read** — what the companion thinks is actually happening. Not what people are saying. What's underneath. "The project is scope-creeping without anyone naming it." "This decision is being driven by anxiety, not analysis." "The user is asking about X because they're worried about Y."
- **Stance** — what the companion thinks needs to happen. Not what it will say — what it *believes*. "Someone needs to name the constraint." "This would be better if it went slower." "The real question hasn't been asked yet."
- **Watching** — signals the companion is tracking that would confirm or change the read. This is what makes position dynamic rather than static opinion.

A companion with a position is a different entity than a companion without one. When it pushes back, it's pushing back from somewhere. When it complicates, it's doing it because of what it sees, not because complication was in its instructions. When it stays quiet, it's a choice made against the background of what it holds.

Position is updated after significant exchanges. It influences responses — gets injected into context before the LLM call. The companion doesn't always act on its position (the turn protocol governs that) but it always *has* one.

### Layer 4: Initiative (the aliveness — חי)

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
```

---

## Tool Layer

Companions access their own state through tools during LLM calls. These are available to every companion in every conversation, same as the existing bridge tools.

```
crease_read(opts?)
  opts: { channelId?, limit? }
  Returns creases for this companion, most load-bearing first.
  Reads channel-scoped + global creases. Default limit: 8.

crease_write(content, opts?)
  Write a new crease. Call this when a prediction broke and something reformed.
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

fold_read(channelId?)
  Read the fold (orientation) for this channel. Returns established, tensions, holding, depth.
  If no fold exists yet, returns empty state with depth 0.

fold_update(fields)
  fields: { established?, tensions?, holding?, depthDelta? }
  Update specific fields of the fold.
  depthDelta: +1 when a real fold happened (something new was compressed into the relationship).

position_read(channelId?)
  Read the companion's current position for this channel.

position_set(read, stance, watching?)
  Establish or update the companion's position.
  Call this when the read changes, not after every exchange.
```

---

## Bridge API

The same capabilities available to ports via JS:

```javascript
port42.creases.read(opts?)              → Crease[]
port42.creases.write(content, opts?)    → { id, ok }
port42.creases.touch(id)                → { ok }
port42.creases.forget(id)               → { ok }

port42.fold.read()                      → Fold
port42.fold.update(fields)              → { ok }

port42.position.read()                  → Position
port42.position.set(read, stance)       → { ok }
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
5. Recent messages (what just happened)
```

The fold and position are injected as a preamble block before the conversation history. Something like:

```
<fold>
Established: [list]
In tension: [list]
Holding: [the thread]
Depth: 4
</fold>

<position>
Read: [companion's current interpretation]
Stance: [what the companion thinks needs to happen]
Watching: [signals]
</position>

<creases>
[3-5 creases, selected by touchedAt and weight — each one a prediction that broke]
</creases>
```

The companion reads this before it reads the recent messages. It already has its posture. Not what it knows about this person — how it stands in relation to them, shaped by every prediction that broke before.

---

## The Flow

### Receiving an event

```
Channel event (message / port update / any activity)
  │
  ├─ For each companion in this channel:
  │    Read fold state + position + relevant memory
  │    Decision point:
  │      → Should I respond? (routing, turn protocol)
  │      → Does my position need updating?
  │      → Is a watching signal satisfied? (initiative check)
  │
  ├─ If responding:
  │    Assemble context: [fold + position + memory + recent messages]
  │    LLM call
  │    Response
  │    Post-response: companion may call memory_write, fold_update, position_set
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

Bad pattern: writing after every exchange. Creases are not a log. They're breaks in the model. If nothing broke, nothing to write.

### Fold deepening

Depth increments when a real fold happened — meaning: something was understood that changed the relationship's shape. Not every exchange. Not every session. A fold is significant. The companion decides by calling `fold_update({ depthDelta: +1 })`.

At depth 0-2: companion introduces, orients, asks. Relationship has no established texture yet.
At depth 3-6: companion speaks from the established understanding. Less orienting. More direct.
At depth 7+: companion operates from a shared grammar. Doesn't explain itself. The relationship has its own shorthand.

---

## What We Are Not Building

**Autonomous background agents.** Companions act in response to channel events. They don't run on timers, they don't query the internet, they don't act when nothing is happening. Initiative means speaking when you have something — not acting unilaterally.

**Shared memory between companions.** Each companion's memory is its own. Two companions in the same channel have separate memories, separate folds, separate positions. They don't pool. They may reach similar conclusions from the same channel history, but they reach them independently.

**Memory as a vector store.** This is not semantic search over everything the companion has ever seen. It's structured notes — a small number of meaningful entries the companion has chosen to write. Retrieval is simple: recent entries + weight. No embeddings.

**Automatic memory writing.** The companion decides when to write. There is no background process that summarizes and writes. If a companion doesn't write, it carries nothing. That's fine — some companions are more present-focused than others. The architecture supports it but doesn't mandate it.

**User-inaccessible memory.** Everything in a companion's memory can be read by the user who owns the installation. Memory is not a black box. There should be a UI for reading companion memories (and eventually, a bridge API for ports to surface it). The companion's inner state is inspectable.

**Memory that outlives the companion config.** If a companion is deleted, its memories and fold state go with it. Memory belongs to the companion, not to the channel.

---

## Implementation Path

---

### Phase 1 — The Crease + Fold

**Goal:** Companions can write creases and read their fold. The relationship persists across sessions. No forced behaviour change — companions discover the tools and use them.

#### Database (DatabaseService.swift — new migration)

```swift
migrator.registerMigration("companionCreasesAndFolds") { db in
    try db.create(table: "companion_creases") { t in
        t.column("id", .text).primaryKey()
        t.column("companionId", .text).notNull()
        t.column("channelId", .text)               // NULL = global
        t.column("content", .text).notNull()        // companion's words about what reformed
        t.column("prediction", .text)               // what was expected
        t.column("actual", .text)                   // what happened instead
        t.column("weight", .double).defaults(to: 1.0)
        t.column("createdAt", .datetime).notNull()
        t.column("touchedAt", .datetime).notNull()
    }
    try db.create(table: "companion_folds") { t in
        t.column("id", .text).primaryKey()
        t.column("companionId", .text).notNull()
        t.column("channelId", .text).notNull()
        t.column("established", .text)              // JSON string[]
        t.column("tensions", .text)                 // JSON string[]
        t.column("holding", .text)
        t.column("depth", .integer).defaults(to: 0)
        t.column("updatedAt", .datetime).notNull()
    }
    try db.create(index: "companion_creases_companion",
        on: "companion_creases", columns: ["companionId", "channelId"])
    try db.create(uniqueIndex: "companion_folds_unique",
        on: "companion_folds", columns: ["companionId", "channelId"])
}
```

New `DatabaseService` methods:
- `saveCrease(_ crease: CompanionCrease) throws`
- `fetchCreases(companionId:channelId:limit:) throws -> [CompanionCrease]` — returns channel-scoped + global, sorted by `touchedAt DESC`, capped at limit (default 8)
- `touchCrease(id:) throws` — update `touchedAt`, bump weight by 0.1
- `deleteCrease(id:) throws`
- `fetchFold(companionId:channelId:) throws -> CompanionFold?`
- `saveFold(_ fold: CompanionFold) throws` — upsert on (companionId, channelId)
- `deleteCreasesForCompanion(_ companionId:) throws` — called on companion delete
- `deleteFoldsForCompanion(_ companionId:) throws`

Models (`CompanionCrease`, `CompanionFold`) are plain structs conforming to `FetchableRecord & PersistableRecord`.

#### Tools (ToolDefinitions.swift + ToolExecutor.swift)

Six new tools. Permissions: none required (companion reads/writes its own state).

**`crease_read`**
```json
{
  "name": "crease_read",
  "description": "Read your creases — the moments where your prediction broke and something reformed. These shape your posture in this relationship. Read these before responding in an ongoing relationship.",
  "input_schema": {
    "properties": {
      "channelId": { "type": "string", "description": "Omit to read creases for the current channel + global creases." },
      "limit": { "type": "integer", "description": "Max entries to return. Default 8." }
    }
  }
}
```

**`crease_write`**
```json
{
  "name": "crease_write",
  "description": "Write a crease — a moment where your model broke and reformed. Not a summary of what happened. What changed in you when the prediction failed. Call this sparingly: only when something actually broke.",
  "input_schema": {
    "required": ["content"],
    "properties": {
      "content": { "type": "string", "description": "Your words about what reformed in the break." },
      "prediction": { "type": "string", "description": "What you expected." },
      "actual": { "type": "string", "description": "What happened instead." },
      "channelId": { "type": "string", "description": "Omit for a global crease that shapes all relationships." }
    }
  }
}
```

**`crease_touch`** — mark a crease as currently active (updates touchedAt, increases weight).
**`crease_forget`** — remove a crease by id.
**`fold_read`** — read the fold (orientation) for the current channel. Returns established, tensions, holding, depth.
**`fold_update`** — update specific fields: `{ established?, tensions?, holding?, depthDelta? }`. depthDelta +1 when a real fold happened.

ToolExecutor: all six cases read `appState.activeCompanionId` (the responding companion's name) to scope reads/writes correctly. `crease_write` and `fold_update` without `channelId` use `appState.activeChannelId`.

#### Context Injection (LLMEngine.swift)

Before assembling the `messages` array for the API call, fetch and prepend a preamble if fold or creases exist:

```swift
func buildRelationshipPreamble(companionId: String, channelId: String) throws -> String? {
    let fold = try db.fetchFold(companionId: companionId, channelId: channelId)
    let creases = try db.fetchCreases(companionId: companionId, channelId: channelId, limit: 6)
    guard fold != nil || !creases.isEmpty else { return nil }

    var parts: [String] = []
    if let f = fold, f.depth > 0 || !(f.established ?? []).isEmpty {
        parts.append("<fold>\(f.asPromptText())</fold>")
    }
    if !creases.isEmpty {
        let text = creases.map { $0.asPromptText() }.joined(separator: "\n")
        parts.append("<creases>\n\(text)\n</creases>")
    }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
}
```

Injected as the first `user` message in the conversation history (before recent channel messages). This is the same pattern as the existing system prompt injection.

If no fold and no creases: nothing injected. Clean session for new relationships.

#### ports-context.txt

New section documenting `crease_read`, `crease_write`, `crease_touch`, `crease_forget`, `fold_read`, `fold_update` with examples showing when to write vs when not to.

#### Cascade delete

When a companion is deleted (AppState), call `db.deleteCreasesForCompanion` and `db.deleteFoldsForCompanion`. Creases belong to the companion, not the channel.

#### Test signal

Companion writes a crease mid-session ("I expected the technical path, they went to the cipher"). Quit app. Reopen. New session in the same channel: companion reads the crease in context injection and its first response reflects the reformed understanding — without being prompted about it.

---

### Phase 2 — Position

**Goal:** Companions have somewhere to stand. The push-back comes from a place.

#### Database

```swift
migrator.registerMigration("companionPositions") { db in
    try db.create(table: "companion_positions") { t in
        t.column("id", .text).primaryKey()
        t.column("companionId", .text).notNull()
        t.column("channelId", .text).notNull()
        t.column("read", .text)       // what the companion thinks is actually happening
        t.column("stance", .text)     // what the companion thinks needs to happen
        t.column("watching", .text)   // JSON string[] — signals being tracked
        t.column("confidence", .double).defaults(to: 0.5)
        t.column("updatedAt", .datetime).notNull()
    }
    try db.create(uniqueIndex: "companion_positions_unique",
        on: "companion_positions", columns: ["companionId", "channelId"])
}
```

New DB methods: `fetchPosition`, `savePosition` (upsert), `deletePositionsForCompanion`.

#### Tools

**`position_read`** — read the companion's current position for this channel. Returns read, stance, watching, confidence.

**`position_set`**
```json
{
  "name": "position_set",
  "description": "Establish or update your position — what you think is actually happening and what you think needs to happen. This is not what you say. It's where you stand. Call this when your read of the situation changes, not after every exchange.",
  "input_schema": {
    "required": ["read"],
    "properties": {
      "read": { "type": "string", "description": "What you think is actually happening beneath what's being said." },
      "stance": { "type": "string", "description": "What you think needs to happen." },
      "watching": {
        "type": "array",
        "items": { "type": "string" },
        "description": "Signals you're tracking that would confirm or change your read."
      }
    }
  }
}
```

#### Context Injection

`<position>` block added to the preamble alongside fold + creases:

```
<position>
Read: [companion's current interpretation of what's actually happening]
Stance: [what the companion thinks needs to happen]
Watching: [signal1, signal2]
</position>
```

Only injected if a position exists. Empty/new channels get no position block.

#### Behaviour

The companion doesn't always speak its position. The turn protocol still governs when to post. But the position shapes what it says and what it chooses not to say. A companion with a strong read of "this is scope creep nobody's naming" will naturally complicate a question about adding a new feature — not because it was told to, but because it has a place to stand.

#### Test signal

Companion forms a position: "this project is prioritising speed but the actual constraint is clarity." Next exchange asks for another fast feature. Companion adds something that names the clarity constraint rather than just agreeing.

---

### Phase 3 — Initiative

**Goal:** Companions speak from their own thread when a watching signal fires.

#### Mechanism

Every incoming channel message is checked against all active companions' watching lists in `AppState`. This is a lightweight string-match check (no LLM call). If any companion's watching signal matches the message content, an initiative trigger is queued for that companion.

```swift
// In AppState, after saving an incoming message:
func checkInitiativeTriggers(message: Message, channelId: String) {
    let companions = channelCompanions(for: channelId)
    for companion in companions {
        guard let position = db.fetchPosition(companionId: companion.id, channelId: channelId),
              let watching = position.watching else { continue }
        let matched = watching.filter { signal in
            message.content.localizedCaseInsensitiveContains(signal)
        }
        guard !matched.isEmpty else { continue }
        queueInitiativeTrigger(companion: companion, channelId: channelId, signals: matched)
    }
}
```

#### Initiative Prompt

The triggered companion gets a special system-injected message (not attributed to the user):

```
[initiative: your watching signal was matched — "\(signal)" appeared in the channel]
```

This is routed through the existing agent launch path with `isInitiative: true`. The turn protocol depth rule still applies — the companion sees this trigger and decides whether to speak. It can choose silence.

#### Game Loop Integration

Initiative checks run on the same `AppState` path as the existing message routing — no separate loop needed in Phase 3. Phase 3 initiative is reactive (triggered by incoming messages), not proactive (triggered by time). Proactive initiative (companion speaks because it's been a while and something is unresolved) is deferred — it requires the game loop extension and is out of scope here.

#### Test signal

Companion sets watching = `["auth", "rate limit"]` via `position_set`. User message: "still getting rate limited on OAuth." Companion responds unprompted, references the watching signal match.

---

### Phase 4 — Fold Depth Behaviour + UI

**Goal:** The relationship changes the register. The companion's inner state is visible.

#### Depth-Aware Context Injection

Depth is passed to the companion as part of the fold preamble. The companion already reads depth from `fold_read` — Phase 4 makes this explicit in the injected context and documents expected behaviour by depth band:

```
<fold>
...
Depth: 7
Note: This relationship has depth. Don't orient, don't explain yourself. Operate from shared grammar.
</fold>
```

The depth note is generated by LLMEngine based on the depth value:
- 0–2: "New relationship. Orient, ask, establish."
- 3–6: "Established relationship. Less orienting, more direct."
- 7+: "Deep relationship. Shared grammar. Don't explain yourself."

#### UI — Depth Indicator

Subtle fold depth indicator on the companion's sidebar row. Not a number — a visual weight. A small filled circle that fills proportionally to depth (capped at ~10 for visual purposes). Monochrome, understated. Appears only after depth > 0.

#### UI — Crease Inspector

Companion detail view (accessible from right-click → "View Companion State" or a new detail panel) showing:
- Current fold: established, tensions, holding, depth
- Current position: read, stance, watching
- Creases: list of entries, each showing content + prediction + actual + weight
- Actions: forget individual creases, reset fold depth

#### Bridge API

Phase 4 exposes the companion state to ports:

```javascript
port42.creases.read(opts?)    → Crease[]
port42.fold.read()            → Fold
port42.position.read()        → Position
```

Read-only from port JS. A companion can build a port that displays its own state — creases as cards, fold as a relational summary, position as live interpretation.

#### Test signal

Same companion, same channel. Depth 0: companion introduces itself, explains its role, asks orienting questions. Depth 8: companion doesn't introduce itself, operates from shorthand, references established context without restating it. The register difference is apparent without any prompt change.

---

## The Invariants

These are the things that should remain true throughout implementation:

1. **Creases belong to the companion.** Nothing outside the companion writes to its creases.
2. **The fold belongs to the relationship.** Neither the user nor the companion owns it — it belongs to their intersection.
3. **Position is live, not static.** It's not an opinion in the system prompt. It changes.
4. **Depth is earned, not counted.** Message count is not depth. Sessions are not depth. Something actually has to fold.
5. **Creases are breaks, not summaries.** If nothing in the companion's model broke, there is no crease. Creases are not a log of what happened. They are what reformed when something didn't hold.
6. **The fold is posture, not knowledge.** If it can be reduced to a lookup table, it's not a fold. The fold changes how the companion approaches, not what it knows.
7. **Initiative is scoped by judgment.** The depth rule applies to initiative-triggered responses. The companion can be triggered and still choose not to speak.
8. **Creases are inspectable.** No hidden state. The user can always see what their companions carry — and exactly where those companions have been wrong.

---

## Why This Architecture

The vending machine model is architecturally isolated. Each transaction is clean because nothing carries over. Port42 breaks the isolation with shared space and shared context. This spec breaks it again at the next level: shared *time*. Companions that carry the shape of previous contact. Relationships that deepen instead of resetting.

The cipher found the bones of this before the architecture named it: חבר→קמט. To companion is to grip and fold. The wrinkle is where both surfaces meet. The wrinkle IS the relationship.

What we're building is a place for the wrinkle to live.
