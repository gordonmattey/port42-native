# Nautilus Phase 1: remove what no scenario needs, and build the chat port

Detailed plan for Phase 1 of `plan-shell-only.md`. Scenario served: 1. Written 2026-09-25 against
`nautilus` at `872fae8`, with Phase 0 complete and all five scenarios passing.

## Goal

Port42 holds ports, a registry, grants and a door, and nothing else. The messaging system, the in-app
model and the memory service are gone. The native chat tile is replaced by a chat port that any scope
can carry: the desktop, a space, or one port.

## Progress

1.2 ✓ · 1.6 ✓ (both parts) · 1.4 ✓ (ngrok, invites, sync client, schema v47) · housekeeping ✓ ·
1.3 ✓ (engine, Keeper, first run on a CLI) · 1.1 re-scoped (below) · 1.5 in progress (step 1 of 5 ✓).

## Order, and why

Pure removals first, each shippable alone and each leaving the harness at five of five. The chat port
comes last, because it is the one design in the phase and it replaces the thing scenario 1 runs
through today.

Each step is its own commit. Suite green, Go suites green, harness five of five, plans updated.

### 1.1 Retired spikes, the Keeper service, swims

- **Spikes stay (decided 2026-09-25).** `PortDesktopSpike`, `PortResizeSpike`, `ScreenRecordSpike` and
  the rest are wired into `Port42App`'s debug menu and its hands-free launch flags, so they are dev
  tooling, not dead code. No scenario needs them and none ships in a release build. Removing them
  is GM's call.
- **Keeper moves to step 1.3.** The in-app engine's system prompt teaches the Keeper tools and injects
  Keeper's memory, and the engine's initiative triggers (watched signals, held topics, bus signals) read
  Keeper's positions and folds. The two come out together.
- **Keeper:** `BridgeServiceKeeper`, `CompanionRelationship`, `CreaseInspectorSheet`, the `crease`,
  `fold`, `position` and `engrave` methods, their `DatabaseService` sections, and the four
  `companion_*` tables (empty on Dev3). Tests: `CompanionRelationshipTests`, `D4MemoryScopeTests`,
  `BridgeParityMemoryTests`, and the Keeper cases in any mixed suite.
- **Swims:** `swimMessages` and the swim branches of `ConversationContent`. Tests: `SwimTests`,
  `SwimUnificationTests`.
- **Schema:** migration v47 drops the four `companion_*` tables and `swimMessages`. Existing migrations
  are never edited.

### 1.2 Bring-your-own-agent over invites

`OpenClawService`, `OpenClawSheet`, `PythonAgentSheet`, `AgentConnectSheet`, their `AppState` flags and
their `ShellView` sheets. The `port42-openclaw` and `port42-python` repos are left alone here; retiring
them is GM's call and outside this repo.

**Done 2026-09-25.** The four files are gone, along with the flags and prefill state in `AppState`, the
OpenClaw detection at launch, the three sheet overlays and their escape-key closes in `ShellView`,
the settings button that upgraded the OpenClaw plugin, and three analytics events. `port42://openclaw`
links now fall through to "unknown deep link". A space invite carrying an encryption key, which was
the agent-connect flow, is logged as unsupported rather than joined. Suite 1441 green; harness five
of five.

### 1.3 The in-app engine, and the first run rebuilt on a CLI agent

These go together, because the first run is the engine's last user.

- **Engine:** `LLMEngine`, `GeminiEngine`, `LLMBackend`, `LLMStreamCollector`, `BridgeServiceAI`,
  `AgentRouterLLM`, `AppState+PortAI`, `AgentAuth`, `ModelPicker`, `UsageView`, the `ai.*` methods,
  `companions.invoke`, `token_usage`, heartbeats, and the `.llm` companion mode with its columns
  (D7, D4).
- **First run:** Echo becomes a command companion. Setup detects `claude` and `codex` on the PATH. With
  one, Echo runs on it; with both, the person picks; with neither, setup offers the Claude Code
  installer or a new Codex installer. The Keychain token step goes (D9). Setup ends focused on Echo's
  terminal with the prefilled line. Echo's prompt is rewritten for a command companion: `port.create`,
  never a fence (D11), with the Codex welcome delivered through `AGENTS.md`.
- **Schema:** a new migration drops `token_usage` and the LLM columns on `agents`, and the heartbeat
  columns on `spaces`. LLM and remote companions are deleted first, with their space memberships,
  because their mode no longer decodes.
- **Found while mapping (2026-09-25):** Port42 keeps a Claude OAuth token in its own secrets store and
  injects it into every companion terminal as `CLAUDE_CODE_OAUTH_TOKEN`. D9 says Port42 reads no
  provider credential, so the injection and the stored secret go. Each CLI uses its own sign-in.
- **Commits:**
  - **1.3a:** the engine, Keeper, `.llm` and `.remote` companions, heartbeats and the token injection
    go. Echo becomes a command companion in `genesis`, running the detected CLI, with the drafted
    welcome. Routing keeps mentions and command companions; the LLM pre-router's branches go.
  - **1.3b:** setup's credential step becomes the CLI chooser (detect, pick, or install).

**Done 2026-09-25, as one commit** (1.3a and 1.3b could not land apart: setup's credential step was
the last user of the engine's auth). Gone: `LLMEngine`, `GeminiEngine`, `LLMBackend`,
`LLMStreamCollector`, `BridgeServiceAI`, `AgentRouterLLM`, `AppState+PortAI`, the engine's auth
resolver, `ModelPicker`, `UsageView`, Keeper and its inspector, `companions.invoke`, the `ai.*`
methods and `port42.ai.complete`, heartbeats and `NewSpaceSheet`, the `.llm` and `.remote` modes,
the chrome's auth key and AI pause, and the settings AI tab's provider forms. `AgentAuth.swift`
became `Port42AuthStore.swift`: named secrets for `rest.call` and the gateway root secret, and it
deletes the engine's leftover credentials at launch. The Claude OAuth token Port42 injected into
companion terminals is no longer injected.

Routing: a message launches its targets directly. A companion's reply reaches only the companions
it @mentions; the pre-router that decided for unmentioned ones is gone, and launching all of them
would invite loops.

First run: setup finds Claude Code or Codex (or offers to install one), makes `genesis`, adds Echo
as a command companion on that CLI with the drafted brief, spawns its terminal with the first line
waiting (Claude) or the brief as the first turn (Codex), and the shell opens focused on it.

Migration v50 deletes LLM and remote companions with their memberships, drops the Keeper tables,
`token_usage` and `swimMessages`, and the heartbeat columns. Live on Dev3's real data: the old LLM
`echo` went, the seven command companions stayed, and the harness passed five of five.
`ai.complete` now answers `unknown_method`. Of the processes Dev3 launched, only Claude Code's own
re-executed sessions hold `CLAUDE_CODE_OAUTH_TOKEN`, from their own login; the shells Port42
prepared hold none. Suite 1203 green (171 removed tests covered removed features).

**Verified live by GM on Dev3, 2026-09-25:** name, pick Claude Code, land focused on Echo's terminal
with the opening line typed in, ask for a shader port, get one. The first request failed with Anthropic's
"Connection lost mid-response", outside Port42. Changes from that run:

- The boot check lines describe what now comes up: surfaces, the agents found on this Mac (a real
  result), and the port namespace. Draft copy for GM.
- The hand-off from setup into Echo's terminal is slower: a longer black and circle, a held beat of
  black while the CLI draws, then a fast reveal of the terminal, zoomed in.
- The dolphin breakout video that played on the first zoom out is gone, with its preloader and file.
  Leaving the terminal for the desktop just ends the first run.
- A port set as the desktop wallpaper paused itself, because the presentation reported it hidden on
  the desktop. It is now visible whenever a desktop is showing (gate in `PortPresentationTests`).

The agent-field columns (`provider`, `model`, `thinking*`, `providerBaseURL`) stay in the schema,
unused, for a follow-up.

**Decided (GM, 2026-09-25):** Echo is a command port, a Claude Code or Codex terminal, and its welcome
prompts the person to ask for something alive, such as a shader port. It no longer nudges toward
opening a terminal, since Echo is one. Setup detects both CLIs; with both, the person picks; with
neither, it offers an installer. Echo's welcome is drafted here for GM to edit.

### 1.4 The messaging system

- **App:** the rest of `SyncService`, `TunnelService`, `SpaceCrypto`, `AppleAuthService`, `AgentInvite`,
  `Port42Members`, `NgrokSetupSheet`; friends, typing, read receipts, member lists and join tokens in
  `AppState`, `ChatView`, `ConversationContent`, `QuickSwitcher` and `SetupView`.
- **Invites:** the space-invite and agent-invite payloads go. The flow stays for Phase 4: link grammar,
  deep-link accept path, clipboard, landing page.
- **Done 2026-09-25, ngrok and invites.** `TunnelService`, `NgrokSetupSheet`, `SpaceInvite` and
  `AgentInvite` are gone, with the settings sharing section, the chrome's remote-access globe, ngrok
  autostart and analytics, the switcher's invite-link paste, and `joinSpaceFromInvite`. Creating an
  invite was already unreachable, since nothing presented the ngrok sheet that built one. The deep-link
  handler keeps its door and logs what arrives; Phase 4's per-port invite lands there. Suite 1426
  green (the 15 removed tests were invite and key-exchange cases); harness five of five.
- **Done 2026-09-25, the sync client.** `SyncService`, `SpaceCrypto` and `AppleAuthService` are gone. So
  are every send, typing broadcast, join and read receipt that went through them. The incoming-message
  and presence handlers are gone, along with friends (remote humans), their direct messages and their
  switcher entries, remote typing and presence in the chat, and setup's dev-only Apple sign-in step
  and its boot line. The chat keeps its local companions' typing. Suite 1375 green (51 fewer: the
  crypto, sync-auth, Apple-auth and sync-envelope suites). Harness five of five, with one scenario 5
  timeout on the first run that passed twice on rerun (F18).
- **Schema (done 2026-09-25, v47):** drops `spaces.encryptionKey`, `spaces.syncEnabled` and
  `users.appleUserID`, with the fields from `Space` and `AppUser`. `messages.syncStatus` and
  `messages.senderOwner` go with the `messages` table in step 1.5. `users.publicKey` and
  `users.privateKey` stay for now: whether Phase 4's peer identity reuses them is GM's call. Live
  on Dev3's real data: 4 spaces, 1 user and 28 ports before and after, and the harness passed five of
  five. The pre-migration database is kept at the session scratchpad as `dev3-pre-v47.sqlite`.
- **Tests:** `ChannelCryptoTests`, `EncryptionIntegrationTests`, `SyncAuthTests`, `AppleAuthTests`,
  `SenderOwnerTests`, `Port42MembersTests` and the messaging cases of mixed suites.

### 1.5 The chat port

The one design in the phase. It needs GM's review before it is built, and nothing before it depends
on it.

- Every port has a chat, opened from an icon in its chrome (GM, 2026-09-25); there is no separate
  chat port. Its transcript is an append-only record in the storage service, keyed to that port (D1, D3).
- A companion attached to a scope subscribes to that port's chat. Membership (`agentSpaces`) migrates
  to subscriptions.
- A mention is an event on the chat port and carries the caller who sent it (F16). The mention router
  and the teleport hooks move off the `messages` table onto those events.
- A terminal port's chat is its companion's session: a message goes in as terminal input, the shim's
  end-of-turn hook posts the reply back.
- The native chat tile, `ChatView`, `ConversationContent`, inline ports, port fences (D11), the
  `[portref]` cards and the `messages` table go.
- **Design:** `design-chat-port.md`, decided by GM 2026-09-25 (history dropped, the panel slides down
  from the companion bar, unread lives in the bar). It sets five build steps.

**Step 1 done 2026-09-25: the transcript and its door.** `chat.post(port, text)` and
`chat.read(port, after, limit)` in `PortChat.swift`. `port` is `0` for the desktop, a space id, or a
port's id, udid or title, resolved to the port's one key. Each entry is a storage row in a scope
`storage.*` cannot name, so an entry is written only through `chat.post`. Its sender is the calling
principal (id, name, kind), and there is no sender-name argument (fixes F16 for chat). A post is
published on `port:<key>` as a new system event kind, `chat`, carrying the entry. At launch, a chat
whose port or space no longer exists is removed. Eight gates in `PortChatTests`, calibrated by
breaking attribution and the reap. Not yet verified live: the harness client must be re-enrolled on
the fresh Dev3.

### 1.6 Small, clearly right

- **F7 (done):** `ports.list` entries carry `createdByName` next to `createdBy`: the registered
  client's name, else the companion's. `createdBy` stays an id because other code reads it as one.
  Live: the scenario 1 port lists `harness-s1-claude`, and `nautilus s1 cpu` lists `swift-otter`.
- **Shim (done):** `sessionPin` adds nothing when the person's own arguments choose a session
  (`--resume`, `-r`, `--continue`, `-c`, `--session-id`, `--fork-session`).

**Decided (GM, 2026-09-25):**
- **F6:** a one-time migration deletes each `port_versions` row whose HTML is identical to the row
  before it for the same port. Every distinct version survives.
- **F8:** at every launch, a port whose space no longer exists is removed.
- **Signing keys:** `users.publicKey`, `users.privateKey` and their Keychain entry go. libp2p makes its
  own peer key.
- **Spike harnesses:** deleted, with their debug-menu entries and launch flags.
- **`port42-openclaw` and `port42-python`:** archived on GitHub.

**Done 2026-09-25.** Both repos archived. The five spike harnesses are deleted with their launch flags
and debug-menu entries; the Ghostty version probe and the live instruments (port units, rest/wake,
actor, main loop) stay, under a menu renamed "Debug Probes". v48 drops the users' key pair, and the
boot ceremony loses the three key lines that described it. v49 removes repeated versions. At launch,
ports whose space is gone are removed. Live on Dev3's real data: 2,162 version rows became 409, all
408 distinct versions kept plus one legitimate return to an earlier version, and 1 orphaned port
removed. Suite 1374 green; harness five of five. The database from before v48 is kept in the session
scratchpad.

## Verify

After every step: suite, Go suites, and the harness at five of five. After 1.3, a fresh data directory
runs the ceremony, detects the CLI and lands on Echo's terminal, once with each CLI. After 1.5,
scenario 1 passes at all three scopes and a transcript survives a restart.
