# Multi-Provider LLM

**Status:** Spec — not built
**Last updated:** 2026-03-21

---

## Why

Cost, capability, and preference. Some people run Gemini for the context window. Some run GPT-4o for code. Some want a local model tuned for Port42's tool use that never leaves the machine. Anthropic is the default and stays well-supported, but it shouldn't be the only option.

---

## Scope

Three provider families. All require tool use support.

| Provider | Protocol | Auth | Notes |
|----------|----------|------|-------|
| **Anthropic** | Anthropic API | Claude Code OAuth or API key | Existing. Thinking mode. |
| **Gemini** | Gemini API | API key from AI Studio | Native Google API. Different wire format but supports function calling and streaming. |
| **Compatible endpoint** | OpenAI API | API key (optional for local) | Any OpenAI-protocol endpoint. Custom base URL — covers Ollama, LM Studio, xAI, Together, etc. Not branded as "OpenAI." |

**Auth note — Gemini CLI OAuth:** Google explicitly prohibits using Gemini CLI OAuth credentials with third-party software and is actively detecting it (announced 2026-03-18). API key only. Get a free key from [AI Studio](https://aistudio.google.com).

**Deferred:** Cohere, Mistral native, AWS Bedrock, Azure OpenAI (Azure works via compatible endpoint with a custom base URL).

---

## Architecture

### Backend Protocol

`LLMEngine` becomes `AnthropicEngine`. A new `LLMBackend` protocol unifies all providers:

```swift
public protocol LLMBackend: AnyObject {
    func send(
        messages: [[String: Any]],
        systemPrompt: String,
        model: String,
        maxTokens: Int,
        tools: [[String: Any]]?,
        thinkingEnabled: Bool,
        thinkingEffort: String,
        delegate: LLMStreamDelegate
    ) throws

    func continueWithToolResults(
        results: [(toolUseId: String, content: [[String: Any]])],
        messages: [[String: Any]],
        systemPrompt: String,
        model: String,
        maxTokens: Int,
        tools: [[String: Any]]?,
        thinkingEnabled: Bool,
        thinkingEffort: String
    ) throws

    func cancel()
}
```

`ChannelAgentHandler` holds a `LLMBackend` instead of `LLMEngine`. A factory resolves the right implementation from `AgentConfig`:

```swift
func makeLLMBackend(for agent: AgentConfig) -> LLMBackend {
    switch agent.provider {
    case .anthropic:            return AnthropicEngine()
    case .gemini:               return GeminiEngine()
    case .compatibleEndpoint:   return CompatibleEngine(baseURL: agent.providerBaseURL)
    case nil:                   return AnthropicEngine()  // legacy
    }
}
```

### Provider Enum

```swift
public enum LLMProvider: String, Codable {
    case anthropic          // existing
    case gemini             // Google Gemini native API
    case compatibleEndpoint // OpenAI protocol with custom base URL (Ollama, xAI, LM Studio, etc.)
}
```

`AgentConfig` gets one new field:

```swift
var providerBaseURL: String?
// nil = provider default endpoint
// "http://localhost:11434/v1" = Ollama
// "https://api.x.ai/v1" = xAI
// "https://api.together.xyz/v1" = Together
```

This is what makes local models work — Ollama speaks the OpenAI protocol so `OpenAIEngine` handles it unchanged, pointed at localhost.

---

## Tool Schema Translation

`ToolDefinitions` currently returns Anthropic format. Needs a second output format. The translation happens in each engine, not in `ToolDefinitions` itself.

**Anthropic format (existing):**
```json
{
  "name": "crease_write",
  "description": "...",
  "input_schema": { "type": "object", "properties": {...} }
}
```

**OpenAI format:**
```json
{
  "type": "function",
  "function": {
    "name": "crease_write",
    "description": "...",
    "parameters": { "type": "object", "properties": {...} }
  }
}
```

**Gemini format:**
```json
{
  "name": "crease_write",
  "description": "...",
  "parameters": { "type": "object", "properties": {...} }
}
```
(Wrapped in a top-level `tools: [{ "function_declarations": [...] }]`)

`ToolDefinitions` adds a static method `openAIFormat() -> [[String: Any]]` and `geminiFormat() -> [[String: Any]]`. The existing `all` property stays Anthropic format. Each engine calls the format it needs.

---

## Response / Streaming Parsing

Each engine owns its own streaming parser. The `LLMStreamDelegate` protocol stays unchanged — all engines emit the same events to the delegate.

**OpenAI streaming:**
- SSE events: `data: {"choices": [{"delta": {"content": "...", "tool_calls": [...]}}]}`
- Tool call accumulation: `tool_calls` arrive as incremental deltas across multiple events, need to be reassembled
- Finish reason: `tool_calls` triggers tool execution

**Gemini streaming:**
- SSE events: `data: {"candidates": [{"content": {"parts": [...]}}]}`
- Function calls appear in `parts` as `{"functionCall": {"name": "...", "args": {...}}}`
- Streaming text in `parts` as `{"text": "..."}`

**Tool result continuation:**
- OpenAI: append `{"role": "assistant", "tool_calls": [...]}` then `{"role": "tool", "tool_call_id": "...", "content": "..."}`
- Gemini: append `{"role": "model", "parts": [{"functionCall": {...}}]}` then `{"role": "user", "parts": [{"functionResponse": {"name": "...", "response": {...}}}]}`

---

## Thinking / Extended Reasoning

| Provider | Mechanism | Control |
|----------|-----------|---------|
| Anthropic | `"thinking": {"type": "adaptive"}` + `effort` header | Per-companion toggle + effort (existing) |
| OpenAI | Model choice: o1, o3, o4-mini (always reasons) | No toggle needed — pick the model |
| Gemini | `thinkingConfig: { thinkingBudget: N }` in request | Budget slider (0 = off, 1024+ = on) — Phase 2 |

For now: thinking toggle only shows for Anthropic companions. OpenAI reasoning is implicit in o-series model selection. Gemini thinking deferred to Phase 2.

---

## Auth

One API key per provider stored in Keychain. Same pattern as current Anthropic API key.

| Provider | Keychain item | Default |
|----------|--------------|---------|
| Anthropic | existing (Claude Code OAuth or `port42.apikey`) | Existing |
| OpenAI-compatible | `port42.apikey.openai` | — |
| Gemini | `port42.apikey.gemini` | — |

Custom base URL companions (Ollama, xAI, etc.) use the OpenAI key slot by default, but can be configured to use no key (Ollama) or a separate key. The `providerBaseURL` field on `AgentConfig` is enough — `OpenAIEngine` checks if the URL is localhost and skips the Authorization header if no key is configured.

`AgentAuth.swift` gains methods:
- `openAIAPIKey() -> String?`
- `geminiAPIKey() -> String?`
- `saveOpenAIAPIKey(_ key: String)`
- `saveGeminiAPIKey(_ key: String)`

---

## Model Picker

Replace the fixed haiku/sonnet/opus picker with a provider-aware component.

**Per-provider model lists:**

```
Anthropic:
  claude-haiku-4-5      fast · cheap
  claude-sonnet-4-6     balanced
  claude-opus-4-6       best · costly

Compatible endpoint:
  [model name]          free text — type llama3.2, mistral, gpt-4o, etc.

Gemini:
  gemini-2.0-flash      fast · cheap
  gemini-2.5-flash      balanced
  gemini-2.5-pro        best · costly
```

The picker is provider-aware: when provider changes in the companion sheet, the model list updates to match.

For OpenAI-compatible with a custom base URL (Ollama), the model list shows a text field instead of fixed options — the user types `llama3.2`, `mistral`, etc.

---

## Settings UI (SignOutSheet)

The `aiConnectionSection` is renamed from "Claude connection" to "AI connection" and becomes a multi-provider accordion. Each provider row expands to show its auth controls.

```
AI connection
  ◆ Anthropic  [connected: Claude Code OAuth, expires 2h 14m]   ▾
     [auto] [manual]  ...existing auth UI unchanged...

  ○ Gemini     [not configured]                                  ▾
     Paste your Gemini API key from AI Studio:
     [________________________]  [save]  [test]

  ○ Compatible  [not configured]                                 ▾
     Base URL: [http://localhost:11434/v1_____________]
     API key (optional): [_____________________________]  [save]
```

- `◆` = configured, `○` = not configured
- Anthropic row: existing auth UI unchanged (auto-detect / manual, OAuth expiry, test button)
- Gemini row: simple API key paste + test (no auto-detect — Gemini CLI OAuth is prohibited)
- Compatible row: base URL field + optional API key, save persists both to UserDefaults/Keychain
- Each row independent — configuring Gemini doesn't affect Anthropic

---

## Boot BIOS Sequence (SetupView)

The auth step currently only presents Anthropic options. With multi-provider, a user who only has a Gemini API key hits the boot flow and has no valid path.

**Change:** Add Gemini as an equal option in the `authOptionsContent` step alongside the existing Anthropic options.

```
Neural bridge requires an AI connection.
Choose your connection method:

  ○ Claude subscription       (auto-detect from Claude Code)
       ↳ [detected accounts / manual OAuth key]

  ○ Anthropic API key         (paste sk-ant-...)

  ○ Gemini API key            (paste from AI Studio)
       ↳ [paste your Gemini API key]

  ○ Compatible endpoint       (Ollama, xAI, LM Studio, any OpenAI-protocol API)
       ↳ Base URL: [http://localhost:11434/v1_______]
          API key (optional): [_____________________]
```

- Selecting Gemini shows a `SecureField` for the key — same UX as the existing API key option
- Selecting Compatible shows a base URL field + optional API key field. Base URL is required to proceed; key is optional (Ollama needs none)
- The selected provider's credential is saved to `Port42AuthStore` on submit
- Boot auth check (`authStatus`) considers all providers — connected if any one has a valid credential

---

## Companion Create / Edit Sheet

Current flow:
1. Pick model (haiku/sonnet/opus)

New flow:
1. Pick provider (Anthropic / Gemini / Compatible)
2. If Compatible: enter base URL (e.g. `http://localhost:11434/v1`)
3. Pick model from provider-specific list (Compatible = free text)
4. If Anthropic: thinking toggle (existing)

Provider selector as a segmented row above the model picker:

```
[Anthropic] [Gemini] [Compatible]
```

If a provider has no key configured, selecting it shows an inline warning: "Add an API key in Settings to use this provider."

---

## DB Migration

`AgentConfig` stores `provider` (text, existing) and `providerBaseURL` (text, nullable, new). Migration `v23-provider-base-url` alters the agents table to add `providerBaseURL`.

No migration needed for existing companions — they all have `provider = "anthropic"` and `providerBaseURL = nil`, which routes to `AnthropicEngine` unchanged.

---

## Implementation Path

### Phase 1 — Gemini

#### Step 1 — `LLMBackend` protocol + `LLMEngine` conformance
- Extract `LLMBackend` protocol with `send`, `continueWithToolResults`, `cancel`
- `LLMEngine` conforms (no rename yet — avoids churn until compatible engine lands)
- `ChannelAgentHandler` holds `LLMBackend` instead of `LLMEngine`

Tests:
- All existing tests still pass (no regression)
- `LLMEngine` compiles as `LLMBackend` (structural, caught at build)

#### Step 2 — `GeminiEngine`
- SSE streaming parser
- Text delta accumulation → `llmDidReceiveToken`
- Function call parts → `llmDidRequestToolUse`
- `continueWithToolResults` builds correct `functionResponse` message format
- Auth: API key sent as `?key=` query param (not Authorization header)
- Error translation: Gemini 400/401/429 JSON → `LLMEngineError`

Tests:
- Text chunk parsing: single text part, multi-part response
- Function call parsing: single call, multiple calls in one response
- Mixed chunk: text + function call in same SSE event
- `continueWithToolResults` message format: `model` role with `functionCall` part, then `user` role with `functionResponse` part
- Auth: request URL contains `?key=` param, no Authorization header set
- Error translation: 401 → `.authExpired`, 429 → rate limit message, malformed body gracefully handled
- `finishReason = "STOP"` → `llmDidFinish`, function call present → `llmDidRequestToolUse`

#### Step 3 — `ToolDefinitions.geminiFormat()`
- Translate Anthropic tool schema to Gemini `function_declarations` format
- `input_schema` → `parameters`, wrapper structure correct
- `required` array preserved

Tests:
- Output structure: `[{"function_declarations": [...]}]`
- Spot-check `crease_write`: `required: ["content"]` present, no `input_schema` key
- Spot-check `position_set`: `required: ["read"]` present
- All tool names from `ToolDefinitions.all` appear in translated output
- No extra keys that would cause Gemini API to reject the request

#### Step 4 — `AgentProvider.gemini` + `providerBaseURL` + DB migration
- Add `.gemini` and `.compatibleEndpoint` to `AgentProvider`
- Add `providerBaseURL: String?` to `AgentConfig`
- Migration `v23-provider-base-url`: adds `providerBaseURL` column (nullable text)

Tests:
- Migration runs cleanly; existing agents have `providerBaseURL = nil`
- Existing `anthropic` agents unaffected — still route to `LLMEngine`
- `AgentConfig` with `provider: .gemini` round-trips through DB (save + fetch)
- `providerBaseURL` stores and retrieves correctly, nil when not set

#### Step 5 — Gemini API key in `Port42AuthStore`
- `saveCredential(_, provider: "gemini")` / `loadCredential(provider: "gemini")`
- Already supported by existing provider-keyed store — just a verification pass

Tests:
- Save and load `gemini` key round-trips correctly
- Returns `nil` when not set
- Anthropic key unchanged after gemini key operations

#### Step 6 — Provider selector + model picker (UI)
- Provider segmented row: Anthropic / Gemini / Compatible
- Model picker swaps list when provider changes; defaults to first model in new provider's list
- Thinking toggle only visible for Anthropic
- If selected provider has no key configured: inline warning

Tests: manual

#### Step 7 — Settings UI (SignOutSheet)
- Rename "Claude connection" → "AI connection"
- Add Gemini row: expandable, shows API key paste field + test button
- Anthropic row: existing UI unchanged, just wrapped in accordion
- `◆` / `○` configured indicator per provider

Tests: manual

#### Step 8 — Boot BIOS sequence (SetupView)
- Add Gemini API key as a parallel auth option in `authOptionsContent`
- Add "Skip for now" escape hatch
- Boot auth check considers all providers — connected if any one has a valid credential
- A provider credential is required to complete boot (same as today)

Tests: manual

**End-to-end test signal:** Create a Gemini 2.0 Flash companion. Have it write a crease mid-conversation. Open the crease inspector — crease appears with correct content.

---

### Phase 2 — Compatible endpoint (Ollama, xAI, etc.)

- `CompatibleEngine` — OpenAI-protocol streaming parser, tool schema translation, tool continuation
- `ToolDefinitions.openAIFormat()`
- Auth: optional API key (Ollama needs none), base URL stored on `AgentConfig.providerBaseURL`
- Settings UI: base URL + optional key fields
- Model picker: free text input for compatible endpoint companions
- UX shortcut: "Local (Ollama)" pre-fills `http://localhost:11434/v1`

Tests: same structure as Gemini steps 2–5 applied to OpenAI protocol.

**End-to-end test signal:** Ollama companion (llama3.2) writes a crease. Crease appears in inspector.

---

## Invariants

1. **Tool use is required.** No provider without function calling support. A companion that can't call tools can't write creases, set position, or use bridge APIs.
2. **Delegate protocol unchanged.** All engines emit the same events. `ChannelAgentHandler` doesn't know which provider is running.
3. **Existing companions untouched.** `provider = anthropic, providerBaseURL = nil` routes to `AnthropicEngine`. No migration of live data.
4. **Auth is per provider, not per companion.** One Gemini key for all Gemini companions. Same pattern as today.
5. **Thinking is provider-specific.** The toggle only appears for Anthropic. Gemini budget is Phase 2.
6. **No Gemini CLI OAuth.** Google explicitly prohibits third-party use of CLI credentials. API key only.
