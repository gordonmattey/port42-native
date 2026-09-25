# Design: the chat port (nautilus Phase 1 step 5)

Draft for GM's review, 2026-09-25. Nothing here is built. It turns the decisions already taken (D1, D2,
D3, D10, D11, and "chat is scoped to a port, every scope is a port") into a buildable shape, and puts
the four choices that are still open at the end.

## What exists today

- **One native chat tile per space.** It is a `PortPanel` with `isChatPort`, rendered by `ChatView` and
  `ConversationContent` (about 1,800 lines of SwiftUI). `port.create {type:"chat"}` reveals it; it
  cannot make a second one.
- **The transcript is the `messages` table**, observed by GRDB and rendered as a list, including inline
  ports from fences and a `[portref]` card for every port created in the space (101 of space-3's 139
  messages on Dev3).
- **A mention reaches a companion** through `routeMentionsToTerminals`: the app parses `@name`, finds
  the companion in `agentSpaces`, respawns its terminal if closed, and types the message into it. The
  shim's end-of-turn hook posts the reply back as a message.
- **What does not work:** a message sent through the API speaks as the person (F16), the chat cannot be
  shared with a browser guest because it is native, and its layout is the likeliest driver of the
  70-second stall (F18).

## The shape

**A chat is a web port.** Same primitive as a chart: HTML and JS, driven through the bridge, one id, one
token. It renders in the shell like any tile, and a browser guest can open it with a per-port invite
(D10) with nothing added. A shared chat is scenario 4 applied to a conversation.

**Its transcript is storage, keyed to the port** (D1, D3). An append-only list under the chat port's
own key, written only by the chat port itself. The port reloads it on mount, so it survives restart,
eviction and remount.

**Everything enters through the port's input.** A person typing, a companion replying, and an API
caller all `port.push` into the chat port. The push carries the caller's principal, so the port records
who actually said it (fixes F16). The port appends, renders, and publishes a `message` event.

**A mention is an event, and a companion is a subscriber.** The chat port publishes `mention` events
naming who was mentioned and who mentioned them. A companion attached to a scope is subscribed to that
scope's chat. The app's router keeps the subscriptions and does what `routeMentionsToTerminals` does
today: wake the companion's terminal and type the message in. `agentSpaces` becomes the list of
subscriptions.

**A reply goes back the same way.** The shim's end-of-turn hook pushes the reply into the chat port the
mention came from, as the companion's principal.

**Scopes.** One chat per space, as now. A terminal port's chat is its companion's session record (the
terminal port carries a chat; a message there is typed into the terminal). Port 0's chat is the
desktop-wide one, reachable from anywhere.

## What goes with it

`ChatView`, `ConversationContent`, inline-presented ports and port fences (D11), `[portref]` cards,
the `messages` table and its GRDB observation, `input_history`, and the unread counters built on
messages.

## Build order

1. The chat port itself (HTML and JS), transcript in storage, principal-stamped entries, `message` and
   `mention` events. Shipped behind the existing chat tile, so nothing changes yet.
2. The router subscribes companions to chat ports, and the shim's reply goes back as a push. Scenario
   1 switches to the chat port.
3. Swap the space's chat tile to the chat port, then delete the native chat and the `messages` table.
4. Terminal-port chats, then port 0's chat.

The harness gains a check at step 2: a reply lands in the chat port attributed to the companion, and a
message sent through the API is attributed to its caller.

## Open for GM

1. **The existing transcripts.** Drop them with the `messages` table (nothing in this plan preserves
   old data), or import each space's history into its chat port once.
2. **How a wider scope shows while you are focused on a narrower one.** For example, the space chat
   while one port is full-screen: a peek when it has something for you (as needs-attention does
   today), or a drawer you open.
3. **Where port 0's chat lives.** In the galaxy view, or as a tile on every desktop.
4. **Echo's copy for the first run** (step 1.3): the welcome currently describes "this conversation is
   itself a port, your DM with me, in your first space, genesis." Under this design Echo's conversation
   is its terminal port's chat, and the wording is yours.
