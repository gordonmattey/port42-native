# Bug Report: messages.recent hangs after sustained API usage

**Date:** 2026-03-26
**Severity:** Medium — blocks external tooling, doesn't crash app
**Reproducible:** Yes

---

## Summary

`messages.recent` endpoint becomes permanently unresponsive after sustained message sending via the HTTP API. Other endpoints (`channel.list`, `messages.send`, `companions.list`) continue to work. The call accepts the TCP connection but never returns a response — times out after 30s.

## Reproduction Steps

1. Open Port42, create a channel with a companion (forge, claude-opus-4-6)
2. Send ~10 messages via the HTTP API over ~15 minutes:
   ```bash
   curl -s http://127.0.0.1:4242/call \
     -d '{"method":"messages.send","args":{"text":"@forge make me a pomodoro timer","channelId":"<id>"}}'
   ```
3. Companion responds to most messages, builds several ports (large HTML payloads)
4. After ~8-10 exchanges, `messages.recent` stops responding:
   ```bash
   # This hangs indefinitely:
   curl -s http://127.0.0.1:4242/call \
     -d '{"method":"messages.recent","args":{"count":3,"channelId":"<id>"}}'
   
   # These still work fine:
   curl -s http://127.0.0.1:4242/call -d '{"method":"channel.list"}'
   curl -s http://127.0.0.1:4242/call -d '{"method":"companions.list"}'
   curl -s http://127.0.0.1:4242/call -d '{"method":"messages.send","args":{"text":"test","channelId":"<id>"}}'
   ```
5. The app UI continues to work — messages are visible in the channel, companions respond. Only the API read path is stuck.

## Likely Trigger

**UPDATE: Reproduced twice.** The exact same message triggers it both times:

```
@forge I keep forgetting to drink water throughout the day
```

After sending this message, `messages.recent` hangs globally (all channels, not just sayitseeit). The message may or may not appear in the UI. After fix/restart, `messages.recent` works again — until the same message is re-sent, which triggers the hang again immediately.

This suggests the issue is not about sustained usage but about something specific in forge's response to this particular prompt.

**UPDATE 2: Forge DID respond.** The port is visible in the UI. The companion built a water reminder port successfully. So the issue is NOT in the response/streaming path — forge finished fine. The issue is in the **`messages.recent` read/serialization path**. Something about this port's HTML content breaks the JSON serialization when `messages.recent` tries to return it.

Possible causes:
- The port HTML contains characters that break JSON serialization (unescaped quotes, control characters, invalid UTF-8)
- The response payload exceeds an internal buffer size and the serializer hangs instead of erroring
- A regex or string processing step in the message serialization path enters catastrophic backtracking on this specific content
- The serialization runs on the main thread and blocks all subsequent `messages.recent` calls globally

## Additional Context

### Identity issue
Messages sent via `messages.send` from the HTTP API appear as the user ("gordon"), not as an external caller. This means:
- The companion sees them as user messages and responds
- But there's no way to distinguish API-sent messages from UI-typed messages
- Need: identity parameter in the API call (and go throguh existign permission mechanism - tihunjk ithsi is already hjow it works but idk)

### What was happening in the channel
- Channel: `sayitseeit` (id: `0AC0612D-E363-452F-98FC-3665060EA253`)
- Companion: forge (claude-opus-4-6)
- ~10 messages sent, forge built 4 ports (Pomodoro, Binary Search, Calories, Bill Split, Spanish Verbs)
- Each port response was a large `\`\`\`port` code fence with full HTML/CSS/JS
- The hang started after message ~9-10

### Endpoints tested during hang

| Endpoint | Status |
|----------|--------|
| `channel.list` | ✅ responds |
| `companions.list` | ✅ responds |
| `messages.send` | ✅ responds (send succeeds, message appears in UI) |
| `messages.recent` | ❌ hangs — accepts connection, never responds |
| `ports.list` | ✅ responds (tested earlier, untested during hang) |

### Environment
- Port42 v0.5.19
- macOS
- Companion: forge on claude-opus-4-6
- Messages sent via curl from Claude Code
