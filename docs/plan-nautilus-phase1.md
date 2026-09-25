# Nautilus Phase 1: remove what no scenario needs, and build the chat port

Detailed plan for Phase 1 of `plan-shell-only.md`. Scenario served: 1. Written 2026-09-25 against
`nautilus` at `872fae8`, with Phase 0 complete and all five scenarios passing.

## Goal

Port42 holds ports, a registry, grants and a door, and nothing else. The messaging system, the in-app
model and the memory service are gone. The native chat tile is replaced by a chat port that any scope
can carry: the desktop, a space, or one port.

## Order, and why

Pure removals first, each shippable alone and each leaving the harness at five of five. The chat port
comes last, because it is the one design in the phase and it replaces the thing scenario 1 runs
through today.

Each step is its own commit. Suite green, Go suites green, harness five of five, plans updated.

### 1.1 Retired spikes, the Keeper service, swims

- **Spikes:** `GhosttyProbe`, `PortDesktopSpike`, `PortResizeSpike`, `ScreenRecordSpike`,
  `GhosttyResizeSpike` (and its one test reference). Nothing else names them. `MainLoopProbe` and
  `GhosttyDebugHarness` stay: `Port42App` uses both, and the debug harness is a working tool.
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
- **Schema:** v48 drops `token_usage` and the LLM columns on `agents`, and the heartbeat columns on
  `spaces`.

**Deferred to GM:** the wording of Echo's welcome, which is product copy.

### 1.4 The messaging system

- **App:** the rest of `SyncService`, `TunnelService`, `SpaceCrypto`, `AppleAuthService`, `AgentInvite`,
  `Port42Members`, `NgrokSetupSheet`; friends, typing, read receipts, member lists and join tokens in
  `AppState`, `ChatView`, `ConversationContent`, `QuickSwitcher` and `SetupView`.
- **Invites:** the space-invite and agent-invite payloads go. The flow stays for Phase 4: link grammar,
  deep-link accept path, clipboard, landing page.
- **Schema:** v49 drops `spaces.encryptionKey`, `spaces.syncEnabled`, `users.publicKey`,
  `users.privateKey`, `users.appleUserID`, `messages.syncStatus`, `messages.senderOwner`.
- **Tests:** `ChannelCryptoTests`, `EncryptionIntegrationTests`, `SyncAuthTests`, `AppleAuthTests`,
  `SenderOwnerTests`, `Port42MembersTests` and the messaging cases of mixed suites.

### 1.5 The chat port

The one design in the phase. It needs GM's review before it is built, and nothing before it depends
on it.

- A chat is a web port that any scope can carry: port 0, a space, or a port. Its transcript is an
  append-only record in the storage service, keyed to that port (D1, D3).
- A companion attached to a scope subscribes to that port's chat. Membership (`agentSpaces`) migrates
  to subscriptions.
- A mention is an event on the chat port and carries the caller who sent it (F16). The mention router
  and the teleport hooks move off the `messages` table onto those events.
- A terminal port's chat is its companion's session: a message goes in as terminal input, the shim's
  end-of-turn hook posts the reply back.
- The native chat tile, `ChatView`, `ConversationContent`, inline ports, port fences (D11), the
  `[portref]` cards and the `messages` table go.
- **Open for GM:** how the chat port looks, and how a wider-scope chat shows while focused on a
  narrower one.

### 1.6 Small, clearly right

- **F7:** a companion's port shows its codename as `createdBy`, not its raw client id.
- **Shim:** a user's own `claude --resume` survives the session pin.

**Deferred to GM, because they delete data:** reaping the `port_versions` rows already written as
layout noise (F6), and reaping the panel whose space no longer exists (F8).

## Verify

After every step: suite, Go suites, and the harness at five of five. After 1.3, a fresh data directory
runs the ceremony, detects the CLI and lands on Echo's terminal, once with each CLI. After 1.5,
scenario 1 passes at all three scopes and a transcript survives a restart.
