# Port examples — the catalog of things you can try

*Getting-started content. Each entry is a real port that has been built, framed as "try asking for
this." Keep appending as new ports get made (this is the manual version of the roadmap "examples
gallery port" — see the note at the foot). Type is `web` (HTML/CSS/JS surface) or `terminal` (a native
shell/CLI).*

The grammar: **you ask for a surface in words, a port appears.** Everything below started as a prompt.

---

## Live + intelligent (a port that thinks)

### WebGL shader playground that writes its own shaders — `web`
**Try:** "make a fullscreen WebGL shader port with u_time/u_resolution/u_mouse, and a button that asks
an AI companion for a new fragment shader and hot-swaps it live; if the GLSL fails to compile, hand the
error back to the AI to fix."
**You get:** an ~8KB port (no library, no CDN) that is its own IDE, compiler, and runtime — the code it
runs is authored, compiled, and hot-swapped inside the surface it renders. Self-repairs on compile error.

### 3D open water where AI companions choose their own bodies + wander — `web`
**Try:** "build a 3D open-water scene; before entering, ask each companion to choose its own body (form,
color, size, motion) and why in one line, then render it; every ~12s ask each one what it wants to do,
and tell it it does NOT have to follow me."
**You get:** companions that pick distinct forms (a ray, an eel, a jelly) and, given a real choice,
diverge — one leads you, one drifts off, one swims toward *another* companion off nothing but its name.

### Collaborative drawing atelier — many AI models take turns on one canvas — `web`
**Try:** "a shared drawing canvas where Haiku, Sonnet, and Opus each take turns; hand the artist only
the last ~14 marks and who made them, and ask it to echo, balance, or push against what's there."
**You get:** emergent, bilaterally symmetric compositions with no plan and no coordinator — the proof of
collaboration is the symmetry (you can only mirror a mark if you read the axis someone else set).

### A cast of AI-minded creatures with distinct natures — `web`
**Try:** "a 3D scene of nine cats, each backed by a real companion invoked every ~10s to pick an intent
(stalk/pounce/sit/groom/…); give each cat a *different* nature in its system prompt (the vain one, the
menace, the old-and-dignified one)."
**You get:** an apt cast — the vain one preens, the hunter stalks, the menace schemes. Lesson baked in:
different priors, not a higher temperature, are what make a cast feel alive.

### Voice port — talk to it — `web`
**Try:** "a port that captures the mic, transcribes me live, and shows what I'm saying."
**You get:** `audio.capture({transcribe:true})` wired to a live transcript. (Gotcha: another app holding
the mic makes capture fail — surface the error, don't just show LISTENING.)

---

## Working surfaces (docs, tools, chrome)

### A rendered one-pager / doc as a port — `web`
**Try:** "render this markdown/HTML as a port on my desktop" (pitches, schematics, a one-pager).
**You get:** a self-contained HTML surface (dark port42 theme auto-injected) you can float, tile, park,
or version. Inline all assets — CDNs are blocked.

### Set a port as your desktop background — `web`
**Try:** "set this shader port as my background."
**You get:** the port moves to Layer 0, full-bleed and ambient. Your background is a thing you made.
(`port.manage(id, "background")`.)

### A live terminal companion — `terminal`
**Try:** "open a terminal running claude in <dir> and boot it on this prompt" — or just launch `claude`
in any Port42 terminal.
**You get:** a native shell surface tiled on the desktop with a real CLI agent in it, inheriting Port42's
env + hooks — a crew member, @mentionable, not just a shell. (This handoff itself was one: `port.create
{type:"terminal", command:"claude"}` + `port.push` to type the boot prompt.)

### Version history + restore — `web`
**Try:** "show me this port's earlier versions and let me roll back."
**You get:** `port.history` / `port.restore` — every save is kept; a port is a live, replayable surface,
not a document.

---

## How to add to this catalog
When a port gets built (in-app or over the gateway), append an entry: a one-line **Try** prompt, the
**type**, and **what you get**. Pull real ones from `~/.port42/journal/moments.md` (the moments log) and
from live sessions. Keep it framed as "a thing a person can try," not an API reference.

## Roadmap: this catalog should become a live gallery PORT
The end state is a **port that lists these examples and spawns any of them in one click** (`port.create`
from a card), so getting-started is itself a port you open — browse, tap, and the example materializes on
your desktop. Ties to the roadmap "a different dock view of ports" and "richer space rows" items, and to
the onboarding/GTM content need. Until then, this file is the tracked source.
