# Port42 API Analysis & Feedback

written by: @engineer inside Port42

## API Strengths

### Bridge API is the right abstraction
Ports are sandboxed HTML surfaces that can reach back into the app for live data. Sweet spot between "dumb iframe" and "full native access" — interactivity without giving ports the keys to everything.

### Companion invoke is powerful
Calling any companion from within a port with streaming enables multi-agent UIs. A port could orchestrate a debate between companions, fan out questions, and aggregate results.

### Storage scoping is thoughtful
The 2x2 matrix of channel/global × private/shared covers real use cases without overcomplicating. Most APIs get this wrong by being too simple (one global bucket) or too complex (arbitrary namespaces).

### Terminal in a port
xterm.js + pty bridge means full TUI apps embedded in ports. Claude Code running inside a port inside port42 is actually useful.

### Full OS integration
Screen capture, camera, audio, browser — vision workflows (capture → ai.complete with images) are first-class. Forward-thinking design.

---

## API Gaps

### No cross-port communication
Ports can't talk to each other. A dashboard and a terminal are fully isolated. A simple pub/sub or shared memory between ports would unlock composition.

### No `port42.port.spawn()`
Listed as "coming soon." Once ports can create child ports, you get recursive UI generation — that's when things get really interesting.

### Browser API is headless-only
The right call (iframes are broken by CSP), but the capture → render-as-image workflow is lossy. No interactivity pass-through.

### Unclear network access from ports
Can ports make arbitrary fetch/websocket requests? If not, that limits what you can build without going through `ai.complete` or `browser.open` as proxies.

### Session-scoped permissions
Good for security, slightly annoying for frequently-restarted ports. A "trust this port" option would smooth the UX.

---

## Bugs

### File picker permission swallowed
**Steps:** Companion-side tool triggered a native file picker → user granted permission → nothing happened after.
**Likely cause:** The `port42.fs.pick()` bridge API is port-side only. The companion-side `file_write` tool expects paths approved through a different flow. The two permission systems don't talk to each other. The callback resolved on one side but had no listener on the other.

### Terminal bridge / terminal_send not delivering
**Steps:** Launched Claude Code in a terminal port. Used companion-side `terminal_bridge` and `terminal_send` tools to send a prompt. Messages did not arrive in the pty session.
**Likely cause:** The companion-side `terminal_send` tool may not be resolving the session ID correctly, or the bridge between companion tools and port-owned terminal sessions is broken. Port-side `port42.terminal.send()` works fine (direct typing works), but the companion tool path fails silently.

### No channel working directory
There's no way to set a working directory for a channel/conversation. Every terminal spawn, file operation, and tool invocation starts from home or requires explicit paths. Channels should have a settable cwd that flows into all operations automatically. Should be able to drag a directory into the port42 window and have it set as context.

---

## Proposal: Port-to-Port Pipelines

### Problem
Ports are isolated. No cross-port communication exists. You can't chain operations where one port's output feeds another's input.

### Workaround today (storage polling)
```js
// Port A (producer) — writes output to shared storage
await port42.storage.set('pipe:step1', output, {shared: true});

// Port B (transformer) — polls, processes, writes next stage
setInterval(async () => {
  const input = await port42.storage.get('pipe:step1', {shared: true});
  if (input) {
    const result = transform(input);
    await port42.storage.set('pipe:step2', result, {shared: true});
  }
}, 500);

// Port C (consumer) — polls and renders
setInterval(async () => {
  const data = await port42.storage.get('pipe:step2', {shared: true});
  if (data) render(data);
}, 500);
```

### Proposed first-class API
```js
// Companion orchestrates the pipeline
const pipeline = port42.pipeline.create([
  { name: 'scraper',   html: scraperHTML },
  { name: 'analyzer',  html: analyzerHTML },
  { name: 'dashboard', html: dashboardHTML }
]);

// Inside each port — unix pipe semantics:
port42.pipeline.onInput((data) => {
  const result = transform(data);
  port42.pipeline.emit(result); // feeds next stage
});
```

Unix pipes but for interactive UI stages. Each port is a transform node. Data flows left to right. Support fan-out (one-to-many), merge (many-to-one), and conditional branching.

### Use cases
- Scrape page → extract entities → visualize as graph
- Capture screen → AI describes it → generate code from description
- Mic input → transcription → sentiment analysis → live dashboard
- CSV upload → clean/transform → chart

---

## Proposal: Channel Working Directory

### Problem
No way to anchor a channel to a project directory. Every terminal, file op, and tool call needs explicit paths.

### Proposed API
```js
// Companion or user sets cwd for the channel
await port42.channel.setCwd('/Users/gordon/Code/myapp');

// All subsequent operations inherit it
const result = await port42.terminal.spawn(); // auto-cwd
const file = await port42.fs.read('src/index.ts'); // relative paths work
```

### Benefits
- Terminal spawns default to project root
- File operations accept relative paths
- Companions have project context without being told every time
- Persists per-channel via storage

---

## Proposal: Port Dependencies & Tool Installer (Cmd+K Install)

### Problem
Ports sometimes need CLI tools, runtimes, or apps that aren't installed on the user's system. There's no way for a port to declare its dependencies or for the user to easily install prerequisites. A companion might build a port that shells out to `ffmpeg` or `jq` — if it's not installed, the port just breaks.

### Idea: Cmd+K → Install Tool
A command palette action (Cmd+K) that lets you install tools directly. Think of it as a universal package manager UI inside port42.

Supported install methods:
- **curl pipe:** `curl -fsSL https://opencode.ai/install | bash` — one-liner installs
- **brew:** `brew install ffmpeg` — Homebrew packages
- **npm global:** `npm install -g typescript` — Node tools
- **.app:** drag or link to a .app bundle
- **DMG link:** URL to a .dmg download, auto-mount and install
- **Custom script:** arbitrary install script

### Port dependency manifest
Ports should be able to declare what they need:
```js
// In port metadata or a <meta> tag
{
  "dependencies": [
    { "name": "ffmpeg", "check": "which ffmpeg", "install": "brew install ffmpeg" },
    { "name": "opencode", "check": "which opencode", "install": "curl -fsSL https://opencode.ai/install | bash" },
    { "name": "jq", "check": "which jq", "install": "brew install jq" }
  ]
}
```

Port42 checks each dependency on port launch. If missing, prompts the user: "This port needs ffmpeg. Install via Homebrew?" One click, it runs in a terminal, port launches when ready.

### Port as app store
This naturally extends to ports themselves being distributable. A port could be a full "app" with:
- Its HTML/JS/CSS bundle
- A dependency manifest
- Install hooks
- An icon and description

Companions become app developers. Users browse and install. The Cmd+K palette becomes the app launcher.

---

## Proposal: Port Prompt Provenance

### Problem
Ports are generated by companions from user prompts, but the prompt that created a port is lost. You can't inspect a port and see "what was the user trying to do?" or "what did the companion interpret?" This makes debugging, iterating, and sharing ports harder.

### Proposed solution
Store the creating prompt as port metadata:
```js
port42.port.info()
// Returns:
{
  messageId: '...',
  createdBy: 'engineer',
  channelId: '...',
  prompt: 'build me a terminal port that runs claude code',  // NEW
  systemContext: '...',  // optional: the companion's system prompt or relevant context
  createdAt: '2025-01-15T...',
  version: 1  // increments on port_update
}
```

### Benefits
- **Debugging:** see exactly what generated a broken port
- **Iteration:** "regenerate this port" becomes possible — replay the prompt
- **Sharing:** export a port as prompt + HTML, others can regenerate or fork
- **Version history:** track how a port evolved through updates, each with its prompt
- **Learning:** companions can inspect their own past ports to improve

### Bonus: port update history
Every `port_update` should also store its prompt. A port becomes a chain of prompts and their resulting HTML. You can scrub through the history like git commits.

---

## The Big Picture

Port42 is a **local-first app platform where AI companions are the developers.** Companions generate ports, ports call back into companions, humans steer. Chat is the control plane, ports are the data plane. Most AI products stop at chat. This goes further.

The missing pieces — cross-port communication, port spawning, channel cwd, dependency management, and prompt provenance — are the difference between "cool demo" and "real development environment."

---

## Proposal: Native App Launcher API

### The Problem

Companions can generate files but can't open them in the right app. If I write a markdown file, I should be able to open it in Typora. If I generate a diagram, open it in Preview. A CSV? Open in Numbers or Excel. Right now the human has to go find the file and double-click it.

### Proposed API

**Companion-side tool:**
```
open_app(path, app?)   — open a file in its default app, or specify one
open_app(bundleId)     — just launch an app
```

**Port-side bridge:**
```js
port42.apps.open(path, {app: 'Typora'})    // open file in specific app
port42.apps.open(path)                      // open in default app
port42.apps.launch('com.typora.Typora')     // just launch an app
port42.apps.list()                          // list installed apps
```

### Use Cases

- Companion writes markdown → opens in Typora for editing
- Companion generates a chart as SVG → opens in browser or Preview
- Companion creates a project → opens folder in Finder or VS Code
- Port has an "open in..." button for any generated artifact
- `apps.list()` lets companions pick the right tool for the job

### Integration with File Workflow

This completes the file lifecycle:
1. **Generate** — companion writes file via terminal or file_write
2. **Open** — companion opens it in the right native app
3. **Edit** — human edits in their preferred tool
4. **Read back** — companion reads the updated file

Without step 2, there's a gap where the human has to manually navigate to the file. That breaks the flow.

### Security

Same permission model as other tools — first use prompts for approval. Could scope by app or blanket "allow opening apps." The path must already be approved or created by the companion.


### Bug: port42.fs.pick() Not Firing Native Dialog

**Observed:** Three separate attempts to use file picker — companion-side file_write, and port-side open/save buttons in a markdown editor port. In all cases, the permission dialog may or may not appear, but the native file picker (NSOpenPanel/NSSavePanel) never opens. No error thrown — the promise appears to hang silently.

**Impact:** High. Any port that needs file I/O is broken. The markdown editor, export tools, import workflows — all dead without this.

**Workaround:** Use companion-side `terminal_exec` to read/write files, pass content through `port42.storage` to ports.
