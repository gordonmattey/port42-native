# Plan: `port42-ports` — the port-authoring skill

*2026-07-16. The skill that teaches any agent — an in-app companion, Claude Code, Cursor, anything —
how to build a **port** correctly. Scope of the summer-todo item "migrate injected context →
installable skills", narrowed to the port surface language. Status: **PLANNED** (v0 not on this
machine; effectively a fresh build).*

**Why it exists:** Port42 injects `ports-context.txt` (~1,100 lines) + `llms.txt` into companion
system prompts *inside* the app. Outside the app none of it exists, so generic built-ins fill the gap
(`artifact-design` teaches a non-Port42 aesthetic for what should be *ports*). Move it into an
installable Agent Skill so the knowledge (a) loads on demand instead of costing every turn, and
(b) travels to any agent.

**Build it AFTER the API/tool-use unification** — there's no point documenting an API that's about to
be made consistent (`ports.list` returning a text blob vs `terminal.list` returning JSON;
`capabilities: []` vs `["terminal"]` for the same port). Document one coherent surface, once.

---

## §1 — The gotchas (the highest-value section; each one cost a live debugging round)

*These are not discoverable. They don't throw, they don't warn — they hand you a blank rectangle or a
frozen picture and let you guess. Every one below was learned the hard way in a single session
(2026-07-15/16) building five real ports. An agent given these three lines up front builds a correct
port first try instead of iterating through four fixes.*

**The root constraint — a port is a TILE, not a window.**
Never assume you're fullscreen or window-aligned. It has an arbitrary, changing size, and it can be
offset inside the shell.
- **Size from your own element**, never `innerWidth`/`innerHeight`.
- **Map pointer coords through `getBoundingClientRect()`**, never `clientX / innerWidth`.
- **Size everything relative** (`min(W,H) * k`), never absolute pixels tuned for your screen.
- *Symptoms seen:* art drawn entirely off-screen in a small tile; click ripples landing offset to the
  right of the cursor.

**Never let the backing store feed layout.**
Sizing a canvas's backing store *from* its `clientWidth` while it has no locked CSS size is a
feedback loop: `canvas.width` grows the element, which grows `clientWidth`, which grows
`canvas.width`.
- **Lock the display size in CSS** (`width:100%; height:100%`), then size the backing store from it.
- *Symptom seen:* `clientWidth` = **33,554,432px**, port blank, no error.

**three.js: `renderer.setSize(w, h)` — never `setSize(w, h, false)`.**
`updateStyle:false` leaves the canvas with no CSS size, so it displays at backing-store size (DPR×)
and the scene is pushed out of frame.
- *Symptom seen:* "way offset to the right, I can only see half the cube."

**Never alias one scratch vector twice in an expression.**
`tmp.copy(a).sub(tmp.copy(b))` is **zero** — same object, silently. Use dedicated vectors.
- *Symptom seen:* camera lerping to the origin forever; the player *was* moving, the camera never
  followed. Presented as "I can't swim."

**WebGL: `toDataURL` is black without `preserveDrawingBuffer: true`.**
The drawing buffer is cleared after compositing, so a working shader captures as a black rectangle.
- *Symptom seen:* a perfect shader, a black screenshot, and a wrong conclusion one step away.

**CDNs are blocked in web ports — inline your library.**
A `<script src="https://unpkg.com/…">` silently does not load. **Probe before you assume.** three.js
min is ~613KB and fits under the gateway's 2MB payload cap; raw WebGL costs ~0KB.

**A closure is not storage.**
State inside an IIFE is unreachable from `port_exec` *and* destroyed by `port_update`.
- **Persist to `port42.storage`** from the first write. Then a full HTML replace is non-destructive
  (proved: *"restored 31 forms"* after replacing an entire port's HTML mid-session).
- The 2D atelier lost its vector data exactly this way — only a rendered image survived.

**One malformed input must never kill the render loop.**
LLM-authored data is untrusted input. Validate + clamp *every* field before it reaches the renderer,
and wrap the draw loop.
- *Symptom seen:* a port whose invoke-loop kept running and reporting while its picture was frozen —
  logic alive, rendering dead.

**Make failure visible.**
A port that dies silently is undebuggable. Ship `window.onerror` → write it into the UI.
- *Symptom seen:* a script error killed a port's every event listener; the button "did nothing" and
  nothing anywhere said why. `typeof start === 'undefined'` while `port42` existed was the tell —
  **`port42` is injected by the app, so its presence proves nothing about your own script.**

**Never render when nobody's looking — a port that doesn't idle is a CPU bomb.**
An unconditional `requestAnimationFrame` loop runs at 60fps forever: while peeking at 210px, while
backgrounded, while the human is in another space. Four animated ports at once **cooked a machine**
and had to be killed (2026-07-16).
- **Pause on hidden** (`document.hidden`), **pause when off-screen** (`IntersectionObserver`), and —
  once it exists — on the port's presentation event (see the summer-todo item; the shell knows the
  state but doesn't yet tell you).
- **Throttle when small/unfocused** (~15-30fps), **cap `devicePixelRatio`**, and **scale particle /
  geometry counts to the tile's size** — a 210px peek does not need 900 particles.
- The desktop is made of live ports: assume **5-10 of you** are running at once. Budget accordingly.

**Retina:** `ctx.setTransform(DPR,0,0,DPR,0,0)` once, then draw in CSS pixels.

## §2 — Patterns worth teaching (earned in the same session)

- **The LLM sets intent; the engine executes it.** Slow, meaningful decisions (~every 10s, an
  `invoke`) + fast, smooth execution (60fps steering/physics). Never call an LLM per frame. This is
  what made companions *choose* whether to follow the human instead of being glued to them by a
  hardcoded weight.
- **Self-repair loops.** When an LLM authors code, feed the *compiler's own error* back to the author
  and retry (bounded). A companion wrote live GLSL, and the port can hand it its compile error to fix.
- **A port can ask an AI directly** — `port42.companions.invoke(id, prompt)` from a port's JS. The
  port doesn't need a human in the loop to become intelligent.
- **Let them choose.** Give a companion a vocabulary and let it pick (its own form, its own intent),
  rather than assigning one. It's both better product and better demo.
- **Parse defensively.** Extract the JSON with a regex (`/\[[\s\S]*\]/`), `try/catch` the parse, and
  sanitize every field. LLMs add prose no matter what the prompt says.

## §3 — What else the skill carries

- **The bridge** (`port42.*`): the method surface, argument shapes, what's permission-gated.
  Source: `Sources/Port42Lib/Resources/ports-context.txt` + `llms.txt`.
- **Read-before-patch discipline** — `port.getHtml` → minimal `port.patch` → bump `<meta version>`.
  Never rewrite a whole port to fix one line.
- **The stateful-app pattern** — a port is a live surface, not a document: persist, restore, replay.
- **The port42 design system** — dark, mono, the accent palette; **overrides `artifact-design`** for
  port tasks (that's the whole point: generic built-ins teach the wrong aesthetic for ports).

## §4 — Work

1. **Write `SKILL.md`** + references: `bridge-and-patterns.md`, **`gotchas.md`** (§1 — lead with it),
   `design-system.md`.
2. **`sync-docs.sh` as the single source** so the skill's bridge reference can never drift from the
   injected `ports-context.txt`.
3. **Install path** — the app's installer drops it into `~/.claude/skills`; install writes
   `skillOverrides: {"artifact-design": "off"}` in Port42-managed config.
4. **Decide lazy vs resident** — safety-critical prompt bits stay injected; reference material becomes
   the skill.
5. **Verify behaviourally** — the gate is: a companion (and Claude Code) given only the skill builds a
   correct, non-blank, correctly-sized, persisted port **first try**. That's testable: today's session
   is the control group — five ports, four plumbing bugs, all preventable by §1.

## §5 — Related

- `../docs/summer2026-todo.md` → "migrate injected context → installable skills" (the parent item),
  "`ports.list` API consistency" (do the unification first).
- `membrane/bus-architecture.md` — a port is an addressable actor; this skill teaches authoring one.
